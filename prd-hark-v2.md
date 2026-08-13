# PRD: PodSmart — Local-First AI Podcast Player (v2)

**Author:** Sne
**Status:** v2.0 — ready for autonomous build
**Last updated:** July 8, 2026
**Ship name:** PodSmart *(chosen; pending a trademark/clearance check — see §12. Internal dev codename "Hark" persists in the pipeline package `HarkCore`/`HarkPipeline`, which is never shipped.)*
**Bundle ID:** com.sne.podsmart

> **What changed from v1.0.** v1 was strong on product thinking but its technical plan was ~18 months stale and infeasible as drawn on the floor device (a single full-transcript LLM pass can't fit the jetsam ceiling, the model context window, or a tolerable prefill time). A 6-lens adversarially-verified review surfaced ~24 holes. This version raises the OS floor to **iOS 26**, makes the LLM engine **pluggable** (the app now ships a single bundled MLX model — Qwen3-1.7B-4bit — for all devices; Foundation Models is bench-only, D38), replaces full-transcript passes with **chunked map-reduce**, reframes the moat around the **intelligence layer** rather than "on-device/free," and replaces the one-shot build with an **autonomous phased build**. Section numbering mirrors v1 for easy diffing.

---

## 1. Vision

An iOS podcast player that delivers **Snipd-class AI** — moment capture, episode summaries, key-moment detection, chapters, and automatic ad skipping — **entirely on-device, for free**. No subscription, no server inference costs, no audio leaving the phone.

The bet has three legs:

1. **Apple Silicon can now run the workload.** iPhone 14 Pro-class Neural Engine runs on-device ASR many times faster than real time and small LLMs at usable token rates — *if* the pipeline is chunked and memory-disciplined.
2. **Small models got good.** 2B–4B-class 4-bit models are good enough for classification, titling, and summarization of clean transcript text.
3. **The OS now ships the primitives for free.** iOS 26 provides **SpeechAnalyzer/SpeechTranscriber** (free built-in ASR), **Apple-Hosted Background Assets** (free model CDN), **BGContinuedProcessingTask** (user-initiated long compute with system progress UI), and Apple **Foundation Models** (a free OS-resident LLM). We build on the ASR/scheduling primitives directly; for the LLM we ship our own bundled model (D38 — one engine on all devices, fully under our control) rather than depending on FM's per-device availability.

**Honest framing of the bar.** A 2–3B on-device model will not beat Snipd's cloud GPT-class summaries head-to-head. That is not the goal. The goal is **Snipd-class quality that is instant, private, and free** — good enough that the loss in raw summary polish is more than paid back by zero cost, zero latency-to-privacy, and offline-everything. "On-device and free" is the **wedge**, not the moat (see §3).

## 2. Problem

Podcast listeners who treat podcasts as a learning medium face three frictions:

1. **Capture friction** — hearing something valuable mid-run or mid-drive with no way to save it without stopping.
2. **Retention friction** — finishing a 2-hour episode and retaining almost nothing actionable.
3. **Time friction** — ads and filler consume 10–20% of listening time.

Snipd solves 1 and 2 well but gates the best features behind a premium subscription (verified pricing: **$83.90/yr annual, or $11.99/mo** — i.e. roughly **$72–144/yr** depending on plan), largely because its inference runs in the cloud. Ad skipping is unsolved in mainstream players and Apple structurally won't ship it.

## 3. Why now / Why us

- **Hardware inflection:** iPhone 14 Pro+ (A16, 6GB) runs on-device ASR many times faster than real time (WhisperKit small.en ≈ 14x RT on A16; base.en ≈ 45x RT) and 2–4B LLMs at usable rates when the work is chunked.
- **Model inflection:** modern 2B-class 4-bit models (Gemma-class, Qwen3-class, LFM2-class) handle summarization/classification/titling of clean transcript text acceptably.
- **OS inflection (the real unlock):** iOS 26 ships SpeechTranscriber, Apple-Hosted Background Assets, and BGContinuedProcessingTask — the exact ASR/scheduling primitives this app needs, for free (the LLM is our own bundled model, D38).

### What is actually the moat

The moat is **the intelligence layer and the loop it feeds**, not the fact that inference is local:

1. **The intelligence layer** — snip enrichment (title + takeaways + cleaned excerpt + category), episode summaries, key moments, chapters, and trustworthy ad detection, tuned specifically for spoken-podcast text. This is the craft Snipd spent years on; matching its *quality and taste* is the hard part.
2. **The capture → enrich → library loop** — every snip compounds into a personal, searchable knowledge base. Switching cost grows with the library. This is retention.
3. **Trust-engineered ad-skip** — audible, reversible, per-show-controllable skipping (§8.3, §8.11). Trust is the feature; a silent hard cut that eats content once loses the user forever.

### Why we still win when competitors adopt the free OS stack

Apple has *commoditized the substrate*: transcripts (iOS 17.4), auto-chapters (iOS 26.2), within-show search (WWDC 2026), and now free on-device LLM/ASR. Free on-device ad-skip apps already exist (Skipper, Herd, Adblock Podcast, PurerPodcasts, PodSkip). So "on-device and free" is table stakes soon, not a moat. We win by being the one app that **integrates the whole loop with taste** — capture that's a single reflex, enrichment worth reading, a library worth returning to, and ad-skip that's trustworthy — while Apple won't ship ad-skip and the point players ship one feature each. The wedge (free, private, zero marginal cost) gets us in the door; the loop keeps them.

- **Privacy as a feature:** listening content never leaves the device. (Anonymous, opt-out feature counters may — see §11.)

## 4. Target user

Knowledge-worker podcast listeners (20s–40s) who listen during workouts, commutes, and chores — and currently screenshot timestamps or lose insights entirely. Secondary: **switchers from Overcast/Pocket Casts/Snipd**, which is why OPML import ships in v1 (§7.6).

## 5. Core product principles

1. **Capture is instant; intelligence can wait.** Any user-initiated action gives feedback in <300ms. AI enrichment happens asynchronously and is allowed to arrive late.
2. **Local by default.** No feature requires a network call beyond fetching podcast RSS/audio/artwork and (optional) anonymous counters.
3. **The player must be great before the AI is.** Table-stakes playback — background audio, lock screen, CarPlay, queue, offline — has to be rock-solid or nothing else matters. This is why the build sequences a zero-AI player first (§10, P1).
4. **Playback is sacred.** Processing degrades before playback does. "Playback never dies to jetsam during processing" is an explicit build success criterion (§9.6).
5. **No dark patterns.** No paywall, no upsell, no fake instancy; processing state is shown honestly (§8.6).

## 6. Content acquisition

- **Directory/search:** **Podcast Index API primary, with the attribution their ToS requires** shown in-app; **iTunes Search API as a debounced fallback** (~20 req/min ceiling). Subscribed-feed metadata is read from the RSS feed directly, which keeps us outside Podcast Index's no-permanent-database clause.
- **Audio:** podcasts are public RSS feeds with direct enclosure URLs — standard player behavior, no licensing required. **Stream-on-tap:** AVPlayer streams immediately; a background download proceeds in parallel to feed the pipeline (§7.6).
- **Transcripts:** check for the Podcasting 2.0 `<podcast:transcript>` RSS tag first. If present, run it through a **format normalizer + quality gate** (HTML transcripts lack timestamps; SRT/VTT lack speakers → diarization still runs on that path — §9.3) and skip ASR. Otherwise transcribe locally.
- **Networking hygiene:** honest, distinct HTTP `User-Agent`; graceful fallback to playing-with-ads if any CDN ever blocks us; never break playback over a directory/enrichment failure.

## 7. Features

### 7.1 Sync (instant, blocking on UX)

| Feature | Behavior | Latency budget |
|---|---|---|
| **Snip capture** | A **remapped remote command** (`previousTrack`/`skipBackward`, user-selectable in Settings) marks the current timestamp with a raw **60s-back / 15s-forward** window. iOS never exposes raw tap counts, so we bind a semantic transport control; **binding it to snip sacrifices that control's normal function** (e.g. rewind), stated plainly to the user. Lock screen exposes a dedicated snip button via a **Live Activity** (`AudioPlaybackIntent`, runs in-process) and an **iOS 26 Control** for the Action button. CarPlay / steering-wheel = single press (accidental-snip tradeoff noted). Acknowledged by an **in-stream beep** (a confirmation *haptic* is not deliverable from a backgrounded app, so it's dropped). The raw window is stored immediately; boundaries snap to sentences later (§7.2, outward-only — §8.4). | <300ms to acknowledge |
| **Manual bookmark** | Single tap in app marks timestamp | <100ms |
| **Ad skip (playback)** | If ad ranges are precomputed, player skips them with an audible whoosh + actionable toast (see §8.3, §8.11) | Instant |

