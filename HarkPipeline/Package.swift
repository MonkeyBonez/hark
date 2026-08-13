// swift-tools-version: 6.2
import PackageDescription

// HarkPipeline — the standalone, macOS-runnable AI pipeline core for Hark (codename).
//
// P0 deliverable. Two products:
//   • HarkCore   — pure-Foundation pipeline: data model, engine protocols, the chunked
//                  map-reduce orchestrator, memory/ad-exclusion contracts, and the
//                  bake-off scoring/metrics. NO model dependencies — engines are injected.
//   • hark-bench — the CLI bake-off harness that runs candidate engines over an eval set
//                  and emits a model-decision-record (RTF, WER, ad-F1, peak RSS, timings).
//
// Real engine adapters (WhisperKit, Apple Foundation Models, Core ML/ANE, FluidAudio,
// NLContextualEmbedding) are added AFTER P0 architecture is frozen — they pull in network
// downloads / entitlements and are mechanical to wire against these protocols. Mock engines
// ship here so the whole harness compiles and runs green today.
let package = Package(
    name: "HarkPipeline",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "HarkCore", targets: ["HarkCore"]),
        .executable(name: "hark-bench", targets: ["hark-bench"]),
    ],
    dependencies: [
        // argmax-oss-swift bundles both PRD-named bake-off candidates in one package:
        //   WhisperKit  — comparison ASR (vs SpeechTranscriber)
        //   SpeakerKit  — diarization candidate
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
        // FluidAudio — second diarization candidate (Apache-2.0, pyannote-style Core ML)
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
        // MLX Tier-2 (re-activated 2026-07-09, D35 — was removed for disk, D26).
        // On iPhone this is FOREGROUND-ONLY (Metal-GPU; crashes when backgrounded) — it is the
        // Tier-2 *test vehicle* for AI-off/pre-A17 devices; the ship path remains Core ML/ANE.
        // mlx-swift-lm 3.x, NOT mlx-swift-examples 2.29.1 (the LLM libraries moved repos):
        // the 2.29.1→mlx-swift 0.29.1 stack produced word-salad generation from 4-bit models
        // in SwiftPM CLI builds on this machine (quantized Metal kernels absent from the AOT
        // metallib; runtime-JIT'd ones computed garbage — verified 2026-07-09: same weights
        // coherent under Python mlx-lm, garbage under tier2-probe). 3.31.4 tracks mlx-swift
        // 0.31.4 and a fixed swift-transformers, which also removes the D35 HubApi SIGBUS
        // landmine. NOTE: SwiftPM CLI builds still can't compile the Metal kernels at ALL
        // (ml-explore/mlx-swift#430) — Mac harness runs need the colocated metallib restored
        // after any .build wipe; see README "MLX on the Mac CLI". Xcode app builds unaffected.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        // Tokenizer loading for local model directories: mlx-swift-lm 3.x no longer bundles
        // swift-transformers — consumers provide it and use MLXHuggingFace's
        // #huggingFaceTokenizerLoader() macro, which expands to Tokenizers.AutoTokenizer.
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.3.3"),
        // `MLXModelStore` still downloads weights with plain URLSession and loads via
        // loadModel(directory:) — app-managed download stays closer to the ship design (D35).
    ],
    targets: [
        .target(
            name: "HarkCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                // MLXHuggingFace (the #huggingFaceTokenizerLoader macro) dropped in D38 — its macro
                // plugin fails under xcodebuild; HarkTokenizerLoader hand-writes the expansion.
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "hark-bench",
            dependencies: ["HarkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "HarkCoreTests",
            dependencies: ["HarkCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
