import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .allButUpsideDown
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
    static func lock(_ orientation: UIInterfaceOrientation?) {
        switch orientation {
        case .portrait: orientationMask = .portrait
        case .landscapeLeft: orientationMask = .landscapeLeft
        case .landscapeRight: orientationMask = .landscapeRight
        default: orientationMask = .allButUpsideDown
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.forEach { $0.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations() }
        }
    }
}

enum Demo {
    static func has(_ flag: String) -> Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains(flag)
        #else
        return false
        #endif
    }
    static var enabled: Bool {
        ["-demo", "-ui-testing", "-prompter", "-camera", "-settings", "-paywall", "-pending", "-milestone", "-pro", "-import-code", "-savesheet", "-trialend", "-trial2", "-voice"].contains(where: has)
    }
    static func argument(_ flag: String) -> String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: flag), args.indices.contains(index + 1) { return args[index + 1] }
        #endif
        return nil
    }
}

@main
@MainActor
struct TiCiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var scripts: ScriptStore
    @StateObject private var settings: SettingsStore
    @StateObject private var purchases: PurchaseStore
    @StateObject private var videos: VideoSaver

    init() {
        let defaults = Demo.enabled ? UserDefaults(suiteName: "TiCi.demo")! : .standard
        if Demo.has("-reset") || Demo.has("-demo") { defaults.removePersistentDomain(forName: "TiCi.demo") }
        let demoDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DemoScripts")
        if Demo.enabled, Demo.has("-reset") || Demo.has("-demo") { try? FileManager.default.removeItem(at: demoDirectory) }
        let store = ScriptStore(directory: Demo.enabled ? demoDirectory : nil)
        if Demo.has("-demo"), store.scripts.count < 4 {
            for script in [Script(title: L("开场，让表达更自然"), body: L("演示开场正文")),
                           Script(title: L("本周的三个想法"), body: L("演示想法正文")),
                           Script(title: L("长稿练习"), body: String(repeating: L("演示长稿正文") + "\n\n", count: 1200))] { store.save(script) }
        }
        _scripts = StateObject(wrappedValue: store)
        _settings = StateObject(wrappedValue: SettingsStore(defaults: defaults))
        let purchaseStore = PurchaseStore(defaults: defaults)
        let videoSaver = VideoSaver(demo: Demo.enabled)
        videoSaver.onRecorded = { [weak purchaseStore] id, seconds, voice, uninterrupted, trialEligible in
            purchaseStore?.settleRecording(id: id, seconds: seconds, voice: voice, uninterrupted: uninterrupted, trialEligible: trialEligible)
        }
        videoSaver.refreshPending()
        Task {
            await VideoSaver.cleanExpiredCaches()
            await videoSaver.settleRecoveredRecordings()
        }
        _purchases = StateObject(wrappedValue: purchaseStore)
        _videos = StateObject(wrappedValue: videoSaver)
        ReviewGate.registerLaunch(defaults: defaults)
    }

    var body: some Scene {
        WindowGroup {
            ScriptListView()
                .environmentObject(scripts).environmentObject(settings)
                .environmentObject(purchases).environmentObject(videos)
                .tint(Design.amber)
        }
    }
}
