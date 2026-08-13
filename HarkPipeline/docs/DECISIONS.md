# Decision log — HarkPipeline P0

Two kinds of entries: **[frozen]** architectural decisions already made in code (change only with
cause), and **[open]** empirical decisions the bake-off must fill in. Model-role winners go in the
"Model-decision-record" table at the bottom once the corpus runs.

## Architectural decisions [frozen] — made while scaffolding P0

| # | Decision | Rationale |
|---|---|---|
| D1 | **Engines are protocols; the orchestrator is model-agnostic.** `SpeechToText / Diarization / Embedding / EpisodeIntelligence / AdDetection`. | The whole point of P0 is a bake-off — swapping a model must not touch orchestration. Matches PRD's pluggable `EpisodeIntelligence`. |
| D2 | **Map-reduce lives in the orchestrator, not each engine.** `Chunker.forContextLimit()` sizes windows from the engine's own `contextTokenLimit`. | Every candidate (incl. Foundation Models @ 4,096 tok) gets identical chunking for free; no engine re-implements it. |
| D3 | **Ad-exclusion is enforced in code, not documented as a convention.** Reduce only ever receives `AdExclusion.adFreeText`; key moments run through `AdExclusion.validate`. | PRD §9.5 calls a sponsor-read summary a "trust catastrophe." Making it a data-flow invariant (with a test + self-check) means a future engine literally cannot violate it. |
| D4 | **Single-AI-model-resident enforced via `Engine.load()/unload()` lifecycle.** ASR is unloaded before the LLM loads. | PRD §9.6 jetsam discipline. The orchestrator owns lifecycle so no engine can leave weights resident. |
| D5 | **Degrade-don't-die is a code path with a test.** `MemoryGuard.decision` can skip the LLM stage; the run still returns transcript + embeddings. | PRD §9.6 "playback never dies to jetsam" is a build success criterion — encoded as `testDegradeDoesNotDropAudio`. |
| D6 | **Embeddings run concurrently with the LLM** via `async let`. | PRD §9.5 — find-a-moment lights up during first listen, not last. |
| D7 | **Snip time ranges are raw ms + denormalized excerpt, never segment FKs** (`SnipEnrichmentRequest`). | PRD §9.4 — re-transcription must never dangle a snip. |
| D8 | **AdDetection is its own protocol, separate from EpisodeIntelligence.** | Lets a tiny fine-tuned classifier replace the LLM for ads without touching summaries (PRD open Q2). |
| D9 | **Objective scoring only in `Scoring.swift` (WER, ad-F1). Summary quality is out-of-band (LLM-judge + human).** | Summarization has no cheap ground truth; pretending otherwise would fake the decision record. |
| D10 | **`HeuristicTokenizer` (chars/4) is an explicit stand-in** behind the `TokenEstimating` protocol. | Keeps P0 buildable with zero model deps; real tokenizer drops in when the real engine does. |
| D11 | **Language mode Swift 5 for the package.** | P0 is a scaffold/harness; strict Swift-6 concurrency proofs aren't worth the iteration cost yet. Types are still `Sendable`-annotated so the flip is cheap later. |
| D12 | **Foundation Models adapter uses guided generation** (`@Generable` mirror structs, kept private in the adapter). | Typed output instead of parsing free text; core types stay framework-free. Proven working on M4 Pro / macOS 26. |
| D13 | **The LLM never generates timestamps.** It produces titles/labels; all ms values are anchored structurally from window/segment bounds (`anchorChapters`/`anchorKeyMoments`). | LLMs are unreliable at exact ms; anchoring guarantees chapters/moments land on real audio positions. |
| D14 | **Fresh FM session per map window; reduce consumes compact per-window notes, not raw transcript.** | No cross-window context bleed; reduce fits ~4,096-token context even for a 3h episode. |
| D15 | **Ad detection is segment-granular and runs BEFORE the map; ad segments are removed from the transcript before chunking** (not filtered out of notes afterward). `AdDetectionEngine.detectAds(in:)` returns tight per-segment ranges; `mapWindow` no longer touches ads. | Fixes E7: a window that merely *contains* an ad keeps its real content. Verified — ad range went from `[0:00–2:25]` (whole intro) to `[0:47–1:02]` (just the sponsor read), and the TL;DR became accurate. Guarded by `testE7_AdInsideSingleWindowKeepsContent`. If the whole episode is ad, reduce degrades instead of hallucinating. |
| D16 | **Two more real adapters wired (Sonnet, following the FM template): `SpeechTranscriberASR`** (Speech framework's `SpeechAnalyzer`/`SpeechTranscriber`, macOS/iOS 26) and **`NLContextualEmbeddingEngine`** (NaturalLanguage framework, mean-pooled token vectors, dim 512). Both zero-download-class (SpeechTranscriber can lazily fetch its locale asset via `AssetInventory`; NLContextualEmbedding ships assets via `requestAssets()`). | These are the two Tier-1/zero-download candidates named in PRD §9.3's ASR and embedding bake-offs. API shapes were verified against the real macOS 26 SDK swiftinterface (not guessed) before writing the adapters — e.g. `SpeechTranscriber.results` yields per-result `CMTimeRange` via `attributeOptions: [.audioTimeRange]`, and each finalized result already segments at phrase boundaries, so no extra sentence-splitting logic was needed. |
| D17 | **`real-full` CLI command runs the ENTIRE orchestrator with real engines** (SpeechTranscriberASR + FoundationModelsAdDetector + FoundationModelsIntelligence + NLContextualEmbeddingEngine; diarizer nil) against a real audio file — the first true end-to-end proof, not just per-adapter smoke tests. | Confirmed on a TTS-generated 10.8s clip: 2.03x end-to-end RTF, correct segment-level ad detection `[0:05–0:10]` (the exact sponsor sentence pair), accurate TL;DR, real 512-dim embeddings. This is the reference example for wiring the next adapter (WhisperKit) into the same slot. |
| D18 | **Added `RealEngineIntegrationTests.swift`** — live (non-mocked) regression tests against Foundation Models + NLContextualEmbedding, gated with `XCTSkip` if Apple Intelligence is unavailable in the running environment (so CI without Apple Intelligence doesn't go red, but a dev Mac with it enabled gets real coverage). | Mock-only tests couldn't have caught E7 — this test tier exists specifically so a future adapter/prompt regression is caught automatically, not just by someone eyeballing `real-demo` output. |
| D19 | **Added `argmax-oss-swift` as an SPM dependency** (one package, two products: `WhisperKit` and `SpeakerKit`) — both PRD-named comparison candidates come from a single consolidated Argmax repo (the classic standalone `argmaxinc/WhisperKit` repo has been folded into this monorepo as of v1.0.0). | Confirmed by reading the package's actual `Package.swift` and source (not assumed) before adding the dependency — avoided guessing at a stale repo/API shape. |
| D20 | **`WhisperKitASR` and `SpeakerKitDiarization` are actors, not structs** — both hold a lazily-constructed model instance (`WhisperKit` / `SpeakerKit`) across `load()`/`transcribe()`/`unload()` calls, per the `Engine` lifecycle contract. | Found and fixed a real bug this way (E9, below) — a struct version that constructed the model inline inside `transcribe()` silently violated the single-model-resident lifecycle and corrupted timing measurements. |
| D21 | **`real-full` now runs FIVE real engines together** (SpeechTranscriberASR + SpeakerKitDiarization + FoundationModelsAdDetector + FoundationModelsIntelligence + NLContextualEmbeddingEngine) — zero mocks anywhere in the chain. | Confirmed on real audio: correct single-speaker diarization (no false speaker splits on single-voice audio — a real, if unglamorous, correctness check), correct segment-level ad detection, accurate summary, real embeddings. This is the reference "everything wired together" example for the next adapter (MLX/Gemma Tier-2 LLM) to slot into. |
| D22 | **Map/reduce refusal resilience** (see E11) — `mapWindow` failures are caught per-window and skipped; `reduce` failure falls back to `PipelineOrchestrator.extractiveFallbackDigest(from:)`, built with zero further model calls from the map notes already collected. | Closes the one real crash found while running against actual podcast audio; matches the PRD's own named risk mitigation instead of inventing a new one. |
| D23 | **Permissive guardrails + orchestrator retry-once** — all FM sessions use `SystemLanguageModel(guardrails: .permissiveContentTransformations)` (Apple's documented mode for transforming user content; no observed downside, kept); orchestrator retries a failed map window / reduce once before degrading. | Neither actually fixed refusals (E15) — kept as cheap defense-in-depth; the real fix is D24. |
| D24 | **Guided-generation → plain-text fallback in every FM call path** (see E16). Try `@Generable` first (typed, no parsing); on refusal, retry the same request as plain `respond()` with a strict line format and parse manually. Applied in `FoundationModelsIntelligence.mapWindow`/`reduce` and `FoundationModelsAdDetector.detectAds` per-batch. | Grounded in 7 controlled probes: plain generation accepts 100% of the content guided generation refuses. Layering: guided (best) → plain-parse (good) → orchestrator retry (transient errors) → skip/extractive (last resort). |
| D25 | **Ad aggregation tuned (the Phase B.4 measured iteration): merge gap 1.5s → 20s, then drop isolated ranges < 8s.** Rationale from ground truth: the detector catches 1–2 lines of a 20–90s read (scattered micro-ranges hurt recall AND precision); real reads are contiguous and distinct ad breaks are minutes apart, so a 20s bridge reconstructs whole reads while an 8s floor kills single-line false positives. Integration-test fixture updated to a realistic 25s ad (the old 5s planted ad was below any real ad's length). | Before → after measured on all 7 episodes vs ground-truth labels (see "True ad-F1" below). |
| D26 | **MLX Tier-2 dependency descoped for disk space, adapter kept.** Filling the dev machine's disk to zero mid-session (ENOSPC hard-blocked ALL tooling) forced the call: the MLX toolchain build (~3–5GB) + Qwen3 weights don't fit the machine's remaining free space alongside everything else. `MLXIntelligence.swift` is fully written (actor, `loadModel(id:)` + `ChatSession` API verified against mlx-swift-examples 2.29.1 source, same D24 line-format prompts as the FM fallback for directly comparable outputs, Qwen3 `<think>` handling) and sits behind `#if canImport(MLXLLM)`; re-adding the two Package.swift lines activates it. `real-full --tier2` errors cleanly when the dep is absent. | Tier-2 empirical row stays open — needs a machine with ~10GB free or an external drive for the model cache. |
| D27 | **FluidAudio diarization adapter wired** (`FluidAudioDiarization`, actor; API verified against FluidAudio v0.15.5 source: `DiarizerManager` → `DiarizerModels.downloadIfNeeded()` → `performCompleteDiarization`). Diarizer→transcript alignment factored into a shared `SpeakerAlignment` helper used by BOTH SpeakerKit and FluidAudio adapters — one alignment policy, comparable outputs. New `real-diarize <audio> --engine fluid\|speakerkit` CLI for the head-to-head. | Phase E comparison results below. |
| D28 | **Ads surfaced as visible "Sponsor break" chapters** — `ChapterAssembly.timeline(content:ads:)` deterministically merges detected AdRanges into the reduce-stage chapter list: content chapters split at ad boundaries and resume under the same title, overlapping ranges coalesce into one ad chapter, post-split fragments <10s are dropped (never-split chapters kept verbatim), and `userVerdict == .notAnAd` ranges vanish from the timeline. Wired post-reduce in the orchestrator on BOTH the LLM and extractive-fallback paths; the LLM never sees or titles ad content, so the ad-exclusion contract is untouched. 5 new tests incl. an end-to-end assertion that no content chapter overlaps a detected ad. | With measured precision stuck at ~20–33% (Phase B), auto-skip is trust-negative but visible flagging is trust-cheap: a false positive is a mislabeled chapter the listener ignores; a miss is an ordinary unflagged ad. This is the shipping ad surface for the Ask/Off modes and the natural collection point for `userVerdict` labels feeding the dedicated-classifier path (open Q2). PRD §7/§8.11/§9.5 updated. |

| D29 | **Second-pass block verification is now the ad detector's production default** (`FoundationModelsAdDetector(verifyPass: true)`): after D25 aggregation, each merged candidate block gets one focused "is this whole block a sponsor read?" call (guided → plain fallback, FAIL-OPEN on double refusal to protect the recall floor). `verify-ads` CLI + `--baseline` A/B path added. | Measured A/B on all 7 episodes, same download, same candidates: **precision 2–3x up on every episode, recall IDENTICAL on every episode** (verify never dropped a true positive). Sponsor-F1 0.52→**0.91** (founders-402, PASSES the ≥0.85 gate), 0.40→0.73, 0.19→0.39, 0.13→0.35, 0.30→0.40, 0.04→0.10; corpus median 0.19→0.39 on this download. Cost ~0.3–0.4s/block, 1.3–9.5s/episode. This was the "LLM-verify-pass over merged blocks" candidate named in the Phase B verdict — it is now confirmed as the production path (a dedicated classifier remains the option if the gate still isn't met after prompt iteration). |
| D30 | **Key moments anchor to a 60s window around the best note's midpoint**, not the whole note span. | Root cause of a silent product-killer found by LLM-judge review: notes span 10–20 min, so every key moment overlapped SOME ad range and `AdExclusion.validate` (correctly) dropped them — keyMoments was empty on 7/7 real-corpus runs. Verified fixed on a real episode re-run (4 moments survive, 60s spans). Known residual: keyword-tie in `matchScore` can anchor several moments to the same note. |
| D31 | **Tier-2 (MLX) empirical row formally DEFERRED out of P0** — risk accepted and recorded: devices without Apple Intelligence get the degrade-don't-die path (transcript + embeddings + keyword search, no digest) until Tier 2 ships in a post-P0 iteration. Reconfirmed D26's disk reality: the dev machine has ~8.6GB free; the MLX toolchain + weights need ~10GB headroom. `MLXIntelligence.swift` stays written and compile-gated; activation = 2 Package.swift lines + ~10GB disk. | P0's gate question — "is there A shippable intelligence tier?" — is answered by Tier 1 (Foundation Models, working, refusals closed). Tier 2 changes WHO gets intelligence, not whether the architecture works; holding P0 open for a disk cleanup buys no information the P1/P2 build needs. |
| D32 | **`enrichSnip` gets the D24 guided→plain fallback + a 10k-char excerpt clamp** (and the fallback strips markdown emphasis from titles). | Found live by the new `enrich-probe` CLI: 4 of 9 real-corpus excerpts REFUSED under guided generation (E16 applies to the snip path too — it had been fixed everywhere except here), plus one context overflow from an unclamped excerpt. After: 6/6 probes succeed, titles serviceable ("Petterfy's Rise and Fall", "AI and Design: The Future of Creativity"). |

| D33 | **Two independent length floors on ad *actioning* (user policy, 2026-07-09), orthogonal to detection labels.** (1) **Skip floor ≈30s** — `AdExclusion.minSkippableAdMs = 30_000` + `skippable(_:)` filter; only >30s detections are auto-skipped/Ask-prompted, short self-promos/segues/outros render but never interrupt (interruption costs more trust than the seconds saved). (2) **Chapter floor 60s** — `ChapterAssembly.minChapterMs = 60_000`; sub-minute ads never chapter or split content (stay "part of the chapter before"), and sub-minute LLM chapters are absorbed into a neighbor via `absorbShort`. Verify-pass prompt also now excludes host self-promotion from the ad class. | Rationale from Snehal's AUDIT-LIST review: 8 of 9 flagged items fall under one/both floors and become non-issues; only allin-ackman #7 (117s Ackman-describes-own-funds) is long enough to matter, and the verify-pass re-run did NOT drop it (a guest describing their own fund reads as promotional to a small model) — that residual is covered by the product surface (Ask default + visible chapter + one-tap "Not an ad"), deliberately not by overfitting the prompt to one example. Detection labels unchanged (selfpromo stays its own F1 class). Word-count was floated as an easier length proxy; kept ms since segments are already precisely timestamped. 20/20 tests (5 new/rewritten chapter cases incl. the two-floor independence case: a 45s ad is skippable but not chaptered). PRD §8.11 updated. |

| D34 | **Degrade-don't-die now covers engine UNAVAILABILITY, not just memory pressure.** The orchestrator's `.proceed` path called `load()` on the embedder/ad-detector/intelligence with a bare `try` — on a device without Apple Intelligence (or `.modelNotReady`), the throw failed the ENTIRE run and discarded the transcript ASR had already produced. Now each optional engine load is guarded: unavailability degrades that stage (ads → none, digest → skipped, embeddings → skipped) and the run completes with transcript + whatever else succeeded. New regression test `testEngineUnavailabilityDegradesInsteadOfFailing` (AI-off-device simulation: transcript + embeddings survive, digest nil, degraded stages recorded). | Found by Snehal asking whether the AI-off fallback "was working" during device testing — it was designed (PRD §9.3: fall back to Tier 2; D31: degraded path until Tier 2 ships) but the wiring hard-failed. Until Tier 2 ships, AI-off devices now correctly get transcript + embeddings + keyword search, no digest. 21/21 tests. |

| D35 | **Tier-2 ACTIVATED as a foreground-only on-device test vehicle** (user decision: test AI features on the iPhone 14 Pro floor device, which has no Apple Intelligence). (1) MLX dependency re-added, pinned `exact: 2.29.1` (disk now permits — D26 reversed). (2) App tier-selection in `ProcessingService.makeEngineSet()`: FM available → Tier 1; else MLX **Qwen3-1.7B-4bit** (~1GB, Apache-2.0, fits the ≤1.5GB gate) + `KeywordAdDetector` (new: the FM detector's high-precision keyword pre-pass promoted to a standalone engine + D25 aggregation) for ads. (3) `MLXModelStore`: model files fetched via PLAIN URLSession into Application Support/HarkModels with size-verified resume — because the transitive swift-transformers 1.0.0 pin **SIGBUS-crashes in HubApi's NSURLSession continuation** (hit live; upstream range `.upToNextMinor(1.0.0)` blocks the fixed 1.3.x) — and app-managed download is closer to the ship design (Apple-Hosted Background Assets) anyway. (4) Foreground-only discipline: MLX is Metal-GPU and dies on backgrounding, so `ProcessingService` disables the idle timer for the run; ship path for Tier 2 remains a Core ML/ANE port. (5) Xcode 26 requires the separate **Metal Toolchain component** (`xcodebuild -downloadComponent MetalToolchain`) or MLX shader compilation fails at build (CLI) / metallib missing at runtime; installed. Verified: iOS device build embeds `mlx-swift_Cmlx.bundle/default.metallib`. increased-memory-limit entitlement DEFERRED (personal signing team can't provision it); 1.7B fits the default ceiling. | Fills the Tier-2 activation half of D31; the Tier-2 QUALITY row still needs the bake-off run. 22/22 tests. |

| D36 | **MLX stack replaced: mlx-swift-lm 3.31.4 (mlx-swift 0.31.4), and the Mac-CLI garbage-generation root cause found.** The D35 stack (examples 2.29.1 → mlx-swift 0.29.1) generated **word salad** from 4-bit models in SwiftPM CLI builds — unbounded runaway generation (a 3-min clip ran 43+ min; a full episode 2h16m unfinished) because incoherent output never hits EOS. Isolation: same weights **coherent under Python mlx-lm 0.31.1** (214 tok/s), garbage under a minimal Swift probe (new `hark-bench tier2-probe`) with default *and* conservative sampling → not weights, not hardware, not params. Root cause: **SwiftPM CLI builds cannot produce MLX's Metal kernel library** (upstream ml-explore/mlx-swift#430, open) — 0.29.1's plugin emitted a *partial* metallib (zero `quantized*` kernels vs 252 in the Python wheel's), so quantized matmuls ran on runtime-JIT'd kernels computing garbage; 0.31.4 emits none at all. Fix: (1) dependency moved to **mlx-swift-lm 3.31.4** (LLM libs moved repos; brings fixed swift-transformers 1.3.3 — D35's HubApi SIGBUS landmine gone; API migration: `loadModel(from:using: #huggingFaceTokenizerLoader())`, `enable_thinking:false` template-level off switch). (2) Mac CLI runs use the **version-matched metallib extracted from the `mlx==0.31.1` Python wheel**, colocated as `mlx.metallib` next to the binary (durable copy: `.eval-corpus/mlx-0.31.1.metallib`; restore command in README). Xcode/iOS builds unaffected (Xcode compiles the shaders). (3) Hardening kept: `GenerateParameters(maxTokens: 768, temperature: 0.2, repetitionPenalty: 1.1)` — ChatSession's default is maxTokens **nil = unlimited**, the runaway amplifier. `HARK_MLX_DEBUG=1` prints per-call wall/chars/think-leaks. | Post-fix: LLM map calls 0.4–2s (were 5+ min runaways); 3-min clip end-to-end in 20s (9.2x RTF). 22/22 tests. |

| D37 | **Tier-2 model bake-off DECIDED: Qwen3-1.7B-4bit stays the on-device default** (validates D35's size-based pick with measured evidence). 4 candidates × 2 episodes (radiolab-forests control + founders-413, an FM-refuser), full pipeline, `/usr/bin/time -l` peak RSS: **Qwen3-1.7B** 1.4–1.5GB peak, 0 format failures, accurate TL;DRs both episodes, 4 chapters on founders, LLM total 3–6s/episode. **LFM2-1.2B DISQUALIFIED**: lightest (1.0–1.2GB) but failed the line-format contract on EVERY map window (6/6 dropped across both episodes) → no digest at all. **Llama-3.2-3B**: works but garbles names ("Sam Hinkey", "Melini Nad Kearney"), 2.3–2.4GB peak, no quality win over 1.7B. **Qwen3-4B**: best TL;DR framing, but 2.6–2.8GB peak — too close to the iPhone 14 Pro ~3GB jetsam ceiling (no increased-memory entitlement on personal signing, D35) and 2.4x the LLM wall time; stays the **Mac-bench default** for quality-ceiling comparisons. None of the 4 refused the FM-refuser episode — reconfirms E16: refusals were an FM-guided-generation problem, not a content problem. D28's Sponsor-break chapter appeared correctly in every model's timeline ([19:29] founders-413). | On-device default CONFIRMED (no ProcessingService change needed). Quality class: faithful-but-generic, same tier as FM's judged 3/5 — Tier 2 is a real degrade-path product, not a toy. Bake-off artifacts: `.eval-corpus/tier2/` (bakeoff.log, per-run JSON+artifacts, scorecard.py). |
| D38 | **App goes SINGLE-MODEL and BUNDLES the weights (user decision 2026-07-20).** The app drops Apple Foundation Models entirely and ships **one** LLM on every device — the D37 winner **Qwen3-1.7B-4bit** — with weights **bundled inside the app** (no first-use Hugging Face download). Rationale: one open model the team fully controls beats maintaining two divergent tiers, the hardware floor / AI-off devices (e.g. the user's iPhone 14 Pro) can't run FM anyway, and FM's refusal history — though root-caused/fixed (E16/D24) — motivated the move. **What changed:** (1) `ProcessingService.makeEngineSet()` is now one path — `MLXIntelligence` + `MLXAdDetector(backing:)` sharing ONE resident model — no FM import, no tier probe; a missing-MLXLLM build fails to compile (never silently ship digest-less). (2) New `MLXAdDetector` ports the D29 ad architecture off FM: keyword candidates + **per-line MLX classify** + **per-block MLX verify-pass** (line-format `VERDICT:`, fail-open), sharing the digest model so no second 1.1GB load (its `unload()` is a no-op; the map stage needs the model resident right after). (3) `MLXModelStore.bundledDirectory`/`resolve` load weights from the app bundle (`Models/<sanitized-id>/`) first, download only as the Mac-bench fallback; xcodegen `type: folder` resource on the Hark target only (HarkTwin excluded). (4) FM adapters kept in HarkCore for the Mac bench. (5) **Dropped the `MLXHuggingFace` macro** (`#huggingFaceTokenizerLoader()`): its compiler plugin builds/runs under SwiftPM but fails under **xcodebuild** ("macro … produced malformed response", even with `-skipMacroValidation`) — and Xcode is the app's build path, so the app wouldn't build. Replaced with a hand-written `HarkTokenizerLoader`/`HarkTokenizerBridge` (verbatim macro expansion over swift-transformers) → no plugin to trust/run, builds identically everywhere, one fewer product dependency. **Ad-F1 gate MEASURED before adoption** (`real-ads --tier2` + `score-ads`, 7 episodes): keyword-only candidates scored **0.00 everywhere** (host-read ads carry no keywords) → the per-line MLX pass is mandatory, not optional; with it, **median sponsor-F1 0.515** across the 6 sponsor-GT episodes (**> FM's 0.39**), but an **inverted profile — recall 51–99%, precision 16–44%** (a 1.7B over-flags company discussion). | Consequences: **~1GB install size**; **foreground-only processing on ALL devices** now (no background-safe tier behind MLX) until the Core ML/ANE port — the stated next step. Ad posture unchanged & safe: high recall suits D28 visible "Sponsor break" chapters; auto-skip stays **Ask/Off** (≥0.85 gate unmet); dedicated classifier (v1 Q2) is the path to the gate. Real gap: radiolab's short music-bed ads missed (recall 0). Model updates now coupled to app releases — revisit Apple-Hosted Background Assets when that bites. Future option: a super-small fast model for latency tasks (deferred). 26/26 tests. |

## P0-closeout measurements (2026-07-09, Phase F)

### LLM Tier-1 task quality — LLM-judge over all 7 real episodes (rubric: 1–5)

Judged by an independent frontier-model judge per episode, digest vs full transcript
(summary faithfulness / chapter sensibility / key-moment quality):

| Episode | faithful | chapters | moments | Hallucination found |
|---|---|---|---|---|
| allin-ackman | 2 | 1 | 1 | chapter title invents "public transportation"; tldr empty |
| founders-402 | 3 | 2 | 1 | subject name distorted ("Petter Fyfe" / "Pete Peterson") |
| founders-413 | 3 | 2 | 1 | none |
| lennys-1m | 3 | 2 | 1 | none (one overstated takeaway) |
| lennys-codex | 2 | 3 | 1 | fabricated "agile/risk-management" takeaway inverting the thesis |
| radiolab | 4 | 1 | 2 | none |
| restishistory | 2 | 1 | 1 | tldr+2 takeaways about Eleanor of Aquitaine (next-episode teaser only); "Podcast Transcript Analysis" meta-title chapters |
| **median** | **3** | **2** | **1**→(D30 fixes the structural zero) | 3/7 episodes had ≥1 hallucination |

Reading: **coverage is full-span on 6/7** (the chunked map-reduce architecture works) and nothing
is unsafe, but Tier-1 quality is **generic-but-faithful at best (3/5), with real hallucinations on
3/7** — summaries name too few specifics, chapters collapse to 3–4 repeated generic titles, and
proper-noun fidelity is weak (ASR+FM compound: Peterffy→"Pete Peterson"). Key-moment zero was a
pipeline bug (D30), now fixed; chapter quality is the next lever (more titles requested + better
anchoring). Snip enrichment after D32: 6/6 succeed, titles 3–4/5. This row is now MEASURED; it
informs, not gates, P0 exit (quality iteration continues through P2/P3 on recorded fixtures).

### Embeddings retrieval — Recall@3 on agent-authored paraphrase queries (49 queries / 7 episodes)

| Episode | Recall@3 | mean search |
|---|---|---|
| allin-ackman | 0.29 (2/7) | 0.37ms @ 405 vec |
| founders-402 | 0.43 (3/7) | 0.36ms @ 404 vec |
| founders-413 | 0.86 (6/7) | 0.47ms @ 501 vec |
| lennys-1m | 0.57 (4/7) | 1.08ms @ 1293 vec |
| lennys-codex | 0.57 (4/7) | 0.95ms @ 995 vec |
| radiolab | 0.57 (4/7) | 0.21ms @ 259 vec |
| restishistory | 0.57 (4/7) | 0.42ms @ 540 vec |
| **corpus** | **0.55 (27/49)** — **FAILS ≥0.90 gate** | all ≪10ms gate ✅ |

Queries were deliberately paraphrase-hard (no verbatim phrase reuse), target = source segments
±15s, scored by `score-recall` CLI. Reading: **NLContextualEmbedding (mean-pooled, 512-dim) does
not clear the retrieval gate on paraphrase queries.** Speed and zero-download are excellent, and
product recall is better than this number (find-a-moment is hybrid keyword FTS5 + semantic), but
the gate as written FAILS → the rubric's named alternative (bge-small/MiniLM-class bundled Core ML
embedder, ~130MB) becomes a post-P0 bake-off item alongside Tier 2. Recorded, not gating P0 exit:
same reasoning as Tier 2 — search works today via FTS5+semantic-assist; a better embedder swaps in
behind the same protocol.

### Ad verify-pass A/B (D29) — same download, same candidates, sponsor-class F1

| Episode | baseline P/R/F1 | verified P/R/F1 |
|---|---|---|
| founders-402 | 35% / 99% / 0.52 | **85% / 99% / 0.91 — PASSES gate** |
| founders-413 | 28% / 71% / 0.40 | 75% / 71% / 0.73 |
| lennys-1m | 12% / 45% / 0.19 | 34% / 45% / 0.39 |
| lennys-codex | 8% / 36% / 0.13 | 34% / 36% / 0.35 |
| restishistory | 24% / 39% / 0.30 | 41% / 39% / 0.40 |
| radiolab | 3% / 7% / 0.04 | 18% / 7% / 0.10 |
| allin (0 sponsor labels) | any-promo 0.27 | any-promo 0.42 |

Caveat: this is a FRESH download; DAI ad fills differ from the 2026-07-08 download the labels were
made against, so absolute numbers are depressed on DAI-heavy shows (radiolab, restishistory, lennys)
— some "misses" no longer exist in this audio and some "false positives" are likely REAL ads absent
from the labels. The within-run baseline→verified delta is download-invariant and is the finding.
Gate still not met corpus-wide; next iteration: verify-prompt tuning + relabel against a frozen
audio snapshot. Ad-skip stays **Ask** (§8.11); D28 ad-chapters remain the shipping surface.

## Open empirical decisions [open] — the bake-off fills these

| # | Question | Resolved by |
|---|---|---|
| E1 | Which ASR? SpeechTranscriber vs WhisperKit small.en vs base.en | ASR gates in the rubric, on the corpus |
| E2 | Which Tier-2 LLM? Gemma E2B / Qwen3-2B / LFM2-1.2B | LLM gates (license + size + background-safe + task quality) |
| E3 | Is a 2B LLM enough for ad classification, or a fine-tuned classifier? | AdDetection F1 gate; try both behind the protocol |
| E4 | Embeddings: NLContextualEmbedding vs bundled MiniLM/bge-small — **NLContextualEmbedding measured (Phase F): Recall@3 0.55, FAILS the ≥0.90 gate as sole retriever**; bge-small bake-off is the open half | Retrieval Recall@3 gate, same `score-recall` harness + query sets in `.eval-corpus/recall/` |
| E17 | **LLM-assisted retrieval (staged plan, PRD §7.3):** if the bge-small bake-off (E4) still misses the ≥0.90 gate, measure (a) LLM re-rank of the top ~15 vector+keyword candidates and (b) LLM query-expansion (2–3 paraphrases, union of hits) — both ~1k tokens/search, rendered as progressive refinement over instant stage-1 results, degrading silently on refusal (E16). The LLM never scans transcripts per query (latency/battery/refusal non-starter). | `score-recall` A/B: stage-2 baseline vs +re-rank vs +expansion, same 49-query sets |
| E5 | Diarization: FluidAudio vs SpeakerKit | Speaker-count accuracy + DER |
| E6 | Real per-episode battery / thermal numbers | Device-twin runs (`docs/device-twin-spec.md`) |
| E7 | ~~Ad detection window-granular → nuked content~~ **RESOLVED (D15).** | ✅ fixed + regression test |
| E8 | **Chapter/key-moment titles collapse to the same timestamp on short/single-window input** (`anchorChapters` degenerates when notes.count < titles.count — confirmed again on the real `real-full` run: 5 chapter titles all anchored to 0:00 from 1 ad-free window). Not a bug on real multi-window (multi-hour) episodes; only visible on tiny fixtures. | Low priority — revisit once real multi-window episodes are in the eval corpus |
| E9 | ~~First `WhisperKitASR` draft built the model inline inside `transcribe()`, so download+Core-ML-compile time leaked into the RTF measurement (149s wall / 10.8s audio → RTF 0.07x, making a real model look ~2000x slower than reality) AND left `skipSpecialTokens`/`withoutTimestamps` at defaults, so raw `<\|startoftranscript\|>`/`<\|1.52\|>` tokens leaked into segment text and inflated WER to 63%.~~ **RESOLVED (D20).** Moved model construction into `load()` (actor-held state); set `skipSpecialTokens: true` while deliberately leaving `withoutTimestamps: false` (that flag was tried and found to also disable per-sentence segment splitting — confirmed by trial, not assumed). Re-run: clean text, correct 4-segment split, WER 6.67% (PASS), and WhisperKit transcribed "SHIP" correctly where SpeechTranscriber misheard it as "chip." | ✅ fixed, both adapters now follow this pattern |
| E10 | ~~RTF numbers from the tiny TTS fixture are not representative~~ **SUPERSEDED — real corpus data now exists (see below).** | see "First real-corpus slice" |
| E11 | **A Foundation Models call can outright REFUSE real content** (`LanguageModelSession.GenerationError.Refusal`, "may contain sensitive content") — hit live on a real biographical episode (business-history content, not anything unusual). Neither `mapWindow` nor `reduce` had a catch around the model call, so one refused window crashed the ENTIRE episode's processing — a direct violation of degrade-don't-die. `FoundationModelsAdDetector` already had per-batch resilience (D15) for this exact failure mode; map/reduce didn't. **Fixed (D22):** map now catches per-window and skips a refused window; reduce now catches and falls back to an **extractive digest built from the notes already in hand** (topic labels → chapters, salient points → takeaways, no further model call) — this is the "extractive-summary fallback" the PRD's own risk table (§13) already named as the mitigation, just not wired until now. **Confirmed on 3 more real episodes across 3 different genres** (business/finance discussion, war/political history) — refusals are a real, generalizable Tier-1 risk, not a one-off. Zero refusals on the one music/science-documentary episode tried (Radiolab) — appears content-topic-dependent. | ✅ fixed; verified on 4 separate real episodes — none crash anymore |
| E12 | **Refusals are NON-DETERMINISTIC across runs of the identical input.** Confirmed by accident: added error-diagnostic logging, re-ran the same All-In episode with unchanged code, and a window that fully failed the first time partially succeeded the second (1 of 3 windows generated instead of 0, producing a real digest instead of the extractive fallback). This suggests a **retry-once policy could recover some refused windows** for free — but retry count/backoff/whether to reword the prompt on retry is a genuine design call (how aggressively to retry trades off latency against yield), not a blind mechanical fix, so it's logged here rather than silently implemented. | Open — candidate mitigation identified, not yet built; flag for Opus/user before implementing a retry policy |
| E15 | **NEGATIVE RESULT (honest): neither the `permissiveContentTransformations` guardrails nor immediate retry-once fixed refusals.** Verified the guardrails API exists and switched all FM sessions to it (D23); added retry-once (D23). Re-ran all 7 episodes: refusals persisted and got noisier (an episode with zero prior refusals refused 5/6 windows); same-mode retries recovered **0 of 8**. | Superseded by E16 — the load hypothesis was also wrong |
| E16 | **ROOT CAUSE ISOLATED (7 controlled probes, deterministic 12/12 vs 0/12): Foundation Models refusals are triggered by GUIDED GENERATION (`@Generable`), not by content policy, guardrails, input length, call rate, or system load.** The same real transcript text that guided generation refuses 100% of the time passes plain `respond()` 100% of the time — same session config, same model, same moment. Systematically ruled out: guardrails mode (no effect either way), the verbatim-quotes schema field (refuses without it), input length (refuses at 1.2KB, passes at 13.8KB synthetic), a specific trigger passage (every fragment of the real episode refuses), rapid-fire load (10/10 unpaced probe calls passed), and global service state (clean-synthetic control passed at the same moment real text refused). What remains: constrained decoding + real-world transcript text trips the safety layer where free text generation does not; my clean synthetic prose never trips it in either mode. **Fix shipped (D24):** every FM guided call now falls back on refusal to a plain-text call with a strict line format (`TOPIC:/POINT:/QUOTE:`, `TLDR:/TAKEAWAY:/CHAPTER:/MOMENT:`, comma-separated line numbers for ads) parsed manually — same information, different decode path. Applied to mapWindow, reduce, AND the ad detector's per-batch calls (whose old silent catch was a hidden recall killer). | ✅ fix shipped; verified on the worst episode (below). This finding matters beyond this project: any Apple-platform app using `@Generable` on real user content will hit this. |
| E13 | **Diarization speaker-cluster count varies sharply by show production style** — clean 2-person interview audio (Lenny's) produced 2 dominant clusters + 1–3 small strays; heavily produced/sound-designed audio (Rest Is History, Radiolab) produced 10–12 clusters for what's realistically 2–3 real voices. Plausible cause: music beds / sound design being misread as distinct "speakers." Not yet compared against FluidAudio to see if it's more robust to this. | Needs real DER scoring + a FluidAudio comparison; in the meantime the PRD's confidence-threshold-hides-the-chip mitigation (§8.1) covers the product-facing risk |
| E14 | **Ad-detection precision/recall quantified for the first time** (still a proxy, not true ground truth — see "Real-corpus ad-detection cross-check" below): aggregate precision ~8%, recall ~45% against an independent keyword-based reference built separately from the detector's own heuristics. Corroborates the manual spot-check finding (E7-era: real sponsor reads caught correctly alongside real false positives) and adds a NEW finding: the detector fully **missed** an obvious keyword-flagged ad on one episode (a real recall miss, not just over-triggering). | Confirms the ad-F1 gate in `docs/P0-scoring-rubric.md` is measuring something real and not yet close to its ≥0.85 bar — worth trying a dedicated small classifier (v1 open Q2 / E3) since general LLM classification is both over- and under-firing |

## First real-corpus slice (2026-07-08)

Not the full ~20-episode spec (`docs/P0-eval-set-spec.md`) — a first slice to replace toy-fixture
numbers with real ones, expanded in a second pass to cover the missing composition axes. **7 real
public episodes, ~5.3 hours combined**, downloaded via each show's RSS feed (all discovered via the
iTunes Search API, matching the PRD §6 acquisition path). Audio kept local, out of git, per the
eval-set spec. None of the 5 shows publish an official `<podcast:transcript>`, so **WER is still
unavailable** (needs hand-corrected reference text — not done this pass); everything else ran for real.

| Episode | Show / axis | Duration | End-to-end RTF (SpeechTranscriber) | Ad % | Speaker clusters | Map refusals |
|---|---|---|---|---|---|---|
| Founders #413 | monologue | 31min | 32.74x | 16.7% (39 ranges) | 1 (correct) | 0 |
| Founders #402 | monologue | 32min | 38.73x | 10.1% | 1 (correct) | 0 |
| Lenny's — OpenAI Codex | 2-person interview | 70min | 35.22x | 12.2% | 2 dominant + 3 stray | 0 |
| Lenny's — 1M subscribers | 2-person interview | 67min | 23.65x | 10.6% | 2 dominant + 1 stray | 0 |
| All-In — Ackman | **crosstalk (4 hosts)** | 30min | 37.82x | 6.0% | 6 clusters, 2 dominant | 2 of 3 |
| Rest Is History — Matilda | **non-US accent (British)** | 43min | 38.18x | 8.3% | 12 clusters, 2 dominant | 3 of 4 |
| Radiolab — Forests | **music-bed-heavy** | 20min | 28.65x | 7.5% | 10 clusters (no clear 2) | 0 of 2 |

All 5 composition axes now have at least one real episode (crosstalk, non-US accent, music-bed added
this pass; monologue and 2-person interview from the first pass). Still missing: non-English-accent
*speakers* specifically distinct from "British" (e.g. non-native English), and heavy phone-quality
remote-guest audio — both from the eval-set spec's harder tail, not yet sourced.

**ASR:** SpeechTranscriber held 23.6–38.7x RTF across all 7 real episodes; WhisperKit small.en held
16.9x on the one episode tested — both comfortably clear the ≥10x gate on real audio. SpeechTranscriber
ran ~2x faster on the same episode. (WhisperKit's earlier 0.50x reading was purely a tiny-fixture
artifact — see E10.)

**LLM refusals (E11/E12) — a real, generalizable risk, not an edge case.** Confirmed across 3
distinct content genres (business biography, finance/investing discussion, war/political history);
zero refusals on the one music/science-documentary-style episode (Radiolab). Non-deterministic
across runs of the same input (E12) — a retry policy is a plausible free win but wasn't built (a
retry-count/backoff decision is a real design call, flagged rather than assumed).

**Diarization — real multi-speaker data, quality clearly tracks production style.** Clean-audio
2-person interviews (Lenny's) → 2 dominant clusters + 1–3 small strays. Heavily-produced/sound-design
audio (Rest Is History, Radiolab) → 10–12 clusters for realistically 2–3 real voices — a real,
measurable diarization-robustness gap tied directly to the music-bed axis this pass was built to test
(E13). Not yet compared against FluidAudio.

**Ad detection — quantified (proxy) precision/recall (E14).** Built an independent keyword-based
cross-check (different phrase set than the detector's own heuristic pre-pass) across all 7 episodes:
**aggregate precision ~8%, recall ~45%** against that proxy reference. Not true ground truth — the
keyword list itself has real blind spots (it completely missed Radiolab's public-radio-style
"support for this show comes from…" sponsorship phrasing, hence 0% there) — but it corroborates the
manual spot-check (real sponsor reads caught correctly, alongside real false positives) and surfaces
a new finding: the detector fully **missed** an obvious keyword-flagged ad on the All-In episode. Net
read: both a precision problem and a recall problem, not just one-sided over-triggering.

## True ad-F1 vs ground truth (2026-07-08, Phase B)

Ground truth: full-transcript read labeling by the agent (`docs/eval/labels/*.json`, 21 ranges,
3 categories, 9 flagged items for human audit — `docs/eval/AUDIT-LIST.md`). Scoring: time-overlap
P/R/F1 via `score-ads`, self-consistency-checked (labels-as-detections → F1 = 1.00 exactly).

| Episode | sponsor-F1 before | after (D24+D25) | recall before→after |
|---|---|---|---|
| founders-413 | 0.41 | 0.33 ⚠ | 71%→50% (run-to-run flag variance; one new FP block in intro) |
| founders-402 | 0.29 | **0.60** | 36%→64% (Ramp read matched to the second) |
| lennys-codex | 0.23 | 0.32 | 50%→**94%** |
| lennys-1m | 0.22 | 0.30 | 34%→70% |
| allin (zero true sponsors) | 0.00 | 0.00 | — (all detections are FPs by construction; any-promo F1 0.26 — it flags the guest's fund pitch) |
| restishistory | 0.32 | 0.46 | 57%→74% |
| radiolab | 0.22 | 0.28 | 35%→37% (its two labels are both flagged/uncertain) |
| **median** | **0.23** | **0.32** | ~36%→~67% |

Reading: the D25 aggregation change did what it was designed to do (recall roughly doubled —
whole reads are now reconstructed from sparse flags; founders-402's Ramp read matches the label
boundary exactly). Precision is the structural residual: the model flags genuine-sounding
discussion *about* products/companies as ads, and no aggregation fixes a wrong flag. Gate verdict
unchanged: **FAIL vs ≥0.85** — production path needs a dedicated classifier or a second-pass
LLM verification over merged candidate blocks (now cheap: 6–11 blocks/episode, not 40–80 lines).

## WER vs large-v3_turbo pseudo-reference (2026-07-08/09, Phase C)

No show publishes an official transcript, so the reference is WhisperKit **large-v3_turbo** run on
the same audio (per the eval-set spec's fallback). Read these as *disagreement with a much larger
model*, not absolute WER — and note the reference shares a model family/tokenizer with small.en,
which systematically flatters small.en in this comparison. Scoring: `score-asr` (normalized,
Levenshtein). Corpus re-downloaded from `docs/eval/corpus-manifest.json` after the first corpus was
lost to a /tmp wipe; DAI ad fills may differ from the originally-labeled downloads, which perturbs
WER slightly on DAI shows (Rest Is History; noted, not corrected).

| Episode | Audio style | SpeechTranscriber | WhisperKit small.en |
|---|---|---|---|
| founders-413 | clean solo narration | 3.48% | **2.16%** |
| founders-402 | clean solo narration | 4.80% | **3.34%** |
| restishistory | produced, music beds, DAI | **6.00%** | 6.14% |
| radiolab | heavy sound design | **8.13%** | 9.43% |
| allin | 5-voice panel, crosstalk | 8.43% | **6.54%** |
| lennys-codex | clean 2p interview | 6.03% | 6.04% |
| lennys-1m | clean 2p interview | 8.55% | **8.17%** |

Reading (7/7 scored — Phase C COMPLETE 2026-07-09): **no engine dominates — they trade wins by
audio type.** small.en wins clean narration and panel crosstalk (1.3–1.9pt); SpeechTranscriber wins
produced/music-bed audio (1.3pt on Radiolab) and ties Rest Is History — despite the reference bias
*against* it. The two clean-interview episodes landed exactly as predicted: a wash (6.03 vs 6.04;
8.55 vs 8.17). Medians: **ST 6.03%, small.en 6.14%** — both clear the <10% gate on every episode
and the <12% music-bed gate (Radiolab: ST 8.13%). Everything is single-digit; both are "usable
transcript" territory on every style tested. Speed separates them decisively: SpeechTranscriber
24–39x RTF cold / 72–82x warm vs small.en 7–23x (small.en also throttled hardest under sustained
load), and SpeechTranscriber is zero-download vs ~500MB. Speed data: D16/E10 table + warm-cache
re-runs this phase.

## Model-decision-record — FILL AFTER CORPUS RUN (P0 exit artifact)

| Role | Winner | Key numbers (median) | Runner-up | Note |
|---|---|---|---|---|
| ASR | **SpeechTranscriber — DECIDED (7/7 episodes scored)** — WER measured vs large-v3_turbo pseudo-reference (see Phase C table): accuracy is a wash (each engine wins some styles, all single-digit, ST wins the *hard* produced audio despite reference bias favoring small.en; the 2 clean interviews landed as predicted, a tie), so the decision falls to the secondary criteria, which all point one way: 3–10x faster (24–82x RTF vs 7–23x, and small.en throttles hardest under sustained load — the overnight-batch scenario), zero-download vs ~500MB, OS-maintained | ST median WER **6.03%**, small.en 6.14% (7 eps); all episodes < 10% gate, music-bed slice 8.13% < 12% gate; ST RTF 24–39x cold / 72–82x warm | WhisperKit small.en — the fallback if pre-26 OS support ever matters (ST requires macOS/iOS 26); base.en not run (small.en already loses on speed, base would only trade accuracy for it) | Reference is model-family-biased toward small.en, so ST's wins understate it. Device-twin RSS/thermal numbers still owed by P2 (Mac-harness gates all pass) |
| LLM Tier 1 (FM) | **RETIRED from the app — bench-only (D38).** Foundation Models is no longer selected on device; the app ships one bundled MLX model on every device. FM adapters stay in HarkCore for Mac-bench comparisons. (History, still valid for the bench: refusal problem CLOSED via E16/D24; Phase F LLM-judge quality — faithfulness 3/5, chapters 2/5, snips 3–4/5 post-D32.) | faithfulness 3/5 · chapters 2/5 (bench reference) | n/a — not shipped | The single-model pivot (D38) makes per-device FM availability a non-factor; FM's measured quality is the bench yardstick the bundled model is compared against |
| LLM (shipped) | **Qwen3-1.7B-4bit via MLX — the ONE engine on all devices (D37 bake-off + D38 single-model + bundled weights).** Full digest pipeline, foreground-only, until the Core ML/ANE port ships | D37: 4 models × 2 episodes — Qwen3-1.7B 1.4–1.5GB peak, 0 failures, accurate TL;DRs; LFM2-1.2B disqualified; Llama-3.2-3B garbles names; Qwen3-4B 2.8GB ≈ jetsam ceiling | Qwen3-1.7B-4bit **shipped, bundled in-app**; Qwen3-4B-4bit Mac-bench quality ceiling | Zero refusals on the FM-refuser corpus (reconfirms E16). Quality: faithful-but-generic, same class as FM's 3/5. Requires D36 stack (mlx-swift-lm 3.31.4; Mac CLI needs colocated metallib — mlx-swift#430) |
| Ad detection | **Ported off FM to the bundled MLX model (D38):** keyword candidates + **per-line MLX classification** + **per-block MLX verify-pass** (D29 architecture). The per-line MLX pass is load-bearing — keyword-only candidates scored F1 0.00 on every episode (host-read ads say no keywords). FM history retained: per-line 0.23 → D25 agg 0.32 → D29 verify best 0.91 / median 0.39 | **MLX median sponsor-F1 0.515** across 6 episodes with sponsor ground-truth (radiolab 0.00, founders-402 0.25, founders-413 0.52, lennys-codex 0.57, lennys-1m 0.59, restishistory 0.51; allin excluded — no sponsor labels). **Beats FM's 0.39 median**, but inverted profile: **high recall 51–99%, low precision 16–44%** (a 1.7B over-flags company discussion). Gate ≥0.85 still unmet | dedicated fine-tuned classifier (E3/v1-Q2) — the path to the gate | Product posture unchanged & safe: high recall is right for D28 visible "Sponsor break" chapters (catch the ad; extra chapters are trust-cheap); ad-skip auto stays **Ask/Off** (§8.11) since the ≥0.85 precision-sensitive gate is unmet. Real gap: radiolab's short music-bed ads missed (recall 0) |
| Embeddings | NLContextualEmbedding (mean-pooled, dim 512) — retrieval now MEASURED (Phase F): **Recall@3 = 0.55 corpus-wide (27/49 paraphrase queries) — FAILS the ≥0.90 gate**; per-episode 0.29–0.86. Speed passes everywhere (0.2–1.1ms search, gate <10ms; embed ~3–9s/episode) | Recall@3 0.55 vs ≥0.90 gate → **FAIL as sole retriever** | bge-small/MiniLM-class bundled Core ML embedder (~130MB) — post-P0 bake-off item (D31-style deferral) | Ship position: find-a-moment is HYBRID (FTS5 keyword + semantic assist), so product recall exceeds this number; NLContextualEmbedding stays as the zero-download default until the bundled-embedder bake-off, swaps behind the same protocol |
| Diarization | **Leaning FluidAudio (Apache-2.0)** — head-to-head on the 3 production-style-problem episodes + 1 clean control (`real-diarize`, shared alignment helper so the comparison is apples-to-apples): Rest Is History **12 clusters (SpeakerKit) → 6 (FluidAudio)** with 2 dominant = 92% of segments (matches the 2-host reality; tiny clusters plausibly the genuinely-distinct DAI ad voices); Radiolab 10 → 7; All-In 6 → 7 (comparable); clean Lenny's control **5 → 3** (2 dominant + 1 tiny stray — cleanest result seen). 12.9–36.5s per episode (~75–100x RT) | FluidAudio better or equal on 4/4 episodes, distinctly better on produced audio (the E13 axis) | SpeakerKit (MIT) — fine on clean audio, fragments on production | DER not scored (no ground-truth speaker labels); cluster-count-vs-reality is the operative product metric for the Host/Guest chips and it favors FluidAudio |

**P0 exit status (2026-07-09): every row is now FILLED** — with a measured number, or an explicit
recorded deferral (Tier 2, D31). Two hard gates are **not met and recorded as such**: ad-F1
(median 0.39 post-D29 vs ≥0.85 — mechanism proven, iteration continues; product ships Ask-mode +
D28 ad-chapters which tolerate current precision) and embeddings Recall@3 (0.55 vs ≥0.90 — hybrid
FTS5+semantic ships; bundled-embedder bake-off queued). Neither failure blocks the P1/P2 build:
both have working product surfaces at current quality and recorded upgrade paths behind stable
protocols. **Remaining human gate: audit the 9 flagged items in `docs/eval/AUDIT-LIST.md` and
sign off on this record.** Device-twin RSS/thermal numbers land in P2 (physical iPhone).
