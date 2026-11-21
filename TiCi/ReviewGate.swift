import Foundation
import StoreKit
import UIKit

enum ReviewGate {
    static func registerLaunch(defaults: UserDefaults) {
        if defaults.object(forKey: "installedAt") == nil { defaults.set(Date(), forKey: "installedAt") }
        defaults.set(defaults.integer(forKey: "launches") + 1, forKey: "launches")
    }
    static func recordSavedVideo(count: Int, defaults: UserDefaults, now: Date = Date()) -> Bool {
        let installed = defaults.object(forKey: "installedAt") as? Date ?? now
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return count >= 3 && defaults.integer(forKey: "launches") >= 5 && now.timeIntervalSince(installed) >= 3 * 86400 && defaults.string(forKey: "reviewedVersion") != version
    }
    @MainActor static func request(in scene: UIWindowScene, defaults: UserDefaults) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        defaults.set(version, forKey: "reviewedVersion")
        SKStoreReviewController.requestReview(in: scene)
    }
}
