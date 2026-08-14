# Ad-detection improvement loop — autonomous playbook

The goal is an on-device ad detector. The loop below is the whole method; each round buys more
training data and re-measures. It is written to be resumable and self-directing: any session can
read this file, run one command, and know what the result means.

**Never train on gold.** The 7 human-labeled episodes in `HarkPipeline/docs/eval/labels/` are the
scoreboard. Training on them turns a measurement into a memorisation test.

## Dataset tiers (naming, user 2026-08-14)

| tier | labeled by | size | cost | role |
|---|---|---|---|---|
| **GOLD** | humans (agent-labeled then audited by Snehal) | 7 episodes | slow | final scoreboard; **never trained on** |
| **SILVER** | Sonnet | tens of episodes | ~$0.13/ep | powered eval set; reference for judging BRONZE and prompts |
| **BRONZE** | the local model (gpt-oss-20b on this Mac) | hundreds | free | bulk training data for the student |

Directories: gold = `HarkPipeline/docs/eval/labels/`, silver = `poc/sporc/audit/out/`,
bronze = `poc/sporc/labels/<teacher-tag>/`.

The point of the split: BRONZE is cheap enough to scale to thousands of episodes but noisy, so it
trains the student. SILVER is accurate enough to *judge* — it tells us how much to trust BRONZE and
whether a prompt change is real. GOLD is small and human-verified, so it is the only honest final
number and stays untouched.

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

## Gates — and which error to prefer

**Product decision (user, 2026-08-14): ad skipping is OPTIONAL — the app offers the skip, the user
takes it. Given that, prefer showing the option slightly too often over not often enough.**

This inverts the assumption the earlier numbers were tuned under. When a skip is *automatic*, a
false positive silently eats content the user wanted and costs trust permanently — so precision was
king and the bar was F1 >= 0.85. When the skip is *offered*, the costs flip:

| error | cost when skipping is automatic | cost when skipping is offered |
|---|---|---|
| false positive | eats real content — severe, trust-destroying | a "Sponsor break" marker the user ignores — minor |
| false negative | an unflagged ad, no worse than any other player | **the feature silently never appears** — this is now the expensive one |

**Consequences for how we measure and tune:**

- Report **precision, recall, F1 and F2** — F2 weights recall twice as heavily as precision and is
  the metric that matches this product. Rank rounds by F2, not F1.
- **Tune the threshold down** (0.6 was chosen under the precision-first assumption; try 0.35-0.5).
  Still tune it on training episodes only, never on gold.
- Keep the length floors: a >=30s block is worth offering, a 5s blip is noise regardless.
- The **>= 0.85 F1 gate still governs silent auto-skip** if we ever offer that as a setting. It is
  no longer the bar for shipping the feature at all.

Gate summary:
- **F2 >= ~0.7 with precision not collapsing** — ship as visible "Sponsor break" chapters / offered
  skips. This is the shipping target now.
- **F1 >= 0.85** — additionally safe to offer silent auto-skip as an opt-in setting.
- **< 0.5 with low recall** — diagnose, do not scale.

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

## Performance: batch the labeling run (do this before round 2)

Round 1 ran at **29s/episode** on an M4 Pro (14 CPU cores, 20 GPU cores, 16-core ANE, 24GB unified)
and used maybe a third of the machine:

- **No batching.** `mlx_lm.batch_generate` exists and we generated one window at a time. Each
  episode is 7-20 *independent* windows, and single-sequence decoding is memory-bandwidth-bound —
  most GPU cores idle waiting on weight reads. Batching 8-16 windows amortises each weight read
  across many sequences: expect **3-5x** (29s -> ~6-10s per episode).
- **ANE idle.** MLX is Metal-only. The Neural Engine is the right unit for the *embedder*, so
  embeddings can run there concurrently rather than queueing behind the LLM.
- **CPU idle** — the labeling process sat at 38% of one core.

**Consistency rule, and it matters more than the speed:** do NOT switch batching on mid-corpus.
Batched generation pads and masks differently and can produce subtly different output; a corpus
half-labeled each way bakes in an inconsistency the student will happily learn and we would never
see. Before using it for real: re-label ~5 already-labeled episodes batched and confirm the ranges
match the unbatched output. Only then run a whole round with it.

## Student recipe (swept on gold, leave-one-episode-out, ranked by F2)

`tune_student.py` swept 24 configurations. Winner, now the default in `train_student.py`:

**ctx=2 sentences each side, position features ON, smoothing 5, linear head** ->
P .53 / R .63 / F1 .54 / **F2 .68** (baseline ctx=1, no position, smooth 3, threshold 0.6: F1 .44).

Two things that only show up in the sweep:

- **Position features and context width interact.** Position features *hurt* at ctx=1
  (F2 .58 -> .49) and *help substantially* at ctx=2 (F2 .52 -> .67), consistently across all three
  smoothing widths. Never change one without re-testing the other.
