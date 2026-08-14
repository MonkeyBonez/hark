"""Steps 4-5: train the on-device student on silver labels, score it on human gold.

Student = frozen bge-small (33M, ANE-friendly) + logistic head (385 numbers). That head is the
only thing trained here; at inference on the phone it's a dot product per sentence.

Two test signals, because gold is only 7 narrow episodes:
  - GOLD: the human-labeled corpus. The honest scoreboard; never trained on.
  - HELD-OUT SILVER: episodes the teacher labeled but the student never saw. If the student does
    well on gold but badly here (or vice versa), the two corpora disagree about what an ad is, and
    that disagreement is the finding.

Usage: python3 train_student.py <teacher-tag> [--holdout 8] [--threshold 0.6]
"""

import json
import sys
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer
from sklearn.linear_model import LogisticRegression

from common import EPISODES, load_episode, load_ad_labels, ad_f1, f_beta, segments_to_ranges

HERE = Path(__file__).resolve().parent
ENCODER = "BAAI/bge-small-en-v1.5"


def contextual(segments):
    """Each sentence embedded with its neighbours — an ad read is recognisable from its run-in."""
    out = []
    for i, s in enumerate(segments):
        prev = segments[i - 1]["text"] if i > 0 else ""
        nxt = segments[i + 1]["text"] if i + 1 < len(segments) else ""
        out.append(f"{prev} {s['text']} {nxt}".strip())
    return out


def labels_for(segments, ranges):
    return np.array([any(s["startMs"] < e and s["endMs"] > st for st, e in ranges)
                     for s in segments], dtype=int)


def load_silver(tag, enc):
    label_dir = HERE / "sporc" / "labels" / tag
    if not label_dir.exists():
        sys.exit(f"no silver labels at {label_dir} — run make_silver.py first")
    rows = []
    for f in sorted(label_dir.glob("*.json")):
        lab = json.load(open(f))
        ep = json.load(open(HERE / "sporc" / "episodes" / f"{lab['episodeId']}.json"))
        segments = ep["transcript"]["segments"]
        ranges = [(s, e) for s, e in lab["ranges"]]
        X = enc.encode(contextual(segments), normalize_embeddings=True, batch_size=64,
                       show_progress_bar=False)
        rows.append({"id": lab["episodeId"], "category": lab.get("category", "?"),
                     "segments": segments, "X": X, "y": labels_for(segments, ranges)})
    return rows


def load_gold(enc):
    rows = []
    for ep in EPISODES:
        _, segments = load_episode(ep)
        X = enc.encode(contextual(segments), normalize_embeddings=True, batch_size=64,
                       show_progress_bar=False)
        rows.append({"id": ep, "segments": segments, "X": X,
                     "gold": load_ad_labels(ep, ("sponsor",))})
    return rows


def evaluate(clf, rows, threshold, truth_key):
    """Returns (id, precision, recall, F1, F2) per episode. F2 is the headline metric — skipping is
    optional, so missing an ad (option never offered) costs more than a spurious marker."""
    out = []
    for r in rows:
        probs = clf.predict_proba(r["X"])[:, 1]
        smooth = np.convolve(probs, np.ones(3) / 3, mode="same")
        pred = segments_to_ranges(smooth >= threshold, r["segments"])
        truth = r[truth_key] if truth_key == "gold" else \
            segments_to_ranges(r["y"].astype(bool), r["segments"])
        p, rec, f1 = ad_f1(pred, truth)
        out.append((r["id"], p, rec, f1, f_beta(p, rec, 2.0)))
    return out


def main():
    tag = sys.argv[1]
    holdout = int(sys.argv[sys.argv.index("--holdout") + 1]) if "--holdout" in sys.argv else 8
    threshold = float(sys.argv[sys.argv.index("--threshold") + 1]) if "--threshold" in sys.argv else 0.6

    enc = SentenceTransformer(ENCODER)
    silver = load_silver(tag, enc)
    gold = load_gold(enc)
    print(f"silver: {len(silver)} episodes  |  gold: {len(gold)} episodes\n")

    # Hold out whole episodes, spread across categories, so the split tests generalisation to a
    # new show rather than to new sentences of a show already seen.
    silver_sorted = sorted(silver, key=lambda r: (r["category"], r["id"]))
    held = silver_sorted[::max(1, len(silver_sorted) // max(1, holdout))][:holdout]
    held_ids = {r["id"] for r in held}
    train = [r for r in silver if r["id"] not in held_ids]

    ad_frac = np.concatenate([r["y"] for r in train]).mean()
    print(f"training on {len(train)} episodes ({ad_frac:.1%} of sentences labeled ad)")

    clf = LogisticRegression(max_iter=2000, class_weight="balanced", C=1.0)
    clf.fit(np.vstack([r["X"] for r in train]), np.concatenate([r["y"] for r in train]))

    def report(title, rows):
        print(f"\n=== {title} ===")
        print(f"  {'episode':<34} {'P':>5} {'R':>5} {'F1':>5} {'F2':>5}")
        for name, p, r, f1, f2 in rows:
            print(f"  {name:<34} {p:5.2f} {r:5.2f} {f1:5.2f} {f2:5.2f}")
        med_f1 = np.median([x[3] for x in rows])
        med_f2 = np.median([x[4] for x in rows])
        print(f"  median F1 {med_f1:.3f} | median F2 {med_f2:.3f}   <- F2 is the shipping metric")
        return med_f1, med_f2

    report("GOLD (human labels, never trained on)", evaluate(clf, gold, threshold, "gold"))
    if held:
        report("HELD-OUT SILVER (teacher labels, unseen episodes)",
               evaluate(clf, held, threshold, "y"))

    print("\nreferences: gold-trained student F1 0.437, Sonnet-label-trained 0.534, "
          "shipped LLM pipeline 0.515")
    print("targets: F2 >= ~0.7 ships as offered skips / Sponsor-break chapters; "
          "F1 >= 0.85 additionally allows silent auto-skip")


if __name__ == "__main__":
    main()
