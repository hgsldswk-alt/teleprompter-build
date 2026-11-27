import XCTest

final class FlowUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }

    private func launch(_ extra: [String] = [], reset: Bool = true) {
        app.launchArguments = ["-ui-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + (reset ? ["-reset"] : []) + extra
        app.launch()
        let openingElement: String
        if extra.contains("-trialend") { openingElement = "continueFree" }
        else if extra.contains("-savesheet") { openingElement = "closeSaveSheet" }
        else if extra.contains("-camera") || extra.contains("-trial2") { openingElement = "closePrompter" }
        else { openingElement = "newScript" }
        XCTAssertTrue(app.buttons[openingElement].waitForExistence(timeout: 15))
    }
    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 8), identifier)
        button.tap()
    }
    private func shot(_ name: String) throws {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["TEST_RUNNER_SHOTS_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: url.appendingPathComponent(name + ".png"))
        }
    }
    private func type(_ text: String, into element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<4 {
            element.tap()
            let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: element)
            if XCTWaiter.wait(for: [focused], timeout: 2) == .completed { break }
        }
        element.typeText(text)
    }
    private func firstScript() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "script-")).element(boundBy: 0)
    }

    func testCreatePromptAdjustMirrorDeleteUndoAndPaywall() throws {
        launch(["-paid-mode"])
        XCTAssertTrue(firstScript().waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "script-", "Try voice follow")).firstMatch.exists)
        try shot("01-first-launch")
        tap("newScript")
        let title = app.textFields["scriptTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        type("Camera practice", into: title)
        let body = app.textViews["scriptBody"]
        type("Hello camera. Take a breath and speak naturally.\nThis is the second paragraph.\nKeep a steady pace and pause when you need to.", into: body)
        try shot("02-editor")
        tap("saveScript")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "script-", "Camera practice")).firstMatch.waitForExistence(timeout: 5))
        let countAppears = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "23 words"), object: firstScript())
        XCTAssertEqual(XCTWaiter.wait(for: [countAppears], timeout: 8), .completed)
        try shot("03-created-script")
        firstScript().tap()
        XCTAssertTrue(app.buttons["startScroll"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.alerts.count, 0)
        tap("scroll-constant")
        tap("openAppearance")
        let size = app.sliders["fontSize"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        size.adjust(toNormalizedSliderPosition: 0.6)
        let mirror = app.switches["mirrorHorizontal"]
        for _ in 0..<4 where !mirror.isHittable { app.swipeUp() }
        XCTAssertTrue(mirror.isHittable)
        mirror.tap()
        let countdown = app.switches["countdownToggle"]
        if countdown.value as? String == "1" { countdown.tap() }
        try shot("04-appearance-mirror")
        tap("closeAppearance")
        tap("startScroll")
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Pause"), object: app.buttons["startScroll"])
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 8), .completed)
        try shot("05-constant-scrolling")
        tap("startScroll")
        tap("closePrompter")
        XCTAssertTrue(app.buttons["newScript"].waitForExistence(timeout: 5))
        firstScript().swipeLeft()
        tap("deleteScript")
        XCTAssertTrue(app.buttons["undoDelete"].waitForExistence(timeout: 5))
        try shot("06-deleted")
        tap("undoDelete")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "script-", "Camera practice")).firstMatch.waitForExistence(timeout: 5))
        try shot("07-undo")
        app.terminate()
        launch(["-paid-mode"], reset: false)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "script-", "Camera practice")).firstMatch.exists)
        tap("openSettings")
        tap("openPaywall")
        XCTAssertTrue(app.buttons["buyPro"].waitForExistence(timeout: 5))
        try shot("08-paywall")
        tap("closePaywall")
        tap("closeSettings")
    }

    func testFreeLaunchHidesPurchasesAndSelectsVoiceWithoutLock() throws {
        throw XCTSkip("Free-period build only; the shipping build is paid (Launch.freePeriod = false).")
        launch()
        tap("openSettings")
        XCTAssertTrue(app.buttons["closeSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["openPaywall"].exists)
        XCTAssertFalse(app.buttons["restorePurchase"].exists)
        XCTAssertFalse(app.buttons["lockedQuality"].exists)
        XCTAssertFalse(app.buttons["lockedRemote"].exists)
        XCTAssertFalse(app.staticTexts["valueCounterPaused"].exists)
        tap("closeSettings")
        firstScript().tap()
        tap("scroll-constant")
        tap("scroll-voice")
        let voice = app.buttons["scroll-voice"]
        XCTAssertEqual(voice.label, "Voice follow")
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: voice)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["buyPro"].exists)
        XCTAssertFalse(app.staticTexts["trialBadge"].exists)
        XCTAssertTrue(app.buttons["closePrompter"].exists)
        try shot("17-free-voice-follow")
    }

    func testInjectedScriptCodeImportAndPersistence() throws {
        launch(["-import-code", Self.importCode])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "script-", "Imported script")).firstMatch.waitForExistence(timeout: 5))
        try shot("09-imported-code")
        app.terminate()
        launch(reset: false)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "script-", "Imported script")).firstMatch.waitForExistence(timeout: 5))
        try shot("10-import-persisted")
    }

    func testCameraSimulatorGracefullyDegradesAndRemoteTest() throws {
        launch(["-demo", "-camera", "-pro"])
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["recordButton"].isEnabled)
        try shot("11-camera-placeholder")
        tap("closePrompter")
        tap("openSettings")
        tap("testRemote")
        XCTAssertTrue(app.staticTexts["lastRemoteKey"].waitForExistence(timeout: 5))
        try shot("12-remote-test")
        tap("closeRemoteTest")
    }

    func testStatisticsAndLockedVoicePaywall() throws {
        launch(["-paid-mode", "-trialend"])
        XCTAssertTrue(app.buttons["continueFree"].waitForExistence(timeout: 8))
        try shot("13-trial-ended")
        tap("continueFree")
        tap("scroll-voice")
        XCTAssertTrue(app.buttons["buyPro"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["valueCounter"].exists)
        XCTAssertTrue(app.staticTexts["valueCounterPaused"].exists)
        tap("closePaywall")
        XCTAssertTrue(app.buttons["scroll-constant"].exists)
        tap("closePrompter")
        tap("openSettings")
        XCTAssertTrue(app.staticTexts["valueCounter"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["valueCounter"].label.contains("2"))
        XCTAssertTrue(app.staticTexts["valueCounterPaused"].exists)
        try shot("14-settings-statistics")
        tap("closeSettings")
    }

    func testSaveSheetFreeExitAndTrialBadge() throws {
        launch(["-paid-mode", "-savesheet"])
        XCTAssertTrue(app.buttons["saveWatermarked"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["buyAndSave"].exists)
        XCTAssertTrue(app.images["savePreview"].waitForExistence(timeout: 5))
        try shot("15-save-sheet")
        tap("closeSaveSheet")
        XCTAssertTrue(app.buttons["closePrompter"].waitForExistence(timeout: 5))
        app.terminate()
        launch(["-paid-mode", "-trial2"])
        XCTAssertTrue(app.staticTexts["trialBadge"].waitForExistence(timeout: 5))
        try shot("16-trial-two-left")
    }

    private static let importCode = "#提词器稿件#eJw9yjEOwjAMBdCrfHmuKrFmY2RmZTGJEVHT2HLdoghxdyaY33vTQek0UdRoQokuq6mHFGzZqwVNdNcyKNEZ25P9D6i_-HBdwTi41YKsReZbv5rwgs6xO7c2wL1gETEM3R366jDOMtPnC9H-LF4#"
}
