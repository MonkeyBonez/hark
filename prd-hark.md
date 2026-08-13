# PRD: Hark — Local-First AI Podcast Player

**Author:** Sne
**Status:** v1.0 — ready for build
**Last updated:** June 9, 2026
**Bundle ID:** com.sne.hark

---

## 1. Vision

An iOS podcast player that delivers Snipd-class AI features — moment capture, episode summaries, key-moment detection, and automatic ad skipping — **entirely on-device, for free**. No subscription, no server inference costs, no audio leaving the phone.

The bet is twofold: Apple Silicon can now run small models fast enough, **and** small language models themselves have gotten dramatically better — 3B-class models today outperform much larger models from two years ago. Together, that means features competitors charge $99/yr for can be delivered at zero marginal cost, on iPhone 14 Pro and newer.

## 2. Problem

Podcast listeners who treat podcasts as a learning medium face three frictions:

1. **Capture friction** — hearing something valuable mid-run or mid-drive and having no way to save it without stopping.
2. **Retention friction** — finishing a 2-hour episode and retaining almost nothing actionable.
3. **Time friction** — ads and filler consume 10–20% of listening time.

Snipd solves 1 and 2 well, but gates the best features behind a premium subscription, because their inference runs in the cloud. Ad skipping is largely unsolved in mainstream players.

## 3. Why now / Why us

- **Hardware inflection:** iPhone 14 Pro+ Neural Engine runs on-device ASR near-real-time (WhisperKit) and 3B-parameter LLMs at usable token rates.
- **Model inflection:** modern SLMs (3B-class, 4-bit quantized) are good enough for summarization, classification, and titling.
- **Cost structure as moat:** competitors' premium pricing exists to cover cloud inference. Local-first makes "free forever" structurally sustainable.
- **Privacy as a feature:** nothing the user listens to or clips ever leaves the device.

## 4. Target user

Knowledge-worker podcast listeners (20s–40s) who listen during workouts, commutes, and chores — and currently screenshot timestamps or lose insights entirely.

## 5. Core product principles

1. **Capture is instant; intelligence can wait.** Any user-initiated action gives feedback in <300ms. AI enrichment happens asynchronously.
2. **Local by default.** No feature requires a network call beyond fetching podcast audio/RSS.
3. **The player must be great before the AI is.** Table-stakes playback has to be solid or nothing else matters.

## 6. Content acquisition

- **Directory/search:** Podcast Index API (free, open) or iTunes Search API.
- **Audio:** podcasts are public RSS feeds with direct audio URLs — standard player behavior, no licensing required.
- **Transcripts:** check for the Podcasting 2.0 `<podcast:transcript>` RSS tag first — if the show ships an official transcript, use it and skip ASR. Otherwise, transcribe locally with WhisperKit.

## 7. Features

### 7.1 Sync (instant, blocking on UX)

| Feature | Behavior | Latency budget |
|---|---|---|
| **Snip capture** | Triple-tap headphones / lock-screen button / steering wheel control marks current timestamp with a 60s-back / 15s-forward window, edges snapped to sentence boundaries in the transcript. Confirmation haptic + beep. | <300ms to acknowledge |
| **Manual bookmark** | Single tap in app marks timestamp | <100ms |
| **Ad skip (playback)** | If ad segments are precomputed, player skips them with a toast + audio cue (see 8.3) | Instant |

### 7.2 Async (background, minutes-scale acceptable)

| Feature | Behavior | Trigger |
|---|---|---|
| **Episode transcription** | Full transcript with speaker turns + timestamps (official transcript if available, else on-device ASR) | On download / first play |
| **Snip enrichment** | Each snip gets a title, summary bullets, cleaned transcript excerpt | After snip, queued |
| **Episode summary** | TL;DR + key takeaways | After transcription |
| **Key-moment detection** | AI proposes 3–7 highlight segments per episode | After transcription |
| **Chapter generation** | Topic-based chapters with titles | After transcription |
| **Ad detection** | Classify transcript segments as ads; store skip ranges. Accuracy target exploratory — tune in beta. | After transcription |

