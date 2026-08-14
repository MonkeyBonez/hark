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

from common import AD_CATEGORIES, EPISODES, load_episode, load_ad_labels, ad_f1

INSTRUCTIONS = """You find advertisements in podcast transcripts.

The test is: WOULD A LISTENER WANT TO SKIP THIS? Mark any promotional break, whoever benefits.

PROMOTIONAL (mark it):
- sponsor reads for an outside company ("this episode is brought to you by...")
- inserted ad spots, promo codes, discount URLs
- underwriting credits ("support for this show comes from the X Foundation")
- the show's OWN Patreon, donations, memberships or "support the podcast" appeals
- the show's OWN website, newsletter, merch, live events, or plugs for its other episodes
- another show being promoted (network cross-promotion)
- "subscribe, rate and review", "follow us", "join our Discord"

CONTENT (do not mark):
- the hosts discussing companies, products or investments as the topic of conversation
- a guest describing their own company as part of the interview
- crediting a source or author of material being read, as attribution rather than a pitch
- ordinary conversation, narration, interviews

When unsure, mark it. A wrongly-marked section is a skip the listener declines; a missed one means
they are never offered the skip at all."""


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


# Boundary cases, taken from measured failures rather than invented. Contrastive near-misses beat
# plain few-shot for classification, and OpenAI's gpt-oss-safeguard guide prescribes 4-6 of them.
# Balanced AD/NOT so the demos carry no majority-label bias.
BOUNDARY_EXAMPLES = """Boundary cases:
- "If you'd like to donate to the author, please visit patreon.com/wildbow" said while reading
  someone else's story -> NOT promotional. It credits the author of the material being read.
- "If you want to support the podcast go to patreon.com/thisshow" -> PROMOTIONAL. The show is
  asking listeners for money.
- "Ramp grew from nothing to a huge company because Peterffy understood spreads" -> NOT
  promotional. The company is the subject of the story.
- "This episode is brought to you by Ramp. Go to ramp.com/founders" -> PROMOTIONAL.
- A guest answering "what does your company do?" in an interview -> NOT promotional.
- "Support for this show comes from the Sloan Foundation" -> PROMOTIONAL (underwriting)."""

# Repeating the task after the transcript measurably helps on long inputs (Post-Ins, ACL Findings
# 2024) — attention is U-shaped, so an instruction sitting only above 60 lines is the weak spot.
TASK_LINE = ("List every run of lines that is promotional. Use EXACTLY this format, one per line:\n"
             "AD: <firstLine>-<lastLine>\n\nIf no lines are promotional, answer exactly:\nNONE")


def build_prompt(tokenizer, lines):
    """v2 (BOUNDARY_EXAMPLES + task line repeated after the transcript) measured +0.11 mean F2 but
    with a CI spanning zero at n=16, and regressed stacked cold opens to NONE. Not adopted; the
    pieces are kept above so resuming the experiment costs nothing."""
    numbered = "\n".join(f"{i + 1}. {t}" for i, t in enumerate(lines))
    user = (f"{INSTRUCTIONS}\n\nNumbered transcript lines:\n{numbered}\n\n{TASK_LINE}")
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
    "You classify podcast transcript excerpts. The test is: would a listener want to skip this?\n"
    "AD (any promotional break, whoever benefits): sponsor reads, inserted ad spots, promo codes, "
    "underwriting credits, the show's own Patreon/donations/memberships/website/newsletter/merch/"
    "events, plugs for its other episodes, cross-promotion of another show, 'subscribe, rate and "
    "review'.\n"
    "CONTENT: hosts discussing companies or products as the topic of conversation; a guest "
    "describing their own company in an interview; attribution or credits for material being read; "
    "ordinary conversation, narration and interviews.\n"
    "When unsure, answer ad — a wrongly-marked section is a skip the listener declines, a missed "
    "one is never offered.")


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
        p, r, f1 = ad_f1(pred, load_ad_labels(ep, AD_CATEGORIES))
        f1s.append(f1)
        print(f"{ep:<34} {p:5.2f} {r:5.2f} {f1:5.2f} {secs:6.0f}{kept_note}")
    print(f"\nmedian sponsor-F1: {np.median(f1s):.3f}")
    print("references: Haiku 0.957, Sonnet 1.000, on-device pipeline 0.515, gate 0.85")


if __name__ == "__main__":
    main()