### 7.2 Async (background, minutes-scale acceptable)

All async AI runs as **chunked map-reduce** over the transcript (§9.2), never a single full-transcript pass.

| Feature | Behavior | Trigger |
|---|---|---|
| **Episode transcription** | Timestamped transcript (+ speaker turns via diarization). Official transcript if available & passes the quality gate, else on-device ASR. Runs **playhead-anchored** during first play (§8.1). | On download / on first play |
| **Diarization** | Speaker clustering aligned to transcript segments; anonymous clusters named "Host"/"Guest" via an LLM pass over the intro (§9.3) | After/with transcription |
| **Snip enrichment** | Each snip gets a **category**, title, summary bullets, and a cleaned transcript excerpt | After snip, queue-jumped |
| **Episode summary** | TL;DR + key takeaways, computed over **transcript minus AdRanges** (§9.5) | After transcription + ad detection |
| **Key-moment detection** | 3–7 highlight segments per episode, validated to not fall inside AdRanges | After transcription + ad detection |
| **Chapter generation** | Topic-based chapters with titles (reduce stage); detected AdRanges are then merged into the timeline as visible **"Sponsor break" chapters** — deterministic post-processing, never an LLM task (§8.11, §9.5) | After transcription |
| **Ad detection** | Classify transcript windows as ads; store skip ranges + confidence. Also runs as a **rolling-window pass during playback** so skips work on first listen. Accuracy target exploratory — tune during dogfood. | During/after transcription |
| **Embedding index** | Per-segment embeddings for find-a-moment, computed **incrementally and in parallel** with LLM passes (§9.5) | During transcription |