### 7.3 Find-a-moment search

"When do they talk about X?" — keyword + semantic search over the episode transcript. Results jump-scroll the user to the matching part of the transcript; tapping a line plays from that moment. Fully local retrieval, no generation. (Entry point — top search bar vs. overflow menu — is a visual-design decision deferred; build the functionality.)

### 7.4 Shareable snip cards

Audio clip + quote image for sharing.

### 7.5 Explicitly out of scope for MVP

- Chat-with-episode (find-a-moment covers the core need)
- Export integrations (Markdown, Obsidian, Notion, Readwise)
- Onboarding flow (defer)
- Android, audiobook/YouTube ingestion, social/discovery feed
- Usage analytics/tracking

## 8. Design & interaction

Reference inspiration: Snipd's player and snip-card patterns (screenshots on file). What we take, what we change:

### 8.1 Navigation

Four tabs: **Home / Discover / Snips / You.** Proven structure, familiar to switchers.

### 8.2 Player (the hero screen)

- **Transcript-first karaoke view:** large type, current sentence bright, upcoming text dimmed, auto-scrolls with playback. Tap any line to seek.
- **Scrubber** with chapter pill (current chapter title), snip markers (dots), and **ad regions rendered as greyed segments**.
- **Persistent "Create snip" pill** at the bottom — always one thumb-tap away.
- Speaker attribution chips above the transcript when speaker changes.
- Standard controls: ±10/30s skip, speed, queue.

### 8.3 Ad-skip feedback

When playback hits a detected ad range: show a toast ("Skipped 90s of ads") **plus an audio cue** — rather than a hard cut, play the ad audibly accelerated (e.g. ~100x, reads as a "zoom/whoosh" artifact) until the range ends. The user *hears* that something was passed, which builds trust that content wasn't silently eaten. Mock the sound design for now; refine later. Single settings toggle controls the whole feature.

### 8.4 Snip cards

Category label (e.g. INSIGHT), bold AI title, 2 bullet takeaways, timestamp, star. Tap to expand to full transcript excerpt + play button.

### 8.5 Snips library

Search bar, filter chips (by podcast), recent-episodes grouping with snip counts, starred section.

### 8.6 Processing state visibility

Local processing is visible machinery — surface it honestly: small badge on episodes ("transcribing…" → "summary ready"), and a processing queue view in the **You** tab (alongside storage used and model status). No fake instancy.

### 8.7 Offline/online

Everything downloaded is fully functional offline — transcripts, snips, summaries, search all live on-device (this is our structural advantage). Network is needed only for directory search, RSS refresh, audio download, artwork. Queued processing continues offline.

### 8.8 Settings (minimal, playback-focused)

Playback speed defaults, skip intervals, queue behavior, download preferences (auto-download, Wi-Fi only), and a single **Ad detection & skip on/off** toggle. No model knobs, no snip-window sliders.

### 8.9 Empty states

First launch: podcast search bar front and center — "find your first show." Zero snips: brief pointer to the snip gesture.

### 8.10 No-paywall identity

No trial banners, no upgrade CTAs, no locked features. The space competitors spend on upsell, we spend on content.

## 9. Technical strategy

### 9.1 Stack

- **UI:** SwiftUI, iOS 18 minimum, iPhone 14 Pro+ device floor.
- **Persistence:** GRDB/SQLite preferred (timestamped transcript segments are highly relational and need fast range queries), but builder may choose SwiftData if it proves cleaner in practice — builder's call, just commit early.
- **Audio:** AVFoundation/AVAudioEngine; background audio session; lock-screen/remote command center integration (required for the headphone snip gesture via remote commands).

### 9.2 Pipeline

