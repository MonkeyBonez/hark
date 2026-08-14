"""POC 2b: classifier candidates + LLM verify — the D29 architecture with the embedding
classifier replacing the per-line LLM classify as the candidate stage.

The classifier (ads_classifier.py) is high-recall/cheap; the bundled Qwen3-1.7B then reads each
candidate block once and answers VERDICT: ad|content (fail-open: unparseable = keep). One LLM
call per block (~a handful per episode) instead of one per line (~400).

Usage: poc/.venv/bin/python poc/ads_hybrid.py
"""

import re

import numpy as np
from mlx_lm import load, generate
from sentence_transformers import SentenceTransformer
from sklearn.linear_model import LogisticRegression

from common import EPISODES, load_episode, load_ad_labels, ad_f1
from ads_classifier import build_episode, predict_ranges, EVAL_CATEGORIES

WEIGHTS = "../HarkApp/Models/mlx-community__Qwen3-1.7B-4bit"

VERIFY_INSTRUCTIONS = (
    "You classify podcast transcript excerpts. A block is an AD only if it is a sponsor read or "
    "paid promotion (product pitch, promo code, sponsor URL, 'this episode is brought to you "
    "by'). The host discussing companies/products as content, or promoting their OWN show, "
    "newsletter, or events, is CONTENT."
)


def verify(model, tokenizer, text):
    user = (f"{VERIFY_INSTRUCTIONS}\n\nExcerpt:\n{text[:1500]}\n\n"
            "Answer with EXACTLY one line:\nVERDICT: ad or VERDICT: content")
    prompt = tokenizer.apply_chat_template([{"role": "user", "content": user}],
                                           add_generation_prompt=True, enable_thinking=False)
    reply = generate(model, tokenizer, prompt=prompt, max_tokens=16)
    reply = re.sub(r"<think>.*?</think>", "", reply, flags=re.S).lower()
    if "verdict: content" in reply:
        return False
    return True  # 'ad' or unparseable -> keep (fail-open, D29)


def block_text(segments, start_ms, end_ms):
    return " ".join(s["text"] for s in segments if s["startMs"] < end_ms and s["endMs"] > start_ms)


def main():
    enc = SentenceTransformer("BAAI/bge-small-en-v1.5")
    model, tokenizer = load(WEIGHTS)
    data = {ep: build_episode(enc, ep) for ep in EPISODES}

    before, after = [], []
    print(f"{'episode':<34} {'F1 before':>9} {'F1 after':>9}  blocks kept")
    for held in EPISODES:
        train_eps = [e for e in EPISODES if e != held]
        clf = LogisticRegression(max_iter=2000, class_weight="balanced", C=1.0)
        clf.fit(np.vstack([data[e][1] for e in train_eps]),
                np.concatenate([data[e][2] for e in train_eps]))

        segs, X, _ = data[held]
        # Recall-leaning threshold: the verify pass is what buys precision back.
        candidates = predict_ranges(segs, clf.predict_proba(X)[:, 1], 0.6)
        kept = [(s, e) for s, e in candidates if verify(model, tokenizer, block_text(segs, s, e))]

        gt = load_ad_labels(held, EVAL_CATEGORIES)
        f1_b = ad_f1(candidates, gt)[2]
        f1_a = ad_f1(kept, gt)[2]
        before.append(f1_b)
        after.append(f1_a)
        print(f"{held:<34} {f1_b:9.2f} {f1_a:9.2f}  {len(kept)}/{len(candidates)}"
              + ("   (no sponsor GT)" if not gt else ""))

    print(f"\nmedian F1: candidates-only {np.median(before):.3f} -> +verify {np.median(after):.3f}")
    print("baseline: full-LLM pipeline 0.515 median; auto-skip gate >= 0.85")


if __name__ == "__main__":
    main()
