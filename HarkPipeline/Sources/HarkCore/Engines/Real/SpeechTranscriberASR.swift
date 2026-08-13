#if canImport(Speech) && canImport(AVFAudio)
import Foundation
import Speech
import AVFAudio
import CoreMedia

/// ASR adapter for Apple's **SpeechTranscriber** (Speech framework, macOS/iOS 26) — the default
/// zero-download ASR candidate in the PRD §9.3 bake-off. Confirmed working: real transcription with
/// word-level `CMTimeRange` attributes via a probe on this machine (locale `en-US` installed).
///
/// Segmentation: each finalized `SpeechTranscriber.Result` becomes one `TranscriptSegment` — the API
/// finalizes at natural phrase/clause boundaries already, so no extra sentence-splitting is needed.
@available(macOS 26.0, iOS 26.0, *)
public struct SpeechTranscriberASR: SpeechToTextEngine {
    public let identifier: String
    public let approxResidentBytes: Int
    public let locale: Locale
    /// Fraction of the audio file transcribed so far (0…1), reported as each segment finalizes.
    /// Called from the collector task's context — hop to your own actor before touching state.
    public let onProgress: (@Sendable (Double) -> Void)?

    public init(identifier: String = "speechtranscriber-en-US", locale: Locale = Locale(identifier: "en-US"),
                approxResidentBytes: Int = 200 * 1_000_000,
                onProgress: (@Sendable (Double) -> Void)? = nil) {
        self.identifier = identifier
        self.locale = locale
        self.approxResidentBytes = approxResidentBytes
        self.onProgress = onProgress
    }

    public enum EngineError: Error, CustomStringConvertible {
        case localeAssetUnavailable(String)
        public var description: String {
            switch self { case .localeAssetUnavailable(let r): return "SpeechTranscriber locale asset unavailable: \(r)" }
        }
    }

    /// Ensures the locale's on-device model is installed, downloading it if needed (this is the
    /// codepath a real device takes on first use — PRD §9.3 model distribution applies to Speech's
    /// own AssetInventory just as it does to our bundled models).
    public func load() async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
    }

    public func transcribe(audioURL: URL) async throws -> Transcript {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let totalSeconds = audioFile.processingFormat.sampleRate > 0
            ? Double(audioFile.length) / audioFile.processingFormat.sampleRate : 0
        let onProgress = self.onProgress

        let collector = Task<[TranscriptSegment], Error> {
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                let text = String(result.text.characters)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let startMs = Int(CMTimeGetSeconds(result.range.start) * 1000)
                let endMs = Int(CMTimeGetSeconds(result.range.end) * 1000)
                segments.append(TranscriptSegment(text: text.trimmingCharacters(in: .whitespaces),
                                                  startMs: startMs, endMs: max(startMs, endMs)))
                if let onProgress, totalSeconds > 0 {
                    onProgress(min(1, Double(endMs) / 1000 / totalSeconds))
                }
            }
            return segments
        }

        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        let segments = try await collector.value

        return Transcript(episodeId: "", source: .asr, format: "asr",
                          modelVersion: identifier, segments: segments)
    }
}
#endif
