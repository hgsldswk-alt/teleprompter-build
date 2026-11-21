import XCTest

final class ModelTests: XCTestCase {
    func testLaunchFreePeriodAndPaidOverrides() {
        XCTAssertFalse(Launch.freePeriod)
        XCTAssertFalse(Launch.isFree)
        XCTAssertTrue(Launch.isFree(arguments: [], freePeriod: true))
        XCTAssertTrue(Launch.isFree(arguments: ["-ui-testing", "-camera", "-settings"], freePeriod: true))
        for flag in ["-paid-mode", "-paywall", "-trialend", "-savesheet", "-trial2"] {
            XCTAssertFalse(Launch.isFree(arguments: ["TiCi", flag]))
        }
        XCTAssertFalse(Launch.isFree(arguments: [], freePeriod: false))
    }

    func testFreeFeaturesDoNotPersistAsPurchased() throws {
        let entitlement = Entitlement(trialTakesUsed: 3)
        XCTAssertTrue(entitlement.hasProFeatures(free: true))
        XCTAssertFalse(entitlement.isPro)
        let reloaded = try JSONDecoder().decode(Entitlement.self, from: JSONEncoder().encode(entitlement))
        XCTAssertFalse(reloaded.hasProFeatures(free: false))
        XCTAssertFalse(reloaded.isPro)
    }

    func testFreeRecordingKeepsAllTrialsAndCountsStatisticsOnce() throws {
        var ledger = TakeLedger(entitlement: Entitlement(), statistics: TakeStatistics())
        for index in 1...5 {
            let id = "free-\(index)"
            XCTAssertNil(ledger.settleRecording(id: id, seconds: 60, voice: true, uninterrupted: true, trialEligible: true, valid: true, free: true))
            ledger = try JSONDecoder().decode(TakeLedger.self, from: JSONEncoder().encode(ledger))
            XCTAssertNil(ledger.settleRecording(id: id, seconds: 60, voice: true, uninterrupted: true, trialEligible: true, valid: true, free: true))
        }
        XCTAssertEqual(ledger.entitlement.remainingTrialTakes, 3)
        XCTAssertTrue(ledger.trialNumbers.isEmpty)
        XCTAssertEqual(ledger.statistics.voiceTakes, 5)
        XCTAssertEqual(ledger.statistics.uninterruptedTakes, 5)
        XCTAssertEqual(ledger.statistics.cameraSeconds, 300)
        XCTAssertEqual(ledger.settleRecording(id: "first-paid", seconds: 60, voice: true, uninterrupted: true, trialEligible: true, valid: true, free: false), 1)
    }

    func testFreeRecordingWithExhaustedTrialsStillCountsValueAndReturnsNoNumber() {
        var ledger = TakeLedger(entitlement: Entitlement(trialTakesUsed: 3), statistics: TakeStatistics())
        XCTAssertNil(ledger.settleRecording(id: "free", seconds: 60, voice: true, uninterrupted: true, trialEligible: false, valid: true, free: true))
        XCTAssertEqual(ledger.statistics.uninterruptedTakes, 1)
        XCTAssertEqual(ledger.entitlement.trialTakesUsed, 3)
        ledger.trialNumbers["free"] = 2
        XCTAssertNil(ledger.settleRecording(id: "free", seconds: 60, voice: true, uninterrupted: true, trialEligible: true, valid: true, free: true))
    }

    func testFreePromptSessionDoesNotConsumeTrials() {
        var entitlement = Entitlement()
        entitlement.finishTake(free: true)
        XCTAssertNil(entitlement.finishPromptSession(continuousSeconds: 3600, free: true))
        XCTAssertEqual(entitlement.remainingTrialTakes, 3)
        XCTAssertEqual(entitlement.finishPromptSession(continuousSeconds: 60, free: false), 1)
    }

