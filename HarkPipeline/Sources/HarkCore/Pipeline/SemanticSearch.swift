import Foundation

/// Brute-force in-memory semantic search per episode (PRD §9.3: ~1,800 float16 vectors, <10ms, no
/// sqlite-vec). This is the find-a-moment retrieval core; it lives in HarkCore so both the app and
/// the harness use the identical implementation.
public struct SemanticSearch: Sendable {
    public let embeddings: [SegmentEmbedding]
    public let segmentsById: [UUID: TranscriptSegment]

    public init(transcript: Transcript, embeddings: [SegmentEmbedding]) {
        self.embeddings = embeddings
        self.segmentsById = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0) })
    }

    public struct Hit: Sendable, Equatable {
        public var segment: TranscriptSegment
        public var score: Float
    }

    /// Returns the top-k segments by cosine similarity to `queryVector`.
    public func topK(_ k: Int, queryVector: [Float]) -> [Hit] {
        embeddings
            .compactMap { emb -> Hit? in
                guard let seg = segmentsById[emb.segmentId] else { return nil }
                return Hit(segment: seg, score: Self.cosine(queryVector, emb.vector))
            }
            .sorted { $0.score > $1.score }
            .prefix(k)
            .map { $0 }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }
}
