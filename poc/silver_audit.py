"""Measure how good the local teacher's silver labels are, without paying to re-label everything.

Design (user's, plus one addition): the local teacher labels all 390 episodes for free; Sonnet then
adjudicates. Confirming every episode would cost ~$30 and hours; confirming a *stratified sample*
answers the same question — "how much should we trust these labels?" — for about a dollar.

The addition: sample ad-NEGATIVE episodes too. A confirm-only-the-positives pipeline can delete
false positives but never discovers ads the local teacher missed entirely, so recall would be
silently capped at whatever the local model can see. Auditing negatives measures that miss rate.

  prep  <teacher-tag> [--positives 12] [--negatives 8]
        picks a category-spread sample and writes numbered transcripts for the labeling agents
  score <teacher-tag>
        compares agent labels in sporc/audit/out/<ep>.json against the teacher's silver labels

Usage: python3 silver_audit.py prep gpt-oss-20b-MXFP4-Q8
"""

import json
import sys
from pathlib import Path

import numpy as np

from common import AD_CATEGORIES, ad_f1

HERE = Path(__file__).resolve().parent
EPISODES_DIR = HERE / "sporc" / "episodes"
AUDIT = HERE / "sporc" / "audit"


def clock(ms):
    s = ms // 1000
    return f"{s // 3600}:{(s % 3600) // 60:02}:{s % 60:02}"


def _silver(tag):
    d = HERE / "sporc" / "labels" / tag
    if not d.exists():
        sys.exit(f"no silver labels at {d} — run make_silver.py first")
    return {f.stem: json.load(open(f)) for f in d.glob("*.json")}


def prep(tag, n_pos=12, n_neg=8):
    silver = _silver(tag)
    pos, neg = [], []
    for ep_id, lab in silver.items():
        (pos if lab["ranges"] else neg).append((lab.get("category", "?"), ep_id))
    # Spread across categories: sorting by category then striding avoids sampling one style.
    pick = sorted(pos)[::max(1, len(pos) // max(1, n_pos))][:n_pos] \
        + sorted(neg)[::max(1, len(neg) // max(1, n_neg))][:n_neg]

    out = AUDIT / "transcripts"
    out.mkdir(parents=True, exist_ok=True)
    for category, ep_id in pick:
        ep = json.load(open(EPISODES_DIR / f"{ep_id}.json"))
        lines = [f"[{clock(s['startMs'])}-{clock(s['endMs'])}] {s['text']}"
                 for s in ep["transcript"]["segments"]]
        (out / f"{ep_id}.txt").write_text("\n".join(lines))
    (AUDIT / "sample.json").write_text(json.dumps(
        {"teacher": tag,
         "positives": [e for _, e in pick[:n_pos]], "negatives": [e for _, e in pick[n_pos:]]},
        indent=1))
    print(f"{len(pick)} episodes ({len(pick[:n_pos])} teacher-positive, {len(pick[n_pos:])} "
          f"teacher-negative) -> {out}")
    print(f"agents should write labels to {AUDIT / 'out'}/<episodeId>.json")


def score(tag):
    silver = _silver(tag)
    sample = json.load(open(AUDIT / "sample.json"))
    out_dir = AUDIT / "out"

    def unclock(t):
        parts = [int(x) for x in str(t).split(":")]
        while len(parts) < 3:
            parts.insert(0, 0)
        return (parts[0] * 3600 + parts[1] * 60 + parts[2]) * 1000

    rows, missed = [], 0
    for group in ("positives", "negatives"):
        for ep_id in sample[group]:
            f = out_dir / f"{ep_id}.json"
            if not f.exists():
                continue
            ref = [(unclock(r["start"]), unclock(r["end"]))
                   for r in json.load(open(f))["ranges"] if r.get("category") in AD_CATEGORIES]
            got = [(s, e) for s, e in silver[ep_id]["ranges"]]
            p, r, f1 = ad_f1(got, ref)
            rows.append((group, ep_id, silver[ep_id].get("category", "?"), p, r, f1))
            if group == "negatives" and ref:
                missed += 1

    print(f"{'group':<10} {'category':<10} {'P':>5} {'R':>5} {'F1':>5}")
    for group, ep_id, cat, p, r, f1 in rows:
        print(f"{group:<10} {cat:<10} {p:5.2f} {r:5.2f} {f1:5.2f}")
    if rows:
        pos = [f1 for g, _, _, _, _, f1 in rows if g == "positives"]
        print(f"\nsilver-vs-Sonnet median F1 on teacher-positive episodes: {np.median(pos):.3f}")
        n_neg = sum(1 for g, *_ in rows if g == "negatives")
        print(f"teacher-negative episodes where Sonnet DID find ads: {missed}/{n_neg} "
              f"(this is the recall leak a confirm-only-positives pipeline cannot see)")


if __name__ == "__main__":
    cmd, tag = sys.argv[1], sys.argv[2]
    if cmd == "prep":
        kw = {}
        for flag, key in (("--positives", "n_pos"), ("--negatives", "n_neg")):
            if flag in sys.argv:
                kw[key] = int(sys.argv[sys.argv.index(flag) + 1])
        prep(tag, **kw)
    else:
        score(tag)