    func testRecordingTrialsSettleBeforeAnyAlbumSaveAndOnlyOncePerID() throws {
        var ledger = TakeLedger(entitlement: Entitlement(), statistics: TakeStatistics())
        for number in 1...3 {
            let id = "recording-\(number)"
            XCTAssertEqual(ledger.settleRecording(id: id, seconds: 10, voice: true, uninterrupted: true, trialEligible: true, valid: true, free: false), number)
            ledger = try JSONDecoder().decode(TakeLedger.self, from: JSONEncoder().encode(ledger))
            XCTAssertEqual(ledger.settleRecording(id: id, seconds: 10, voice: true, uninterrupted: true, trialEligible: true, valid: true, free: false), number)
            XCTAssertEqual(ledger.entitlement.trialTakesUsed, number)
        }
        XCTAssertNil(ledger.settleRecording(id: "recording-4", seconds: 10, voice: true, uninterrupted: true, trialEligible: true, valid: true, free: false))
        XCTAssertEqual(ledger.entitlement.remainingTrialTakes, 0)
        XCTAssertEqual(ledger.statistics.recordedIDs.count, 4)
        XCTAssertEqual(ledger.statistics.cameraSeconds, 40)
        XCTAssertEqual(ledger.statistics.uninterruptedTakes, 3)
    }

    func testInvalidRecordingAndProRecordingDoNotConsumeTrials() {
        var ledger = TakeLedger(entitlement: Entitlement(), statistics: TakeStatistics())
        XCTAssertNil(ledger.settleRecording(id: "failed-empty", seconds: 0, voice: false, uninterrupted: false, trialEligible: true, valid: false, free: false))
        XCTAssertTrue(ledger.statistics.recordedIDs.isEmpty)
        XCTAssertEqual(ledger.entitlement.trialTakesUsed, 0)
        ledger.entitlement.isPro = true
        XCTAssertNil(ledger.settleRecording(id: "paid", seconds: 60, voice: true, uninterrupted: true, trialEligible: true, valid: true, free: false))
        XCTAssertEqual(ledger.entitlement.trialTakesUsed, 0)
        XCTAssertEqual(ledger.statistics.uninterruptedTakes, 1)
    }