### 7.3 Find-a-moment search

"When do they talk about X?" — keyword + semantic search over the episode transcript. Results jump-scroll to the matching part; tapping a line plays from that moment. Fully local retrieval; the base path involves no generation. Because embeddings run incrementally (§9.5), this lights up during the first listen, not last. (Entry-point placement is a visual-design decision; build the functionality.)

**Staged retrieval-quality plan** (measured Recall@3 = 0.55 vs ≥0.90 gate on paraphrase queries — DECISIONS Phase F; each stage is gated by the `score-recall` harness before the next is considered):
1. **Ship hybrid FTS5 keyword + semantic** (current engines) — exact-wording queries, the majority, hit via keywords regardless of embedder quality.
2. **Bundled-embedder bake-off** (bge-small/MiniLM-class, ~130MB, retrieval-trained) — expected to close most of the paraphrase gap at zero per-query cost (open Q E4).
3. **LLM-assisted retrieval as progressive enhancement, only if the gate is still unmet:** instant vector+keyword results render immediately; one small LLM call then either **re-ranks** the top ~15 candidates or **expands the query** into 2–3 paraphrases (union of their hits). The LLM touches ~1k tokens per search, never scans transcripts (a 2h episode vs a 4k context makes per-query scanning a tens-of-seconds, battery-hostile non-starter — and E16 refusal risk makes it unreliable). Results refine in place a beat later; a refused/slow LLM call degrades silently to stage-1/2 results.

### 7.4 Shareable snip cards

Audio clip + quote image for sharing, **constrained for policy** (§12): default clip **60–90s, hard cap ~3 min**; show/episode/timestamp attribution baked into both the image and the audio; **local share-sheet only — we never host clips**.

### 7.5 Snip boundary editor (now in v1)

Drag sentence-boundary handles + ±5s steppers with instant audio preview. The verified Snipd pain is *recovering* from wrong auto-boundaries, not choosing them upfront — so editing ships in v1. (LLM-determined semantic boundaries — "expand until the thought completes" — stay v1.1.)

### 7.6 Scope adds

- **OPML import (v1):** cheapest activation lever for the switcher persona. OPML *export* stays deferred.
- **Stream-on-tap (v1):** play immediately while the download that feeds the pipeline runs in the background.
- **Storage retention policy (v1):** auto-delete episode audio N days after processing completes; keep transcripts/snips/embeddings forever (~3% of the bytes). Surfaced in **You** as "knowledge kept" vs "audio reclaimable."

### 7.7 Explicitly out of scope for MVP

- Chat-with-episode (find-a-moment covers the core need)
- Export integrations (Markdown, Obsidian, Notion, Readwise) and OPML *export*
- Rich onboarding flow (defer; empty states carry v1 — §8.9)
- Android, audiobook/YouTube ingestion, social/discovery feed
- Content-level usage tracking (only anonymous, opt-out counters — §11)
- **CarPlay** — fully deferred to a future release (UI *and* entitlement). The player will still expose its transport via `MPRemoteCommandCenter`, so basic steering-wheel play/pause/skip works through the system; a dedicated CarPlay audio app + snip control is post-v1.

## 8. Design & interaction

Reference inspiration: Snipd's player and snip-card patterns (screenshots on file). What we take, what we change:

### 8.1 Player (the hero screen) — including the first-play degraded state

The player has **two states that morph into each other**:

- **Pre-transcript (degraded) state** — shown when playback starts before a transcript exists. Artwork + standard transport controls + a small honest status line: *"Transcript catching up — 32%."* Playhead-anchored ASR (§9.5) transcribes *ahead of the playhead first*, so within ~1–2 minutes the karaoke view can begin. Scrubber ad-regions and chapter pills appear incrementally as detection catches up. Official `<podcast:transcript>` feeds skip this wait entirely.
- **Transcript-first karaoke view** — large type, current sentence bright, upcoming dimmed, auto-scrolls with playback; tap any line to seek. Speaker attribution chips appear above the transcript when the speaker changes (hidden below a diarization confidence threshold).

