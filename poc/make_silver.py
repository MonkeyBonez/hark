"""Step 3 of the plan: the chosen teacher labels the diverse corpus -> the silver training set.

Reuses the exact windowed labeling the teacher bake-off scored, so the labels we train on are
produced the same way as the labels we measured. Output is one JSON per episode:
{"episodeId":..., "model":..., "ranges":[[startMs,endMs], ...]}

Usage:
  python3 make_silver.py <model-id> [--corpus sporc/episodes] [--limit N] [--no-verify]
"""

import json
import sys
import time
from pathlib import Path

from mlx_lm import load
from mlx_lm.sample_utils import make_sampler

from local_teacher import label_episode, verify_block, block_text

HERE = Path(__file__).resolve().parent


def load_corpus(corpus_dir):
    out = []
    for f in sorted((HERE / corpus_dir).glob("*.json")):
        d = json.load(open(f))
        out.append((d["episodeId"], d.get("category", "?"), d["transcript"]["segments"]))
    return out


def main():
    model_id = sys.argv[1]
    corpus_dir = "sporc/episodes"
    limit, verify = None, True
    if "--corpus" in sys.argv:
        corpus_dir = sys.argv[sys.argv.index("--corpus") + 1]
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])
    if "--no-verify" in sys.argv:
        verify = False

    tag = model_id.rstrip("/").split("/")[-1]
    out_dir = HERE / "sporc" / "labels" / tag
    out_dir.mkdir(parents=True, exist_ok=True)

    episodes = load_corpus(corpus_dir)[:limit]
    model, tokenizer = load(model_id)
    sampler = make_sampler(temp=0.0)
    print(f"labeling {len(episodes)} episodes with {tag} (verify={verify})\n")

    for i, (ep_id, category, segments) in enumerate(episodes, 1):
        dest = out_dir / f"{ep_id}.json"
        if dest.exists():
            print(f"[{i}/{len(episodes)}] {ep_id} ({category}) — cached")
            continue
        t0 = time.time()
        ranges = label_episode(model, tokenizer, segments, 60, 10, sampler)
        if verify:
            ranges = [(s, e) for s, e in ranges
                      if verify_block(model, tokenizer, sampler, block_text(segments, s, e))]
        dest.write_text(json.dumps({"episodeId": ep_id, "category": category, "model": tag,
                                    "ranges": [[s, e] for s, e in ranges]}))
        ad_s = sum(e - s for s, e in ranges) / 1000
        print(f"[{i}/{len(episodes)}] {ep_id} ({category}) — {len(ranges)} ranges, "
              f"{ad_s:.0f}s ad, {time.time() - t0:.0f}s")

    print(f"\nsilver labels in {out_dir}")


if __name__ == "__main__":
    main()
