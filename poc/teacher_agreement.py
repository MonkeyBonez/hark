"""Do two teachers disagreeing predict that the labels are wrong?

If yes, we get quality control for free: label everything with the cheap teacher, run a second
teacher, and only spend human/expensive attention where they diverge. Measures per episode:
teacher-vs-teacher overlap F1 (agreement) against each one's F1 vs gold (accuracy).

Usage: python3 teacher_agreement.py
"""

import json

import numpy as np

from common import EPISODES, load_ad_labels, ad_f1
from teacher_eval import ODIR, unclock


def ranges_of(model, ep):
    path = ODIR / model / f"{ep}.json"
    if not path.exists():
        return None
    return [(unclock(r["start"]), unclock(r["end"]))
            for r in json.load(open(path))["ranges"] if r.get("category") == "sponsor"]


def main():
    print(f"{'episode':<34} {'agree':>6} {'haiku':>6} {'sonnet':>6}   worst-vs-gold")
    agree, worst = [], []
    for ep in EPISODES:
        h, s = ranges_of("haiku", ep), ranges_of("sonnet", ep)
        if h is None or s is None:
            continue
        gold = load_ad_labels(ep, ("sponsor",))
        a = ad_f1(h, s)[2]                      # teacher-vs-teacher, no gold needed
        fh, fs = ad_f1(h, gold)[2], ad_f1(s, gold)[2]
        agree.append(a)
        worst.append(min(fh, fs))
        print(f"{ep:<34} {a:6.2f} {fh:6.2f} {fs:6.2f}   {min(fh, fs):.2f}")

    if len(agree) > 2:
        r = np.corrcoef(agree, worst)[0, 1]
        print(f"\ncorrelation(agreement, worst-teacher-accuracy) = {r:.2f} over {len(agree)} episodes")
        print("high positive => disagreement is a usable 'needs review' flag (n is small; "
              "treat as directional)")


if __name__ == "__main__":
    main()
