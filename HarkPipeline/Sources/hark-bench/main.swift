import Foundation
import HarkCore
import AVFAudio
#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
#endif

// hark-bench — the P0 bake-off harness (PRD §9.3, §10).
//
// Subcommands:
//   hark-bench demo                         Run the full pipeline on synthetic audio with mock
//                                           engines and print a decision-record table. No inputs.
//   hark-bench real-demo                    Full pipeline with REAL Foundation Models (LLM + ad
//                                           detection) over a hand-authored fixture transcript.
//   hark-bench real-asr <audio> [--ref txt] Real SpeechTranscriber ASR over an audio file; prints
//                                           the transcript + RTF, and WER if --ref is given.
//   hark-bench run <manifest.json> [--json out.json]
//                                           Run the mock engine set over a real eval manifest.
//                                           (Swap in real engines in `Bench.engineSets` as wired.)
//   hark-bench score-asr <ref.txt> <hyp.txt>        Print WER between two transcripts.
//   hark-bench self-check                   Assert the architectural invariants hold; non-zero on failure.

enum Bench {
    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else { printUsage(); exit(2) }
        do {
            switch cmd {
            case "demo":        try await runDemo()
            case "real-demo":   try await runRealDemo()
            case "real-asr":    try await runRealASR(Array(args.dropFirst()))
            case "real-asr-whisperkit": try await runRealASRWhisperKit(Array(args.dropFirst()))
            case "real-full":   try await runRealFull(Array(args.dropFirst()))
            case "real-ads":    try await runRealAds(Array(args.dropFirst()))
            case "real-diarize": try await runRealDiarize(Array(args.dropFirst()))
            case "tier2-probe": try await tier2Probe(Array(args.dropFirst()))
            case "run":         try await runManifest(Array(args.dropFirst()))
            case "score-asr":   try scoreASR(Array(args.dropFirst()))
            case "score-ads":   try scoreAds(Array(args.dropFirst()))
            case "verify-ads":  try await verifyAds(Array(args.dropFirst()))
            case "score-recall": try await scoreRecall(Array(args.dropFirst()))
            case "enrich-probe": try await enrichProbe(Array(args.dropFirst()))
            case "self-check":  try await selfCheck()
            default:            printUsage(); exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        hark-bench — P0 bake-off harness
          demo                              run mock pipeline on synthetic audio, print table
          real-demo                         real Foundation Models over a fixture transcript
          real-asr <audio> [--ref txt] [--dump-text f]   real SpeechTranscriber ASR; WER if --ref
          real-asr-whisperkit <audio> [--model m] [--ref txt] [--dump-text f]
          real-full <audio> [--json out] [--artifacts out]   full pipeline, all-real engines
          run <manifest.json> [--json out]  run engine set over an eval manifest
          real-ads <audio> [--json out] [--tier2 [--tier2-model id]]   ASR+ad-detect (FM or MLX D38)
          score-asr <ref.txt> <hyp.txt>     WER between two transcripts
          score-ads <detected.json> <labels.json>   true ad-F1 vs ground-truth labels
          verify-ads <artifacts.json> [--json out] [--baseline out] [--tier2 [--tier2-model id]]   block verify over saved candidates
          score-recall <artifacts.json> <queries.json> [--k 3]   embeddings Recall@k on saved transcript
          enrich-probe <artifacts.json> [--count 3]  run snip enrichment on sampled excerpts
          self-check                        assert pipeline invariants (CI gate)
        """)
    }

    // MARK: - Engine registry (swap real adapters in here as they are built)

    static func engineSets(audioSeconds: Double) -> [EngineSet] {
        [
            .mock(label: "mock", audioSeconds: audioSeconds),
            // TODO(post-P0-freeze): EngineSet(label: "speechtranscriber+foundationmodels", asr: SpeechTranscriberEngine(), ...)
            // TODO(post-P0-freeze): EngineSet(label: "whisperkit-small+gemma-e2b-coreml", ...)
        ]
    }

    // MARK: - demo

    static func runDemo() async throws {
        let audioSeconds = 3600.0
        let dummyURL = URL(fileURLWithPath: "/dev/null")
        for set in engineSets(audioSeconds: audioSeconds) {
            let orch = PipelineOrchestrator(engines: set)
            let result = try await orch.process(episodeId: "demo-3600s", audioURL: dummyURL, audioSeconds: audioSeconds)
            let report = BakeoffReport(engineSetLabel: set.label, runs: [result.record])
            print(Reporting.table(report))
            if let d = result.artifacts.digest {
                print("digest: \(d.chapters.count) chapters, \(d.keyMoments.count) key moments (ad-validated), TL;DR: \(d.summary.tldr)")
            }
            print("ads detected: \(result.artifacts.ads.count) range(s); embeddings: \(result.artifacts.embeddings.count)\n")
        }
    }

    // MARK: - real-demo (REAL Apple Foundation Models over a fixture transcript)

    static func runRealDemo() async throws {
        guard #available(macOS 26.0, *) else { throw CLIError("real-demo needs macOS 26+") }

        let transcript = fixtureTranscript()
        let audioSeconds = Double(transcript.durationMs) / 1000.0

        // REAL intelligence engine; the rest stay mock (this milestone is the FM digest).
        let set = EngineSet(
            label: "foundationmodels",
            asr: MockSpeechToText(),                 // unused: we pass an official transcript
            diarizer: MockDiarizer(),
            embedder: MockEmbedder(),
            intelligence: FoundationModelsIntelligence(),
            adDetector: FoundationModelsAdDetector()      // REAL segment-level ad detection (E7 fix)
        )

        print("Running the pipeline with REAL Apple Foundation Models on a \(transcript.segments.count)-segment fixture…\n")
        let orch = PipelineOrchestrator(engines: set)
        let result = try await orch.process(episodeId: "fixture", audioURL: URL(fileURLWithPath: "/dev/null"),
                                            audioSeconds: audioSeconds, officialTranscript: transcript)

        guard let d = result.artifacts.digest else {
            print("digest was degraded away (memory guard) — unexpected on a fixture"); return
        }
        print("── EpisodeDigest (real, generated on-device) ──")
        print("TL;DR: \(d.summary.tldr)\n")
        print("Takeaways:")
        for t in d.summary.takeaways { print("  • \(t)") }
        print("\nChapters:")
        for c in d.chapters { print("  [\(clock(c.startMs))] \(c.title)") }
        print("\nKey moments (ad-validated):")
        for k in d.keyMoments { print("  [\(clock(k.startMs))] \(k.title)") }
        print("\nAd ranges detected: \(result.artifacts.ads.count)")
        for a in result.artifacts.ads { print("  [\(clock(a.startMs))–\(clock(a.endMs))] conf \(String(format: "%.2f", a.confidence))") }

        // Prove snip enrichment too (real, on-demand).
        let snipReq = SnipEnrichmentRequest(episodeId: "fixture",
                                            excerpt: transcript.segments[2].text + " " + transcript.segments[3].text,
                                            startMs: transcript.segments[2].startMs, endMs: transcript.segments[3].endMs)
        if #available(macOS 26.0, *) {
            let enrich = try await FoundationModelsIntelligence().enrichSnip(snipReq)
            print("\n── Snip enrichment (real) ──")
            print("  [\(enrich.category.rawValue.uppercased())] \(enrich.title)")
            for b in enrich.bullets { print("    • \(b)") }
        }
    }

    static func clock(_ ms: Int) -> String { let s = ms / 1000; return String(format: "%d:%02d", s / 60, s % 60) }

    /// A short realistic podcast transcript with a planted sponsor read in the middle.
    static func fixtureTranscript() -> Transcript {
        let lines: [String] = [
            "Welcome back to the show. Today we're digging into how small teams ship fast without burning out.",
            "My guest has scaled three startups, and the throughline is always the same: ruthless prioritization.",
            "The biggest mistake I see is teams treating every task as equally urgent. It flattens judgment.",
            "What worked for us was a weekly review where we killed anything that wasn't moving the core metric.",
            "This episode is brought to you by Acme Notes. Stay organized with Acme Notes — use promo code SHIP at acme dot com slash deal for twenty percent off your first year.",
            "So back to prioritization — the trick is to make the cost of saying yes visible to the whole team.",
            "We started tagging each new request with the thing it would delay. Suddenly people self-selected out.",
            "Right, scarcity forces honesty. And it protected the engineers' focus time, which compounded.",
            "One listener asked how to handle a boss who keeps adding scope. Name the tradeoff out loud, every time.",
            "Exactly. 'If we do X, Y slips to next month' — said calmly, repeatedly, changes the whole dynamic.",
            "Before we wrap, the one habit you'd give a new founder? Talk to five users before writing any code.",
            "Love it. Thanks for coming on, and thanks everyone for listening. See you next week."
        ]
        var segments: [TranscriptSegment] = []
        var t = 0
        for (i, line) in lines.enumerated() {
            let dur = 8000 + line.count * 40
            segments.append(TranscriptSegment(text: line, startMs: t, endMs: t + dur,
                                              speaker: i % 3 == 0 ? "SPEAKER_0" : "SPEAKER_1"))
            t += dur
        }
        return Transcript(episodeId: "fixture", source: .official, format: "fixture",
                          modelVersion: "hand-authored", segments: segments)
    }

    // MARK: - real-asr (REAL SpeechTranscriber over a real audio file)

    static func runRealASR(_ args: [String]) async throws {
        guard #available(macOS 26.0, *) else { throw CLIError("real-asr needs macOS 26+") }
        guard let audioPath = args.first else { throw CLIError("real-asr needs <audio path> [--ref ref.txt] [--dump-text out.txt]") }
        var refPath: String? = nil
        if let i = args.firstIndex(of: "--ref"), i + 1 < args.count { refPath = args[i + 1] }
        var dumpPath: String? = nil
        if let i = args.firstIndex(of: "--dump-text"), i + 1 < args.count { dumpPath = args[i + 1] }

        let audioURL = URL(fileURLWithPath: audioPath)
        let asr = SpeechTranscriberASR()
        try await asr.load()

        let sw = Stopwatch()
        let transcript = try await asr.transcribe(audioURL: audioURL)
        let wallClock = sw.seconds()
        let audioSeconds = Double(transcript.durationMs) / 1000.0
        let rtf = wallClock > 0 ? audioSeconds / wallClock : Double.infinity

        print("── SpeechTranscriber real-audio run ──")
        print("segments: \(transcript.segments.count)")
        for seg in transcript.segments {
            print("  [\(clock(seg.startMs))–\(clock(seg.endMs))] \(seg.text)")
        }
        print(String(format: "\naudio: %.2fs  wall: %.2fs  RTF: %.2fx", audioSeconds, wallClock, rtf))

        if let refPath {
            let ref = try String(contentsOf: URL(fileURLWithPath: refPath), encoding: .utf8)
            let wer = Scoring.wordErrorRate(reference: ref, hypothesis: transcript.fullText)
            print(String(format: "WER: %.2f%%  (gate: <10%%) -> %@", wer * 100, wer < 0.10 ? "PASS" : "FAIL"))
        }
        if let dumpPath {
            try transcript.fullText.write(to: URL(fileURLWithPath: dumpPath), atomically: true, encoding: .utf8)
            print("wrote \(dumpPath)")
        }
    }

    // MARK: - real-asr-whisperkit (WhisperKit comparison candidate)

    static func runRealASRWhisperKit(_ args: [String]) async throws {
        guard let audioPath = args.first else { throw CLIError("real-asr-whisperkit needs <audio path> [--model small.en] [--ref ref.txt] [--dump-text out.txt]") }
        var refPath: String? = nil
        if let i = args.firstIndex(of: "--ref"), i + 1 < args.count { refPath = args[i + 1] }
        var dumpPath: String? = nil
        if let i = args.firstIndex(of: "--dump-text"), i + 1 < args.count { dumpPath = args[i + 1] }
        var model = "small.en"
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count { model = args[i + 1] }

        let audioURL = URL(fileURLWithPath: audioPath)
        let asr = WhisperKitASR(modelVariant: model)

        print("Loading WhisperKit \(model) (downloads + Core ML compiles on first use)…")
        let loadSW = Stopwatch()
        try await asr.load()
        let loadSeconds = loadSW.seconds()

        let sw = Stopwatch()
        let transcript = try await asr.transcribe(audioURL: audioURL)
        let wallClock = sw.seconds()
        let audioSeconds = Double(transcript.durationMs) / 1000.0
        let rtf = wallClock > 0 ? audioSeconds / wallClock : Double.infinity

        print("── WhisperKit (\(model)) real-audio run ──")
        print("segments: \(transcript.segments.count)")
        for seg in transcript.segments {
            print("  [\(clock(seg.startMs))–\(clock(seg.endMs))] \(seg.text)")
        }
        print(String(format: "\nmodel load (one-time): %.2fs", loadSeconds))
        print(String(format: "audio: %.2fs  transcribe wall: %.2fs  RTF: %.2fx", audioSeconds, wallClock, rtf))

        if let refPath {
            let ref = try String(contentsOf: URL(fileURLWithPath: refPath), encoding: .utf8)
            let wer = Scoring.wordErrorRate(reference: ref, hypothesis: transcript.fullText)
            print(String(format: "WER: %.2f%%  (gate: <10%%) -> %@", wer * 100, wer < 0.10 ? "PASS" : "FAIL"))
        }
        if let dumpPath {
            try transcript.fullText.write(to: URL(fileURLWithPath: dumpPath), atomically: true, encoding: .utf8)
            print("wrote \(dumpPath)")
        }
    }

    // MARK: - real-full (the whole orchestrator, every engine real — the P0 end-to-end milestone)

    static func runRealFull(_ args: [String]) async throws {
        guard #available(macOS 26.0, *) else { throw CLIError("real-full needs <macOS 26+") }
        guard let audioPath = args.first else { throw CLIError("real-full needs <audio path> [--json out.json] [--tier2] [--diarizer fluid|speakerkit]") }
        let audioURL = URL(fileURLWithPath: audioPath)
        var jsonOut: String? = nil
        if let i = args.firstIndex(of: "--json"), i + 1 < args.count { jsonOut = args[i + 1] }
        let useTier2 = args.contains("--tier2")
        var diarizerChoice = "speakerkit"
        if let i = args.firstIndex(of: "--diarizer"), i + 1 < args.count { diarizerChoice = args[i + 1] }

        let intelligence: EpisodeIntelligenceEngine
        #if canImport(MLXLLM)
        // --tier2-model overrides the bench default (Qwen3-4B); pass the device-sized id
        // (mlx-community/Qwen3-1.7B-4bit) to preview exactly what an iPhone 14 Pro will run.
        var tier2Model = "mlx-community/Qwen3-4B-4bit"
        if let i = args.firstIndex(of: "--tier2-model"), i + 1 < args.count { tier2Model = args[i + 1] }
        intelligence = useTier2 ? MLXIntelligence(modelId: tier2Model) : FoundationModelsIntelligence()
        #else
        if useTier2 { throw CLIError("--tier2 requires the MLX dependency (see Package.swift note — removed for disk space)") }
        intelligence = FoundationModelsIntelligence()
        #endif
        let diarizer: DiarizationEngine = diarizerChoice == "fluid"
            ? FluidAudioDiarization()
            : SpeakerKitDiarization()
        let set = EngineSet(
            label: "all-real (\(useTier2 ? "tier2-mlx" : "foundationmodels")+\(diarizerChoice))",
            asr: SpeechTranscriberASR(),
            diarizer: diarizer,
            embedder: try NLContextualEmbeddingEngine(),
            intelligence: intelligence,
            adDetector: FoundationModelsAdDetector()
        )

        // Probe audio duration up front (orchestrator needs it for RTF reporting).
        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate

        print("Running the FULL pipeline with all-real engines on \(audioURL.lastPathComponent) (\(String(format: "%.1f", audioSeconds))s)…\n")
        let orch = PipelineOrchestrator(engines: set)
        let result = try await orch.process(episodeId: "real-full", audioURL: audioURL, audioSeconds: audioSeconds)

        print(Reporting.table(BakeoffReport(engineSetLabel: set.label, runs: [result.record])))
        print("\nTranscript (\(result.artifacts.transcript.segments.count) segments):")
        for seg in result.artifacts.transcript.segments {
            let speakerTag = seg.speaker.map { "[\($0)] " } ?? ""
            print("  [\(clock(seg.startMs))–\(clock(seg.endMs))] \(speakerTag)\(seg.text)")
        }
        print("\nAds detected: \(result.artifacts.ads.count)")
        for a in result.artifacts.ads { print("  [\(clock(a.startMs))–\(clock(a.endMs))] conf \(String(format: "%.2f", a.confidence))") }
        if let d = result.artifacts.digest {
            print("\nTL;DR: \(d.summary.tldr)")
            print("Takeaways:"); for t in d.summary.takeaways { print("  • \(t)") }
            print("Chapters:"); for c in d.chapters { print("  [\(clock(c.startMs))] \(c.title)") }
        } else {
            print("\ndigest: degraded/none")
        }
        print("embeddings: \(result.artifacts.embeddings.count) (dim \(result.artifacts.embeddings.first?.vector.count ?? 0))")

        // Always show per-stage notes — this is where refusal/failure diagnostics surface (E11).
        print("\nstage details:")
        for s in result.record.stages {
            let flag = s.degraded ? " [DEGRADED]" : ""
            print("  \(s.stage)\(flag): \(s.note ?? "-")")
        }

        if let out = jsonOut {
            var record = result.record
            record.episodeId = audioURL.deletingPathExtension().lastPathComponent
            let artifact = RunArtifactFile(record: record, ads: result.artifacts.ads)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(artifact).write(to: URL(fileURLWithPath: out))
            print("\nwrote \(out)")
        }
        if let i = args.firstIndex(of: "--artifacts"), i + 1 < args.count {
            let out = args[i + 1]
            let full = FullArtifactFile(episodeId: audioURL.deletingPathExtension().lastPathComponent,
                                        audioSeconds: audioSeconds,
                                        transcript: result.artifacts.transcript,
                                        ads: result.artifacts.ads,
                                        digest: result.artifacts.digest)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(full).write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
        }
    }

    // MARK: - real-ads (ASR + ad-detect only — the fast loop for ad-detector tuning)

    static func runRealAds(_ args: [String]) async throws {
        guard #available(macOS 26.0, *) else { throw CLIError("real-ads needs macOS 26+") }
        guard let audioPath = args.first else { throw CLIError("real-ads needs <audio path> [--json out.json] [--tier2 [--tier2-model id]]") }
        var jsonOut: String? = nil
        if let i = args.firstIndex(of: "--json"), i + 1 < args.count { jsonOut = args[i + 1] }
        // --tier2 scores the shipping MLX ad detector (keyword candidates + MLX verify pass, D38)
        // instead of the FM detector, so its ad-F1 can be measured against docs/eval/labels/.
        let useTier2 = args.contains("--tier2")
        var tier2Model = "mlx-community/Qwen3-1.7B-4bit"
        if let i = args.firstIndex(of: "--tier2-model"), i + 1 < args.count { tier2Model = args[i + 1] }

        let audioURL = URL(fileURLWithPath: audioPath)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let audioSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate

        let asr = SpeechTranscriberASR()
        try await asr.load()
        let transcript = try await asr.transcribe(audioURL: audioURL)
        await asr.unload()

        let detector: any AdDetectionEngine
        if useTier2 {
            #if canImport(MLXLLM)
            detector = MLXAdDetector(backing: MLXIntelligence(modelId: tier2Model,
                                                              approxResidentBytes: 1_300 * 1_000_000))
            #else
            throw CLIError("--tier2 requires the MLX dependency (see Package.swift)")
            #endif
        } else {
            detector = FoundationModelsAdDetector()
        }
        try await detector.load()
        let sw = Stopwatch()
        let ads = try await detector.detectAds(in: transcript)
        let secs = sw.seconds()

        print("── real-ads: \(audioURL.lastPathComponent) ──")
        print(String(format: "audio %.0fs, ad-detect wall %.1fs, %d range(s), %.1f%% of episode",
                     audioSeconds, secs,
                     ads.count, AdExclusion.adFraction(transcript, ads: ads) * 100))
        for a in ads { print("  [\(clock(a.startMs))–\(clock(a.endMs))]") }

        if let out = jsonOut {
            let record = EpisodeRunRecord(episodeId: audioURL.deletingPathExtension().lastPathComponent,
                                          audioSeconds: audioSeconds,
                                          stages: [StageMetric(stage: "ad-detect", engineId: detector.identifier, wallClockSeconds: secs)],
                                          quality: QualityScore())
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(RunArtifactFile(record: record, ads: ads)).write(to: URL(fileURLWithPath: out))
            print("wrote \(out)")
        }
    }

    // MARK: - real-diarize (ASR + one diarizer — the Phase-E comparison loop)

    static func runRealDiarize(_ args: [String]) async throws {
        guard #available(macOS 26.0, *) else { throw CLIError("real-diarize needs macOS 26+") }
        guard let audioPath = args.first else { throw CLIError("real-diarize needs <audio path> [--engine fluid|speakerkit]") }
        var engineChoice = "fluid"
        if let i = args.firstIndex(of: "--engine"), i + 1 < args.count { engineChoice = args[i + 1] }
        let audioURL = URL(fileURLWithPath: audioPath)

        let asr = SpeechTranscriberASR()
        try await asr.load()
        let transcript = try await asr.transcribe(audioURL: audioURL)
        await asr.unload()

        let diarizer: DiarizationEngine = engineChoice == "speakerkit" ? SpeakerKitDiarization() : FluidAudioDiarization()
        try await diarizer.load()
        let sw = Stopwatch()
        let labeled = try await diarizer.diarize(audioURL: audioURL, transcript: transcript)
        let secs = sw.seconds()
        await diarizer.unload()

        var counts: [String: Int] = [:]
        for seg in labeled.segments { counts[seg.speaker ?? "nil", default: 0] += 1 }
        let sorted = counts.sorted { $0.value > $1.value }
        print("── real-diarize [\(diarizer.identifier)]: \(audioURL.lastPathComponent) ──")
        print(String(format: "diarize wall %.1fs; %d clusters over %d segments", secs, counts.keys.filter { $0 != "nil" }.count, labeled.segments.count))
        for (label, n) in sorted { print("  \(label): \(n)") }
    }

    // MARK: - tier2 probe (raw MLX sanity check, bypasses the pipeline)

    /// Minimal generation probe to isolate MLX failures: wrong-kernel / wrong-tokenizer garbage
    /// shows up on ANY prompt; sampling-parameter bugs only with --hark-params.
    static func tier2Probe(_ args: [String]) async throws {
        #if canImport(MLXLLM)
        var modelId = "mlx-community/Qwen3-1.7B-4bit"
        if let i = args.firstIndex(of: "--model"), i + 1 < args.count { modelId = args[i + 1] }
        let prompt = args.first(where: { !$0.hasPrefix("--") && $0 != modelId })
            ?? "In one short sentence, what is a podcast?"
        let harkParams = args.contains("--hark-params")

        let dir = try await MLXModelStore.ensureDownloaded(modelId: modelId)
        let ctx = try await loadModel(from: dir, using: HarkTokenizerLoader())
        let params: GenerateParameters = harkParams
            ? .init(maxTokens: 768, temperature: 0.2, repetitionPenalty: 1.1, repetitionContextSize: 64)
            : .init(maxTokens: 256)
        let session = ChatSession(ctx, instructions: "You are terse. /no_think", generateParameters: params)
        let sw = Stopwatch()
        let reply = try await session.respond(to: prompt)
        print("── tier2-probe [\(modelId)] params=\(harkParams ? "hark" : "default") \(String(format: "%.1fs", sw.seconds())) ──")
        print(reply)
        #else
        throw CLIError("tier2-probe requires the MLX dependency")
        #endif
    }

    // MARK: - run manifest

    static func runManifest(_ args: [String]) async throws {
        guard let manifestPath = args.first else { throw CLIError("run needs a manifest path") }
        var jsonOut: String? = nil
        if let i = args.firstIndex(of: "--json"), i + 1 < args.count { jsonOut = args[i + 1] }

        let manifestURL = URL(fileURLWithPath: manifestPath)
        let manifest = try EvalManifest.load(from: manifestURL)
        let base = manifestURL.deletingLastPathComponent()

        for set in engineSets(audioSeconds: 3600) {
            var runs: [EpisodeRunRecord] = []
            for ep in manifest.episodes {
                let audioURL = resolve(ep.audioPath, base: base)
                let orch = PipelineOrchestrator(engines: EngineSet.mock(label: set.label, audioSeconds: ep.audioSeconds))
                var result = try await orch.process(episodeId: ep.id, audioURL: audioURL, audioSeconds: ep.audioSeconds)

                // Objective scoring where ground truth exists.
                var q = result.record.quality
                if let refPath = ep.referenceTranscriptPath {
                    let ref = try String(contentsOf: resolve(refPath, base: base), encoding: .utf8)
                    q.werPercent = Scoring.wordErrorRate(reference: ref, hypothesis: result.artifacts.transcript.fullText)
                }
                if let labeled = ep.labeledAdRanges {
                    let s = Scoring.adScore(predicted: result.artifacts.ads,
                                            labeled: labeled.map(\.asAdRange),
                                            episodeDurationMs: result.artifacts.transcript.durationMs)
                    q.adPrecision = s.adPrecision; q.adRecall = s.adRecall; q.adF1 = s.adF1
                }
                result.record.quality = q
                runs.append(result.record)
            }
            let report = BakeoffReport(engineSetLabel: set.label, runs: runs)
            print(Reporting.table(report))
            if let out = jsonOut {
                try Reporting.json(report).write(to: URL(fileURLWithPath: out))
                print("wrote \(out)")
            }
        }
    }

    // MARK: - score-ads (true F1 vs ground-truth labels — Phase B)

    static func scoreAds(_ args: [String]) throws {
        guard args.count >= 2 else { throw CLIError("score-ads needs <detected.json> <labels.json>") }
        let artifact = try RunArtifactFile.load(from: URL(fileURLWithPath: args[0]))
        let labels = try AdLabelFile.load(from: URL(fileURLWithPath: args[1]))
        let durationMs = Int(artifact.record.audioSeconds * 1000)

        // The ad-F1 gate scores the SPONSOR class only.
        let sponsorTruth = labels.ranges(in: .sponsor)
        let s = Scoring.adScore(predicted: artifact.ads, labeled: sponsorTruth, episodeDurationMs: durationMs)
        print("── ad scoring: \(labels.episodeId) (labeler: \(labels.labeler)) ──")
        print(String(format: "sponsor-class:  precision %.0f%%  recall %.0f%%  F1 %.2f   (gate: F1 ≥ 0.85)",
                     (s.adPrecision ?? 0) * 100, (s.adRecall ?? 0) * 100, s.adF1 ?? 0))

        // Product-facing secondary metric: ANY promotional content (sponsor+selfpromo+crosspromo)
        // as the positive class — flagging a host's own promo is defensible skip behavior, so the
        // strict sponsor-only number under-credits it.
        let allPromoTruth = labels.ranges(in: .sponsor) + labels.ranges(in: .selfpromo) + labels.ranges(in: .crosspromo)
        if allPromoTruth.count > sponsorTruth.count {
            let a = Scoring.adScore(predicted: artifact.ads, labeled: allPromoTruth, episodeDurationMs: durationMs)
            print(String(format: "any-promo:      precision %.0f%%  recall %.0f%%  F1 %.2f   (secondary)",
                         (a.adPrecision ?? 0) * 100, (a.adRecall ?? 0) * 100, a.adF1 ?? 0))
        }

        // Diagnostic: how much detected time actually fell on selfpromo/crosspromo (category confusion,
        // not hallucination) vs on unlabeled content (true false positives).
        for cat in [AdLabelFile.LabeledRange.Category.selfpromo, .crosspromo] {
            let truth = labels.ranges(in: cat)
            guard !truth.isEmpty else { continue }
            let sc = Scoring.adScore(predicted: artifact.ads, labeled: truth, episodeDurationMs: durationMs)
            print(String(format: "  detected-time overlapping %@: %.0f%% of that category covered", cat.rawValue, (sc.adRecall ?? 0) * 100))
        }
        let flaggedCount = labels.ranges.filter { $0.flagged == true }.count
        if flaggedCount > 0 { print("  ⚠ \(flaggedCount) label(s) flagged for human audit") }
    }

    // MARK: - score-asr

    static func scoreASR(_ args: [String]) throws {
        guard args.count == 2 else { throw CLIError("score-asr needs <ref.txt> <hyp.txt>") }
        let ref = try String(contentsOf: URL(fileURLWithPath: args[0]), encoding: .utf8)
        let hyp = try String(contentsOf: URL(fileURLWithPath: args[1]), encoding: .utf8)
        let wer = Scoring.wordErrorRate(reference: ref, hypothesis: hyp)
        print(String(format: "WER: %.2f%%  (gate: <10%%)  -> %@", wer * 100, wer < 0.10 ? "PASS" : "FAIL"))
    }

    // MARK: - verify-ads (second-pass block verification — the ad-precision experiment)

    static func verifyAds(_ args: [String]) async throws {
        guard #available(macOS 26.0, *) else { throw CLIError("verify-ads needs macOS 26+") }
        guard let artifactsPath = args.first else { throw CLIError("verify-ads needs <artifacts.json> [--json out.json] [--baseline out.json] [--tier2 [--tier2-model id]]") }
        var jsonOut: String? = nil
        if let i = args.firstIndex(of: "--json"), i + 1 < args.count { jsonOut = args[i + 1] }
        // --tier2 replays the saved candidates through the shipping MLX verify pass (D38) — the
        // fast prompt-iteration loop, no ASR re-run.
        let useTier2 = args.contains("--tier2")
        var tier2Model = "mlx-community/Qwen3-1.7B-4bit"
        if let i = args.firstIndex(of: "--tier2-model"), i + 1 < args.count { tier2Model = args[i + 1] }

        let full = try FullArtifactFile.load(from: URL(fileURLWithPath: artifactsPath))
        let verified: [AdRange]
        let detectorId: String
        let secs: Double
        if useTier2 {
            #if canImport(MLXLLM)
            let detector = MLXAdDetector(backing: MLXIntelligence(modelId: tier2Model,
                                                                  approxResidentBytes: 1_300 * 1_000_000))
            try await detector.load()
            detectorId = detector.identifier
            let sw = Stopwatch()
            verified = await detector.verifyAds(full.ads, in: full.transcript)
            secs = sw.seconds()
            #else
            throw CLIError("--tier2 requires the MLX dependency (see Package.swift)")
            #endif
        } else {
            let detector = FoundationModelsAdDetector()
            try await detector.load()
            detectorId = detector.identifier
            let sw = Stopwatch()
            verified = await detector.verifyAds(full.ads, in: full.transcript)
            secs = sw.seconds()
        }

        print("── verify-ads: \(full.episodeId) ──")
        print(String(format: "%d candidate block(s) -> %d verified (%.1fs, %.1fs/block)",
                     full.ads.count, verified.count, secs, full.ads.isEmpty ? 0 : secs / Double(full.ads.count)))
        for a in full.ads {
            let kept = verified.contains { $0.startMs == a.startMs && $0.endMs == a.endMs }
            print("  [\(clock(a.startMs))–\(clock(a.endMs))] \(kept ? "KEPT" : "dropped")")
        }

        func writeRunArtifact(_ ads: [AdRange], to path: String) throws {
            let record = EpisodeRunRecord(episodeId: full.episodeId, audioSeconds: full.audioSeconds,
                                          stages: [StageMetric(stage: "ad-verify", engineId: detectorId, wallClockSeconds: secs)],
                                          quality: QualityScore())
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(RunArtifactFile(record: record, ads: ads)).write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
        if let out = jsonOut { try writeRunArtifact(verified, to: out) }
        // Baseline candidates through the identical scoring path — the honest A/B.
        if let i = args.firstIndex(of: "--baseline"), i + 1 < args.count {
            try writeRunArtifact(full.ads, to: args[i + 1])
        }
    }

    // MARK: - score-recall (embeddings Recall@k on a saved transcript — the retrieval gate)

    static func scoreRecall(_ args: [String]) async throws {
        guard args.count >= 2 else { throw CLIError("score-recall needs <artifacts.json> <queries.json> [--k 3]") }
        var k = 3
        if let i = args.firstIndex(of: "--k"), i + 1 < args.count, let v = Int(args[i + 1]) { k = v }

        let full = try FullArtifactFile.load(from: URL(fileURLWithPath: args[0]))
        let queryFile = try RecallQueryFile.load(from: URL(fileURLWithPath: args[1]))

        let embedder = try NLContextualEmbeddingEngine()
        try await embedder.load()
        let segments = full.transcript.segments
        let embedSW = Stopwatch()
        let vectors = try await embedder.embed(segments.map(\.text))
        let embedSecs = embedSW.seconds()
        let embeddings = zip(segments, vectors).map { SegmentEmbedding(segmentId: $0.id, vector: $1) }
        let search = SemanticSearch(transcript: full.transcript, embeddings: embeddings)

        var hits = 0
        var totalSearchMs = 0.0
        var misses: [String] = []
        for q in queryFile.queries {
            let qv = try await embedder.embed([q.query])[0]
            let sw = Stopwatch()
            let top = search.topK(k, queryVector: qv)
            totalSearchMs += sw.seconds() * 1000
            let hit = top.contains { $0.segment.startMs < q.targetEndMs && $0.segment.endMs > q.targetStartMs }
            if hit { hits += 1 } else { misses.append(q.query) }
        }
        await embedder.unload()

        let recall = queryFile.queries.isEmpty ? 0 : Double(hits) / Double(queryFile.queries.count)
        print("── score-recall: \(full.episodeId) (\(queryFile.queries.count) queries, author: \(queryFile.author)) ──")
        print(String(format: "Recall@%d: %.2f (%d/%d)  (gate: ≥0.90 corpus-wide)", k, recall, hits, queryFile.queries.count))
        print(String(format: "embed: %d segments in %.1fs; search: %.2fms mean over %d vectors (gate: <10ms)",
                     segments.count, embedSecs, totalSearchMs / Double(max(1, queryFile.queries.count)), segments.count))
        for m in misses { print("  MISS: \(m)") }
    }

    // MARK: - enrich-probe (snip enrichment over sampled excerpts — task-quality evidence)

    static func enrichProbe(_ args: [String]) async throws {
        guard #available(macOS 26.0, *) else { throw CLIError("enrich-probe needs macOS 26+") }
        guard let artifactsPath = args.first else { throw CLIError("enrich-probe needs <artifacts.json> [--count 3]") }
        var count = 3
        if let i = args.firstIndex(of: "--count"), i + 1 < args.count, let v = Int(args[i + 1]) { count = v }

        let full = try FullArtifactFile.load(from: URL(fileURLWithPath: artifactsPath))
        // Sample N ~45s ad-free excerpts at evenly-spaced positions — what a real snip would grab.
        let clean = AdExclusion.adFreeSegments(full.transcript, ads: full.ads)
        guard !clean.isEmpty else { throw CLIError("no ad-free segments in artifact") }

        let intelligence = FoundationModelsIntelligence()
        try await intelligence.load()

        print("── enrich-probe: \(full.episodeId) (\(count) excerpts) ──")
        for i in 0..<count {
            let anchorIdx = clean.count * (i * 2 + 1) / (count * 2)   // 1/6, 3/6, 5/6 for count=3
            var excerptSegs: [TranscriptSegment] = []
            var idx = anchorIdx
            let windowStart = clean[anchorIdx].startMs
            while idx < clean.count, clean[idx].startMs - windowStart < 45_000 {
                excerptSegs.append(clean[idx]); idx += 1
            }
            let req = SnipEnrichmentRequest(episodeId: full.episodeId,
                                            excerpt: excerptSegs.map(\.text).joined(separator: " "),
                                            startMs: excerptSegs.first?.startMs ?? 0,
                                            endMs: excerptSegs.last?.endMs ?? 0)
            do {
                let enriched = try await intelligence.enrichSnip(req)
                print("\n[\(clock(req.startMs))–\(clock(req.endMs))] [\(enriched.category.rawValue.uppercased())] \(enriched.title)")
                for b in enriched.bullets { print("  • \(b)") }
                print("  excerpt(in):  \(req.excerpt.prefix(140))…")
                print("  cleaned(out): \(enriched.cleanedExcerpt.prefix(140))…")
            } catch {
                print("\n[\(clock(req.startMs))–\(clock(req.endMs))] ENRICH FAILED: \(error)")
            }
        }
    }

    // MARK: - self-check (architectural invariants — a CI gate)

    static func selfCheck() async throws {
        let orch = PipelineOrchestrator(engines: .mock(label: "self-check", audioSeconds: 1800))
        let result = try await orch.process(episodeId: "sc", audioURL: URL(fileURLWithPath: "/dev/null"), audioSeconds: 1800)

        try assertInvariant("transcript non-empty", !result.artifacts.transcript.segments.isEmpty)
        try assertInvariant("ads detected on planted sponsor read", !result.artifacts.ads.isEmpty)
        try assertInvariant("digest present", result.artifacts.digest != nil)

        // Ad-exclusion contract: no key moment may overlap a detected ad.
        let ads = result.artifacts.ads
        let leaks = (result.artifacts.digest?.keyMoments ?? []).filter { km in
            ads.contains { $0.overlaps(startMs: km.startMs, endMs: km.endMs) }
        }
        try assertInvariant("no key moment overlaps an ad (ad-exclusion contract)", leaks.isEmpty)

        // Embeddings cover every segment (find-a-moment works).
        try assertInvariant("one embedding per segment", result.artifacts.embeddings.count == result.artifacts.transcript.segments.count)

        // Chunker keeps every window within the model context budget.
        let chunker = Chunker.forContextLimit(4096)
        let windows = chunker.windows(for: result.artifacts.transcript)
        try assertInvariant("no window exceeds token budget", windows.allSatisfy { $0.estimatedTokens <= chunker.targetTokens || $0.segments.count == 1 })

        print("self-check: PASS (\(windows.count) windows, \(result.artifacts.ads.count) ads, \(result.artifacts.embeddings.count) embeddings)")
    }

    static func assertInvariant(_ label: String, _ cond: Bool) throws {
        if !cond { throw CLIError("INVARIANT FAILED: \(label)") }
        print("  ✓ \(label)")
    }

    static func resolve(_ path: String, base: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    }
}

struct CLIError: Error, CustomStringConvertible {
    let msg: String
    init(_ m: String) { msg = m }
    var description: String { msg }
}

await Bench.run()