    func testOldLedgerReceiptsMigrateWithoutChargingAgain() throws {
        var statistics = TakeStatistics()
        statistics.record(id: "old", seconds: 20, voice: true, uninterrupted: true, enabled: true)
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TakeLedger(entitlement: Entitlement(trialTakesUsed: 1), statistics: statistics))) as? [String: Any])
        data.removeValue(forKey: "trialNumbers")
        var ledger = try JSONDecoder().decode(TakeLedger.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertNil(ledger.settleRecording(id: "old", seconds: 20, voice: true, uninterrupted: true, trialEligible: true, valid: true, free: false))
        XCTAssertEqual(ledger.entitlement.trialTakesUsed, 1)
        XCTAssertEqual(ledger.statistics.cameraSeconds, 20)
        XCTAssertEqual(ledger.settleRecording(id: "new", seconds: 20, voice: true, uninterrupted: true, trialEligible: true, valid: true, free: false), 2)
    }

    func testWordCountAndMixedDuration() {
        let script = Script(title: "", body: "你好世界，hello wonderful world!")
        XCTAssertEqual(script.wordCount, 7)
        XCTAssertEqual(script.estimatedSeconds(chineseRate: 60, englishRate: 60), 7)
        XCTAssertEqual(Script(title: "", body: "...\n").wordCount, 0)
        XCTAssertEqual(Script(title: "", body: "one two three").estimatedSeconds(englishRate: 120), 2)
    }
    func testLanguageDetectionAndOverride() {
        XCTAssertEqual(Script(title: "", body: "hello there").recognitionLanguage, "en-US")
        XCTAssertEqual(Script(title: "", body: "欢迎使用").recognitionLanguage, "zh-CN")
        XCTAssertEqual(Script(title: "", body: "歡迎使用").recognitionLanguage, "zh-TW")
        XCTAssertEqual(Script(title: "", body: "Hello", languageOverride: "zh-TW").recognitionLanguage, "zh-TW")
    }
    func testLegacyScriptMissingFields() throws {
        let script = try JSONDecoder().decode(Script.self, from: Data(#"{"title":"Old","body":"hello"}"#.utf8))
        XCTAssertEqual(script.title, "Old")
        XCTAssertEqual(script.readingOffset, 0)
        XCTAssertNil(script.languageOverride)
        XCTAssertEqual(script.createdAt, script.modifiedAt)
    }
    func testLegacyPositionClamped() throws {
        let script = try JSONDecoder().decode(Script.self, from: Data(#"{"body":"你好","readingOffset":99999}"#.utf8))
        XCTAssertEqual(script.readingOffset, 2)
    }
    func testSettingsRoundTripAndDefaults() throws {
        var settings = PromptSettings()
        settings.fontSize = 52
        settings.mirrorHorizontal = true
        settings.scrollMode = .manual
        let copy = try JSONDecoder().decode(PromptSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(settings, copy)
        XCTAssertEqual(try JSONDecoder().decode(PromptSettings.self, from: Data("{}".utf8)), PromptSettings())
    }
    func testSettingsClampMalformedLegacyValues() throws {
        let settings = try JSONDecoder().decode(PromptSettings.self, from: Data(#"{"fontSize":-10,"speed":900,"margin":9999}"#.utf8))
        XCTAssertEqual(settings.fontSize, 22)
        XCTAssertEqual(settings.speed, 2)
        XCTAssertEqual(settings.margin, 80)
    }
    func testThreeFullFeatureTakesAndExhaustion() {
        var entitlement = Entitlement()
        XCTAssertTrue(entitlement.hasProFeatures(free: false))
        entitlement.finishTake(free: false)
        XCTAssertEqual(entitlement.remainingTrialTakes, 2)
        entitlement.finishTake(free: false)
        XCTAssertTrue(entitlement.hasProFeatures(free: false))
        entitlement.finishTake(free: false)
        XCTAssertFalse(entitlement.hasProFeatures(free: false))
        entitlement.finishTake(free: false)
        XCTAssertEqual(entitlement.trialTakesUsed, 3)
        entitlement.isPro = true
        XCTAssertTrue(entitlement.hasProFeatures(free: false))
        entitlement.isPro = false
        XCTAssertFalse(entitlement.hasProFeatures(free: false))
    }

    func testContinuousPromptBoundaryAndProDoesNotConsumeTrials() {
        var entitlement = Entitlement()
        entitlement.finishPromptSession(continuousSeconds: 59.999, free: false)
        XCTAssertEqual(entitlement.trialTakesUsed, 0)
        entitlement.finishPromptSession(continuousSeconds: 60, free: false)
        XCTAssertEqual(entitlement.trialTakesUsed, 1)
        entitlement.finishPromptSession(continuousSeconds: 3600, free: false)
        XCTAssertEqual(entitlement.trialTakesUsed, 2)
        entitlement.isPro = true
        entitlement.finishTake(free: false)
        entitlement.finishPromptSession(continuousSeconds: 3600, free: false)
        XCTAssertEqual(entitlement.trialTakesUsed, 2)
        entitlement.isPro = false
        XCTAssertTrue(entitlement.hasProFeatures(free: false))
    }

    func testLegacyTrialMigrationAndBounds() throws {
        let decoder = JSONDecoder()
        for used in -1...5 {
            let legacy = try decoder.decode(Entitlement.self, from: Data("{\"usedVoiceTrials\":\(used)}".utf8))
            XCTAssertEqual(legacy.trialTakesUsed, min(3, max(0, used)))
        }
        let current = try decoder.decode(Entitlement.self, from: Data(#"{"trialTakesUsed":1,"usedVoiceTrials":3}"#.utf8))
        XCTAssertEqual(current.trialTakesUsed, 1)
        XCTAssertEqual(try decoder.decode(Entitlement.self, from: Data("{}".utf8)), Entitlement())
        XCTAssertEqual(try decoder.decode(Entitlement.self, from: JSONEncoder().encode(current)), current)
    }

    func testValueCounterDeduplicatesAndPauses() throws {
        var statistics = TakeStatistics()
        statistics.record(id: "first", seconds: 60, voice: true, uninterrupted: true, enabled: true)
        statistics.record(id: "first", seconds: 60, voice: true, uninterrupted: true, enabled: true)
        statistics.record(id: "paused", seconds: 60, voice: true, uninterrupted: true, enabled: false)
        statistics.record(id: "manual", seconds: 60, voice: false, uninterrupted: true, enabled: true)
        statistics.record(id: "dragged", seconds: 60, voice: true, uninterrupted: false, enabled: true)
        XCTAssertEqual(statistics.uninterruptedTakes, 1)
        XCTAssertEqual(statistics.voiceTakes, 3)
        XCTAssertEqual(statistics.cameraSeconds, 240)
        XCTAssertEqual(try JSONDecoder().decode(TakeStatistics.self, from: JSONEncoder().encode(statistics)), statistics)
    }

    func testLockedSettingsSurviveRoundTrip() throws {
        var settings = PromptSettings()
        settings.recordingQuality = "uhd60"
        settings.remoteEnabled = true
        let copy = try JSONDecoder().decode(PromptSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(copy.recordingQuality, "uhd60")
        XCTAssertTrue(copy.remoteEnabled)
        XCTAssertEqual(copy.speed, 1)
    }

    @MainActor
    func testStoreSaveDeleteUndoAndRelaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScriptStore(directory: directory)
        XCTAssertEqual(store.scripts.count, 1)
        let script = Script(title: "A", body: String(repeating: "长稿", count: 25_000))
        XCTAssertTrue(store.save(script))
        store.updatePosition(id: script.id, offset: 100)
        let reloaded = ScriptStore(directory: directory)
        XCTAssertEqual(reloaded.scripts.first(where: { $0.id == script.id })?.readingOffset, 100)
        reloaded.delete(script)
        let undone = ScriptStore(directory: directory)
        undone.recoverUndo()
        undone.restoreDeleted()
        XCTAssertEqual(undone.scripts.count, 2)
    }

    @MainActor
    func testEmptyLibraryDoesNotReseed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScriptStore(directory: directory)
        store.delete(try XCTUnwrap(store.scripts.first))
        XCTAssertTrue(ScriptStore(directory: directory).scripts.isEmpty)
    }

    @MainActor
    func testDamagedFilePreservedAndOtherFilesLoad() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ScriptStore(directory: directory, seed: false)
        let script = Script(title: "Good", body: "safe")
        store.save(script)
        let damaged = directory.appendingPathComponent("damaged.json")
        try Data("{".utf8).write(to: damaged)
        let reloaded = ScriptStore(directory: directory, seed: false)
        XCTAssertEqual(reloaded.scripts.map(\.id), [script.id])
        XCTAssertNotNil(reloaded.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: damaged.path))
    }

    @MainActor
    func testLegacyFileWithoutIDCanBeSavedDeletedAndRestored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("legacy.json")
        try Data(#"{"title":"Legacy","body":"hello"}"#.utf8).write(to: file)
        let store = ScriptStore(directory: directory, seed: false)
        let script = try XCTUnwrap(store.scripts.first)
        store.updatePosition(id: script.id, offset: 2)
        XCTAssertEqual(ScriptStore(directory: directory, seed: false).scripts.count, 1)
        XCTAssertEqual(ScriptStore(directory: directory, seed: false).scripts.first?.id, script.id)
        store.delete(script)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        store.restoreDeleted()
        XCTAssertEqual(ScriptStore(directory: directory, seed: false).scripts.count, 1)
    }

    func testSettingsPersistence() throws {
        let suite = "TiCi.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.value.mirrorVertical = true
        XCTAssertTrue(SettingsStore(defaults: defaults).value.mirrorVertical)
    }
}
