# TODO

The whole-transcript LLM path is parked (crashes the device — memory ceiling), so the
intelligence roadmap runs through approaches that never feed the model more than a small window.

## Explore: embeddings & lightweight models (added 2026-08-13)

- [ ] **Embedding search over snips + transcript.** Embed per-segment (small windows — no
      whole-transcript pass, so no crash risk) and search semantically. Pieces that already exist:
      `NLContextualEmbeddingEngine` in HarkCore (512-dim, zero-download) and the FTS5 index over
      `transcriptSegment` (populated, no UI yet). Prior bench result: NLContextualEmbedding scored
      Recall@3 0.55 vs the 0.90 gate — plan was hybrid FTS5 + embeddings, with a bge-small
      bake-off queued. Start there.
- [ ] **Ad detection → auto-skip via a lightweight dedicated model.** General-LLM classification
      topped out ~0.5 F1 (precision is the weak spot); the ≥0.85 auto-skip gate needs a dedicated
      classifier. Explore: (a) an existing off-the-shelf model (none found in earlier research —
      re-check periodically), (b) training our own small classifier (embeddings + logistic head or
      a tiny fine-tune) on the 7-episode labeled corpus in `HarkPipeline/docs/eval/labels/`,
      grown with more labeled episodes. Runs per-segment — device-safe by construction.

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
