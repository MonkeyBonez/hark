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

## 3. Teacher quality: can a cheap model label the silver data? (`teacher_eval.py`)

Before scaling LLM-auto-labeling, measure the teacher against the human-audited gold labels —
the student's ceiling is the teacher's accuracy. Each model got one full timestamped transcript
per episode and labeled ad ranges under the gold pass's own category definitions; scored with the
same time-overlap sponsor-F1.

| episode | Haiku 4.5 | Sonnet 5 | note |
|---|---|---|---|
| allin-ackman (no ads) | 1.00 | 1.00 | control — both correctly found nothing |
| founders-402 | 0.96 | 1.00 | host-read |
| founders-413 | 0.95 | 1.00 | host-read |
| lennys-1m | 0.96 | 0.99 | host-read |
| lennys-codex | 0.96 | 1.00 | host-read |
| radiolab | **0.74** | **0.15** | produced/NPR — see below |
| restishistory | (pending) | 0.79 | stacked produced spots |
| **median** | **0.96** | **1.00** | gate 0.85 |

**Both models clear the 0.85 gate on host-read shows by a wide margin** — Sonnet essentially
reproduces gold, Haiku trails by ~4pts (looser boundaries, same ads found). At ~⅓ the cost,
**Haiku is good enough to be the bulk labeler**, with Sonnet worth reserving for spot-audits.

Sonnet's radiolab 0.15 is **not** a judgment failure — two mechanical artifacts, both fixed:
1. **21 of radiolab's 38s of gold ad time has no transcript text** (a music/DAI break; the
   transcript jumps 0:12:15 → 0:12:38 with the cue "Right after this short break" before it).
   Sonnet followed the "only label what is actually there" instruction and skipped it; Haiku
   inferred it from the cue and scored better. `teacher_eval.py analyze` measures this across the
   corpus: **every host-read episode is 100% text-visible; radiolab is 46%.** That fraction is a
   hard ceiling on any text-only detector, teacher or student.
2. **End-of-file truncation**: the closing underwriting read is the last thing in the transcript,
   so "end = the line after the ad" had no next line and the range collapsed to 3s of 15s.
   `prep()` now emits `[start-end]` per line, so a future labeling batch can't hit this.

Corrected for both, Sonnet's radiolab is ~0.97 — i.e. **teacher quality is not the bottleneck**.

### Local teachers: can this Mac label the silver data itself? (`local_teacher.py`)

The teacher runs on the Mac (M4 Pro, 24GB), not the phone, so it can be far bigger than the
bundled 1.7B — only the student has to fit an iPhone. Same task and scoring; the transcript is fed
in overlapping 60-line windows (context never grows with episode length) and the model answers
with line indices, not timestamps — small models copy `12-18` reliably and `0:12:15` badly.

| model | size | median sponsor-F1 | sec/episode |
|---|---|---|---|
| Qwen3-1.7B-4bit (the bundled one) | 0.9GB | 0.175 | 10 |
| Qwen3-4B-Instruct-2507-4bit | 2.1GB | 0.620 | 22 |
| Qwen3-8B-4bit | 4.3GB | 0.815 | 38 |
| Qwen3-8B-4bit **+ verify pass** | 4.3GB | **0.823** | 40 |
| *(reference)* Haiku 4.5 | API | 0.957 | — |
| *(reference)* Sonnet 5 | API | 1.000 | — |

Quality scales steeply with size and the verify pass buys precision as it always has (founders-402
0.85→0.95 precision, lennys-1m 0.89→0.96). **On host-read episodes the local 8B is already at
0.86/0.96/0.98/0.82** — over the 0.85 gate. Its two zeros are the same edge cases everything else
trips on: an ad-free episode where one false positive survived verify, and radiolab (whose
text-visible ceiling is 0.46 regardless of model).

### Does the student lose anything learning from teacher labels? (`silver_student.py`)

The whole silver plan rests on one assumption — that a student trained on LLM labels is as good as
one trained on human labels. Testable now, because both teachers labeled the same 7 episodes the
humans did. Identical pipeline (bge-small + logistic head, leave-one-episode-out, fixed threshold
0.6), only the *training labels* differ; all three are evaluated against human gold:

| student trained on | median sponsor-F1 vs gold |
|---|---|
| human gold labels | 0.437 |
| Haiku labels | 0.386 |
| Sonnet labels | **0.534** |

The Sonnet-trained student beat the gold-trained one. At n=7 with this much per-episode variance
these gaps are **within noise** — which is exactly the point: **teacher labels cost the student
nothing measurable.** The assumption holds, so the constraint on student quality is corpus size
and style coverage, which is what silver labeling exists to fix.

### Side finding: silent gaps as an ad signal (`gap_signal.py`)

Gaps ≥5s between consecutive segments exist in only the 2 produced shows (host-read episodes have
none). As a standalone signal they're weak (2/6 land in a labeled ad); a gap immediately preceded
by a break cue ("right after this short break") hit 1/1 — suggestive but **n=1, not evidence**.
Worth computing at transcription time (it's free) and re-testing once the silver corpus has more
produced/DAI-heavy shows.

## On-device cost summary

- Embedder: 22–33M params (~25–70MB quantized), ANE-friendly; per-segment at transcription time.
- Vectors: 384 floats × ~400 segments/episode ≈ 300KB fp16 per episode — trivial in SQLite.
- Classifier head: logistic regression = a dot product. Free.
- LLM stages stay small-prompt (10 passages / 1 block) — the crash-causing whole-transcript
  pass is never needed.