Shared chrome: **scrubber** with chapter pill (current chapter title), snip markers (dots), and **ad regions rendered as greyed segments**; a persistent **"Create snip" pill** always one thumb-tap away; standard ±10/30s skip, speed, queue.

**Karaoke performance spec (acceptance-gated):** sentence-granularity rows with stable segment IDs; word-level highlight only inside the active row; `scrollPosition(id:)` + scroll-phase detection to pause auto-scroll on manual scroll (with a "resume" pill). **Acceptance bar: 60fps scroll + <16ms highlight update on a 3-hour transcript on iPhone 14 Pro.**

### 8.2 Navigation

Four tabs: **Home / Discover / Snips / You.** Proven structure, familiar to switchers.

### 8.3 Ad-skip feedback

When playback hits a detected ad range, the skip is **audibly marked** rather than a silent hard cut — the user *hears* that something was passed, which builds trust that content wasn't eaten.

**Mechanism (v1):** ~100ms crossfade into a **pre-rendered 300–500ms "whoosh" asset** (pitch/length scaled to the ad duration), seek to the ad range's end, ~100ms crossfade back into content. (True ~100x live playback is not achievable as a live rate parameter — AVFoundation caps pitch-preserving rate at 32x — but is achievable via offline pre-render as a later refinement. The pre-rendered asset delivers the same perceptual "zoom/whoosh" cue now.)

Paired with an **actionable toast** and per-show controls — see §8.11.

### 8.4 Snip cards & the snip lifecycle

Card face: **category label** (INSIGHT / QUOTE / TAKEAWAY — now produced by the enrichment prompt, §9.3), bold AI title, 2 bullet takeaways, timestamp, star. Tap to expand to the full transcript excerpt + play button.

**Lifecycle (was undefined):** a snip captured before the transcript exists is stored instantly as a raw time window and shows explicit states — **captured → transcribing → enriched**. Snip regions **jump the ASR/enrichment queue**. When segments arrive, boundaries **re-snap outward only** — never trimmed inside what the user believes they saved.

### 8.5 Snips library

Search bar, filter chips (by podcast), recent-episodes grouping with snip counts, starred section.

### 8.6 Processing-state visibility

Local processing is visible machinery — surfaced honestly: small per-episode badge ("transcribing…" → "summary ready"), and a **processing queue view** in **You** (backed by the `ProcessingJob` entity, §9.4), alongside storage used and model status. No fake instancy.

### 8.7 Offline/online

Everything downloaded is fully functional offline — transcripts, snips, summaries, search all live on-device. Network is needed only for directory search, RSS refresh, audio download/stream, artwork, and (optional) anonymous counters. Queued processing continues offline.

### 8.8 Settings (minimal, playback-focused)

Playback-speed defaults, skip intervals, **snip-trigger control binding** (which remote command maps to snip), queue behavior, download preferences (auto-download, Wi-Fi only, retention window), a global **Ad detection & skip on/off** toggle, and an anonymous-counters opt-out. No model knobs, no snip-window sliders.

### 8.9 Empty states

First launch: podcast search bar front and center — "find your first show," with an OPML-import affordance for switchers. Zero snips: brief pointer to the snip gesture.

### 8.10 No-paywall identity

No trial banners, no upgrade CTAs, no locked features. The space competitors spend on upsell, we spend on content.

### 8.11 Ad-skip trust loop

The toast is **actionable**:

- **"Play it anyway"** — seeks back to the ad start and suppresses that AdRange for this playback (no re-trigger when the user seeks back into the range).
- **"Not an ad"** — writes `userVerdict` on the AdRange (feeds tuning; never used to phone home content).
- **Per-show override (On / Off / Ask)** on the podcast page, alongside the global toggle.
- **Two independent length floors (user policy, 2026-07-09)** — because a false interruption costs more trust than the seconds a short skip saves:
  - **Skip-eligibility floor ≈ 30s** (`AdExclusion.minSkippableAdMs`, `AdExclusion.skippable(_:)`): only detections **longer than ~30s** are ever auto-skipped or Ask-prompted. Short self-promos, segue sentences, own-episode mentions, and outros (a few seconds) are **not** actioned — they still render as scrubber regions but never interrupt playback. `userVerdict == .notAnAd` is also excluded regardless of length.
  - **Chapter floor = 60s** (`ChapterAssembly.minChapterMs`): a sponsor/self-promo/content block **under a minute never becomes its own chapter** — it stays part of the preceding chapter, so the timeline doesn't fragment into sliver pills. Applies symmetrically to natively-short LLM chapters (absorbed into a neighbor).
  - These are **product-policy floors on what the player does with a detection**, orthogonal to the detection *labels* (selfpromo stays a distinct class from sponsor for F1 scoring). Self-promotion of the host's own content is treated as content, not a paid ad, in the detector's verify-pass prompt as well.
