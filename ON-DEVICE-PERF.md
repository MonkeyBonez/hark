# On-device acceleration on iPhone 14 Pro (A16 / iOS 26)

Researched 2026-08-14. Target hardware: A16 — 6 CPU cores, 5 GPU cores, **16-core Neural Engine**,
6GB RAM. Sources are linked inline; where Apple publishes no number, the estimate is marked.

Three workloads: **(A)** a 33M sentence embedder over ~400 sentences/episode, **(B)** a
385-parameter logistic head, **(C)** a 1.7B LLM (MLX/Metal) for snip enrichment.

---

## 1. URGENT: our Metal path can now crash the app on iOS 26.2

Metal compute is hard-blocked when an iPhone app backgrounds
(`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`), and the **audio background mode
does not exempt it**. That was already known (D35) and is why processing is foreground-only.

What changed: on **iOS 26.2, in-flight GPU work returns `MTLCommandBufferError` code 8
`accessRevoked` and crashes the process**, where previously it merely failed the job
([whisper.cpp#3531](https://github.com/ggml-org/whisper.cpp/issues/3531),
[llama.cpp#16998](https://github.com/ggml-org/llama.cpp/issues/16998)).

We run MLX (Metal) for snip enrichment, triggered by a user capturing a snip — i.e. exactly when
they are likely to lock the phone and put it in a pocket. **Action: catch/guard MLX work against
backgrounding, or gate it on `UIApplication.shared.applicationState == .active` and abandon cleanly
on `willResignActive`.** This is a crash risk in current shipping code, not a future concern.

## 2. Background execution: ANE yes, GPU never (on iPhone)

- `MLComputeUnits.cpuAndNeuralEngine` exists specifically to exclude the GPU, and Apple's docs
  recommend restricting compute units if the app may run in the background
  ([docs](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandneuralengine)).
- Apple DTS on [thread 807957](https://developer.apple.com/forums/thread/807957): a developer saw
  4-5x slowdown running Core ML in a `BGContinuedProcessingTask`; DTS attributed it to **lost GPU
  access elsewhere in the pipeline, not ANE throttling**. So ANE work continues; anything that
  quietly touches Metal does not.
- `BGContinuedProcessingTask.supportedResources.contains(.gpu)` returns **false on every iPhone
  tested** — that entitlement is iPad-only ([thread 816774](https://developer.apple.com/forums/thread/816774)).
- Honest caveat: there is **no categorical Apple statement** that ANE inference is permitted while
  backgrounded. Evidence is strong and consistent but circumstantial — verify on device before
  designing around it.

**The cheaper lever we already have:** the app ships `UIBackgroundModes: [audio]`, so during
playback we are alive anyway. Transcription (SpeechTranscriber) is not Metal — so *transcribe while
the user listens* is available now and needs no new entitlement. That alone removes most of the
"keep Hark open" friction, without waiting for any Core ML port.

## 3. Getting the embedder actually onto the ANE

A plain coremltools conversion of an HF model will **run, but fall back** to CPU/GPU. Apple's
[ANE transformers guidance](https://machinelearning.apple.com/research/neural-engine-transformers)
requires rewriting the model:

1. 4D **channels-first `(B, C, 1, S)`** tensors, not 3D channels-last.
2. Replace every `nn.Linear` with `nn.Conv2d`.
3. Split Q/K/V into explicit per-head chunks (L2 residency).
4. `einsum("bchq,bkhc->bkhq")` instead of reshape/transpose, to avoid memory copies.

Hard constraints: the **last axis must be contiguous and 64-byte aligned** (a singleton last axis is
padded to 64 bytes — 32x memory waste in fp16), and **`compute_precision=FLOAT32` bars the ANE
entirely**. ANE wants static shapes.

Reported wins: **10x latency, 14x peak memory**; distilbert seq128/batch1 on iPhone 13 =
**3.47 ms @ 0.454 W**. Note latency is *flat* across seq 32/64/128 at batch 1 — bandwidth-bound, so
short sentences buy nothing; batching does.

[`apple/ml-ane-transformers`](https://github.com/apple/ml-ane-transformers) ships **distilbert
only**. No ANE-optimized MiniLM/bge exists publicly, so porting the recipe to bge-small is original
work — budget for it rather than assuming a converter flag.

## 4. Batching 400 sentences — the shape choice decides ANE or not

- **Never `RangeDim`**: only the default shape runs on ANE; other shapes drop to GPU/CPU. A
  community repro measured **0% ANE / 60 it/s** with RangeDim vs **~75% ANE / 375 it/s** with
  [`EnumeratedShapes`](https://apple.github.io/coremltools/docs-guides/source/flexible-inputs.html),
  which Apple labels "use for best performance".
- From iOS 17.4, flexible-shape models also need `MLReshapeFrequencyHint.infrequent` to reach ANE.
- Bake a **fixed batch (16-32) and fixed sequence length (64)** and pad the tail.
- A batch-N *graph* is what amortises weight traffic — 400 batch-1 predictions is not the same
  thing, even through `predictions(fromBatch:)`.
- Estimated **0.2-0.6s for 400 sentences** (scaled from distilbert; no published MiniLM/bge A-series
  benchmark exists).

## 5. The logistic head: one `cblas_sgemv`, not 400 dot products

400 sentences against one weight vector is a matrix-vector product: a single
`cblas_sgemv` (400x384 · w), then `vDSP_vsadd` for the bias and `vvexpf` for the sigmoid.

Estimated **~10-30 µs** (0.31 MFLOP, ~614 KB streamed, memory-bound). Even a naive Swift loop is
~150-300 µs. This stage is ~4 orders of magnitude cheaper than the embedder — choose sgemv for
clarity, not speed. **BNNSGraph is not relevant** here (it targets real-time audio-thread inference
with zero runtime allocation; the classic BNNS layer API is deprecated).

## 6. Quantization: W8A8 for speed, palettization for size

Apple's own iPhone 14 Pro measurements:
- **W8A8 quantization is the latency lever**: MobileNetV2 0.48 -> **0.27 ms**, ResNet50 1.52 ->
  **0.94 ms** (~1.6-1.8x) for ~0.2 pt accuracy
  ([quantization perf](https://apple.github.io/coremltools/docs-guides/source/opt-quantization-perf.html)).
- **4-bit palettization is a size win, not latency** (MobileNetV2 0.48 -> 0.45 ms).

Third-party int8 on BGE-class embedders costs **<1% relative MTEB** — cheap for us.

## 7. Conversion + verification

`torch.jit.trace` (not `torch.export` — beta, ~70% op coverage), `mlprogram`, fp16,
`minimum_deployment_target=ct.target.iOS18`. Wrap pooling + L2 norm into the traced module
(sentence-transformers' `Pooling`/`Normalize` are not in `AutoModel.forward`), and ship a Swift
tokenizer.

**Always verify which unit actually ran** — assuming ANE placement is the classic mistake:
Xcode performance report (per-op compute unit; Xcode 16 adds "why unsupported"),
[`MLComputePlan`](https://developer.apple.com/documentation/coreml/mlcomputeplan-85vdw)
(`deviceUsage(for:)`, `estimatedCost`), and the Instruments **Core ML** template alongside the
**Neural Engine** and **GPU** instruments to catch mid-prediction handoffs.

## 8. Apple-native alternatives: keep shipping our own embedder

- **NLContextualEmbedding** (iOS 17+, not Apple-Intelligence-gated so it works on A16): BERT-class,
  512-dim, ~256 tokens. Three problems: it returns **per-token vectors only** (you mean-pool
  yourself, and mean-pooled BERT without contrastive fine-tuning is precisely the weakness bge/
  MiniLM were built to fix); assets are **downloaded on demand**, so first use can fail offline;
  and there are **no published MTEB/BEIR numbers**. Consistent with our own measurement:
  **0.55 Recall@3 vs bge/MiniLM 0.82**.
- **Foundation Models is unavailable on iPhone 14 Pro** — Apple Intelligence needs A17 Pro+. This
  independently confirms the D38 decision to drop FM from the app. It exposes no embedding API
  regardless.
- Core Spotlight semantic search returns ranked results, never vectors.

## Priority order for us

1. **Guard MLX/Metal against backgrounding** — crash risk today on iOS 26.2. (§1)
2. **Transcribe during audio playback** — already entitled, no port needed, kills most of the
   foreground-only friction. (§2)
3. **Core ML embedder with EnumeratedShapes + fixed batch**, verified on ANE. Unlocks search, ad
   detection, snip search from one pass. (§3, §4)
4. **W8A8 quantize** the embedder once it works. (§6)
5. `cblas_sgemv` for the head — trivial, do it when wiring the classifier. (§5)
