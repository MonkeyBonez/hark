"""Can a LOCAL model on this Mac label silver data as well as Haiku/Sonnet?

If yes, the silver-labeling pipeline is free, offline, and unlimited. The teacher runs on the Mac
(24GB, M4 Pro) — NOT the phone — so it can be far bigger than the bundled 1.7B; only the student
(logistic head) has to fit an iPhone.

Design notes that matter for small models:
  - **Windowed**: the transcript is fed in overlapping windows of N lines, so context never grows
    with episode length (and it mirrors what an on-device pass would have to do anyway).
  - **Line indices, not timestamps**: models emit "AD: 12-18 sponsor" far more reliably than they
    copy "0:12:15" — indices are mapped back to real times here.
  - **Line-format output, not JSON** (the D24/D38 lesson).

Usage:
  python3 local_teacher.py <model-path-or-id> [--episodes ep1,ep2] [--window 60] [--overlap 10]
Scored against gold with the same time-overlap sponsor-F1 as every other experiment.
"""

import re
import sys
import time

import numpy as np
from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler

from common import EPISODES, load_episode, load_ad_labels, ad_f1

INSTRUCTIONS = """You find advertisements in podcast transcripts.

An AD is: a sponsor read (host reading a paid message for a product/service), an inserted ad \
spot, a promo code or sponsor URL, or an underwriting credit ("support for this show comes from").
NOT an ad: the hosts discussing companies, products, or investments as the topic of conversation; \
the host promoting their own show or newsletter (that is SELFPROMO, not an ad)."""


def chat(tokenizer, user):
    """Family-agnostic prompt building. Templates disagree on how to suppress reasoning:
    `enable_thinking` is a Qwen-ism, `reasoning_effort` is gpt-oss/harmony. Try each in turn."""
    msgs = [{"role": "user", "content": user}]
    # Pass both and let each template use what it knows: jinja silently ignores unknown variables,
    # so a try/except chain would always stop at the first kwarg and never apply the second.
    try:
        return tokenizer.apply_chat_template(msgs, add_generation_prompt=True,
                                             enable_thinking=False, reasoning_effort="low")
    except (TypeError, ValueError):
        return tokenizer.apply_chat_template(msgs, add_generation_prompt=True)


def final_channel(reply):
    """Reasoning models emit a scratchpad before the answer; keep only the answer. Harmony marks it
    `<|channel|>final<|message|>`, Qwen-likes wrap the scratchpad in <think>...</think>."""
    if "<|channel|>final<|message|>" in reply:
        reply = reply.split("<|channel|>final<|message|>")[-1]
    return re.sub(r"<think>.*?</think>", "", reply, flags=re.S)


def build_prompt(tokenizer, lines):
    numbered = "\n".join(f"{i + 1}. {t}" for i, t in enumerate(lines))
    user = (f"{INSTRUCTIONS}\n\nNumbered transcript lines:\n{numbered}\n\n"
            f"List every run of lines that is an advertisement. Use EXACTLY this format, one per "
            f"line:\nAD: <firstLine>-<lastLine>\n\nIf there are no advertisements in these lines, "
            f"answer exactly:\nNONE")
    return chat(tokenizer, user)


def parse(reply, n_lines):
    reply = final_channel(reply)
    out = []
    for m in re.finditer(r"AD:\s*(\d+)\s*-\s*(\d+)", reply):
        a, b = int(m.group(1)), int(m.group(2))
        if 1 <= a <= b <= n_lines:
            out.append((a - 1, b - 1))
    return out


def merge_ms(ranges, gap=10_000):
    out = []
    for s, e in sorted(ranges):
        if out and s - out[-1][1] <= gap:
            out[-1] = (out[-1][0], max(out[-1][1], e))
        else:
            out.append((s, e))
    return out


# Reasoning models (gpt-oss) spend hundreds of tokens in their analysis channel before answering,
# so a tight cap silently truncates them to zero output. Set generously; non-reasoning models stop
# at their EOS long before this and pay nothing for the headroom.
MAX_TOKENS = 1536

VERIFY_INSTRUCTIONS = (
    "You classify podcast transcript excerpts. The excerpt is an AD only if it is a sponsor read "
    "or paid promotion (product pitch, promo code, sponsor URL, 'brought to you by'), an inserted "
    "ad spot, or an underwriting credit. The hosts discussing companies, products, or investments "
    "as the topic of conversation is CONTENT. The host promoting their own show or newsletter is "
    "CONTENT.")


def verify_block(model, tokenizer, sampler, text):
    """Second pass (D29): re-read each candidate block on its own and keep only real ads.
    Fail-open — an unparseable answer keeps the block, so verify can only raise precision."""
    user = (f"{VERIFY_INSTRUCTIONS}\n\nExcerpt:\n{text[:1500]}\n\n"
            "Answer with EXACTLY one line:\nVERDICT: ad\nor\nVERDICT: content")
    reply = generate(model, tokenizer, prompt=chat(tokenizer, user), max_tokens=MAX_TOKENS,
                     sampler=sampler)
    return "verdict: content" not in final_channel(reply).lower()


def block_text(segments, start_ms, end_ms):
    return " ".join(s["text"] for s in segments
                    if s["startMs"] < end_ms and s["endMs"] > start_ms)


def label_episode(model, tokenizer, segments, window, overlap, sampler):
    preds = []
    step = window - overlap
    for start in range(0, len(segments), step):
        chunk = segments[start:start + window]
        if not chunk:
            break
        prompt = build_prompt(tokenizer, [s["text"] for s in chunk])
        reply = generate(model, tokenizer, prompt=prompt, max_tokens=MAX_TOKENS, sampler=sampler)
        for a, b in parse(reply, len(chunk)):
            preds.append((chunk[a]["startMs"], chunk[b]["endMs"]))
    return merge_ms(preds)


def main():
    model_id = sys.argv[1]
    episodes = EPISODES
    window, overlap = 60, 10
    if "--episodes" in sys.argv:
        episodes = sys.argv[sys.argv.index("--episodes") + 1].split(",")
    if "--window" in sys.argv:
        window = int(sys.argv[sys.argv.index("--window") + 1])
    if "--overlap" in sys.argv:
        overlap = int(sys.argv[sys.argv.index("--overlap") + 1])

    verify = "--verify" in sys.argv

    model, tokenizer = load(model_id)
    sampler = make_sampler(temp=0.0)
    print(f"model: {model_id}  window={window} overlap={overlap} verify={verify}\n")
    print(f"{'episode':<34} {'P':>5} {'R':>5} {'F1':>5} {'sec':>6}"
          + ("   kept" if verify else ""))
    f1s = []
    for ep in episodes:
        _, segments = load_episode(ep)
        t0 = time.time()
        pred = label_episode(model, tokenizer, segments, window, overlap, sampler)
        kept_note = ""
        if verify:
            n_before = len(pred)
            pred = [(s, e) for s, e in pred
                    if verify_block(model, tokenizer, sampler, block_text(segments, s, e))]
            kept_note = f"   {len(pred)}/{n_before}"
        secs = time.time() - t0
        p, r, f1 = ad_f1(pred, load_ad_labels(ep, ("sponsor",)))
        f1s.append(f1)
        print(f"{ep:<34} {p:5.2f} {r:5.2f} {f1:5.2f} {secs:6.0f}{kept_note}")
    print(f"\nmedian sponsor-F1: {np.median(f1s):.3f}")
    print("references: Haiku 0.957, Sonnet 1.000, on-device pipeline 0.515, gate 0.85")


if __name__ == "__main__":
    main()
