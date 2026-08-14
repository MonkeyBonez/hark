"""Find the best student recipe — optimised for F2, because ad-skip is offered, not automatic.

Runs on the gold corpus with leave-one-episode-out, so it can run while silver labeling is still
going. The winning configuration is then applied to the silver run.

Levers swept:
  - threshold           the 0.6 default was chosen when precision was king; F2 wants it lower
  - smoothing window    ads are long contiguous blocks, so more smoothing may beat 3
  - context width       how many neighbouring sentences go into each embedding
  - position features   ads cluster at pre-roll / mid-roll / post-roll, which text cannot express
  - head                linear vs a small MLP (can it curve around "discussing vs advertising"?)

Every sweep is scored leave-one-episode-out, and the threshold is chosen on TRAINING episodes only
— tuning a threshold on the test set is training on it.

Usage: python3 tune_student.py [--quick]
"""

import sys

import numpy as np
from sentence_transformers import SentenceTransformer
from sklearn.linear_model import LogisticRegression
from sklearn.neural_network import MLPClassifier

from common import (AD_CATEGORIES, EPISODES, load_episode, load_ad_labels, ad_f1, f_beta,
                    segments_to_ranges)

ENCODER = "BAAI/bge-small-en-v1.5"
TRAIN_CATEGORIES = ("sponsor", "selfpromo", "crosspromo")
EVAL_CATEGORIES = AD_CATEGORIES


def context_text(segments, i, width):
    lo, hi = max(0, i - width), min(len(segments), i + width + 1)
    return " ".join(s["text"] for s in segments[lo:hi])


def position_features(segments):
    """Where in the episode a sentence sits. Ads cluster at the edges and around the midpoint;
    the text itself carries no such signal, so this is information the embedding cannot have."""
    total = max(1, segments[-1]["endMs"])
    feats = []
    for s in segments:
        rel = s["startMs"] / total
        feats.append([
            rel,                                   # 0..1 through the episode
            min(rel, 1 - rel),                     # distance to nearest edge (pre/post-roll)
            np.exp(-((rel - 0.5) ** 2) / 0.02),    # proximity to the midpoint (mid-roll)
            1.0 if s["startMs"] < 180_000 else 0.0,   # first 3 minutes
            1.0 if rel > 0.9 else 0.0,                # last 10%
        ])
    return np.array(feats, dtype=np.float32)


def build(enc, width, with_position):
    data = {}
    for ep in EPISODES:
        _, segments = load_episode(ep)
        texts = [context_text(segments, i, width) for i in range(len(segments))]
        X = enc.encode(texts, normalize_embeddings=True, batch_size=64, show_progress_bar=False)
        if with_position:
            X = np.hstack([X, position_features(segments)])
        train_ranges = load_ad_labels(ep, TRAIN_CATEGORIES)
        y = np.array([any(s["startMs"] < e and s["endMs"] > st for st, e in train_ranges)
                      for s in segments], dtype=int)
        data[ep] = (segments, X, y)
    return data


def predict(clf, segments, X, threshold, smooth_w):
    probs = clf.predict_proba(X)[:, 1]
    if smooth_w > 1:
        probs = np.convolve(probs, np.ones(smooth_w) / smooth_w, mode="same")
    return segments_to_ranges(probs >= threshold, segments)


def run_config(data, head, threshold_grid, smooth_w):
    """Leave-one-episode-out. Threshold picked on training episodes only, then applied to the
    held-out episode — so the reported score never saw its own tuning."""
    scores = []
    for held in EPISODES:
        train_eps = [e for e in EPISODES if e != held]
        X_tr = np.vstack([data[e][1] for e in train_eps])
        y_tr = np.concatenate([data[e][2] for e in train_eps])
        clf = (LogisticRegression(max_iter=2000, class_weight="balanced", C=1.0) if head == "linear"
               else MLPClassifier(hidden_layer_sizes=(64,), max_iter=400, random_state=0))
        clf.fit(X_tr, y_tr)

        best_thr, best = threshold_grid[0], -1.0
        for thr in threshold_grid:
            f2s = []
            for e in train_eps:
                segs, X, _ = data[e]
                p, r, _ = ad_f1(predict(clf, segs, X, thr, smooth_w),
                                load_ad_labels(e, EVAL_CATEGORIES))
                f2s.append(f_beta(p, r, 2.0))
            if np.median(f2s) > best:
                best, best_thr = np.median(f2s), thr

        segs, X, _ = data[held]
        p, r, f1 = ad_f1(predict(clf, segs, X, best_thr, smooth_w),
                         load_ad_labels(held, EVAL_CATEGORIES))
        scores.append((p, r, f1, f_beta(p, r, 2.0)))
    arr = np.array(scores)
    return arr[:, 0].mean(), arr[:, 1].mean(), np.median(arr[:, 2]), np.median(arr[:, 3])


def main():
    quick = "--quick" in sys.argv
    enc = SentenceTransformer(ENCODER)
    grid = np.arange(0.25, 0.75, 0.05)

    configs = []
    for width in ([1] if quick else [1, 2]):
        for with_pos in [False, True]:
            for smooth_w in ([3] if quick else [3, 5, 7]):
                for head in ["linear"] if quick else ["linear", "mlp"]:
                    configs.append((width, with_pos, smooth_w, head))

    print(f"sweeping {len(configs)} configs, leave-one-episode-out, ranked by F2\n")
    print(f"{'ctx':>3} {'pos':>4} {'smooth':>6} {'head':>6} | {'P':>5} {'R':>5} {'F1':>5} {'F2':>5}")
    cache, results = {}, []
    for width, with_pos, smooth_w, head in configs:
        key = (width, with_pos)
        if key not in cache:
            cache[key] = build(enc, width, with_pos)
        p, r, f1, f2 = run_config(cache[key], head, grid, smooth_w)
        results.append((f2, f1, p, r, width, with_pos, smooth_w, head))
        print(f"{width:>3} {str(with_pos):>4} {smooth_w:>6} {head:>6} | "
              f"{p:5.2f} {r:5.2f} {f1:5.2f} {f2:5.2f}")

    results.sort(reverse=True)
    f2, f1, p, r, width, with_pos, smooth_w, head = results[0]
    print(f"\nBEST by F2: ctx={width} position={with_pos} smooth={smooth_w} head={head}")
    print(f"  P={p:.2f} R={r:.2f} F1={f1:.2f} F2={f2:.2f}")
    print("\nbaseline (ctx=1, no position, smooth=3, linear, threshold 0.6): F1 ~0.44")
    print("NOTE: 7 episodes — treat gaps under ~0.05 as noise, and re-check on silver.")


if __name__ == "__main__":
    main()
