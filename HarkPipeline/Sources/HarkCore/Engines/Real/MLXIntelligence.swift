#if canImport(MLXLLM)
import Foundation
import MLXLLM
import MLXLMCommon

/// Tier-2 LLM adapter running an open-weights model via **MLX**. Two sanctioned uses (D35):
///  • Mac harness — measure Tier-2 model quality/speed/refusal behavior in the bake-off.
///  • iPhone FOREGROUND-ONLY Tier-2 test vehicle for pre-A17/AI-off devices (e.g. iPhone 14 Pro,
///    the hardware floor) — MLX is Metal-GPU-only and crashes when backgrounded, so the caller
///    must keep the app foreground/awake for the run. The SHIP path for Tier 2 remains a Core
///    ML/ANE port (background-safe); this exists so real devices can exercise AI features today.
///
/// Default model: **Qwen3-4B-4bit (Apache 2.0)** from mlx-community — passes the license gate.
/// On-device callers should pass a ~2B-class id (e.g. "mlx-community/Qwen3-1.7B-4bit", ~1GB) to
/// respect the ≤1.5GB Tier-2 weights gate and the jetsam ceiling.
/// MLX has no guided generation, so prompts use the same strict line format as the D24 fallback
/// (`TOPIC:/POINT:/QUOTE:`, `TLDR:/TAKEAWAY:/CHAPTER:/MOMENT:`) with the same parsing — one format,
/// two engines, directly comparable outputs. Qwen3 thinking mode is disabled via `/no_think` and
/// `<think>` blocks are stripped defensively.
/// App-managed model download: fetches a model repo's config/weights/tokenizer files from the
/// HF CDN with PLAIN URLSession into Application Support/HarkModels/<id>, verifying sizes against
/// the repo's file listing so interrupted downloads resume cleanly. Exists to bypass HubApi (see
/// `MLXIntelligence.load()`), and doubles as the shape of the eventual ModelAsset downloader.
public enum MLXModelStore {
    struct TreeEntry: Decodable {
        let path: String
        let size: Int?
        let type: String
    }