```
RSS fetch → audio download → [official transcript? use it : WhisperKit ASR]
  → timestamped transcript
  → [LLM pass 1: segment classification — ads, chapters]
  → [LLM pass 2: summarization — episode TL;DR, key moments]
  → [LLM on-demand: snip enrichment]
  → [embedding index for find-a-moment search]
```

### 9.3 Models & inference

- **ASR:** WhisperKit (Core ML). `small.en` or `base` quantized; target ≥5x real-time.
- **LLM:** 3B-class instruction-tuned, 4-bit quantized (~2GB), e.g. Llama 3.2 3B or Qwen 2.5 3B. **Framework not committed: evaluate both MLX Swift and Core ML during the build** and pick based on measured throughput/memory on target hardware.
- **Search:** small on-device embedding model; keyword match as the floor.
- **Ad detection:** LLM classification over transcript windows + heuristics (sponsor phrases, promo codes/URLs).
- **Mac-first testability (required):** the entire AI pipeline (ASR → classification → summarization → embedding) must be built as a Swift package that runs standalone on macOS with a CLI harness, so models can be tested and benchmarked on the build machine against real episodes before porting to device. Simulator does not exercise ANE/MLX properly; on-device validation happens on a physical iPhone.

### 9.4 Data model (lock the entities; refine fields during build)

Everything hangs off timestamped transcript segments — one source of truth that every feature reads from.

- **Podcast** — RSS URL, title, artwork, subscription state
- **Episode** — → Podcast; audio URL, download state, processing state (none → transcribing → transcribed → summarized), duration, pub date
- **Transcript** — → Episode; composed of **Segments** (text, startTime, endTime, speaker)
- **Snip** — → Episode; time range (segment-aligned), AI title, summary bullets, starred, createdAt
- **AdRange** — → Episode; startTime, endTime, confidence
- **Chapter** — → Episode; title, startTime, endTime
- **EmbeddingIndex** — per-episode vector index over segments for find-a-moment

### 9.5 Background processing

iOS `BGProcessingTask` is opportunistic. Mitigations: process while app is foregrounded/playing (audio-session runtime), charging-time processing, honest UX ("Summary ready" notification rather than promised immediacy).

## 10. Build directive

**Build the complete MVP in one shot** — no phased milestones. All of: player + RSS/directory/downloads + snip capture + full AI pipeline (transcription, snip enrichment, summaries, key moments, chapters, ad detection) + find-a-moment search + snip cards + the design spec in §8. The Mac CLI harness (§9.3) is part of the deliverable, used to validate models locally during the build. No mock-inference mode — real pipeline end to end.

**Distribution:** local builds to a physical iPhone for now (direct Xcode install; Fastlane ad-hoc if convenient). No TestFlight yet.

## 11. Success metrics

- **Activation:** % of new users who play an episode and create ≥1 snip in week 1.
- **Retention:** week-2 / week-4 return rate.

(No behavioral tracking of what users snip or listen to — consistent with local-first privacy. Revisit opt-in analytics later.)

## 12. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| 3B model quality insufficient | High | Mac CLI harness benchmarks (3B vs 7B-quantized) on ~20 real episodes during build; extractive-summary fallback |
| iOS background task starvation | High | Foreground-piggyback processing; charging-time processing; honest UX |
| Ad-skip false positives erode trust | Med | Audible-skip design makes skips perceptible; toggle off; tune in beta |
| Legal/industry friction on ad skipping | Med — flagged, proceeding | User-side playback control (skip-button/SponsorBlock category); never modify, re-host, or redistribute content. Legal sanity check before public launch. |
| Thermal throttling on long episodes | Med | Chunked processing with cooldowns |

## 13. Open questions (resolve during build)

1. WhisperKit `base` vs `small` on real podcast audio (music beds, crosstalk)?
2. Is 3B enough for ad classification, or is a tiny fine-tuned classifier better?
3. Transcribe every downloaded episode automatically vs. on-demand?
4. v1.1: LLM-determined semantic snip boundaries ("expand until the thought completes")?
