import Foundation

/// Splits a transcript into token-bounded windows with a small overlap so context isn't lost at
/// window seams. Never splits a segment. This is the mechanism that makes a 2h episode fit a
/// 4,096-token model (PRD §9.2).
public struct Chunker: Sendable {
    public let targetTokens: Int      // window budget (leave headroom below the model's context limit)
    public let overlapTokens: Int     // carry-over between adjacent windows
    private let tokenizer: TokenEstimating

    public init(targetTokens: Int, overlapTokens: Int = 128, tokenizer: TokenEstimating = HeuristicTokenizer()) {
        precondition(targetTokens > overlapTokens, "target must exceed overlap")
        self.targetTokens = targetTokens
        self.overlapTokens = overlapTokens
        self.tokenizer = tokenizer
    }

    /// Convenience: derive a safe window budget from an engine's context limit, reserving room for
    /// the prompt scaffold and the generated output.
    public static func forContextLimit(_ contextTokens: Int, promptOverhead: Int = 512, outputReserve: Int = 512) -> Chunker {
        let budget = max(256, contextTokens - promptOverhead - outputReserve)
        return Chunker(targetTokens: budget)
    }

    public func windows(for transcript: Transcript) -> [TranscriptWindow] {
        var windows: [TranscriptWindow] = []
        var current: [TranscriptSegment] = []
        var currentTokens = 0
        var windowId = 0

        func flush(carryOverlap: Bool) {
            guard !current.isEmpty else { return }
            windows.append(TranscriptWindow(id: windowId, segments: current, estimatedTokens: currentTokens))
            windowId += 1
            guard carryOverlap else { current = []; currentTokens = 0; return }
            // Carry trailing segments up to overlapTokens into the next window.
            var carried: [TranscriptSegment] = []
            var carriedTokens = 0
            for seg in current.reversed() {
                let t = tokenizer.estimateTokens(seg.text)
                if carriedTokens + t > overlapTokens { break }
                carried.insert(seg, at: 0)
                carriedTokens += t
            }
            current = carried
            currentTokens = carriedTokens
        }

        for seg in transcript.segments {
            let segTokens = tokenizer.estimateTokens(seg.text)
            // A single monster segment that alone exceeds the budget still goes in its own window.
            if currentTokens + segTokens > targetTokens && !current.isEmpty {
                flush(carryOverlap: true)
            }
            current.append(seg)
            currentTokens += segTokens
        }
        flush(carryOverlap: false)
        return windows
    }
}
