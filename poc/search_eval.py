"""POC 1: retrieval quality for find-a-moment search, iPhone-14-Pro-feasible models only.

Compares, on the exact score-recall protocol (segment-level, hit = top-k overlap with target):
  - BM25 (lexical — what FTS5 gives us today)
  - all-MiniLM-L6-v2      (22M params, 384-dim; runs on ANE via Core ML)
  - bge-small-en-v1.5     (33M params, 384-dim; the bake-off candidate queued in the decision log)
  - hybrid RRF(BM25 + best embedder)  — the shape FTS5+vectors would take on device
Baseline for comparison: NLContextualEmbedding scored corpus-wide Recall@3 = 0.55 (Phase F).

Usage: python3 poc/search_eval.py
"""

import numpy as np
from sentence_transformers import SentenceTransformer

from common import EPISODES, load_episode, load_queries, recall_at_k, BM25

MODELS = {
    "minilm-l6": ("sentence-transformers/all-MiniLM-L6-v2", ""),
    "bge-small": ("BAAI/bge-small-en-v1.5",
                  "Represent this sentence for searching relevant passages: "),
}
KS = (1, 3, 10)


def rrf(rank_lists, k=60):
    """Reciprocal-rank fusion over multiple rankings of the same doc set."""
    scores = {}
    for ranks in rank_lists:
        for pos, doc in enumerate(ranks):
            scores[doc] = scores.get(doc, 0.0) + 1.0 / (k + pos + 1)
    return sorted(scores, key=scores.get, reverse=True)


def main():
    encoders = {name: SentenceTransformer(repo) for name, (repo, _) in MODELS.items()}
    # method -> k -> hits
    totals = {m: {k: 0 for k in KS} for m in list(MODELS) + ["bm25", "hybrid"]}
    total_queries = 0
    per_episode_r3 = {m: [] for m in totals}

    for ep in EPISODES:
        _, segments = load_episode(ep)
        queries = load_queries(ep)
        total_queries += len(queries)
        texts = [s["text"] for s in segments]

        bm25 = BM25(texts)
        bm25_ranked = [np.argsort(bm25.scores(q["query"]))[::-1].tolist() for q in queries]

        ranked_by_model = {"bm25": bm25_ranked}
        for name, (repo, qprefix) in MODELS.items():
            enc = encoders[name]
            doc_vecs = enc.encode(texts, normalize_embeddings=True, batch_size=64,
                                  show_progress_bar=False)
            q_vecs = enc.encode([qprefix + q["query"] for q in queries],
                                normalize_embeddings=True, show_progress_bar=False)
            sims = q_vecs @ doc_vecs.T
            ranked_by_model[name] = [np.argsort(row)[::-1].tolist() for row in sims]

        ranked_by_model["hybrid"] = [
            rrf([ranked_by_model["bge-small"][qi][:50], bm25_ranked[qi][:50]])
            for qi in range(len(queries))
        ]

        for method, ranked in ranked_by_model.items():
            for k in KS:
                totals[method][k] += recall_at_k(ranked, queries, segments, k)
            per_episode_r3[method].append(
                recall_at_k(ranked, queries, segments, 3) / max(1, len(queries)))

        print(f"{ep}: {len(queries)} queries, {len(segments)} segments — "
              + ", ".join(f"{m} R@3={per_episode_r3[m][-1]:.2f}" for m in ranked_by_model))

    print(f"\n=== corpus-wide over {total_queries} queries "
          f"(NLContextualEmbedding baseline R@3 = 0.55, gate >= 0.90) ===")
    print(f"{'method':<10}" + "".join(f"  R@{k:<3}" for k in KS))
    for method, by_k in totals.items():
        print(f"{method:<10}" + "".join(f"  {by_k[k] / total_queries:.3f}" for k in KS))


if __name__ == "__main__":
    main()
