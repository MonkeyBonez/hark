# POC findings: semantic search + ad detection (2026-08-13)

Scripts in this directory; data = the 7-episode eval corpus (transcripts in
`.eval-corpus/artifacts`, 49 recall queries in `.eval-corpus/recall`, ad labels in
`docs/eval/labels`). All candidate models fit iPhone 14 Pro comfortably (22–33M-param
embedders → Core ML/ANE; the reranker/verifier is the already-bundled Qwen3-1.7B).
Run: `python3 search_eval.py` / `ads_classifier.py`; `./.venv/bin/python search_rerank.py` /
`ads_hybrid.py` (venv pins transformers<5 for mlx-lm).

## 1. Find-a-moment search (`search_eval.py`, `search_rerank.py`)

Protocol identical to hark-bench `score-recall`: segment-level retrieval, hit = any top-k
segment overlaps the query's target range. Corpus-wide over 49 paraphrase queries:

| method | R@1 | R@3 | R@10 |
|---|---|---|---|
| NLContextualEmbedding (Phase F baseline) | — | 0.55 | — |
| BM25 (≈ FTS5 today) | 0.571 | 0.816 | 0.918 |
| all-MiniLM-L6-v2 (22M) | 0.531 | 0.816 | **0.980** |
| bge-small-en-v1.5 (33M) | 0.551 | 0.816 | 0.898 |
| hybrid RRF(BM25 + bge) | 0.592 | **0.857** | 0.939 |
| **retrieve top-10 (MiniLM) → Qwen3-1.7B picks 3** | — | **0.878** | — |

Read: Apple's built-in embeddings were the bottleneck (0.55), not the approach — swapping to a
22M open embedder gains +26pts, and the RAG shape (embeddings retrieve, LLM chooses) adds
another +6pts at **0.46s/query** on the Mac (expect ~1–2s on device; fine for a search action).
Ceiling is 0.98 (R@10), so the 0.90 gate is reachable with a better chooser prompt / top-20 /
windowed passages. LLM prompt is ~10 short passages — snip-enrichment-sized, no crash risk.

Prior art: [SimilaritySearchKit](https://github.com/ZachNagengast/similarity-search-kit) ships
exactly this stack on iOS (MiniLM-class CoreML models + on-device vector search), with
[ready-made CoreML conversions](https://huggingface.co/ZachNagengast/similarity-search-coreml-models).

**Ship shape:** embed each segment once at transcription time (store 384-dim vectors), FTS5 +
vector hybrid for instant results, optional LLM "choose" pass on top-10 when the model is warm.

## 2. Ad detection (`ads_classifier.py`, `ads_hybrid.py`)

Scored with hark-bench's time-overlap sponsor-F1, leave-one-episode-out CV, D25 aggregation
(merge ≤20s, drop <8s). Baselines: full-LLM pipeline (keyword + per-line MLX classify + verify)
median **0.515**; keyword-only 0.00; auto-skip gate ≥0.85.

| approach | median sponsor-F1 | LLM calls/episode |
|---|---|---|
| bge-small embeddings + logistic regression | 0.491 | 0 |
| classifier candidates (recall-leaning) + Qwen verify per block | **0.580** | ~4–12 |

Read: a logistic head over embeddings **matches the whole per-line LLM pipeline** with zero LLM
cost, and using it as the candidate stage with the LLM verify-pass on top (the D29 two-pass
architecture, better front end) beats the shipped pipeline — with ~50–100× fewer LLM calls
(per-block, not per-line). Best episodes hit 0.79–0.96. The failure mode is **training-data
diversity**, not architecture: radiolab's NPR-style underwriting ("support comes from…") scores
0.00 because nothing similar is in the 6 training episodes.

No usable pretrained open model exists — confirmed again:
[heidonomm/AdDetection](https://github.com/heidonomm/AdDetection) (context-window classifier,
~63% precision), audio-side experiments
([spectrogram-transformer fine-tune](https://medium.com/@jacobschwarz00/can-ai-skip-podcast-ads-fine-tuning-an-audio-spectrogram-transformer-to-find-out-62c81805dd22),
[amsterg/Podcast-Ad-Detection](https://github.com/amsterg/Podcast-Ad-Detection)), and commercial
closed systems ([ZeroAds](https://zeroads.ai/), two-pass classifier, claims 90%+). Academic work
(Reddy et al., BERT on sponsor segments) matches our text-classifier framing.

**Path to the 0.85 gate:** more labeled episodes, cheaply — weak supervision: run the existing
MLX verify prompt as a *teacher* over many downloaded episodes to auto-label, train the
classifier as the *student*, keep the LLM verify-pass at inference. 20–50 episodes across
production styles (esp. produced/NPR-style) is the next experiment. Audio cues (music beds,
loudness shifts) are a further orthogonal signal if text alone stalls.

## On-device cost summary

- Embedder: 22–33M params (~25–70MB quantized), ANE-friendly; per-segment at transcription time.
- Vectors: 384 floats × ~400 segments/episode ≈ 300KB fp16 per episode — trivial in SQLite.
- Classifier head: logistic regression = a dot product. Free.
- LLM stages stay small-prompt (10 passages / 1 block) — the crash-causing whole-transcript
  pass is never needed.
