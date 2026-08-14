"""End-to-end test of the silver pipeline on the data we already have.

The plan is: teacher (LLM) auto-labels many episodes -> student (embeddings + logistic head) trains
on those labels -> student runs on-device. The open question is how much the student loses by
learning from teacher labels instead of human ones.

We can answer it now, because the teachers labeled the same 7 episodes the humans did: train the
student on GOLD labels vs on HAIKU labels vs on SONNET labels, and evaluate all three against gold
(leave-one-episode-out, identical in every other respect). Any gap is the cost of silver data.

Usage: python3 silver_student.py
"""

import json
from pathlib import Path

import numpy as np
from sentence_transformers import SentenceTransformer
from sklearn.linear_model import LogisticRegression

from common import EPISODES, load_episode, load_ad_labels, ad_f1
from ads_classifier import build_episode, predict_ranges
from teacher_eval import ODIR, unclock

THRESHOLD = 0.6


def teacher_ranges(model_name, ep):
    """All ad-ish ranges a teacher marked (any category — the student learns 'ad-ish' broadly,
    exactly as the gold-trained version does)."""
    path = ODIR / model_name / f"{ep}.json"
    if not path.exists():
        return None
    return [(unclock(r["start"]), unclock(r["end"])) for r in json.load(open(path))["ranges"]]


def labels_from(ranges, segments):
    return np.array([any(s["startMs"] < e and s["endMs"] > st for st, e in ranges)
                     for s in segments], dtype=int)


def main():
    enc = SentenceTransformer("BAAI/bge-small-en-v1.5")
    data = {ep: build_episode(enc, ep) for ep in EPISODES}          # (segments, X, y_gold)

    sources = {"gold": None, "haiku": "haiku", "sonnet": "sonnet"}
    results = {}

    for name, teacher in sources.items():
        # Per-episode training labels from this source.
        y_by_ep = {}
        for ep in EPISODES:
            segments, _, y_gold = data[ep]
            if teacher is None:
                y_by_ep[ep] = y_gold
            else:
                ranges = teacher_ranges(teacher, ep)
                y_by_ep[ep] = labels_from(ranges, segments) if ranges is not None else y_gold

        f1s = []
        for held in EPISODES:
            train_eps = [e for e in EPISODES if e != held]
            clf = LogisticRegression(max_iter=2000, class_weight="balanced", C=1.0)
            clf.fit(np.vstack([data[e][1] for e in train_eps]),
                    np.concatenate([y_by_ep[e] for e in train_eps]))
            segments, X, _ = data[held]
            pred = predict_ranges(segments, clf.predict_proba(X)[:, 1], THRESHOLD)
            f1s.append(ad_f1(pred, load_ad_labels(held, ("sponsor",)))[2])
        results[name] = f1s
        print(f"trained on {name:<7} per-episode F1: "
              + " ".join(f"{f:.2f}" for f in f1s) + f"   median {np.median(f1s):.3f}")

    print("\n(all evaluated against human gold labels; leave-one-episode-out)")
    print("If silver ≈ gold, teacher labels are good enough to scale the training set.")


if __name__ == "__main__":
    main()