    public static func directory(for modelId: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("HarkModels", isDirectory: true)
            .appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Model weights shipped inside the app bundle at `Models/<sanitized-id>/` (D38 — the app
    /// bundles Qwen3-1.7B-4bit so first launch needs zero network). Returns nil when there is no
    /// such bundle folder (the Mac bench binary has none), which routes callers to the download
    /// path. Validity is a present `config.json` — the file `loadModel` reads first.
    public static func bundledDirectory(for modelId: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(modelId.replacingOccurrences(of: "/", with: "__"), isDirectory: true)
        let hasConfig = FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path)
        return hasConfig ? dir : nil
    }

    /// Bundled weights win (offline, instant); otherwise fall back to the URLSession download into
    /// Application Support. The app hits the bundle branch; the Mac bench hits the download branch.
    public static func resolve(modelId: String,
                               progress: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        if let bundled = bundledDirectory(for: modelId) { return bundled }
        return try await ensureDownloaded(modelId: modelId, progress: progress)
    }

    /// Idempotent: files already present with the expected byte size are skipped, so a killed
    /// download resumes where it left off and subsequent loads are offline.
    public static func ensureDownloaded(modelId: String,
                                        progress: (@Sendable (String) -> Void)? = nil) async throws -> URL {
        let dir = try directory(for: modelId)
        let treeURL = URL(string: "https://huggingface.co/api/models/\(modelId)/tree/main")!
        let (data, _) = try await URLSession.shared.data(from: treeURL)
        let entries = try JSONDecoder().decode([TreeEntry].self, from: data)
        let wanted = entries.filter { e in
            e.type == "file" && (e.path.hasSuffix(".json") || e.path.hasSuffix(".safetensors")
                                 || e.path.hasSuffix(".model") || e.path.hasSuffix(".txt"))
        }
        for entry in wanted {
            let dest = dir.appendingPathComponent(entry.path)
            if let size = entry.size,
               let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
               (attrs[.size] as? Int) == size {
                continue
            }
            progress?(entry.path)
            let src = URL(string: "https://huggingface.co/\(modelId)/resolve/main/\(entry.path)")!
            let (tmp, response) = try await URLSession.shared.download(from: src)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw MLXIntelligence.EngineError.downloadFailed(entry.path)
            }
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        return dir
    }
}

public actor MLXIntelligence: EpisodeIntelligenceEngine {
    public let identifier: String
    public let contextTokenLimit: Int
    public let approxResidentBytes: Int
    private let modelId: String
    private var model: ModelContext?

    public init(modelId: String = "mlx-community/Qwen3-4B-4bit",
                contextTokenLimit: Int = 4096,   // matched to FM windowing for apples-to-apples quality comparison
                approxResidentBytes: Int = 2_500 * 1_000_000) {
        self.modelId = modelId
        self.identifier = "mlx-\(modelId.split(separator: "/").last.map(String.init) ?? modelId)"
        self.contextTokenLimit = contextTokenLimit
        self.approxResidentBytes = approxResidentBytes
    }

    public func load() async throws {
        guard model == nil else { return }
        // Weights resolve from the app bundle first (D38 — shipped inside the app, offline), else
        // download into Application Support (Mac bench). The tokenizer loads from the same local
        // directory via swift-transformers.
        let dir = try await MLXModelStore.resolve(modelId: modelId)
        model = try await loadModel(from: dir, using: HarkTokenizerLoader())
    }

    public func unload() async {
        model = nil
    }

    /// ChatSession's default GenerateParameters has maxTokens: nil — UNLIMITED generation. Small
    /// 4-bit models routinely fail to emit EOS on structured-output prompts and run away (a 3-min
    /// clip took 43+ min live, 2026-07-09). Our line-format replies are short: cap hard, sample
    /// near-greedy, and penalize the repetition loops that quantized models fall into.
    private static let generateParameters = GenerateParameters(
        maxTokens: 768,
        temperature: 0.2,
        repetitionPenalty: 1.1,
        repetitionContextSize: 64
    )

    /// Internal (not private) so the shared-model ad detector (`MLXAdDetector`, D38) can issue its
    /// per-block verify calls through the same resident model instead of loading a second copy.
    func respond(instructions: String, prompt: String) async throws -> String {
        if model == nil { try await load() }
        guard let model else { throw EngineError.notLoaded }
        // enable_thinking:false is the chat-template-level off switch (Qwen3 honors it; other
        // templates ignore the key); "/no_think" stays as the in-band fallback for templates
        // that only implement the soft switch.
        let session = ChatSession(model, instructions: instructions + " /no_think",
                                  generateParameters: Self.generateParameters,
                                  additionalContext: ["enable_thinking": false])
        let start = Date()
        let raw = try await session.respond(to: prompt)
        if ProcessInfo.processInfo.environment["HARK_MLX_DEBUG"] != nil {
            let secs = Date().timeIntervalSince(start)
            FileHandle.standardError.write(Data(
                "[mlx] \(String(format: "%.1f", secs))s, \(raw.count) chars\(raw.contains("<think>") ? ", THINK-LEAK" : "")\n".utf8))
        }
        return Self.stripThinking(raw)
    }

    /// Remove Qwen3 `<think>…</think>` blocks if present.
    static func stripThinking(_ s: String) -> String {
        guard let open = s.range(of: "<think>") else { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let close = s.range(of: "</think>") {
            return (String(s[..<open.lowerBound]) + String(s[close.upperBound...]))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(s[..<open.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: MAP (same line format + parser as the FM D24 fallback)

    public func mapWindow(_ window: TranscriptWindow) async throws -> WindowNotes {
        let reply = try await respond(
            instructions: "You analyze one passage of a podcast transcript. Be terse and factual. Do not invent content that isn't present.",
            prompt: """
                Passage:
                \(window.text)

                Respond in EXACTLY this line format (no other text):
                TOPIC: <3-6 word topic label>
                POINT: <key point 1>
                POINT: <key point 2>
                QUOTE: <one short quotable line, or omit>
                """)
        var topic = "Untitled section"
        var points: [String] = []
        var quotes: [String] = []
        for line in reply.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("TOPIC:") { topic = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if l.hasPrefix("POINT:") { points.append(String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
            else if l.hasPrefix("QUOTE:") { quotes.append(String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces)) }
        }
        if points.isEmpty { throw EngineError.unparseableReply(String(reply.prefix(120))) }
        return WindowNotes(windowId: window.id, startMs: window.startMs, endMs: window.endMs,
                           topicLabel: topic, salientPoints: points, quotableLines: quotes)
    }

    // MARK: REDUCE

    public func reduce(notes: [WindowNotes], adFreeText: String) async throws -> EpisodeDigest {
        let brief = notes.map { n in
            "• [\(msToClock(n.startMs))] \(n.topicLabel): \(n.salientPoints.joined(separator: "; "))"
        }.joined(separator: "\n")
        let reply = try await respond(
            instructions: "You synthesize an episode-level digest from ordered per-section notes. Titles only — never fabricate timestamps or content not in the notes.",
            prompt: """
                Section notes (chronological):
                \(brief)

                Respond in EXACTLY this line format (no other text):
                TLDR: <1-2 sentence summary>
                TAKEAWAY: <takeaway>
                CHAPTER: <chapter title>
                MOMENT: <key moment title>
                (repeat TAKEAWAY/CHAPTER/MOMENT lines as needed)
                """)
        var tldr = ""; var takeaways: [String] = []; var chapterTitles: [String] = []; var momentTitles: [String] = []
        for line in reply.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("TLDR:") { tldr = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            else if l.hasPrefix("TAKEAWAY:") { takeaways.append(String(l.dropFirst(9)).trimmingCharacters(in: .whitespaces)) }
            else if l.hasPrefix("CHAPTER:") { chapterTitles.append(String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces)) }
            else if l.hasPrefix("MOMENT:") { momentTitles.append(String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces)) }
        }
        if tldr.isEmpty && takeaways.isEmpty { throw EngineError.unparseableReply(String(reply.prefix(120))) }

        // Structural timestamp anchoring — same policy as the FM adapter (the LLM never emits ms).
        var chapters: [Chapter] = []
        if !notes.isEmpty, !chapterTitles.isEmpty {
            let stride = max(1, notes.count / chapterTitles.count)
            for (i, title) in chapterTitles.enumerated() {
                let startNote = notes[min(i * stride, notes.count - 1)]
                let endMs = (i + 1 < chapterTitles.count) ? notes[min((i + 1) * stride, notes.count - 1)].startMs : (notes.last?.endMs ?? startNote.endMs)
                chapters.append(Chapter(title: title, startMs: startNote.startMs, endMs: max(endMs, startNote.endMs)))
            }
        }
        let keyMoments: [KeyMoment] = momentTitles.compactMap { title in
            guard let best = notes.max(by: { matchScore(title, $0) < matchScore(title, $1) }) else { return nil }
            return KeyMoment(title: title, startMs: best.startMs, endMs: best.endMs)
        }
        return EpisodeDigest(summary: EpisodeSummary(tldr: tldr, takeaways: takeaways),
                             keyMoments: keyMoments, chapters: chapters)
    }

    // MARK: SNIP ENRICHMENT

    public func enrichSnip(_ request: SnipEnrichmentRequest) async throws -> SnipEnrichment {
        let reply = try await respond(
            instructions: "You turn a saved podcast excerpt into a shareable snip card. Faithful, punchy, no hype.",
            prompt: """
                Excerpt:
                \(request.excerpt)

                Respond in EXACTLY this line format (no other text):
                CATEGORY: <one of: insight, quote, takeaway, question, story>
                TITLE: <punchy 4-8 word title>
                BULLET: <takeaway bullet 1>
                BULLET: <takeaway bullet 2>
                CLEANED: <the excerpt lightly cleaned of filler words>
                """)
        var category = "insight"; var title = ""; var bullets: [String] = []; var cleaned = request.excerpt
        for line in reply.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("CATEGORY:") { category = String(l.dropFirst(9)).trimmingCharacters(in: .whitespaces).lowercased() }
            else if l.hasPrefix("TITLE:") { title = String(l.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if l.hasPrefix("BULLET:") { bullets.append(String(l.dropFirst(7)).trimmingCharacters(in: .whitespaces)) }
            else if l.hasPrefix("CLEANED:") { cleaned = String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
        }
        return SnipEnrichment(category: SnipEnrichment.Category(rawValue: category) ?? .insight,
                              title: title.isEmpty ? String(request.excerpt.prefix(40)) : title,
                              bullets: bullets, cleanedExcerpt: cleaned)
    }

    public func nameSpeakers(introText: String, clusters: [String]) async throws -> [String: String] {
        var map: [String: String] = [:]
        for (i, c) in clusters.enumerated() { map[c] = i == 0 ? "Host" : (i == 1 ? "Guest" : "Speaker \(i + 1)") }
        return map
    }

    private func matchScore(_ title: String, _ note: WindowNotes) -> Int {
        let words = Set(Scoring.normalizeWords(title))
        let hay = Set(Scoring.normalizeWords(note.topicLabel + " " + note.salientPoints.joined(separator: " ")))
        return words.intersection(hay).count
    }

    private func msToClock(_ ms: Int) -> String {
        let s = ms / 1000; return String(format: "%d:%02d", s / 60, s % 60)
    }

    public enum EngineError: Error, CustomStringConvertible {
        case notLoaded
        case unparseableReply(String)
        case downloadFailed(String)
        public var description: String {
            switch self {
            case .notLoaded: return "MLXIntelligence.load() did not populate the model"
            case .unparseableReply(let r): return "MLX reply did not match the line format: \(r)"
            case .downloadFailed(let f): return "model file download failed: \(f)"
            }
        }
    }
}
#endif
