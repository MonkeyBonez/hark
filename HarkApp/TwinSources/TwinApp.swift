import SwiftUI
import AVFoundation
import HarkCore

/// Device twin (docs/device-twin-spec.md): a dynamometer, not a product. Runs the SAME
/// PipelineOrchestrator + real engines HarkCore ships, on a bundled or picked episode, and reports
/// per-stage RTF / peak RSS / thermal — the numbers the Mac harness cannot measure. Never shipped.
@main
struct TwinApp: App {
    var body: some Scene {
        WindowGroup { TwinView() }
    }
}

struct StageReading: Identifiable {
    let id = UUID()
    var stage: String
    var wallClockSeconds: Double
    var realTimeFactor: Double?
    var peakRSSBytes: Int
    var thermal: String
    var note: String?
}

@MainActor
final class TwinRunner: ObservableObject {
    @Published var readings: [StageReading] = []
    @Published var running = false
    @Published var status = "Pick an audio file, then Run."
    @Published var batteryDelta: Float?
    @Published var reportJSON: String?

    private let sampler = RSSSampler()

    func run(audioURL: URL) async {
        running = true
        readings = []
        defer { running = false }

        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryBefore = UIDevice.current.batteryLevel

        do {
            let secured = audioURL.startAccessingSecurityScopedResource()
            defer { if secured { audioURL.stopAccessingSecurityScopedResource() } }

            let audioFile = try AVAudioFile(forReading: audioURL)
            let audioSeconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            status = String(format: "Running pipeline on %.0fs of audio…", audioSeconds)

            // Measure the SHIPPING engine set (D38): the bundled MLX model for digest + ads,
            // sharing one resident model. The twin has no bundled weights (it's excluded from the
            // Models resource), so MLXModelStore.resolve downloads them on first run — that's the
            // intended twin behavior. Numbers here reflect what the app actually runs.
            let intelligence = MLXIntelligence(modelId: "mlx-community/Qwen3-1.7B-4bit",
                                               approxResidentBytes: 1_300 * 1_000_000)
            let engines = EngineSet(label: "device-twin",
                                    asr: SpeechTranscriberASR(),
                                    diarizer: nil,
                                    embedder: try NLContextualEmbeddingEngine(),
                                    intelligence: intelligence,
                                    adDetector: MLXAdDetector(backing: intelligence))

            sampler.start()
            let orchestrator = PipelineOrchestrator(engines: engines)
            let result = try await orchestrator.process(episodeId: "twin", audioURL: audioURL,
                                                        audioSeconds: audioSeconds)
            let overallPeak = sampler.stop()

            readings = result.record.stages.map { s in
                StageReading(stage: s.stage,
                             wallClockSeconds: s.wallClockSeconds,
                             realTimeFactor: s.realTimeFactor,
                             peakRSSBytes: overallPeak,   // per-run peak; per-stage split needs stage hooks
                             thermal: Self.thermalLabel(),
                             note: s.note)
            }

            let batteryAfter = UIDevice.current.batteryLevel
            if batteryBefore >= 0, batteryAfter >= 0 { batteryDelta = batteryBefore - batteryAfter }

            var record = result.record
            record.peakResidentBytesOverall = overallPeak
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            reportJSON = String(data: (try? enc.encode(record)) ?? Data(), encoding: .utf8)
            status = "Done. Peak RSS \(overallPeak / 1_000_000) MB, thermal \(Self.thermalLabel())."
        } catch {
            status = "Failed: \(error)"
        }
    }

    static func thermalLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Samples phys_footprint (the jetsam-relevant number) ~4x/s on a background task.
final class RSSSampler: @unchecked Sendable {
    private var peak = 0
    private var task: Task<Void, Never>?

    func start() {
        peak = 0
        task = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                if let self { self.peak = max(self.peak, Self.currentFootprint()) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() -> Int {
        task?.cancel()
        task = nil
        return max(peak, Self.currentFootprint())
    }

    static func currentFootprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

struct TwinView: View {
    @StateObject private var runner = TwinRunner()
    @State private var pickedURL: URL?
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Pick audio file") { showPicker = true }
                    if let url = pickedURL {
                        Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        guard let url = pickedURL else { return }
                        Task { await runner.run(audioURL: url) }
                    } label: {
                        if runner.running { ProgressView() } else { Text("Run pipeline") }
                    }
                    .disabled(pickedURL == nil || runner.running)
                    Text(runner.status).font(.caption).foregroundStyle(.secondary)
                }

                if !runner.readings.isEmpty {
                    Section("Stages") {
                        ForEach(runner.readings) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(r.stage).font(.subheadline.weight(.medium))
                                    Spacer()
                                    if let rtf = r.realTimeFactor {
                                        Text(String(format: "%.1fx RT", rtf)).font(.caption.monospacedDigit())
                                    }
                                }
                                Text(String(format: "%.1fs · peak %d MB · %@",
                                            r.wallClockSeconds, r.peakRSSBytes / 1_000_000, r.thermal))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let note = r.note {
                                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        if let delta = runner.batteryDelta {
                            LabeledContent("Battery used", value: String(format: "%.0f%%", delta * 100))
                        }
                    }
                }

                if let json = runner.reportJSON {
                    Section {
                        ShareLink(item: json) { Label("Share run record JSON", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .navigationTitle("HarkTwin")
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result { pickedURL = url }
            }
        }
    }
}