- **The MLP head buys precision but loses recall** (P .50-.65, R .44-.55) so it loses on F2 despite
  often winning on F1. Keep it in mind if silent auto-skip ever becomes the goal — different metric,
  possibly different head.

Threshold is swept 0.25-0.75 and chosen on training episodes only. Re-run the sweep on silver
before trusting it: 7 episodes means gaps under ~0.05 are noise.

## Round 1 result: the silver run FAILED, and why (2026-08-14)

390 episodes labeled, student trained, and it scored **worse** than the 6-episode gold-trained
model: gold F1 0.35 / F2 0.55 vs gold-trained F1 0.54 / F2 0.68. Recall was high (0.85-1.00),
precision collapsed (0.10-0.34).

Three fixes were tried and none moved it: tuning the threshold on a validation split (F2 .565 ->
.547), re-segmenting SPoRC's 3-word diarization turns up to gold's 10-word granularity
(F2 -> .488), and checking for pathological ranges (only 1% of ranges exceed 5 min).

**The Sonnet audit found the actual cause: the teacher's labels on SPoRC are F1 0.588, not the
0.945 it scored on gold.** Two of five audited teacher-positive episodes were F1 0.00 — e.g. a
fiction reading whose `patreon.com` attribution was flagged as an ad — and one of three
teacher-negative episodes had a real sponsor read the teacher missed entirely.

**The methodological lesson, which is the important part:** we measured the teacher on gold
(seven well-known, professionally-produced shows) and then applied it to SPoRC (long-tail 2020
hobbyist podcasts) without re-validating. Teacher quality is **distribution-specific**. Never
reuse a teacher score across corpora — audit on the corpus you are actually labeling, *before*
spending hours labeling it. The audit costs ~12 episodes and would have caught this immediately.

Candidate fixes, cheapest first:
1. **Fix the prompt for this domain.** Failures look systematic — Patreon/attribution/self-promo
   mentions flagged as sponsor. Small podcasts are full of these; gold's shows are not.
2. **Filter the silver set** to episodes where two signals agree; fewer, cleaner labels.
3. **Pay for a better teacher**: Haiku over 390 episodes is ~$15, Sonnet ~$50 — cheap, but
   re-audit on SPoRC first rather than assuming their gold scores transfer either.
4. **Change corpus**: RSS-fetched current episodes of established shows sit much closer to gold's
   distribution (and dodge the 2020/licence problems).

## Prompt v2: NOT adopted (2026-08-14)

Restructured per the researched evidence — gpt-oss-safeguard 4-section schema, 6 contrastive
boundary cases taken from measured failures, task line repeated after the transcript (Post-Ins /
lost-in-the-middle). Deliberately skipped role prompting and CoT, both of which fail to replicate
for classification.

Paired A/B against SILVER, episode-level bootstrap:

| silver episodes | mean F2 old -> new | delta | 95% CI | P(better) |
|---|---|---|---|---|
| 8 | 0.693 -> 0.807 | +0.116 | [-0.070, +0.395] | 80% |
| 16 | 0.501 -> 0.609 | +0.110 | [-0.087, +0.310] | 86% |

Doubling the eval set moved the CI barely, because **the variance is per-episode, not sample-size
driven**: 8 of 16 episodes are exactly unchanged while a few swing +-0.8 (one 0.11 -> 0.82, another
0.81 -> 0.00). The prompt changes behaviour on a minority of episodes, dramatically.

At sd(delta) ~0.4, detecting a +0.11 effect needs roughly **64 silver episodes**. Until then a
prompt change is not measurable, and adopting on P=86% would be exactly the underpowered comparison
the literature warns about. **Keep the current prompt** — it already yields 0.859 bronze labels
under the corrected definition, so prompt tuning is a second-order optimisation.

Known v2 regression to fix if resumed: stacked cold opens (a self-promo immediately followed by a
sponsor read) — v2 returned NONE where the old prompt caught both blocks.

**Flaw in that A/B, stated plainly:** the "old" arm read the stored BRONZE labels, which were
generated with the *pre-definition-change* prompt. So the comparison moved two things at once — the
ad definition AND the structural changes — and cannot attribute the delta to either. A clean rerun
must re-label the old arm with the current definition and vary only structure. This is the standard
trap of comparing against cached outputs from an older pipeline; cache the *prompt* alongside the
labels so the arms are always identifiable.

## Corpus limitation found while building SILVER

Several Sonnet labellers reported ads they could not mark: SPoRC merges some passages into single
multi-minute ASR lines, so an ad embedded mid-line cannot be isolated without mislabelling minutes
of real content. That caps achievable precision on those episodes **for every method**, and is an
argument for rebuilding the corpus from RSS with our own sentence-level ASR rather than tuning
against it.

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
