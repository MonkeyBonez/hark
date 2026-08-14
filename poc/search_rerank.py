"""POC 1b: RAG-style rerank — embeddings retrieve top-10, the bundled 1.7B LLM picks the best 3.

Retrieval ceiling from search_eval.py: minilm-l6 R@10 = 0.98. If the LLM can spot the right
passage among 10, R@3 approaches that ceiling (gate: >= 0.90; embeddings alone: 0.816).

Uses the app's actual bundled weights (Qwen3-1.7B-4bit via mlx-lm) so latency and behavior are
representative of on-device. Each call sees ~10 short passages — snip-enrichment-sized prompts,
nowhere near the whole-transcript path that crashes the device.

Usage: python3 poc/search_rerank.py
"""

import re
import time

import numpy as np
from mlx_lm import load, generate
from sentence_transformers import SentenceTransformer

from common import EPISODES, load_episode, load_queries, recall_at_k

WEIGHTS = "../HarkApp/Models/mlx-community__Qwen3-1.7B-4bit"
TOP_N = 10


def build_prompt(tokenizer, query, passages):
    numbered = "\n".join(f"{i + 1}. {p}" for i, p in enumerate(passages))
    user = (
        "A listener is searching a podcast transcript for a moment.\n"
        f'Search: "{query}"\n\n'
        f"Candidate passages:\n{numbered}\n\n"
        "Which passages match what the listener means? Answer with EXACTLY one line:\n"
        "BEST: <up to three passage numbers, best first, comma-separated>"
    )
    return tokenizer.apply_chat_template(
        [{"role": "user", "content": user}],
        add_generation_prompt=True, enable_thinking=False)


def parse_best(reply, n):
    reply = re.sub(r"<think>.*?</think>", "", reply, flags=re.S)
    m = re.search(r"BEST:\s*([0-9,\s]+)", reply)
    if not m:
        return []
    picks = []
    for tok in m.group(1).split(","):
        tok = tok.strip()
        if tok.isdigit() and 1 <= int(tok) <= n and int(tok) - 1 not in picks:
            picks.append(int(tok) - 1)
    return picks[:3]


def main():
    enc = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
    model, tokenizer = load(WEIGHTS)

    base_hits = {1: 0, 3: 0}
    rerank_hits = 0
    ceiling_hits = 0
    total = 0
    latencies = []

    for ep in EPISODES:
        _, segments = load_episode(ep)
        queries = load_queries(ep)
        texts = [s["text"] for s in segments]
        doc_vecs = enc.encode(texts, normalize_embeddings=True, batch_size=64,
                              show_progress_bar=False)
        q_vecs = enc.encode([q["query"] for q in queries], normalize_embeddings=True,
                            show_progress_bar=False)
        sims = q_vecs @ doc_vecs.T
        ranked = [np.argsort(row)[::-1].tolist() for row in sims]

        for k in base_hits:
            base_hits[k] += recall_at_k(ranked, queries, segments, k)
        ceiling_hits += recall_at_k(ranked, queries, segments, TOP_N)
        total += len(queries)

        for qi, q in enumerate(queries):
            top = ranked[qi][:TOP_N]
            # Give the LLM a little context around each hit segment for readability.
            passages = []
            for i in top:
                lo, hi = max(0, i - 1), min(len(segments), i + 2)
                passages.append(" ".join(s["text"] for s in segments[lo:hi])[:400])
            t0 = time.time()
            prompt = build_prompt(tokenizer, q["query"], passages)
            reply = generate(model, tokenizer, prompt=prompt, max_tokens=64)
            latencies.append(time.time() - t0)
            picks = parse_best(reply, len(top)) or [0, 1, 2]
            chosen = [top[p] for p in picks]
            hit = any(segments[i]["startMs"] < q["targetEndMs"]
                      and segments[i]["endMs"] > q["targetStartMs"] for i in chosen)
            rerank_hits += hit
        print(f"{ep}: done (running rerank R@3 = {rerank_hits}/{total})")

    print(f"\n=== rerank over {total} queries (gate >= 0.90) ===")
    print(f"minilm R@1 (no rerank):      {base_hits[1] / total:.3f}")
    print(f"minilm R@3 (no rerank):      {base_hits[3] / total:.3f}")
    print(f"minilm R@{TOP_N} (= rerank ceiling): {ceiling_hits / total:.3f}")
    print(f"rerank R@3 (LLM picks 3/{TOP_N}):  {rerank_hits / total:.3f}")
    print(f"LLM latency/query: mean {np.mean(latencies):.2f}s  p90 {np.percentile(latencies, 90):.2f}s")


if __name__ == "__main__":
    main()
