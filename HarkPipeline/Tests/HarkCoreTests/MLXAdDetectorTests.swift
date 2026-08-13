import XCTest
@testable import HarkCore

// The MLX verdict parser is the fail-open gate for the shipping ad detector (D38): it decides
// whether a candidate block survives verification. These exercise the parse without a model.
#if canImport(MLXLLM)
final class MLXAdDetectorTests: XCTestCase {

    func testParseVerdictAd() {
        XCTAssertEqual(MLXAdDetector.parseVerdict("VERDICT: ad"), true)
        XCTAssertEqual(MLXAdDetector.parseVerdict("verdict: AD"), true)
        XCTAssertEqual(MLXAdDetector.parseVerdict("Here is my answer.\nVERDICT: ad"), true)
    }

    func testParseVerdictContent() {
        XCTAssertEqual(MLXAdDetector.parseVerdict("VERDICT: content"), false)
        XCTAssertEqual(MLXAdDetector.parseVerdict("VERDICT: Content"), false)
    }

    func testParseVerdictFailsOpenOnGarbage() {
        // Unparseable → nil → caller KEEPS the block (verify must never silently cut recall).
        XCTAssertNil(MLXAdDetector.parseVerdict(""))
        XCTAssertNil(MLXAdDetector.parseVerdict("I'm not sure about this one."))
        XCTAssertNil(MLXAdDetector.parseVerdict("VERDICT: maybe"))
    }

    func testParseVerdictIgnoresAdSubstringOutsideVerdictLine() {
        // A company name containing "ad" echoed in the block must not flip a content verdict.
        let reply = "The block mentions Adobe and Adidas.\nVERDICT: content"
        XCTAssertEqual(MLXAdDetector.parseVerdict(reply), false)
    }
}
#endif
