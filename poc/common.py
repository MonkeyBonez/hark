"""Shared loaders + metrics for the search/ads POCs.

Data: HarkPipeline/.eval-corpus/artifacts/*.json (transcripts with per-segment timings),
      HarkPipeline/.eval-corpus/recall/*.json   (49 paraphrase queries with target time ranges),
      HarkPipeline/docs/eval/labels/*.json      (ground-truth ad ranges, categorized).

Metrics mirror hark-bench exactly:
  - Recall@k: hit if any of the top-k retrieved segments overlaps [targetStartMs, targetEndMs].
  - Ad F1: per-millisecond time-overlap precision/recall (Scoring.swift), robust to boundary jitter.
"""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ARTIFACTS = ROOT / "HarkPipeline/.eval-corpus/artifacts"
RECALL = ROOT / "HarkPipeline/.eval-corpus/recall"
LABELS = ROOT / "HarkPipeline/docs/eval/labels"

EPISODES = [
    "allin-ackman",
    "founders-402-peterffy",
    "founders-413-run-down-dream",
    "lennys-1m-subscriber-newsletter",
    "lennys-openai-codex",
    "radiolab-forests",
    "restishistory-empress-matilda",
]


def load_episode(ep):
    art = json.load(open(ARTIFACTS / f"{ep}.json"))
    segments = art["transcript"]["segments"]  # [{text,startMs,endMs,...}]
    return art, segments


def load_queries(ep):
    return json.load(open(RECALL / f"{ep}.json"))["queries"]


def load_ad_labels(ep, categories=None):
    ranges = json.load(open(LABELS / f"{ep}.json"))["ranges"]
    if categories:
        ranges = [r for r in ranges if r["category"] in categories]
    return [(r["startMs"], r["endMs"]) for r in ranges]


# --- Recall protocol (score-recall) ---

def recall_at_k(ranked_segment_indices_per_query, queries, segments, k):
    hits = 0
    for qi, q in enumerate(queries):
        top = ranked_segment_indices_per_query[qi][:k]
        if any(segments[i]["startMs"] < q["targetEndMs"] and segments[i]["endMs"] > q["targetStartMs"]
               for i in top):
            hits += 1
    return hits


# --- Ad time-overlap F1 (Scoring.swift) ---

def _merge(ranges):
    out = []
    for s, e in sorted((r for r in ranges if r[1] > r[0])):
        if out and s <= out[-1][1]:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return out


def _covered(ranges):
    return sum(e - s for s, e in _merge(ranges))


def ad_f1(predicted, labeled):
    ma, mb = _merge(predicted), _merge(labeled)
    overlap = sum(max(0, min(e1, e2) - max(s1, s2)) for s1, e1 in ma for s2, e2 in mb)
    pred_ms, label_ms = _covered(predicted), _covered(labeled)
    precision = overlap / pred_ms if pred_ms else (1.0 if not label_ms else 0.0)
    recall = overlap / label_ms if label_ms else (1.0 if not pred_ms else 0.0)
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return precision, recall, f1


def segments_to_ranges(flags, segments, merge_gap_ms=20_000, min_ms=8_000):
    """Predicted per-segment booleans -> ad ranges, with the D25 aggregation:
    merge blocks separated by <=20s, drop isolates shorter than 8s."""
    raw = [(seg["startMs"], seg["endMs"]) for seg, f in zip(segments, flags) if f]
    merged = []
    for s, e in sorted(raw):
        if merged and s - merged[-1][1] <= merge_gap_ms:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append((s, e))
    return [(s, e) for s, e in merged if e - s >= min_ms]


# --- Tiny BM25 (Okapi) so the lexical baseline mirrors FTS5 ---

import math
import re


def _tokens(text):
    return re.findall(r"[a-z0-9']+", text.lower())


class BM25:
    def __init__(self, docs, k1=1.5, b=0.75):
        self.k1, self.b = k1, b
        self.docs = [_tokens(d) for d in docs]
        self.avgdl = sum(len(d) for d in self.docs) / max(1, len(self.docs))
        self.df = {}
        for d in self.docs:
            for t in set(d):
                self.df[t] = self.df.get(t, 0) + 1
        self.n = len(self.docs)

    def scores(self, query):
        q = _tokens(query)
        out = [0.0] * self.n
        for t in q:
            df = self.df.get(t)
            if not df:
                continue
            idf = math.log(1 + (self.n - df + 0.5) / (df + 0.5))
            for i, d in enumerate(self.docs):
                tf = d.count(t)
                if tf:
                    out[i] += idf * tf * (self.k1 + 1) / (
                        tf + self.k1 * (1 - self.b + self.b * len(d) / self.avgdl))
        return out
