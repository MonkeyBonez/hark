"""Paired A/B of a teacher prompt against the Sonnet-audited episodes.

Measurement discipline follows the prompt-optimisation research:
  - the unit of analysis is the EPISODE, not the line-range (outcomes cluster within an episode);
  - comparisons are PAIRED on the same episodes at temp 0, which is the single biggest variance
    reduction available;
  - a paired bootstrap over episodes gives the CI, because with ~12 episodes a raw median moves
    +-0.10 on noise alone and any smaller "improvement" is unreadable.

Re-labels the audited episodes with the current prompt and compares to both the stored labels
(previous prompt) and the Sonnet reference.

Usage: python3 prompt_ab.py <model-id> [--tag new-prompt]
"""

import json
import sys
import time
from pathlib import Path

import numpy as np
from mlx_lm import load
from mlx_lm.sample_utils import make_sampler

from common import AD_CATEGORIES, ad_f1, f_beta
from local_teacher import label_episode, verify_block, block_text
from silver_audit import AUDIT, EPISODES_DIR, _silver

HERE = Path(__file__).resolve().parent


def unclock(t):
    parts = [int(x) for x in str(t).split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000


def reference(ep_id):
    f = AUDIT / "out" / f"{ep_id}.json"
    if not f.exists():
        return None
    return [(unclock(r["start"]), unclock(r["end"]))
            for r in json.load(open(f))["ranges"] if r.get("category") in AD_CATEGORIES]


def paired_bootstrap(a, b, n=10000, seed=0):
    """P(new > old) over episode-level resamples. Paired: the same episode indices are drawn for
    both arms, so per-episode difficulty cancels."""
    rng = np.random.default_rng(seed)
    a, b = np.asarray(a), np.asarray(b)
    idx = rng.integers(0, len(a), size=(n, len(a)))
    diffs = b[idx].mean(axis=1) - a[idx].mean(axis=1)
    return diffs.mean(), np.percentile(diffs, [2.5, 97.5]), (diffs > 0).mean()


def main():
    model_id = sys.argv[1]
    tag = sys.argv[sys.argv.index("--tag") + 1] if "--tag" in sys.argv else "new-prompt"
    old = _silver("gpt-oss-20b-MXFP4-Q8")
    sample = json.load(open(AUDIT / "sample.json"))
    episodes = [e for e in sample["positives"] + sample["negatives"] if reference(e) is not None]

    out_dir = HERE / "sporc" / "labels" / tag
    out_dir.mkdir(parents=True, exist_ok=True)
    model, tokenizer = load(model_id)
    sampler = make_sampler(temp=0.0)

    print(f"paired A/B on {len(episodes)} Sonnet-audited episodes\n")
    print(f"{'episode':<20} {'old F2':>7} {'new F2':>7}   delta")
    old_f2, new_f2 = [], []
    for ep_id in episodes:
        segs = json.load(open(EPISODES_DIR / f"{ep_id}.json"))["transcript"]["segments"]
        dest = out_dir / f"{ep_id}.json"
        if dest.exists():
            ranges = [(s, e) for s, e in json.load(open(dest))["ranges"]]
        else:
            t0 = time.time()
            ranges = label_episode(model, tokenizer, segs, 60, 10, sampler)
            ranges = [(s, e) for s, e in ranges
                      if verify_block(model, tokenizer, sampler, block_text(segs, s, e))]
            dest.write_text(json.dumps({"episodeId": ep_id, "model": tag,
                                        "ranges": [[s, e] for s, e in ranges]}))
            print(f"  (labeled {ep_id} in {time.time() - t0:.0f}s)")

        ref = reference(ep_id)
        po, ro, _ = ad_f1([(s, e) for s, e in old[ep_id]["ranges"]], ref)
        pn, rn, _ = ad_f1(ranges, ref)
        o, n = f_beta(po, ro, 2.0), f_beta(pn, rn, 2.0)
        old_f2.append(o)
        new_f2.append(n)
        print(f"{ep_id:<20} {o:7.2f} {n:7.2f}   {n - o:+.2f}")

    mean_d, ci, p_better = paired_bootstrap(old_f2, new_f2)
    print(f"\nmean F2: old {np.mean(old_f2):.3f} -> new {np.mean(new_f2):.3f}")
    print(f"paired delta {mean_d:+.3f}  95% CI [{ci[0]:+.3f}, {ci[1]:+.3f}]  "
          f"P(new better) = {p_better:.0%}")
    if ci[0] > 0:
        print("VERDICT: real improvement (CI excludes zero)")
    elif ci[1] < 0:
        print("VERDICT: real regression (CI excludes zero)")
    else:
        print("VERDICT: indistinguishable from noise at this sample size — "
              "expand the audited set before trusting either prompt")


if __name__ == "__main__":
    main()
