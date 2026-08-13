import Foundation

/// Token estimation. P0 uses a deterministic chars/4 heuristic as a stand-in so the chunker and
/// budgets are testable without pulling a real tokenizer. When a real engine is wired in, replace
/// this with the model's own tokenizer (the chunker takes any `TokenEstimating`).
public protocol TokenEstimating: Sendable {
    func estimateTokens(_ text: String) -> Int
}

/// chars/4 — a well-known rough approximation for English text. Documented as a stand-in.
public struct HeuristicTokenizer: TokenEstimating {
    public init() {}
    public func estimateTokens(_ text: String) -> Int {
        max(1, (text.count + 3) / 4)
    }
}
