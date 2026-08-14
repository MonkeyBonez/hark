# Ad-detection improvement loop — autonomous playbook

The goal is an on-device ad detector. The loop below is the whole method; each round buys more
training data and re-measures. It is written to be resumable and self-directing: any session can
read this file, run one command, and know what the result means.

**Never train on gold.** The 7 human-labeled episodes in `HarkPipeline/docs/eval/labels/` are the
scoreboard. Training on them turns a measurement into a memorisation test.

## The pipeline

```
SPoRC corpus  ->  local teacher labels it  ->  student trains on those labels  ->  scored on
(sporc_corpus)    (make_silver, free)          (train_student, 385 params)        gold + held-out silver
```

Why this shape: the teacher is too big for a phone but only runs at build time; the student is a
frozen 33M embedder plus a logistic head and runs per-sentence on-device. Teacher quality was
measured first (below) precisely because a student can never exceed its teacher.

## Run one round

```sh
cd poc && ./run_round.sh <round-number> <episodes-per-category> <shards>
# e.g. round 2 with twice the data:  ./run_round.sh 2 60 40
```

It expands the corpus, labels only the new episodes (existing labels are skipped, so it is
resumable and costs nothing to re-run), trains, evaluates, and appends a row to `rounds.md`.

Watch a long labeling run and get notified on completion: `./watch_silver.sh`

## Reading the result

Two numbers matter, and the gap between them matters more than either:

| gold | held-out silver | meaning | action |
|---|---|---|---|
| high | high | genuinely generalising | ship it; keep rounds going for margin |
| high | low | gold is narrow/easy; silver has styles gold lacks | trust silver more; keep adding data |
| low | high | student learned the teacher's quirks, not ads | fix the teacher/prompt, not the data volume |
| low | low | method or features are wrong | diagnose per-category before adding data |

**Decision rule for "add more data?"** Look at per-category F1, not the median.
- Failures concentrated in categories with *few or no training episodes* -> **coverage gap, add data**.
  This was the original diagnosis: radiolab scored 0.00 because NPR-style underwriting appeared in
  zero training episodes.
- Failures spread evenly across well-covered categories -> **not a data problem**. More of the same
  will not help; change threshold, context window, features, or add the LLM verify pass at
  inference.

**Stop when** two consecutive rounds improve gold median by < 0.02. That is diminishing returns;
spend the effort on the app instead.

## Gates

- **>= 0.85** — clears auto-skip. Even here, keep iterating: margin is what makes auto-skip safe on
  shows unlike anything in the corpus.
- **0.6-0.85** — ships as visible "Sponsor break" chapters (PRD 8.11), which need no gate: a false
  positive is a mislabeled chapter, not eaten content.
- **< 0.6** — diagnose, do not scale.

## Reference numbers (do not re-measure)

Teachers, median sponsor-F1 vs human gold:

| teacher | F1 | speed |
|---|---|---|
| Sonnet 5 | 1.000 | API |
| Haiku 4.5 | 0.957 | API |
| Qwen3-14B + verify | 0.950 | 76s/ep |
| **gpt-oss-20b + verify (chosen)** | **0.945** | **~30s/ep** |
| Qwen3-8B + verify | 0.823 | 40s/ep |
| Qwen3-4B | 0.620 | 22s/ep |
| Qwen3-1.7B (bundled in app) | 0.175 | 10s/ep |

Students: gold-label-trained 0.437, Sonnet-label-trained 0.534 (n=7, within noise — teacher labels
cost the student nothing measurable). Shipped LLM pipeline 0.515. Keyword-only 0.00.

## Traps already hit — do not repeat

- **Keyword pre-filtering the corpus.** Biases training toward keyword-detectable ads, the ones we
  already find easy. Sample broadly instead; ad-free episodes are useful negatives.
- **Snapping predicted ranges to segment edges.** Made scores worse (Sonnet 1.000 -> 0.946); gold
  boundaries are tighter than segment edges.
- **Truncating reasoning models.** gpt-oss emits an analysis channel first; a small token cap scores
  it at zero for parsing reasons. `local_teacher.final_channel` handles this.
- **Jinja templates silently ignore unknown kwargs**, so a try/except chain over
  `enable_thinking` / `reasoning_effort` always takes the first branch. Pass both together.
- **Text-only ceilings.** 21 of radiolab's 38s of ad time has no transcript text at all (silent DAI
  break). No text model can find it; a cue phrase plus a timestamp gap can.

## Licensing

SPoRC is research/education only and this repo is public: `poc/sporc/` is gitignored and must stay
so. Anything shipped should be rebuilt from RSS (SPoRC's catalog carries `rss_url`, so it doubles
as a categorised feed directory).
