import Foundation

/// Per-stage measurements — the raw material of the model-decision-record (PRD §10, P0 exit).
public struct StageMetric: Sendable, Codable, Equatable {
    public var stage: String
    public var engineId: String
    public var wallClockSeconds: Double
    /// Real-time factor = audioSeconds / wallClockSeconds. Higher is faster. Nil for non-audio stages.
    public var realTimeFactor: Double?
    public var peakResidentBytes: Int
    public var degraded: Bool          // did the memory guard force a skip?
    public var note: String?

    public init(stage: String, engineId: String, wallClockSeconds: Double, realTimeFactor: Double? = nil,
                peakResidentBytes: Int = 0, degraded: Bool = false, note: String? = nil) {
        self.stage = stage; self.engineId = engineId; self.wallClockSeconds = wallClockSeconds
        self.realTimeFactor = realTimeFactor; self.peakResidentBytes = peakResidentBytes
        self.degraded = degraded; self.note = note
    }
}

/// Accuracy scores for one episode (WER for ASR, F1/IoU for ads — see Scoring).
public struct QualityScore: Sendable, Codable, Equatable {
    public var werPercent: Double?         // ASR word error rate, if a reference transcript exists
    public var adPrecision: Double?
    public var adRecall: Double?
    public var adF1: Double?
    public var adFractionDetected: Double? // share of episode marked as ad
    public init(werPercent: Double? = nil, adPrecision: Double? = nil, adRecall: Double? = nil,
                adF1: Double? = nil, adFractionDetected: Double? = nil) {
        self.werPercent = werPercent; self.adPrecision = adPrecision; self.adRecall = adRecall
        self.adF1 = adF1; self.adFractionDetected = adFractionDetected
    }
}

/// One episode run through the whole pipeline with one engine set.
public struct EpisodeRunRecord: Sendable, Codable, Equatable {
    public var episodeId: String
    public var audioSeconds: Double
    public var stages: [StageMetric]
    public var quality: QualityScore
    public var digest: EpisodeDigest?
    public var peakResidentBytesOverall: Int
    public var thermalNote: String?        // filled by the device-twin, not the mac harness

    public init(episodeId: String, audioSeconds: Double, stages: [StageMetric], quality: QualityScore,
                digest: EpisodeDigest? = nil, peakResidentBytesOverall: Int = 0, thermalNote: String? = nil) {
        self.episodeId = episodeId; self.audioSeconds = audioSeconds; self.stages = stages
        self.quality = quality; self.digest = digest
        self.peakResidentBytesOverall = peakResidentBytesOverall; self.thermalNote = thermalNote
    }

    public var totalWallClockSeconds: Double { stages.reduce(0) { $0 + $1.wallClockSeconds } }
    public var endToEndRealTimeFactor: Double? {
        totalWallClockSeconds > 0 ? audioSeconds / totalWallClockSeconds : nil
    }
}

/// The full bake-off output for one engine-set across the eval corpus.
public struct BakeoffReport: Sendable, Codable {
    public var engineSetLabel: String
    public var runs: [EpisodeRunRecord]
    public init(engineSetLabel: String, runs: [EpisodeRunRecord]) {
        self.engineSetLabel = engineSetLabel; self.runs = runs
    }

    public var medianEndToEndRTF: Double? {
        let vals = runs.compactMap(\.endToEndRealTimeFactor).sorted()
        guard !vals.isEmpty else { return nil }
        return vals[vals.count / 2]
    }
    public var medianWER: Double? {
        let vals = runs.compactMap(\.quality.werPercent).sorted()
        guard !vals.isEmpty else { return nil }
        return vals[vals.count / 2]
    }
    public var medianAdF1: Double? {
        let vals = runs.compactMap(\.quality.adF1).sorted()
        guard !vals.isEmpty else { return nil }
        return vals[vals.count / 2]
    }
    public var peakResidentBytes: Int { runs.map(\.peakResidentBytesOverall).max() ?? 0 }
}

/// Tiny stopwatch used by the orchestrator to time each stage.
public struct Stopwatch: Sendable {
    private let start: ContinuousClock.Instant
    public init() { start = ContinuousClock.now }
    public func seconds() -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
