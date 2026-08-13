import Foundation

/// Memory guardrails (PRD §9.6). On device this wraps `os_proc_available_memory()`; on macOS (the
/// harness) it reports host free memory so budgets can be exercised. The orchestrator checks the
/// budget before each stage and follows the **degrade-don't-die** rule: under pressure it drops the
/// LLM pass, never the audio.
public struct MemoryGuard: Sendable {
    /// Bytes below which we refuse to load another large model and degrade instead.
    public let floorBytes: Int

    public init(floorBytes: Int = 350 * 1_000_000) {   // ~350MB headroom default
        self.floorBytes = floorBytes
    }

    /// Best-effort available memory for this process, in bytes.
    public func availableBytes() -> Int {
        #if os(iOS)
        return Int(os_proc_available_memory())
        #else
        // macOS harness: approximate with host free + inactive pages.
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return Int.max }   // don't false-trip the guard on error
        let pageSize = Int(vm_kernel_page_size)
        return (Int(stats.free_count) + Int(stats.inactive_count)) * pageSize
        #endif
    }

    public enum Decision: Sendable, Equatable {
        case proceed
        case degrade(reason: String)   // skip this AI stage, keep playback/audio alive
    }

    /// Decide whether a stage needing `requiredBytes` may run.
    public func decision(forStageNeeding requiredBytes: Int) -> Decision {
        let available = availableBytes()
        if available - requiredBytes < floorBytes {
            return .degrade(reason: "available \(available / 1_000_000)MB - need \(requiredBytes / 1_000_000)MB would breach \(floorBytes / 1_000_000)MB floor")
        }
        return .proceed
    }
}
