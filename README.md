# Hark

An iOS podcast player with on-device AI. Episodes are transcribed locally — starting from wherever you're listening — so you can follow along karaoke-style, snip the moment you just heard, and get AI titles and takeaways for your snips from a bundled local LLM. No cloud, no accounts; audio never leaves the phone.

## What's inside

- `HarkApp/` — SwiftUI app (iOS 26). Playhead-anchored chunked transcription (SpeechTranscriber), live transcript in the player, one-tap snips (in-app or the lock-screen bookmark button) with boundaries edited through the transcript text, snip enrichment via MLX (Qwen3-1.7B-4bit), plus the table stakes: RSS subscriptions, downloads, queue, background audio.
- `HarkPipeline/` — Swift package with the processing pipeline and `hark-bench`, a Mac CLI for benchmarking ASR/LLM/diarization engines against a real-episode corpus.
- `prd-hark-v2.md` — the product spec.

## Build

The bundled model weights are not in the repo: download [mlx-community/Qwen3-1.7B-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-4bit) into `HarkApp/Models/mlx-community__Qwen3-1.7B-4bit/`. Then:

```sh
cd HarkApp
xcodegen generate   # required again after adding source files
```

Open `HarkApp.xcodeproj` and run the `Hark` scheme on an iOS 26 device.

## Find a moment

The **Find** tab searches saved transcript lines and snips locally with the existing SQLite/GRDB
FTS5 index. It searches snip titles and takeaways, plus transcript lines that overlap a saved
snip. Enter whole words: all words must occur in the same transcript line or snip's indexed
metadata. This is lexical search, not semantic or prefix search. Edits and deletions are reflected
in the index; results survive relaunch. Each section shows up to 50 matches.

Tapping a result opens the player at the stored transcript-line or snip start. Downloaded audio is
preferred; otherwise the player's existing episode stream is used. Missing or unplayable audio and
saved times beyond the audio are reported instead of pretending playback succeeded. Search never
sends transcripts or audio to a service.

For simulator testing only, the Debug launch environment variable `HARK_SEARCH_FIXTURE=1` seeds
clearly labelled, authored synthetic text and a locally generated tone into the app's own data
container. It is not a transcription or an inference result and needs no model weights. A
search-only simulator build can use an empty `HarkApp/Models` directory; without bundled weights,
the app's existing LLM enrichment path may try to download them if invoked, so the fixture marks
its text and snip as already supplied and does not invoke that path.

Search uses the project's existing [GRDB](https://github.com/groue/GRDB.swift) (MIT license) and
SQLite [FTS5](https://www.sqlite.org/fts5.html) (SQLite's deliverable code is
[public domain](https://www.sqlite.org/copyright.html)); no additional search dependency is bundled.
