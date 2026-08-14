# TODO

The whole-transcript LLM path is parked (crashes the device — memory ceiling), so the
intelligence roadmap runs through approaches that never feed the model more than a small window.

## Explore: embeddings & lightweight models (added 2026-08-13)

- [x] **Embedding search over snips + transcript — POC done, works.** See `poc/FINDINGS.md`:
      MiniLM/bge-small (22–33M, ANE-class) hit R@3 0.816–0.857 vs NLContextualEmbedding's 0.55;
      RAG-style rerank (retrieve top-10 → bundled Qwen3-1.7B picks 3) reaches **0.878** at
      0.46s/query on Mac; R@10 ceiling 0.98, so the 0.90 gate is reachable. Next: convert
      MiniLM/bge to CoreML (SimilaritySearchKit has ready conversions), embed at transcription
      time, hybrid FTS5+vector, then wire the search UI.
- [x] **Ad detection lightweight model — POC done, beats the LLM pipeline.** See
      `poc/FINDINGS.md`: bge-small embeddings + logistic regression alone ≈ 0.49 median
      sponsor-F1 (matches full per-line-LLM pipeline at zero LLM cost); classifier candidates +
      per-block Qwen verify = **0.580** vs 0.515 shipped, with 50–100× fewer LLM calls. No
      pretrained open model exists (re-confirmed). Path to the 0.85 auto-skip gate: weak
      supervision — LLM-as-teacher auto-labels 20–50 more episodes (esp. produced/NPR styles),
      classifier-as-student retrains. Next experiment: scale training data that way.

## On-device performance (see ON-DEVICE-PERF.md, researched 2026-08-13)

- [ ] **URGENT — guard MLX/Metal against backgrounding.** On iOS 26.2 in-flight GPU work now
      *crashes the process* (`accessRevoked`) rather than just failing. Snip enrichment runs MLX
      right when a user is likely to pocket the phone. Gate on `applicationState == .active` and
      abandon cleanly on `willResignActive`.
- [ ] **Transcribe during playback.** We already ship `UIBackgroundModes: [audio]`, and
      SpeechTranscriber is not Metal — so we can index while the user listens today, no new
      entitlement, no Core ML port. Removes most of the "keep Hark open" friction.
- [ ] Core ML embedder on the ANE: needs Apple's transformer rewrite (4D channels-first,
      Linear->Conv2d, per-head Q/K/V, einsum), `EnumeratedShapes` **not** `RangeDim` (RangeDim
      measured 0% ANE), fixed batch 16-32 / seq 64. Verify placement with MLComputePlan — do not
      assume it.
- [ ] W8A8 quantize the embedder (~1.6-1.8x latency per Apple's A16 numbers; <1% MTEB cost).
- [ ] Logistic head via one `cblas_sgemv` (~10-30us for 400 sentences).

## Backlog (agreed earlier)

- [ ] On-device dogfood pass: chunk-boundary seams, enrichment memory alongside ASR, accessory
      mini player, speed scrub feel
- [ ] Background transcription via BGContinuedProcessingTask (ASR is CPU/ANE — background-safe,
      unlike MLX)
- [ ] Find-a-moment search UI (FTS5 now; upgrades to hybrid embedding search above)
- [ ] Shareable snip cards (PRD §7.4)
- [ ] Cooldown eviction: delete transcripts for episodes not listened to in N days
- [ ] Revive summaries chunk-scoped (per-chapter windows, snip-enrichment-sized prompts) — only
      after the above feel solid
