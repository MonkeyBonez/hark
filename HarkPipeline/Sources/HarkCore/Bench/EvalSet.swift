import Foundation

/// The bake-off corpus manifest (PRD §10, P0: ~20 real episodes with music beds/crosstalk).
/// A JSON file points at local audio + optional reference transcript + labeled ad ranges.
/// See docs/P0-eval-set-spec.md for how to build one.
public struct EvalManifest: Sendable, Codable {
    public var episodes: [EvalEpisode]
    public init(episodes: [EvalEpisode]) { self.episodes = episodes }
}

public struct EvalEpisode: Sendable, Codable {
    public var id: String
    /// Path to a local audio file (wav/m4a/mp3), relative to the manifest or absolute.
    public var audioPath: String
    public var audioSeconds: Double
    /// Optional ground-truth transcript text for WER scoring.
    public var referenceTranscriptPath: String?
    /// Optional human-labeled ad ranges for ad-detection F1.
    public var labeledAdRanges: [LabeledAd]?
    /// Free-form tags: "music-bed", "crosstalk", "two-host", "dynamic-ads", etc.
    public var tags: [String]?

    public init(id: String, audioPath: String, audioSeconds: Double,
                referenceTranscriptPath: String? = nil, labeledAdRanges: [LabeledAd]? = nil, tags: [String]? = nil) {
        self.id = id; self.audioPath = audioPath; self.audioSeconds = audioSeconds
        self.referenceTranscriptPath = referenceTranscriptPath
        self.labeledAdRanges = labeledAdRanges; self.tags = tags
    }
}

public struct LabeledAd: Sendable, Codable {
    public var startMs: Int
    public var endMs: Int
    public init(startMs: Int, endMs: Int) { self.startMs = startMs; self.endMs = endMs }
    public var asAdRange: AdRange { AdRange(startMs: startMs, endMs: endMs, confidence: 1.0, userVerdict: .confirmed) }
}

public extension EvalManifest {
    static func load(from url: URL) throws -> EvalManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(EvalManifest.self, from: data)
    }
}

// MARK: - Ground-truth ad labels (Phase B)

/// Hand/agent-authored ad labels for one episode — the ground truth the ad-F1 gate scores against.
/// Categories follow the SponsorBlock-style distinction: only `sponsor` counts as the "ad" class for
/// the F1 gate; selfpromo/crosspromo are labeled so detector confusions can be analyzed separately.
public struct AdLabelFile: Sendable, Codable {
    public struct LabeledRange: Sendable, Codable {
        public enum Category: String, Sendable, Codable {
            case sponsor      // paid third-party ad / sponsor read
            case selfpromo    // host promoting own products/newsletter/community
            case crosspromo   // promoting another show/episode of the same network
        }
        public var startMs: Int
        public var endMs: Int
        public var category: Category
        public var note: String?
        /// True when the labeler was genuinely unsure — collected into the human audit list.
        public var flagged: Bool?

        public init(startMs: Int, endMs: Int, category: Category, note: String? = nil, flagged: Bool? = nil) {
            self.startMs = startMs; self.endMs = endMs; self.category = category
            self.note = note; self.flagged = flagged
        }
    }
    public var episodeId: String
    public var labeler: String       // "agent-fable" / "human" — provenance matters for trust
    public var ranges: [LabeledRange]

    public init(episodeId: String, labeler: String, ranges: [LabeledRange]) {
        self.episodeId = episodeId; self.labeler = labeler; self.ranges = ranges
    }

    public static func load(from url: URL) throws -> AdLabelFile {
        try JSONDecoder().decode(AdLabelFile.self, from: Data(contentsOf: url))
    }

    public func ranges(in category: LabeledRange.Category) -> [AdRange] {
        ranges.filter { $0.category == category }
            .map { AdRange(startMs: $0.startMs, endMs: $0.endMs, confidence: 1.0, userVerdict: .confirmed) }
    }
}

/// Full pipeline artifact dump (`real-full --artifacts`): transcript (timestamped segments),
/// detected ads, and the digest. One expensive pipeline run feeds every downstream scorer —
/// task-quality judging, retrieval (Recall@k) scoring, snip-enrichment probes, and the ad
/// verify-pass experiment — without re-running ASR or the LLM stages.
public struct FullArtifactFile: Sendable, Codable {
    public var episodeId: String
    public var audioSeconds: Double
    public var transcript: Transcript
    public var ads: [AdRange]
    public var digest: EpisodeDigest?
    public init(episodeId: String, audioSeconds: Double, transcript: Transcript,
                ads: [AdRange], digest: EpisodeDigest?) {
        self.episodeId = episodeId; self.audioSeconds = audioSeconds
        self.transcript = transcript; self.ads = ads; self.digest = digest
    }
    public static func load(from url: URL) throws -> FullArtifactFile {
        try JSONDecoder().decode(FullArtifactFile.self, from: Data(contentsOf: url))
    }
}

/// Hand/agent-authored retrieval queries for one episode — the ground truth for the embeddings
/// Recall@k gate. Targets are TIME RANGES (not segment ids) so re-transcription can't dangle them.
public struct RecallQueryFile: Sendable, Codable {
    public struct Query: Sendable, Codable {
        public var query: String
        public var targetStartMs: Int
        public var targetEndMs: Int
        public init(query: String, targetStartMs: Int, targetEndMs: Int) {
            self.query = query; self.targetStartMs = targetStartMs; self.targetEndMs = targetEndMs
        }
    }
    public var episodeId: String
    public var author: String
    public var queries: [Query]
    public init(episodeId: String, author: String, queries: [Query]) {
        self.episodeId = episodeId; self.author = author; self.queries = queries
    }
    public static func load(from url: URL) throws -> RecallQueryFile {
        try JSONDecoder().decode(RecallQueryFile.self, from: Data(contentsOf: url))
    }
}

/// Compact JSON artifact `real-full --json` writes: the run record + detected ad ranges — everything
/// `score-ads` needs, without dumping full transcripts/embeddings.
public struct RunArtifactFile: Sendable, Codable {
    public var record: EpisodeRunRecord
    public var ads: [AdRange]
    public init(record: EpisodeRunRecord, ads: [AdRange]) {
        self.record = record; self.ads = ads
    }
    public static func load(from url: URL) throws -> RunArtifactFile {
        try JSONDecoder().decode(RunArtifactFile.self, from: Data(contentsOf: url))
    }
}
