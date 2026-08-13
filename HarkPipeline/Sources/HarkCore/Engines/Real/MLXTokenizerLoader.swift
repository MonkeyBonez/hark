#if canImport(MLXLLM)
import Foundation
import MLXLMCommon
import Tokenizers

/// Loads a swift-transformers tokenizer from a local model directory and bridges it to
/// `MLXLMCommon.Tokenizer`. This is a hand-written replacement for mlx-swift-lm's
/// `#huggingFaceTokenizerLoader()` macro (D38).
///
/// Why not the macro: its plugin (`MLXHuggingFaceMacros`) builds and runs fine under SwiftPM but
/// fails under **xcodebuild** ("external macro … produced malformed response", 2026-07-20) — and
/// Xcode is the app's only build path. A plain type has no compiler plugin to trust, sign, or run,
/// so it builds identically under SwiftPM, xcodebuild, and Xcode. The bodies below are copied
/// verbatim from `MLXHuggingFaceMacros.TokenizerLoaderMacro` / `TokenizerAdaptorMacro`, so behavior
/// is unchanged; dropping the macro also lets HarkCore drop the whole `MLXHuggingFace` product.
public struct HarkTokenizerLoader: MLXLMCommon.TokenizerLoader {
    public init() {}
    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return HarkTokenizerBridge(upstream)
    }
}

/// Adapts a swift-transformers `Tokenizers.Tokenizer` to `MLXLMCommon.Tokenizer` (name/signature
/// differences: `decode(tokens:)` vs `decode(tokenIds:)`, distinct `TokenizerError`).
struct HarkTokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
#endif