- **Ads as visible chapters (default surfacing, active in every mode):** minute-plus detected AdRanges are merged into the episode's chapter timeline as labeled **"Sponsor break" chapters** — deterministic post-processing after the reduce stage (`ChapterAssembly`); the LLM never sees or titles ad content, so the ad-exclusion contract (§9.5) is untouched. Content chapters split at ad boundaries and resume under the same title. In **Ask/Off** modes this *is* the ad feature: the listener sees the break coming in the chapter pill/scrubber and skips it with one tap. The failure modes are trust-cheap where auto-skip's are not — a false positive is a mislabeled chapter the listener ignores; a miss is just an unflagged ad, no worse than any other player. The chapter row is also the natural surface for collecting `userVerdict` taps ("Not an ad" removes the range from the timeline), feeding the dedicated-classifier path (open Q2). When the detection gate passes and auto-skip turns on, it operates on the same ≥30s ranges, with the chapters remaining as the visible audit trail.

Default **Ask during dogfood** *(revised 2026-07-08: measured ad-detection F1 on a 7-episode ground-truth corpus is ~0.32 median — precision ~20–33% — far below the ≥0.85 gate; defaulting skips ON at that precision would silently eat real content. Flips to ON only when the measured gate passes — see `HarkPipeline/docs/DECISIONS.md`)*; the public-launch default is decided with real undo-rate data (§11).

## 9. Technical strategy

### 9.1 Stack

- **UI:** SwiftUI. **iOS 26 minimum.** Hardware floor stated by capability, not marketing name: **A16 + 6GB RAM or better** (iPhone 14 Pro / Pro Max, iPhone 15 and all later) — roughly two-thirds of active iPhones, and iOS 26 adoption already dominates. This floor unlocks BGContinuedProcessingTask, Apple-Hosted Background Assets, SpeechAnalyzer/SpeechTranscriber, and enough RAM to run the bundled 1.7B model (D38).
- **Persistence:** **GRDB/SQLite — committed** (timestamped segments are highly relational and need fast range queries + FTS5; SwiftData has no FTS/virtual tables, so the v1 "builder may pick SwiftData" hedge is deleted). Build with the `SQLITE_ENABLE_FTS5` SPM flag documented.
- **Audio:** AVFoundation/AVAudioEngine; background audio session; `MPRemoteCommandCenter` for the snip gesture (semantic commands only); `MPNowPlayingInfoCenter`; Live Activity + iOS 26 Control for lock-screen/Action-button snip.

### 9.2 Pipeline

```
RSS fetch → audio stream/download → [official transcript passes quality gate? normalize it : SpeechTranscriber/WhisperKit ASR]
  → timestamped transcript  (playhead-anchored during first play)
  → diarization (align speaker clusters to segments; LLM names Host/Guest)
  → embedding index         (incremental, parallel — only needs transcript)
  → ad detection            (rolling-window during play; full pass after)
  → CHUNKED MAP-REDUCE LLM:
        map:   over 2–4k-token windows → per-window classification + notes
        reduce: episode TL;DR, key moments, chapters   (input = transcript MINUS AdRanges)
  → snip enrichment (on demand, queue-jumped): category + title + bullets + cleaned excerpt
```

**Single AI model resident at a time:** ASR is fully unloaded before the LLM loads (§9.6).

### 9.3 Models & inference

Everything below is **decided empirically by the P0 bake-off harness** (§10), which produces a **model decision record** (quality/F1, tok/s, peak RSS, battery, thermal) on ~20 real episodes. The PRD names *candidates and hard criteria*, not final winners.

**LLM — pluggable `EpisodeIntelligence` protocol, one shipped engine (single-model, D38):**

