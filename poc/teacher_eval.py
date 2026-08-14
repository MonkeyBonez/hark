"""Teacher-quality eval: how well do candidate labeling models reproduce the gold ad labels?

The silver-data plan (see FINDINGS.md) trains a tiny on-device classifier on teacher-labeled
episodes. The student's ceiling is the teacher's accuracy, so before scaling: score each teacher
against the human-audited gold set, using the same time-overlap sponsor-F1 as everything else.

  prep:  dump per-episode transcripts with [h:mm:ss] line timestamps for the labeling agents
  score: read out/<model>/<episode>.json produced by the agents, score vs gold

Usage: python3 teacher_eval.py prep | python3 teacher_eval.py score
"""

import json
import sys
from pathlib import Path

import numpy as np

from common import EPISODES, load_episode, load_ad_labels, ad_f1

HERE = Path(__file__).resolve().parent
TDIR = HERE / "teacher_eval" / "transcripts"
ODIR = HERE / "teacher_eval" / "out"


def clock(ms):
    s = ms // 1000
    return f"{s // 3600}:{(s % 3600) // 60:02}:{s % 60:02}"


def unclock(text):
    parts = [int(p) for p in str(text).split(":")]
    while len(parts) < 3:
        parts.insert(0, 0)
    h, m, s = parts
    return (h * 3600 + m * 60 + s) * 1000


def prep():
    """Emit start-END timestamps per line. v1 emitted only the start, which forced labelers to
    express an ad's end as 'the start of the next line' — and truncated any ad that runs to the
    end of the file (cost Sonnet ~0.8 F1 on radiolab). With both stamps, an ad's end is just the
    end stamp of its last line."""
    TDIR.mkdir(parents=True, exist_ok=True)
    for ep in EPISODES:
        _, segments = load_episode(ep)
        lines = [f"[{clock(s['startMs'])}-{clock(s['endMs'])}] {s['text']}" for s in segments]
        (TDIR / f"{ep}.txt").write_text("\n".join(lines))
        print(f"{ep}: {len(lines)} lines -> {TDIR / (ep + '.txt')}")


def analyze():
    """How much labeled ad time has NO transcript text behind it?

    Produced/DAI ads are often music or ASR-dropped audio: the transcript shows a silent gap where
    the ad ran. That time is invisible to ANY text-based detector — teacher or on-device student —
    so it bounds what this whole approach can score. Detecting it needs the gap itself as a signal.
    """
    print(f"{'episode':<34} {'gold ad':>8} {'w/ text':>8} {'silent':>8}  text-visible ceiling")
    for ep in EPISODES:
        _, segments = load_episode(ep)
        gold = load_ad_labels(ep, ("sponsor",))
        total = sum(e - s for s, e in gold)
        with_text = 0
        for s, e in gold:
            for seg in segments:
                with_text += max(0, min(e, seg["endMs"]) - max(s, seg["startMs"]))
        silent = max(0, total - with_text)
        ceiling = with_text / total if total else 1.0
        print(f"{ep:<34} {total / 1000:7.0f}s {with_text / 1000:7.0f}s {silent / 1000:7.0f}s"
              f"  {ceiling:.2f}" + ("   (no sponsor GT)" if not total else ""))


def score():
    models = sorted(p.name for p in ODIR.iterdir() if p.is_dir())
    print(f"{'episode':<34}" + "".join(f" {m:>10}" for m in models))
    medians = {}
    per_model = {m: [] for m in models}
    for ep in EPISODES:
        gold = load_ad_labels(ep, ("sponsor",))
        row = f"{ep:<34}"
        for m in models:
            path = ODIR / m / f"{ep}.json"
            if not path.exists():
                row += f" {'—':>10}"
                continue
            ranges = json.load(open(path))["ranges"]
            pred = [(unclock(r["start"]), unclock(r["end"]))
                    for r in ranges if r.get("category") == "sponsor"]
            f1 = ad_f1(pred, gold)[2]
            per_model[m].append(f1)
            row += f" {f1:10.2f}"
        print(row + ("   (no sponsor GT)" if not gold else ""))
    for m in models:
        medians[m] = float(np.median(per_model[m])) if per_model[m] else 0.0
    print("\nmedian sponsor-F1 vs gold: "
          + "  ".join(f"{m}={medians[m]:.3f}" for m in models))
    print("references: on-device pipeline 0.515; POC hybrid 0.580; "
          "gold self-consistency 1.00; auto-skip gate 0.85")


if __name__ == "__main__":
    {"prep": prep, "score": score}[sys.argv[1]]()
