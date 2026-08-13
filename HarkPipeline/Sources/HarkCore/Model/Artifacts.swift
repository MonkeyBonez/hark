import Foundation

/// A time range classified as advertising. Confidence + userVerdict feed the trust loop (PRD §8.11).
public struct AdRange: Sendable, Codable, Equatable {
    public enum UserVerdict: String, Sendable, Codable { case unset, confirmed, notAnAd }
    public var startMs: Int
    public var endMs: Int
    public var confidence: Double        // 0...1
    public var userVerdict: UserVerdict

    public init(startMs: Int, endMs: Int, confidence: Double, userVerdict: UserVerdict = .unset) {
        self.startMs = startMs
        self.endMs = endMs
        self.confidence = confidence
        self.userVerdict = userVerdict
    }

    public var durationMs: Int { max(0, endMs - startMs) }
    public func overlaps(startMs a: Int, endMs b: Int) -> Bool { a < endMs && b > startMs }
}

public struct Chapter: Sendable, Codable, Equatable {
    public var title: String
    public var startMs: Int
    public var endMs: Int
    public init(title: String, startMs: Int, endMs: Int) {
        self.title = title; self.startMs = startMs; self.endMs = endMs
    }
}

/// A proposed highlight. Validated to NOT fall inside any AdRange before it is surfaced (PRD §9.5).
public struct KeyMoment: Sendable, Codable, Equatable {
    public var title: String
    public var startMs: Int
    public var endMs: Int
    public init(title: String, startMs: Int, endMs: Int) {
        self.title = title; self.startMs = startMs; self.endMs = endMs
    }
}

public struct EpisodeSummary: Sendable, Codable, Equatable {
    public var tldr: String
    public var takeaways: [String]
    public init(tldr: String, takeaways: [String]) { self.tldr = tldr; self.takeaways = takeaways }
}

/// The bundled output of the reduce stage.
public struct EpisodeDigest: Sendable, Codable, Equatable {
    public var summary: EpisodeSummary
    public var keyMoments: [KeyMoment]
    public var chapters: [Chapter]
    public init(summary: EpisodeSummary, keyMoments: [KeyMoment], chapters: [Chapter]) {
        self.summary = summary; self.keyMoments = keyMoments; self.chapters = chapters
    }
}

// MARK: - Snip enrichment (on-demand, queue-jumped)

public struct SnipEnrichmentRequest: Sendable, Codable, Equatable {
    public var episodeId: String
    /// The raw excerpt the user believes they saved (denormalized text, never a segment FK).
    public var excerpt: String
    public var startMs: Int
    public var endMs: Int
    public init(episodeId: String, excerpt: String, startMs: Int, endMs: Int) {
        self.episodeId = episodeId; self.excerpt = excerpt; self.startMs = startMs; self.endMs = endMs
    }
}

public struct SnipEnrichment: Sendable, Codable, Equatable {
    /// The category label rendered on the snip card face — produced HERE, fixing v1's orphaned
    /// "INSIGHT" label that nothing generated (PRD §8.4).
    public enum Category: String, Sendable, Codable, CaseIterable {
        case insight, quote, takeaway, question, story
    }
    public var category: Category
    public var title: String
    public var bullets: [String]
    public var cleanedExcerpt: String
    public init(category: Category, title: String, bullets: [String], cleanedExcerpt: String) {
        self.category = category; self.title = title; self.bullets = bullets; self.cleanedExcerpt = cleanedExcerpt
    }
}

/// A per-segment embedding, stored as float16-equivalent values (PRD §9.3: float16 BLOBs,
/// brute-force in-memory search per episode, no sqlite-vec).
public struct SegmentEmbedding: Sendable, Codable, Equatable {
    public var segmentId: UUID
    public var vector: [Float]
    public init(segmentId: UUID, vector: [Float]) { self.segmentId = segmentId; self.vector = vector }
}
