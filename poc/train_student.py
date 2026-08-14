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

from common import AD_CATEGORIES, EPISODES, load_episode, load_ad_labels, ad_f1, f_beta, segments_to_ranges
from tune_student import context_text, position_features

HERE = Path(__file__).resolve().parent
ENCODER = "BAAI/bge-small-en-v1.5"

# Winning recipe from tune_student.py (leave-one-episode-out on gold, ranked by F2):
# ctx=2, position features on, smoothing 5, linear head -> P .53 R .63 F1 .54 F2 .68
# (baseline ctx=1/no-position/smooth-3/threshold-0.6 was F1 .44). Position features only pay off
# at ctx=2 — at ctx=1 they actively hurt, so the two must be changed together.
CONTEXT_WIDTH = 2
USE_POSITION = True
SMOOTH_WINDOW = 5


def normalize_segments(segments, target_words=7, max_ms=4000):
    """Merge consecutive segments up to roughly gold's granularity.

    Measured mismatch: gold (SpeechTranscriber) segments are median 2.9s / 10 words; SPoRC's
    diarization *turns* are median 1.2s / 3 words — often bare interjections ("Yeah."). Training on
    3-word fragments and inferring on 10-word sentences means every context and smoothing width
    covers a different amount of time in each corpus, and 3 words carry almost no signal to embed.
    That mismatch made 60x more data score WORSE than the tiny gold-trained model.

    Labels are time ranges, so re-segmenting costs no re-labeling.
    """
    out, buf = [], None
    for s in segments:
        if buf is None:
            buf = dict(s)
            continue
        long_enough = len(buf["text"].split()) >= target_words
        would_overrun = s["endMs"] - buf["startMs"] > max_ms
        if long_enough or would_overrun:
            out.append(buf)
            buf = dict(s)
        else:
            buf = {**buf, "text": f"{buf['text']} {s['text']}".strip(), "endMs": s["endMs"]}
    if buf is not None:
        out.append(buf)
    return out


def featurize(enc, segments):
    texts = [context_text(segments, i, CONTEXT_WIDTH) for i in range(len(segments))]
    X = enc.encode(texts, normalize_embeddings=True, batch_size=64, show_progress_bar=False)
    return np.hstack([X, position_features(segments)]) if USE_POSITION else X


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
        segments = normalize_segments(ep["transcript"]["segments"])
        ranges = [(s, e) for s, e in lab["ranges"]]
        rows.append({"id": lab["episodeId"], "category": lab.get("category", "?"),
                     "segments": segments, "X": featurize(enc, segments),
                     "y": labels_for(segments, ranges)})
    return rows


def load_gold(enc):
    rows = []
    for ep in EPISODES:
        _, segments = load_episode(ep)
        rows.append({"id": ep, "segments": segments, "X": featurize(enc, segments),
                     "gold": load_ad_labels(ep, AD_CATEGORIES)})
    return rows


def evaluate(clf, rows, threshold, truth_key):
    """Returns (id, precision, recall, F1, F2) per episode. F2 is the headline metric — skipping is
    optional, so missing an ad (option never offered) costs more than a spurious marker."""
    out = []
    for r in rows:
        probs = clf.predict_proba(r["X"])[:, 1]
        smooth = np.convolve(probs, np.ones(SMOOTH_WINDOW) / SMOOTH_WINDOW, mode="same")
        pred = segments_to_ranges(smooth >= threshold, r["segments"])
        truth = r[truth_key] if truth_key == "gold" else \
            segments_to_ranges(r["y"].astype(bool), r["segments"])
        p, rec, f1 = ad_f1(pred, truth)
        out.append((r["id"], p, rec, f1, f_beta(p, rec, 2.0)))
    return out


def main():
    tag = sys.argv[1]
    holdout = int(sys.argv[sys.argv.index("--holdout") + 1]) if "--holdout" in sys.argv else 8
    threshold = float(sys.argv[sys.argv.index("--threshold") + 1]) if "--threshold" in sys.argv else None

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

    # Carve a validation slice out of TRAIN to choose the threshold. Guessing it is a real error:
    # at a 1.5% positive rate, class_weight="balanced" weights ads ~65:1, so the operating point
    # moves a long way and a hand-picked threshold lands nowhere near optimal.
    val = train[::8]
    val_ids = {r["id"] for r in val}
    fit_rows = [r for r in train if r["id"] not in val_ids]

    ad_frac = np.concatenate([r["y"] for r in fit_rows]).mean()
    print(f"training on {len(fit_rows)} episodes ({ad_frac:.1%} of sentences labeled ad), "
          f"{len(val)} for threshold selection")

    clf = LogisticRegression(max_iter=2000, class_weight="balanced", C=1.0)
    clf.fit(np.vstack([r["X"] for r in fit_rows]), np.concatenate([r["y"] for r in fit_rows]))

    if threshold is None:
        best, threshold = -1.0, 0.5
        for thr in np.arange(0.30, 0.96, 0.05):
            f2s = [x[4] for x in evaluate(clf, val, thr, "y")]
            if np.median(f2s) > best:
                best, threshold = np.median(f2s), thr
        print(f"threshold {threshold:.2f} chosen on validation episodes (F2 {best:.3f})")

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
