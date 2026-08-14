"""POC 2: lightweight ad classifier — embeddings + logistic regression, no LLM in the loop.

Per-segment: embed (prev + segment + next) with bge-small (33M, ANE-friendly), logistic
regression with balanced classes, leave-one-episode-out CV. Probabilities are smoothed over a
3-segment window (ads are contiguous blocks), thresholded (threshold picked on the 6 training
episodes only), then aggregated exactly like the pipeline (D25: merge gaps <= 20s, drop < 8s)
and scored with hark-bench's time-overlap F1 against the sponsor ground truth.

Baselines to beat: keyword candidates + per-line MLX classify + verify = median sponsor-F1 0.515
(D38); keyword-only candidates = 0.00.

Usage: poc/.venv/bin/python poc/ads_classifier.py   (or python3; venv not required here)
"""

import numpy as np
from sentence_transformers import SentenceTransformer
from sklearn.linear_model import LogisticRegression

from common import EPISODES, load_episode, load_ad_labels, ad_f1, segments_to_ranges

TRAIN_CATEGORIES = ("sponsor", "selfpromo", "crosspromo")  # learn "ad-ish" broadly
EVAL_CATEGORIES = ("sponsor",)                             # score against sponsor GT (as D38 did)


def overlaps(seg, ranges):
    return any(seg["startMs"] < e and seg["endMs"] > s for s, e in ranges)


def build_episode(enc, ep):
    _, segments = load_episode(ep)
    texts = []
    for i, s in enumerate(segments):
        prev_text = segments[i - 1]["text"] if i > 0 else ""
        next_text = segments[i + 1]["text"] if i + 1 < len(segments) else ""
        texts.append(f"{prev_text} {s['text']} {next_text}".strip())
    X = enc.encode(texts, normalize_embeddings=True, batch_size=64, show_progress_bar=False)
    train_ranges = load_ad_labels(ep, TRAIN_CATEGORIES)
    y = np.array([overlaps(s, train_ranges) for s in segments], dtype=int)
    return segments, X, y


def smooth(probs, w=3):
    kernel = np.ones(w) / w
    return np.convolve(probs, kernel, mode="same")


def predict_ranges(segments, probs, threshold):
    flags = smooth(probs) >= threshold
    return segments_to_ranges(flags, segments)


def main():
    enc = SentenceTransformer("BAAI/bge-small-en-v1.5")
    data = {ep: build_episode(enc, ep) for ep in EPISODES}
    thresholds = np.arange(0.3, 0.85, 0.05)

    f1s = []
    print(f"{'episode':<34} {'P':>5} {'R':>5} {'F1':>5}  thr")
    for held in EPISODES:
        train_eps = [e for e in EPISODES if e != held]
        X_tr = np.vstack([data[e][1] for e in train_eps])
        y_tr = np.concatenate([data[e][2] for e in train_eps])
        clf = LogisticRegression(max_iter=2000, class_weight="balanced", C=1.0)
        clf.fit(X_tr, y_tr)

        # Pick the threshold on TRAINING episodes only (median of their per-episode F1).
        best_thr, best_score = 0.5, -1.0
        for thr in thresholds:
            scores = []
            for e in train_eps:
                segs, X, _ = data[e]
                pred = predict_ranges(segs, clf.predict_proba(X)[:, 1], thr)
                scores.append(ad_f1(pred, load_ad_labels(e, EVAL_CATEGORIES))[2])
            med = float(np.median(scores))
            if med > best_score:
                best_score, best_thr = med, thr

        segs, X, _ = data[held]
        pred = predict_ranges(segs, clf.predict_proba(X)[:, 1], best_thr)
        gt = load_ad_labels(held, EVAL_CATEGORIES)
        p, r, f1 = ad_f1(pred, gt)
        f1s.append(f1)
        print(f"{held:<34} {p:5.2f} {r:5.2f} {f1:5.2f}  {best_thr:.2f}"
              + ("   (no sponsor GT)" if not gt else ""))

    print(f"\nmedian sponsor-F1 (leave-one-episode-out): {np.median(f1s):.3f}")
    print("baselines: MLX per-line classify + verify = 0.515 median; keyword-only = 0.00; "
          "auto-skip gate >= 0.85")


if __name__ == "__main__":
    main()
