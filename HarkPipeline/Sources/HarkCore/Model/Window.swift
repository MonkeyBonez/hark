import Foundation

/// A token-bounded slice of the transcript — the unit the LLM "map" stage sees. This exists
/// because a 2h episode is 25–40k tokens, larger than any candidate model's context and far past
/// a tolerable single-pass prefill; the pipeline maps over these windows and reduces (PRD §9.2/§9.5).
public struct TranscriptWindow: Sendable, Codable, Equatable, Identifiable {
    public let id: Int              // ordinal index within the episode
    public var segments: [TranscriptSegment]
    public var estimatedTokens: Int

    public init(id: Int, segments: [TranscriptSegment], estimatedTokens: Int) {
        self.id = id; self.segments = segments; self.estimatedTokens = estimatedTokens
    }

    public var startMs: Int { segments.first?.startMs ?? 0 }
    public var endMs: Int { segments.last?.endMs ?? 0 }
    public var text: String { segments.map(\.text).joined(separator: " ") }
}

/// The "map" output for one window. Deliberately small and structured so the reduce stage stays
/// cheap and so guided-generation engines (Foundation Models) can produce it directly.
public struct WindowNotes: Sendable, Codable, Equatable {
    public var windowId: Int
    /// Window time bounds (ms) carried on the notes so the reduce stage can drop ad-overlapping
    /// windows without re-deriving geometry — the ad-exclusion contract at map granularity.
    public var startMs: Int
    public var endMs: Int
    public var topicLabel: String
    public var salientPoints: [String]
    public var quotableLines: [String]

    public init(windowId: Int, startMs: Int, endMs: Int, topicLabel: String, salientPoints: [String],
                quotableLines: [String]) {
        self.windowId = windowId; self.startMs = startMs; self.endMs = endMs
        self.topicLabel = topicLabel
        self.salientPoints = salientPoints; self.quotableLines = quotableLines
    }
}
