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

## On-device performance — BACKLOG (see ON-DEVICE-PERF.md, researched 2026-08-13)

Deferred by decision 2026-08-14: get the model good first. None of this blocks model quality.

- [ ] Guard MLX/Metal against backgrounding (iOS 26.2 crashes the process on in-flight GPU work).
- [ ] Transcribe during playback — `UIBackgroundModes: [audio]` already shipped, ASR isn't Metal.
- [ ] Core ML embedder: start with a *plain* conversion + `.cpuAndNeuralEngine` (background-safe
      without any rewrite), measure, and only do Apple's full ANE transformer rewrite if measurement
      demands it. We are not latency-bound — embedding runs once per episode inside a transcription
      that already takes minutes.
- [ ] W8A8 quantize the embedder; `cblas_sgemv` for the head.

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
