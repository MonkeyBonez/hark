"""Build a style-diverse podcast corpus from SPoRC for silver labeling.

Why: every number so far rests on 7 episodes that are mostly host-read business/interview shows.
The student's failures are all "this style wasn't in training" (radiolab 0.00). SPoRC has 1.1M
episodes across 228k podcasts and 60+ languages, with turn-level text and timings — the same shape
our own ASR produces — so it's the cheapest way to buy style diversity.

Caveats recorded in FINDINGS: SPoRC is May-June 2020 (pre-dates today's heavy dynamic ad
insertion), research/education licensed, and its transcripts come from a different ASR than ours.
So it's for method validation and teacher selection; anything shipped should be rebuilt from RSS.

Episodes are written in the same JSON shape as .eval-corpus/artifacts so every existing script
(local_teacher, ads_classifier, teacher_eval) reads them unchanged.

Usage:
  python3 sporc_corpus.py build [--shards 4] [--per-category 4] [--min-turns 40]
  python3 sporc_corpus.py stats
"""

import json
import sys
from pathlib import Path

import pandas as pd
from huggingface_hub import HfApi, hf_hub_download

HERE = Path(__file__).resolve().parent
OUT = HERE / "sporc" / "episodes"
REPO = "blitt/SPoRC"
# Deliberately mild. A stricter filter (>=25 episodes) moved the ad-cue rate only 33% -> 39% while
# costing four whole categories: SPoRC's 2020 crawl is mostly long-tail shows, and no cheap filter
# changes that. Since local labeling is free, the answer is volume, not pre-selection — and ad-free
# episodes are useful negatives, not waste.
MIN_EPISODE_COUNT = 10

# Styles whose ad conventions differ most from our host-read business corpus. News/NPR-likes carry
# underwriting reads; comedy and crime carry produced spots; kids/religion often carry none.
# These are SPoRC's own single-word category values (see metadata/category_index.parquet).
WANTED = ["news", "crime", "comedy", "society", "health", "education", "sports", "business",
          "arts", "science", "technology", "religion", "history", "music", "kids", "sciences"]


def _shard_names(limit):
    api = HfApi()
    info = api.dataset_info(REPO, files_metadata=True)
    files = [(s.size or 0, s.rfilename) for s in (info.siblings or [])
             if s.rfilename.startswith("turns/text/part-") and s.rfilename.endswith(".parquet")]
    # Smallest shards first: they download fast and still hold thousands of episodes.
    return [name for _, name in sorted(files)[:limit]]


def build(n_shards=4, per_category=4, min_turns=40):
    OUT.mkdir(parents=True, exist_ok=True)

    cat_path = hf_hub_download(REPO, "metadata/category_index.parquet", repo_type="dataset")
    # Establishment filter. A broad SPoRC sample is dominated by tiny unmonetised 2020 shows: a
    # keyword probe of a naive sample found ad cues in only 13 of 40 episodes, with four whole
    # categories at zero. Preferring English shows with a real back catalogue raises the ad rate
    # without biasing *which kind* of ad we see — filtering by ad keywords would do that, and would
    # teach the student only the keyword-detectable ads it already finds easy.
    cat_meta = pd.read_parquet(hf_hub_download(REPO, "metadata/podcast_catalog.parquet",
                                               repo_type="dataset"),
                               columns=["podcast_id", "pod_title", "language", "episode_count"])
    est = cat_meta[(cat_meta["language"].astype(str).str.lower().str.startswith("en"))
                   & (cat_meta["episode_count"] >= MIN_EPISODE_COUNT)]
    established = set(est["podcast_id"])
    titles = est.set_index("podcast_id")["pod_title"].to_dict()
    print(f"{len(established):,} established English podcasts (>= {MIN_EPISODE_COUNT} episodes)")

    cats = pd.read_parquet(cat_path)
    cats["category"] = cats["category"].str.lower()
    # A podcast carries several categories. Prefer whichever WANTED style it matches (so a show
    # tagged both "society" and "comedy" can fill the comedy bucket) rather than an arbitrary first.
    rank = {c: i for i, c in enumerate(WANTED)}
    cats["rank"] = cats["category"].map(rank).fillna(len(WANTED))
    primary = (cats.sort_values("rank").drop_duplicates("podcast_id")
               .set_index("podcast_id")["category"])

    frames = []
    for name in _shard_names(n_shards):
        p = hf_hub_download(REPO, name, repo_type="dataset")
        frames.append(pd.read_parquet(p))
        print(f"  loaded {name}: {len(frames[-1]):,} turns")
    turns = pd.concat(frames, ignore_index=True)
    turns["category"] = turns["podcast_id"].map(primary).fillna("unknown")

    # One episode = one group of turns; require enough turns to be a real episode.
    sizes = turns.groupby("episode_id").size()
    keep = set(sizes[sizes >= min_turns].index)
    turns = turns[turns["episode_id"].isin(keep)]
    print(f"{turns['episode_id'].nunique():,} episodes with >= {min_turns} turns")

    chosen, counts = [], {}
    ep_meta = turns.drop_duplicates("episode_id").set_index("episode_id")[["category", "podcast_id"]]
    ep_meta = ep_meta[ep_meta["podcast_id"].isin(established)]
    print(f"{len(ep_meta):,} episodes from established podcasts")
    for ep_id, row in ep_meta.iterrows():
        cat = row["category"]
        if not any(w in cat for w in WANTED):
            continue
        bucket = next(w for w in WANTED if w in cat)
        if counts.get(bucket, 0) >= per_category:
            continue
        counts[bucket] = counts.get(bucket, 0) + 1
        chosen.append((ep_id, bucket, titles.get(row["podcast_id"], "?")))

    for ep_id, bucket, title in chosen:
        g = turns[turns["episode_id"] == ep_id].sort_values("start_time")
        segments = [{
            "id": f"{ep_id}-{i}",
            "text": str(row.turn_text).strip(),
            "startMs": int(float(row.start_time) * 1000),
            "endMs": int(float(row.end_time) * 1000),
            "speaker": str(row.speaker),
        } for i, row in enumerate(g.itertuples()) if str(row.turn_text).strip()]
        if not segments:
            continue
        (OUT / f"{ep_id}.json").write_text(json.dumps({
            "episodeId": ep_id,
            "category": bucket,
            "podcastTitle": title,
            "source": "sporc",
            "audioSeconds": segments[-1]["endMs"] / 1000,
            "transcript": {"episodeId": ep_id, "source": "sporc", "format": "turns",
                           "modelVersion": "sporc-v1", "segments": segments},
        }, indent=1))

    print(f"\nwrote {len(list(OUT.glob('*.json')))} episodes to {OUT}")
    for k in sorted(counts):
        print(f"  {k:<24} {counts[k]}")


def stats():
    files = sorted(OUT.glob("*.json"))
    if not files:
        print("no episodes yet — run: python3 sporc_corpus.py build")
        return
    by_cat, total_min = {}, 0.0
    for f in files:
        d = json.load(open(f))
        by_cat[d["category"]] = by_cat.get(d["category"], 0) + 1
        total_min += d["audioSeconds"] / 60
    print(f"{len(files)} episodes, {total_min / 60:.1f} hours of audio")
    for k in sorted(by_cat):
        print(f"  {k:<24} {by_cat[k]}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "stats"
    if cmd == "build":
        kw = {}
        for flag, key in (("--shards", "n_shards"), ("--per-category", "per_category"),
                          ("--min-turns", "min_turns")):
            if flag in sys.argv:
                kw[key] = int(sys.argv[sys.argv.index(flag) + 1])
        build(**kw)
    else:
        stats()
