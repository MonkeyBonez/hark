import XCTest

final class MomentSearchUITests: XCTestCase {
    func testDelayedOpenDoesNotOutliveFind() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HARK_SEARCH_FIXTURE"] = "1"
        app.launchEnvironment["HARK_SEARCH_DELAY_MS"] = "10000"
        app.launch()
        openFind(in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)
        setQuery("violet", in: field)
        let line = app.buttons["search.transcript.search-fixture-lantern"]
        XCTAssertTrue(line.waitForExistence(timeout: 15), app.debugDescription)
        let submit = app.keyboards.buttons["Search"]
        if submit.exists { submit.tap() }
        line.tap()
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(home.isHittable, app.debugDescription)
        home.tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5), app.debugDescription)
        record("home-before-delayed-response", app)
        let latePlayer = app.buttons["player.playPause"].waitForExistence(timeout: 15)
        if latePlayer { record("baseline-late-player", app) }
        XCTAssertFalse(latePlayer, "A delayed search opened the player after leaving Find.\n\(app.debugDescription)")
        XCTAssertFalse(app.buttons["player.mini.playPause"].exists,
                       "A delayed search started audio after leaving Find.\n\(app.debugDescription)")
        record("navigation-after-delay", app)
    }

    func testCancelAndQueryReplacementIgnoreOlderResponses() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HARK_SEARCH_FIXTURE"] = "1"
        app.launchEnvironment["HARK_SEARCH_DELAY_MS"] = "15000"
        app.launch()
        openFind(in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)
        setQuery("violet", in: field)
        let line = app.buttons["search.transcript.search-fixture-lantern"]
        XCTAssertTrue(line.waitForExistence(timeout: 15), app.debugDescription)
        let submit = app.keyboards.buttons["Search"]
        if submit.exists { submit.tap() }

        line.tap()
        let opening = app.staticTexts["Opening audio"]
        let cancel = app.buttons["search.cancelOpening"]
        XCTAssertTrue(opening.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(cancel.exists, app.debugDescription)
        let firstObserved = Date()
        record("opening-with-cancel", app)
        cancel.tap()
        XCTAssertFalse(opening.exists, app.debugDescription)
        record("cancelled-before-response", app)

        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(line.waitForExistence(timeout: 5), app.debugDescription)
        line.tap()
        XCTAssertTrue(opening.waitForExistence(timeout: 10), app.debugDescription)
        let secondObserved = Date()
        wait(until: firstObserved.addingTimeInterval(15.5))
        XCTAssertLessThan(Date().timeIntervalSince(secondObserved), 14,
                          "The second delayed response arrived before the race could be checked.")
        XCTAssertTrue(opening.exists, "The older completion cleared the newer opening.\n\(app.debugDescription)")
        XCTAssertTrue(cancel.exists, app.debugDescription)
        XCTAssertFalse(app.buttons["player.playPause"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["player.mini.playPause"].exists, app.debugDescription)
        record("newer-opening-after-old-response", app)

        setQuery("copper", in: field)
        XCTAssertTrue(app.buttons["search.transcript.search-fixture-intro"].waitForExistence(timeout: 15),
                      app.debugDescription)
        XCTAssertFalse(opening.exists, "Changing the query must cancel its pending opening.")
        wait(until: secondObserved.addingTimeInterval(16))
        XCTAssertFalse(app.buttons["player.playPause"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["player.mini.playPause"].exists, app.debugDescription)
        record("query-replaced-after-response", app)
    }

    func testCancelDuringSeekRestoresEarlierPlayback() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["HARK_SEARCH_FIXTURE"] = "1"
        app.launchEnvironment["HARK_SEARCH_DELAY_MS"] = "10000"
        app.launchEnvironment["HARK_SEARCH_DELAY_STAGE"] = "seek"
        app.launch()
        openFind(in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), app.debugDescription)
        setQuery("violet", in: field)
        let line = app.buttons["search.transcript.search-fixture-lantern"]
        XCTAssertTrue(line.waitForExistence(timeout: 15), app.debugDescription)
        let submit = app.keyboards.buttons["Search"]
        if submit.exists { submit.tap() }
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars["Home"].waitForExistence(timeout: 5), app.debugDescription)
        let episode = app.staticTexts["Synthetic Search Episode"]
        XCTAssertTrue(episode.waitForExistence(timeout: 10), app.debugDescription)
        episode.tap()
        let mini = app.buttons["player.mini.playPause"]
        XCTAssertTrue(mini.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(mini.label, "Pause mini player", app.debugDescription)
        let startingTime = try XCTUnwrap(playerSeconds(mini), app.debugDescription)

        openFind(in: app)
        XCTAssertTrue(line.waitForExistence(timeout: 10), app.debugDescription)
        line.tap()
        let opening = app.staticTexts["Opening audio"]
        XCTAssertTrue(opening.waitForExistence(timeout: 10), app.debugDescription)
        let pendingSeek = expectation(for: NSPredicate(format: "label == %@", "Play mini player"),
                                      evaluatedWith: mini)
        wait(for: [pendingSeek], timeout: 10)
        record("seek-pending-before-cancel", app)
        app.buttons["search.cancelOpening"].tap()
        XCTAssertFalse(opening.exists, app.debugDescription)
        XCTAssertEqual(mini.label, "Pause mini player", app.debugDescription)
        XCTAssertFalse(app.buttons["player.playPause"].exists, app.debugDescription)
        record("seek-cancel-restored-playback", app)
        Thread.sleep(forTimeInterval: 11)
        XCTAssertEqual(mini.label, "Pause mini player", app.debugDescription)
        let resumedTime = try XCTUnwrap(playerSeconds(mini), app.debugDescription)
        XCTAssertGreaterThan(resumedTime, startingTime + 5, "Previous audio did not continue after cancellation.")
        print("Previous synthetic audio advanced from \(startingTime)s to \(resumedTime)s after cancel.")
        XCTAssertFalse(app.buttons["player.playPause"].exists, app.debugDescription)
        XCTAssertFalse(app.alerts["Audio unavailable"].exists, app.debugDescription)
        record("seek-restored-after-late-response", app)
    }

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

    private func wait(until deadline: Date) {
        let remaining = deadline.timeIntervalSinceNow
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
    }

    private func playerSeconds(_ element: XCUIElement) -> Double? {
        guard let value = element.value as? String, let seconds = value.split(separator: " ").first else {
            return nil
        }
        return Double(seconds)
    }

    private func record(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
