# Ad-label audit list — flagged ranges needing a human ear/judgment call

Labels were produced by a full transcript read (`labeler: agent-fable-transcript-read`,
2026-07-08). Unflagged ranges are unambiguous host-read sponsor blocks or DAI ads with clear
textual boundaries. The ranges below are the only ones where judgment was genuinely uncertain —
listening to a few seconds of audio (or just making the policy call) resolves each. Scoring
currently treats them as labeled; re-run `score-ads` after any edits.

## User audit + length policy (2026-07-09)

Snehal reviewed the list and set a **length-based skip/chapter policy** that resolves most of these
without per-item calls. Two independent floors, both implemented (see PRD §8.11):

- **Skip-eligibility floor ≈ 30s** (`AdExclusion.minSkippableAdMs`): only detections longer than
  ~30s are ever auto-skipped or Ask-prompted. Short self-promos and segue sentences (a few seconds)
  are **fine** — they render as scrubber regions but never interrupt. "The interruption costs more
  trust than the seconds it saves." (Word-count was floated as an easier-to-reason proxy; we keep
  milliseconds since segments are already precisely time-stamped — same idea, more direct.)
- **Chapter floor = 60s** (`ChapterAssembly.minChapterMs`): a sponsor/self-promo/content block
  under a minute never becomes its own chapter — it stays "part of the chapter before," so the
  timeline doesn't fragment into sliver pills.

Detection *labels* are unchanged by this (selfpromo stays a distinct class from sponsor for F1);
the policy governs what the **player** does with a detection, not what counts as one.

| # | Episode | Range | Len | Labeled | Verdict under policy |
|---|---|---|---|---|---|
| 1 | founders-413 | 12:25–12:31 | 6s | sponsor | Segue — **not skippable, not chaptered** (<30s/<60s). Label kept sponsor for F1. |
| 2 | founders-413 | 16:04–16:07 | 3s | selfpromo | **Content, fine** — Snehal: "his own content, mid content, not really a promo." Not skipped. |
| 3 | founders-413 | 16:56–17:01 | 5s | selfpromo | Same as #2 — short self-mention, not skipped. |
| 4 | lennys-codex | 66:37–66:57 | 20s | selfpromo | Outro <30s → **not skipped**. |
| 5 | lennys-1m | 1:34–1:49 | 15s | selfpromo | Wife's book mention <30s → **not skipped**, stays in intro. |
| 6 | lennys-1m | 66:28–66:49 | 21s | selfpromo | Outro <30s → **not skipped**. |
| 7 | allin-ackman | 26:24–28:21 | **117s** | selfpromo | **The one case the length floor doesn't resolve, and the verify-pass does NOT catch it either** — re-ran `real-ads` 2026-07-09 with the self-promo/guest-discussion prompt: still flagged (26:40–28:20). A guest describing their own fund's strategy/returns when asked reads as promotional to a small model even though it's editorial. This is the detector's genuine precision ceiling (long editorial content that sounds like a pitch). **Mitigation is the designed product surface, not a hand fix:** ad-skip defaults **Ask**, it shows as a visible "Sponsor break" chapter the listener judges for themselves, and one "Not an ad" tap removes it + feeds tuning. Do not overfit the prompt to this single example. |
| 8 | radiolab | 12:15–12:38 | 21s→gap | sponsor | <30s and an untranscribed gap → **not skippable** regardless; detection still **needs a listen** to know if ad audio exists. |
| 9 | radiolab | 19:27–19:42 | 15s | sponsor | Public-radio underwriting credits, <30s → **not skipped**. Policy call on whether credits are "ads" deferred (immaterial to skip behavior now). |

Everything else (12 unflagged ranges across 7 episodes, incl. all Ramp/Vanta/Collateral/WorkOS/
Mercury/MetaView/DX reads and the Rest Is History DAI spots) is unambiguous.

**Net:** the length policy makes 8 of 9 flagged items non-issues for the player (all under one or
both floors). Item **#7** is the only substantive judgment call, and it now falls to the verify-pass
prompt rather than a hand label — re-run `real-ads` on allin-ackman to confirm the detector drops it.
Original scoring note (labels still drive F1 unchanged): the materially F1-relevant items are #1/#8/#9.
