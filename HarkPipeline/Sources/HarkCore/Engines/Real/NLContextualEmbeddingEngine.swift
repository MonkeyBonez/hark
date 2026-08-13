#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// Embedding adapter for Apple's **NLContextualEmbedding** (NaturalLanguage framework) — the
/// zero-download embedding candidate in the PRD §9.3 bake-off. Confirmed working on this machine:
/// English embedder, dimension 512, per-token vectors via `enumerateTokenVectors`.
///
/// `EmbeddingEngine.embed` needs one vector per input string (a transcript segment), but the API
/// gives per-token vectors — so each text is **mean-pooled** across its token vectors into a single
/// segment-level embedding. Mean-pooling is a standard, cheap sentence-embedding technique and keeps
/// this fully local/synchronous per call (no model download beyond the OS-bundled embedder).
@available(macOS 13.0, iOS 16.0, *)
public struct NLContextualEmbeddingEngine: EmbeddingEngine {
    public let identifier: String
    public let dimension: Int
    public let approxResidentBytes: Int
    private let language: NLLanguage

    public enum EngineError: Error, CustomStringConvertible {
        case noEmbedderForLanguage(String)
        public var description: String {
            switch self { case .noEmbedderForLanguage(let l): return "No NLContextualEmbedding available for \(l)" }
        }
    }

    public init(identifier: String = "nlcontextualembedding-en", language: NLLanguage = .english,
                approxResidentBytes: Int = 100 * 1_000_000) throws {
        self.identifier = identifier
        self.language = language
        self.approxResidentBytes = approxResidentBytes
        guard let embedder = NLContextualEmbedding(language: language) else {
            throw EngineError.noEmbedderForLanguage(language.rawValue)
        }
        self.dimension = embedder.dimension
    }

    public func load() async throws {
        guard let embedder = NLContextualEmbedding(language: language) else {
            throw EngineError.noEmbedderForLanguage(language.rawValue)
        }
        if !embedder.hasAvailableAssets {
            try await embedder.requestAssets()
        }
        try embedder.load()
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let embedder = NLContextualEmbedding(language: language) else {
            throw EngineError.noEmbedderForLanguage(language.rawValue)
        }
        try embedder.load()   // idempotent; cheap if already loaded

        return try texts.map { text in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [Float](repeating: 0, count: dimension) }

            let result = try embedder.embeddingResult(for: trimmed, language: language)
            var sum = [Float](repeating: 0, count: dimension)
            var count = 0
            result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
                for i in 0..<min(dimension, vector.count) { sum[i] += Float(vector[i]) }
                count += 1
                return true
            }
            guard count > 0 else { return sum }
            let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
            return norm > 0 ? sum.map { $0 / norm } : sum.map { $0 / Float(count) }
        }
    }
}
#endif