- **The engine:** **MLX Qwen3-1.7B-4bit** (Apache-2.0, ~1GB), the D37 bake-off winner over LFM2-1.2B / Llama-3.2-3B / Qwen3-4B on the 7-episode corpus. **Bundled inside the app** (§ Model distribution) — identical on every supported device, no first-run download, no per-device tiering. Its context is ~4,096 tokens, which is exactly why the pipeline is chunked (§9.2). Selection criteria it clears: Apache-2.0 license, ≤1.5GB weights, fits the 6GB-floor jetsam ceiling, passes the task evals.
- **Foundation Models is no longer used by the app.** Its adapters stay in HarkCore for **Mac-bench comparisons only**. (History: FM was the Tier-1 engine; its guided-generation refusals were root-caused and fixed — E16/D24 — but a single open model the team fully controls beats maintaining two divergent tiers, and the hardware floor / AI-off devices couldn't run FM anyway.)
- **Consequence — foreground-only on every device:** MLX is Metal-GPU-only on iPhone and crashes when backgrounded (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`). So all processing runs foreground/awake (the run loop holds the idle timer) or under BGContinuedProcessingTask-with-GPU. **The background-safe Core ML/ANE port of this model remains the stated next step** — it is what lifts the foreground-only constraint.
- **Future option (not built):** a super-small fast model (e.g. ~0.5B) for latency-sensitive sub-tasks (snip enrichment, speaker naming) alongside the main model — recorded, deferred.

**ASR — three-way bake-off:** **SpeechTranscriber (default candidate: free, built-in, zero download)** vs **WhisperKit `small.en`** vs **WhisperKit `base.en`**, gated on **WER < 10%** over the ~20-episode set (with music beds/crosstalk). base-class is a low-power fallback only (a ~1-in-8-word error rate is too visible in a karaoke UI; small.en ≈ 7.5% WER vs base ≈ 12%).

**Diarization (named):** **FluidAudio (Apache-2.0)** or **SpeakerKit (MIT, in argmax-oss-swift)** as an explicit stage with a segment-alignment step; runs on the official-transcript path too (SRT/VTT lack speakers).

**Embeddings:** Apple **NLContextualEmbedding** vs a small bundled embedder (MiniLM/bge-small-class), same harness. Stored as **float16 BLOBs per segment**; brute-force in-memory search per episode (<10ms at ~1,800 vectors). **No sqlite-vec dependency** (still alpha).

**Ad detection:** keyword candidates + per-line MLX classification, then a per-block **MLX verify pass** (D29 architecture ported off Foundation Models to the shipping model, D38). Shares the one resident MLX model — no second model load.

**Model distribution:** **bundled inside the app** (D38) — the ~1GB Qwen weights ship in the app binary, so first launch needs zero network. Trade-off accepted: ~1GB install size, and model updates are coupled to app releases. **Apple-Hosted Background Assets** (free Apple CDN, `ModelAsset`-versioned, decoupled from releases) is deferred — revisit when model updates need to ship independently of the app.

**Dev tooling (never shipped):** the pipeline is a Swift package runnable standalone on macOS with a CLI harness, so models can be benchmarked on the build machine against real episodes; a thin **device-twin** iOS app reports RTF/RSS/thermal per stage on a physical iPhone 14 Pro. Simulator does not exercise ANE properly; on-device validation happens on real hardware.

### 9.4 Data model (v2)

Everything hangs off timestamped transcript segments — one source of truth every feature reads from. Changes from v1 are marked **[new]** / **[changed]**.

- **Podcast** — RSS URL, title, artwork, subscription state, **[new]** `adSkipMode` (on/off/ask).
- **Episode** — → Podcast; audio URL, download state, duration, pub date, **[new]** `playbackPosition`, `lastPlayedAt`, `audioRetentionState`.
- **Transcript** — → Episode; **Segments** (text, startTime, endTime, speaker); **[new]** `source` (official/ASR), `format`, `modelVersion`.
- **[changed] Artifact status** — per-stage table (episodeId × stage × status × modelVersion) **replaces the linear `processing state` enum** — represents "ads done, summary failed" and lets a stage re-run when its model upgrades.
- **[new] ProcessingJob** — episodeId, stage, status, priority, attempts, error — the backing entity for the queue UI (§8.6).
- **[new] ModelAsset** — name, version, quantization, size, downloadState.
- **Snip** — → Episode; **[changed]** time range stored as **raw milliseconds + denormalized excerpt text, never segment FKs** (re-transcription must never dangle a snip); **[new]** `category`; AI title, summary bullets, starred, createdAt, lifecycle state.
- **AdRange** — → Episode; startTime, endTime, confidence, **[new]** `userVerdict`.
- **Chapter** — → Episode; title, startTime, endTime.
- **[new] KeyMoment** — → Episode; startTime, endTime, title (was a feature with no entity).
- **[changed] Embeddings** — Segment-adjacent float16 BLOBs (not a separate opaque index).
- **[new] PlayQueue** — persisted ordered episode list.

### 9.5 Pipeline performance & triggers

- **Chunked map-reduce (the core infeasibility fix):** a 2h episode is 25–40k tokens — larger than any candidate model's context and far past a tolerable single-pass prefill (~5.5 min at A16 prefill rates), against a ~2.5–3GB per-app jetsam ceiling. Map over 2–4k-token windows; reduce for episode-level outputs. Chunk size is a tunable.
- **Ad-exclusion contract:** summary and key-moment inputs are **transcript minus detected AdRanges** — a TL;DR that summarizes a sponsor read is a trust catastrophe for this product. Key moments are validated to not fall inside AdRanges. Bonus: 10–20% fewer input tokens. Detected AdRanges are additionally surfaced as labeled **"Sponsor break" chapters** in the merged chapter timeline (§8.11) — deterministic post-reduce assembly (`ChapterAssembly`), never an LLM task, so this surfacing adds zero model calls and cannot leak ad text into the model.
- **Embeddings run incrementally, in parallel** with LLM passes (they only need the transcript) so find-a-moment works during the first listen.
- **Triggers & battery:** the full pipeline defaults to **charging + Wi-Fi** (auto-download makes this natural). During playback, ASR is **playhead-anchored** and ad detection runs as a **rolling window**, so the player is useful immediately. User-initiated "process now" runs as a **BGContinuedProcessingTask** with system progress UI. A per-episode budget table is maintained (≈25–30 min sustained compute ≈ 15–20% battery if unplugged — hence the charging default). This resolves v1's open Q3: **auto for subscribed-while-charging, on-demand otherwise.**

### 9.6 Memory & thermal budget (new)

- **Single-AI-model-resident rule:** ASR is fully unloaded before the LLM loads; never two large models resident at once.
- **Entitlements from day one:** `com.apple.developer.kernel.increased-memory-limit`; the background-GPU entitlement for BGContinuedProcessingTask GPU work.
- **Guardrails:** `os_proc_available_memory` checked before each stage; **degrade-don't-die** — under pressure, drop the LLM pass, never the audio.
- **Explicit success criterion:** *playback never dies to jetsam during processing.*
- **Thermal:** budget for **steady-state throughput (~55–60% of peak)**, not fictional "cooldowns" — sustained inference throttles −37–44% within minutes. The device-twin harness reports thermal state per stage.

## 10. Build directive (autonomous phased build)

**Replaces v1's one-shot directive.** Autonomous agent-driven build, **real pipeline** end to end, minimal human gates — but with an integration spine and hard exit criteria per phase. Human review only at phase exits. The builder keeps a decision log.

- **P0 — Pipeline package + Mac CLI harness + bake-offs.**
  *Exit:* a **model decision record** (quality/F1, tok/s, peak RSS, battery, thermal) from ~20 real episodes, with budgets measured on the **device twin** (physical iPhone 14 Pro). LLM, ASR, diarization, and embedding winners chosen against §9.3 criteria.
- **P1 — Player "thread of steel," zero AI.**
  *Exit demo:* search → subscribe → OPML import → download/stream → background playback → lock-screen/remote-command snip timestamp capture. Rock-solid transport, queue, offline.
- **P2 — Pipeline on device.**
  *Exit:* one 2h episode fully processed within the §9.5/§9.6 budgets; **playback survives processing**; the first-play degraded state works end to end.
- **P3 — Full UX.**
  Karaoke view (to the §8.1 acceptance bar), snips library + boundary editor, find-a-moment, snip cards, ad-skip trust loop.
- **P4 — Dogfood polish.**
  Replaying **recorded real-pipeline fixtures** for UI iteration is explicitly permitted (that is *not* mock inference — the fixtures came from the real pipeline). Dogfood metrics per §11.

**Distribution:** local builds to a physical iPhone for now (direct Xcode install; Fastlane ad-hoc if convenient). TestFlight at P4/dogfood for the anonymized-counter phase.

## 11. Success metrics

Split by phase, because v1's metrics were uncollectable under a no-tracking stance.

- **Dogfood phase (concrete, self-measured):** N snips/week sustained; **ad-skip undo rate < X% over 20 episodes**; **zero jetsam playback deaths**; first-play-to-karaoke latency; per-episode battery within budget.
- **TestFlight phase (anonymized counters, opt-out):** TelemetryDeck-style events — `snip_created`, `episode_played`, `ad_skip_undone` — **no content, no PII, no ATT prompt**. The public ad-skip default (§8.11) is decided from real undo-rate data.

**Privacy line:** listening *content* never leaves the device; anonymous *feature counters* do, with an opt-out shown at first run.

## 12. Legal & policy

| Item | Position |
|---|---|
| **Ship name** | **PodSmart** (chosen). This retires the "Hark" conflict (the live *Hark Audio* clips app + Hark Labs' pending USPTO Class 9 "HARK" filing). **⚠ Clearance not yet done:** a same-category AI podcast-summary product named "Podsmart" appears to exist — a direct in-category collision, the same failure mode we left Hark to avoid. **Run a proper trademark/App-Store-name search on "PodSmart" before any public artifact; keep a fallback name ready.** Launch blocker, not a build blocker. Internal code stays `HarkCore` (never shipped). |
| **Ad skipping** | Client-side, user-controlled playback skipping of public RSS enclosures. Supported by *Fox v. Dish* and *Sony Betamax*; live precedent apps exist (Skipper — on-device, Herd, Adblock Podcast, PurerPodcasts, PodSkip). We never modify, re-host, or redistribute content. |
| **Snip cards** | Default 60–90s, **hard cap ~3 min**; attribution baked into image + audio; **local share-sheet only, never hosted**; no language inviting episode redistribution. |
| **Model licenses** | **Hard model-selection criterion** — prefer Apache-2.0/MIT; the About screen in **You** carries required notices (e.g. "Built with Llama" *only if ever used* — prefer Apache to avoid it). |
| **Directory APIs** | Podcast Index primary **with required attribution**; iTunes Search fallback (debounced); subscribed-feed metadata from RSS keeps us outside PI's no-permanent-database clause. Honest, distinct `User-Agent`. |
| **App Review** | Canned **5.2.3** response ready (public RSS enclosures, standard player behavior, Overcast/Pocket Casts precedent). Expect a 17+ rating from directory content. |

## 13. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| 1.7B model quality insufficient | Med — **measured** | D37 bake-off picked Qwen3-1.7B (faithful-but-generic digests, same class as FM's judged 3/5); extractive-summary fallback on refusal/parse-fail; a larger bundled model or the ANE port can raise quality later |
| Full-transcript pass infeasible on device | **Was fatal in v1 — fixed** | Chunked map-reduce (§9.2/§9.5); single-model-resident + memory guardrails (§9.6) |
| iOS background-task starvation | High | Playhead-anchored + rolling-window processing during play; charging-time processing; BGContinuedProcessingTask for "process now"; honest UX |
| MLX foreground-only (crashes when backgrounded) | **High — now applies to ALL processing** (single MLX engine, D38, no background-safe tier behind it) | Runs are foreground/awake (idle timer held) or BGContinuedProcessingTask-with-GPU; playhead-anchored during play; **the Core ML/ANE port of the model is the fix** that restores background inference |
| Foundation Models refuses guided-generation requests on real transcript content | **Retired for the app** (FM is bench-only, D38) | N/A in the shipping app — the bundled MLX model showed zero refusals on the FM-refuser corpus (D37). Retained note for the Mac bench: guided generation was the trigger (E16/D24), plain-text + line-format fallback fixed it |
| Ad-skip false positives erode trust | **Med** — the app's MLX ad detector (D38: per-line MLX classify + MLX verify-pass) is **weaker than the FM detector** it replaced: recall holds but precision is low (a 1.7B is a weaker discriminator), so corpus F1 sits below the ≥0.85 auto-skip gate | Ad-skip stays **Ask/Off** (§8.11) — auto-skip is gated by F1 and remains unmet; ads surface as **visible "Sponsor break" chapters** (§8.11, D28) where recall matters more than precision and a mislabeled chapter is trust-cheap; "Play it anyway" undo + "Not an ad" + per-show On/Off/Ask; **a dedicated fine-tuned ad classifier is the path to the gate** (v1 open Q2) |
| Legal/industry friction on ad skipping | Med — proceeding | User-side playback control; never modify/re-host/redistribute; canned 5.2.3 response; precedent apps live |
| Ship-name "PodSmart" not cleared (possible in-category "Podsmart") | Med | Trademark + App Store name search before public launch; fallback name ready (§12) |
| Thermal throttling on long episodes | Med | Budget for ~55–60% steady-state throughput; device-twin thermal reporting (§9.6) |
| Jetsam kills playback during processing | High | Degrade-don't-die; increased-memory-limit entitlement; explicit success criterion (§9.6) |

## 14. Resolved from v1's open questions

1. **WhisperKit `base` vs `small` vs SpeechTranscriber** → decided by the P0 ASR bake-off under a <10% WER gate (§9.3).
2. **Is 1.7B enough for ad classification, or a tiny fine-tuned classifier?** → Measured (D38): keyword candidates + per-line MLX classify + MLX verify-pass on the 7-episode corpus lands **below** FM's ad-F1 — recall is fine, precision is the weak point (a 1.7B is a weaker discriminator). Ad-skip auto-mode stays gated (§8.11); visible Sponsor-break chapters tolerate it; a **dedicated fine-tuned ad classifier remains the path** (v1 open Q2, §9.3).
3. **Transcribe every downloaded episode vs on-demand?** → **auto for subscribed-while-charging-on-Wi-Fi; on-demand otherwise** (§9.5).
4. **LLM-determined semantic snip boundaries** → v1.1 (the v1 snip boundary *editor* covers the verified recovery need — §7.5).

---

*v1 (`prd-hark.md`) is retained unchanged for diffing.*
