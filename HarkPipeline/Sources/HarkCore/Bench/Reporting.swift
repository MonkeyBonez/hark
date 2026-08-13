import Foundation

/// Renders a BakeoffReport as the human-readable model-decision-record table + machine JSON.
public enum Reporting {

    public static func table(_ report: BakeoffReport) -> String {
        var out = ""
        out += "── Bake-off: \(report.engineSetLabel) ──\n"
        out += "episodes: \(report.runs.count)\n"
        out += pad("median end-to-end RTF", 26) + fmt(report.medianEndToEndRTF, "x") + "\n"
        out += pad("median WER", 26) + fmt(report.medianWER.map { $0 * 100 }, "%") + "\n"
        out += pad("median ad-F1", 26) + fmt(report.medianAdF1) + "\n"
        out += pad("peak resident", 26) + "\(report.peakResidentBytes / 1_000_000) MB\n"
        out += "\nper-episode:\n"
        out += pad("id", 16) + pad("audio", 9) + pad("wall", 9) + pad("RTF", 8) + pad("ad%", 7) + "stages\n"
        for r in report.runs {
            out += pad(String(r.episodeId.prefix(15)), 16)
            out += pad(String(format: "%.0fs", r.audioSeconds), 9)
            out += pad(String(format: "%.2fs", r.totalWallClockSeconds), 9)
            out += pad(fmt(r.endToEndRealTimeFactor, "x"), 8)
            out += pad(fmt(r.quality.adFractionDetected.map { $0 * 100 }, "%"), 7)
            out += r.stages.map { "\($0.stage)\($0.degraded ? "!" : "")" }.joined(separator: ",")
            out += "\n"
        }
        return out
    }

    public static func json(_ report: BakeoffReport) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(report)
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count)
    }
    private static func fmt(_ v: Double?, _ suffix: String = "") -> String {
        guard let v = v else { return "—" }
        return String(format: "%.2f%@", v, suffix)
    }
}
