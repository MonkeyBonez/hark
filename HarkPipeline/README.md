# HarkPipeline — P0 pipeline core + bake-off harness

The standalone, macOS-runnable AI pipeline for Hark (codename), plus the CLI harness that
benchmarks candidate models to produce the **model-decision-record** that gates the rest of the
build (PRD `prd-hark-v2.md` §9, §10, phase P0).

This is **dev tooling — never shipped**. The app links `HarkCore`; `hark-bench` is the harness.

## What's here

```
Sources/HarkCore/           the pipeline — pure Foundation, no model deps, engines injected
  Model/                    Transcript/Segment, AdRange/Chapter/KeyMoment/Summary/Snip, Window
  Protocols/Engines.swift   SpeechToText, Diarization, Embedding, EpisodeIntelligence, AdDetection
  Pipeline/                 Chunker (map-reduce windows), AdExclusion contract, MemoryGuard,
                            PipelineOrchestrator (the spine), SemanticSearch, Tokenizer
  Bench/                    Metrics, Scoring (WER + ad-F1), EvalSet manifest, Reporting
  Engines/MockEngines.swift deterministic stubs so everything runs green with zero models
  Engines/Real/              REAL adapters (all confirmed working against live audio/models):
                              FoundationModelsIntelligence, FoundationModelsAdDetector (Apple
                              Foundation Models — zero download), SpeechTranscriberASR (Speech
                              framework — zero download), NLContextualEmbeddingEngine (NaturalLanguage
                              — zero download), WhisperKitASR + SpeakerKitDiarization (Argmax
                              `argmax-oss-swift` SPM dependency — downloads model weights on first use)
Sources/hark-bench/         the CLI (demo / real-demo / real-asr / real-asr-whisperkit / real-full /
                            run / score-asr / self-check)
Tests/HarkCoreTests/        invariant tests (mock) + RealEngineIntegrationTests.swift (live model
                            calls, XCTSkip-gated if Apple Intelligence is unavailable)
docs/                       eval-set spec, scoring rubric, decision log, device-twin spec
```

## Run it

```bash
swift build
swift test                                # 13 tests: 10 mock-pipeline invariants + 3 live-model integration
swift run hark-bench self-check           # asserts the architectural invariants (CI gate)
swift run hark-bench demo                 # full mock pipeline on synthetic audio → table
swift run hark-bench real-demo            # real Foundation Models over a fixture transcript
swift run hark-bench real-asr <audio> [--ref ref.txt] [--dump-text out.txt]     # SpeechTranscriber
swift run hark-bench real-asr-whisperkit <audio> [--model small.en|large-v3_turbo] [--ref r] [--dump-text o]
swift run hark-bench real-full <audio> [--json out.json] [--tier2] [--diarizer fluid|speakerkit]
swift run hark-bench real-ads <audio> [--json out.json]         # ASR+ad-detect only (tuning loop)
swift run hark-bench real-diarize <audio> [--engine fluid|speakerkit]   # diarizer head-to-head
swift run hark-bench score-ads detected.json docs/eval/labels/<ep>.json # true ad-F1 vs ground truth
swift run hark-bench score-asr ref.txt hyp.txt                          # WER between two transcripts
swift run hark-bench run docs/sample-manifest.json
```

`real-full` is the reference "everything wired together" example. Ground-truth ad labels live in
`docs/eval/labels/` (audit list: `docs/eval/AUDIT-LIST.md`). The MLX Tier-2 adapter is active
(mlx-swift-lm 3.31.4); `--tier2 [--tier2-model mlx-community/<id>]` selects it, and
`tier2-probe [--model id] [--hark-params] ["prompt"]` is the raw-generation sanity check.

**MLX on the Mac CLI needs one manual step.** SwiftPM CLI builds of mlx-swift cannot compile the
Metal kernel library (upstream issue ml-explore/mlx-swift#430; Xcode app builds are unaffected).
Without it, 4-bit models load fine but generate word salad — the quantized matmuls run on a
partial/JIT kernel set that computes garbage. After any fresh build or `.build` wipe, restore the
version-matched library (extracted from the `mlx==0.31.1` Python wheel, kept in the repo):

```sh
cp .eval-corpus/mlx-0.31.1.metallib .build/arm64-apple-macosx/release/mlx.metallib
```

If the mlx-swift pin moves, re-extract `lib/mlx.metallib` from the matching `mlx==<version>` wheel
(`pip download mlx==<version>`) — the kernel ABI must match the vendored mlx exactly.

## The one thing to understand: the orchestrator

`PipelineOrchestrator.process(...)` is the architectural spine. It encodes, in code (not in
prose the next engineer has to remember):

1. **Chunked map-reduce** — a 2h episode is 25–40k tokens; it never goes to the model in one pass.
   `Chunker.forContextLimit(model.contextTokenLimit)` sizes windows; map per window, reduce once.
2. **Single AI model resident at a time** — ASR is `unload()`ed before the LLM `load()`s (§9.6).
3. **Ad-exclusion contract** — the reduce stage only ever sees transcript **minus** detected ads,
   and key moments are validated against ads (§9.5). A TL;DR must never summarize a sponsor read.
4. **Degrade-don't-die** — if `MemoryGuard` trips, the LLM stage is skipped and the run still
   returns a transcript + embeddings. Audio/playback is never dropped (§9.6).
5. **Embeddings in parallel** with the LLM (they only need the transcript), so find-a-moment lights
   up during the first listen (§9.5).

## How to add a real engine (the post-P0 mechanical work)

Implement the relevant protocol in `Sources/HarkCore/Engines/` and register the `EngineSet` in
`Bench.engineSets(...)`. Nothing in the orchestrator changes. Candidates & criteria: see
`docs/DECISIONS.md` and PRD §9.3. Real adapters pull in network model downloads / entitlements —
that's why they're deliberately **not** in P0.
