# P0 scoring rubric — how a candidate wins its role

Each engine role is decided independently against explicit gates. A candidate must clear **all**
hard gates to be eligible; among eligible candidates, pick the best on the soft metric.

## ASR (SpeechToText)

| Gate | Threshold |
|---|---|
| **WER (hard)** | median **< 10%** across corpus; **< 12%** on the music-bed slice |
| Speed (hard) | ≥ **10× real-time** on the device twin (iPhone 14 Pro), `.cpuAndNeuralEngine` |
| Memory (hard) | peak RSS ≤ **900 MB** while resident |
| Background-safe (hard) | survives app backgrounding (Core ML/ANE path; no MLX-GPU) |
| Download (soft) | prefer zero-download (SpeechTranscriber) over a bundled model |

Candidates: **SpeechTranscriber** (default), **WhisperKit small.en**, **WhisperKit base.en**
(base only as a low-power fallback — a ~1-in-8-word error rate is too visible in a karaoke UI).

## LLM (EpisodeIntelligence)

| Gate | Threshold |
|---|---|
| **License (hard)** | Apache-2.0 / MIT-class only. **Qwen 2.5 3B struck** (research-only). Llama deprioritized. |
| Weights (hard) | ≤ **~1.5 GB** on disk (4-bit) for the Tier-2 bundled model |
| Background-safe (hard) | runs on Core ML/ANE while backgrounded |
| Memory (hard) | peak RSS ≤ **1.6 GB** while resident; obeys single-model-resident rule |
| **Task quality (soft, LLM-judge + spot human)** | summary faithfulness, chapter sensibility, snip-title quality, speaker-naming accuracy — scored 1–5 on a rubric over ~20 episodes |
| Ad-classification F1 (soft) | reported, but the **AdDetection** role owns the hard ad gate |

Tier 1 = **Apple Foundation Models** (zero download, where Apple Intelligence is available);
Tier 2 candidates = **Gemma-class E2B QAT** (<1 GB), **Qwen3-class ~2B**, **LFM2-class ~1.2B**;
~4B Apache model only as an 8GB+ quality tier.

> Summary quality is **not** auto-scored by `Scoring.swift` — it records the digest text; run an
> LLM-judge pass (Foundation Models or a cloud judge, offline) + a human spot-check on ~5 episodes.

## Ad detection (AdDetection)

| Gate | Threshold |
|---|---|
| **Ad-F1 (hard)** | median **≥ 0.85** (time-overlap F1) |
| **False-positive rate (hard)** | on zero-ad control episodes, predicted ad-time ≤ **2%** of duration |
| Recall floor (hard) | **≥ 0.90** recall on baked host-read ads (missing an ad is worse than a short over-skip, given the "Play it anyway" undo) |

Scored objectively by `Scoring.adScore` (per-millisecond overlap → precision/recall/F1).

## Embeddings

| Gate | Threshold |
|---|---|
| Retrieval (hard) | **Recall@3 ≥ 0.9** on a hand-built query→segment set (~50 queries) |
| Speed (hard) | full-episode embed + search **< 10 ms** search at ~1,800 vectors |
| Memory (soft) | prefer NLContextualEmbedding (zero download) if it clears recall |

## Diarization

| Gate | Threshold |
|---|---|
| DER (soft) | reported; alignment to Whisper segments must not corrupt timestamps |
| Speaker-count accuracy (hard) | correct #speakers on ≥ **80%** of two-host/interview episodes |
| License (hard) | Apache-2.0 (FluidAudio) / MIT (SpeakerKit) |

## The decision record

For each role, `docs/DECISIONS.md` records: winner, the numbers it hit, the runners-up, and any
gate that forced a choice. That record is the **P0 exit artifact** — the whole build is blocked on it.
