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
