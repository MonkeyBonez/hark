import XCTest

final class MomentSearchUITests: XCTestCase {
    func testSearchOpensRealPlayerAtTranscriptAndSnipTimes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HARK_SEARCH_FIXTURE"] = "1"
        app.launch()
        openFind(in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)

        setQuery("notawordfixture", in: field)
        XCTAssertTrue(app.staticTexts["No moments found"].waitForExistence(timeout: 15), app.debugDescription)
        record("01-no-match", app)

        setQuery("!!!", in: field)
        XCTAssertTrue(app.staticTexts["Enter words or numbers"].waitForExistence(timeout: 15), app.debugDescription)
        record("02-invalid-query", app)

        setQuery("marigold", in: field)
        let missing = app.buttons["search.transcript.search-fixture-missing"]
        XCTAssertTrue(missing.waitForExistence(timeout: 15), app.debugDescription)
        missing.tap()
        let unavailable = app.alerts["Audio unavailable"]
        XCTAssertTrue(unavailable.waitForExistence(timeout: 15), app.debugDescription)
        record("03-audio-unavailable", app)
        unavailable.buttons["OK"].tap()

        setQuery("violet", in: field)
        let line = app.buttons["search.transcript.search-fixture-lantern"]
        let snip = app.buttons["search.snip.search-fixture-snip"]
        XCTAssertTrue(line.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(snip.waitForExistence(timeout: 15), app.debugDescription)
        record("04-search-results", app)
        line.tap()
        pauseAndCheckPosition(in: app, from: 42, through: 45)
        XCTAssertTrue(app.staticTexts["Synthetic Search Episode"].exists, app.debugDescription)
        record("05-transcript-player", app)

        app.buttons["player.close"].tap()
        XCTAssertTrue(snip.waitForExistence(timeout: 10), app.debugDescription)
        snip.tap()
        pauseAndCheckPosition(in: app, from: 47, through: 50)
        XCTAssertTrue(app.staticTexts["player.selectedSnip"].label.contains("Lantern by the harbor"),
                      app.debugDescription)
        record("06-snip-player", app)

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "HARK_SEARCH_FIXTURE")
        app.launch()
        openFind(in: app)
        let reopenedField = app.searchFields.firstMatch
        XCTAssertTrue(reopenedField.waitForExistence(timeout: 15), app.debugDescription)
        setQuery("violet", in: reopenedField)
        XCTAssertTrue(app.buttons["search.transcript.search-fixture-lantern"].waitForExistence(timeout: 15),
                      app.debugDescription)
        XCTAssertTrue(app.buttons["search.snip.search-fixture-snip"].exists, app.debugDescription)
        record("07-reopened-results", app)
        print("Synthetic search accessibility tree after relaunch:\n\(app.debugDescription)")
    }

    private func openFind(in app: XCUIApplication) {
        let tab = app.tabBars.buttons["Find"]
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
    }

    private func setQuery(_ text: String, in field: XCUIElement) {
        field.tap()
        if let old = field.value as? String, old != "Search transcripts and snips", !old.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(text)
    }

    private func pauseAndCheckPosition(in app: XCUIApplication, from lower: Int, through upper: Int) {
        let button = app.buttons["player.playPause"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), app.debugDescription)
        if button.label == "Pause" { button.tap() }
        let elapsed = app.staticTexts["player.elapsedTime"]
        XCTAssertTrue(elapsed.waitForExistence(timeout: 10), app.debugDescription)
        let components = elapsed.label.split(separator: ":").compactMap { Int($0) }
        let seconds = components.reduce(0) { $0 * 60 + $1 }
        print("Synthetic fixture real player clock: \(elapsed.label), value: \(elapsed.value ?? "not exposed")")
        XCTAssertTrue((lower...upper).contains(seconds), "Actual player clock: \(elapsed.label)\n\(app.debugDescription)")
    }

    private func record(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
