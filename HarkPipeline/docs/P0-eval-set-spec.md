# P0 eval-set spec — the ~20-episode bake-off corpus

The model-decision-record is only as good as the corpus it's measured on. Target **~20 real
episodes** chosen to stress the exact failure modes a podcast player hits (PRD §10, §13 Q1).

## Composition targets (~20 episodes)

| Axis | Coverage to hit |
|---|---|
| **Audio hardness** | ≥6 with music beds / stingers; ≥4 with crosstalk / overlapping speakers; ≥2 phone-quality remote guests; ≥2 heavy accents / non-US English |
| **Speakers** | ≥6 single-host monologue; ≥8 two-host; ≥4 interview (host + rotating guests) |
| **Ads** | ≥8 with baked-in host-read ads; ≥6 with dynamically-inserted (DAI) ads; ≥3 with mid-roll + pre-roll + post-roll; ≥2 with **no ads** (false-positive control) |
| **Length** | ≥3 short (<20 min); ≥10 medium (30–70 min); ≥4 long (>2 h) — the long ones are the memory/thermal stressors |
| **Transcript availability** | ≥3 that ship a Podcasting 2.0 `<podcast:transcript>` (exercise the official-transcript fast path + quality gate) |

## Ground truth (what to label)

Per episode, in the `EvalManifest` JSON (`Bench/EvalSet.swift`):

- **`audioPath`** — local file (wav/m4a/mp3). Keep audio out of git; store paths relative to the manifest.
- **`audioSeconds`** — exact duration (drives RTF).
- **`referenceTranscriptPath`** *(for WER)* — a human-corrected transcript. You do **not** need all 20;
  ~8 well-corrected references give a stable median WER. Correct at least the hard-audio ones.
- **`labeledAdRanges`** *(for ad-F1)* — human-marked ad start/end in ms. Label **all** episodes here
  (including the zero-ad controls); ad-F1 is cheap to label and the most product-critical metric.
- **`tags`** — free-form (`music-bed`, `crosstalk`, `dynamic-ads`, `two-host`, `official-transcript`…),
  so scores can be sliced by condition (e.g. "WER on music-bed episodes").

## Sourcing & hygiene

- Pull real public RSS enclosures you actually listen to. Keep the audio **local and out of the repo**
  (it's copyrighted third-party content — same stance as the app: never re-host).
- For DAI episodes, download once and pin that file — dynamic ads change per request.
- Reference transcripts: start from an ASR pass, then hand-correct. Budget ~1× realtime per episode to correct.

## How scores are used

`hark-bench run manifest.json --json out.json` emits per-episode + median **RTF, WER, ad-F1, peak RSS**.
The decision record (`docs/DECISIONS.md`) records the winner per role against the gates in the rubric.
