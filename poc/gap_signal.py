"""Is a silent gap in the transcript an ad signal?

Produced / dynamically-inserted ads are often music or ASR-dropped audio: the transcript jumps
from one segment to the next with seconds of nothing in between (radiolab: 21s of the 38s of gold
ad time is silent). Text models are blind to that by construction — but the gap itself is free to
compute at transcription time, and pairs with the cue phrase right before it ("we'll be right
back", "after this short break").

Measures, across the corpus: how much gap time falls inside gold ad ranges vs content.

Usage: python3 gap_signal.py
"""

import re

from common import EPISODES, load_episode, load_ad_labels

MIN_GAP_MS = 5_000
CUE = re.compile(r"\b(right back|short break|after (the|this) break|we'?ll be back|stick around|"
                 r"more in a (moment|minute)|back in a (moment|minute))\b", re.I)


def main():
    print(f"{'episode':<34} {'gaps>=5s':>9} {'in ads':>7} {'w/ cue':>7}  gap time in ads")
    tot_gaps = tot_in_ad = tot_cue = tot_cue_in_ad = 0
    for ep in EPISODES:
        _, segs = load_episode(ep)
        gold = load_ad_labels(ep, ("sponsor",))
        gaps = []
        for prev, nxt in zip(segs, segs[1:]):
            gap = nxt["startMs"] - prev["endMs"]
            if gap >= MIN_GAP_MS:
                gaps.append((prev["endMs"], nxt["startMs"], bool(CUE.search(prev["text"]))))

        in_ad = [g for g in gaps if any(g[0] < e and g[1] > s for s, e in gold)]
        cued = [g for g in gaps if g[2]]
        cued_in_ad = [g for g in cued if g in in_ad]
        gap_ms = sum(g[1] - g[0] for g in gaps)
        ad_gap_ms = sum(g[1] - g[0] for g in in_ad)

        tot_gaps += len(gaps); tot_in_ad += len(in_ad)
        tot_cue += len(cued); tot_cue_in_ad += len(cued_in_ad)
        print(f"{ep:<34} {len(gaps):9} {len(in_ad):7} {len(cued):7}"
              f"  {ad_gap_ms / 1000:.0f}s of {gap_ms / 1000:.0f}s")

    print(f"\nall gaps >= {MIN_GAP_MS // 1000}s: {tot_in_ad}/{tot_gaps} land in a labeled ad "
          f"({tot_in_ad / max(1, tot_gaps):.0%} precision as a standalone signal)")
    print(f"gaps preceded by a break cue: {tot_cue_in_ad}/{tot_cue} land in a labeled ad "
          f"({tot_cue_in_ad / max(1, tot_cue):.0%} precision)")


if __name__ == "__main__":
    main()
