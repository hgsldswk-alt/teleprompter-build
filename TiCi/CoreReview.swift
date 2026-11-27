import SwiftUI

@MainActor
final class CoreReview: ObservableObject {
    static let shared = CoreReview()

    @Published private(set) var pending = false
    private let defaults = UserDefaults.standard
    private let progressKey = "review.coreProgress"
    private let versionKey = "reviewedVersion"
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"

    var canRequest: Bool {
        !(Demo.enabled) && defaults.string(forKey: versionKey) != version
    }

    func record(at date: Date = .now) {
        guard !(Demo.enabled) else { return }
        var progress = defaults.data(forKey: progressKey)
            .flatMap { try? JSONDecoder().decode(CoreReviewProgress.self, from: $0) } ?? CoreReviewProgress()
        progress.record(at: date)
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: progressKey)
        if progress.isEligible && canRequest { pending = true }
    }

    @discardableResult
    func attempt(ifEligible: () -> Bool = { true }, _ request: () -> Void) -> Bool {
        attemptIfPerformed(ifEligible: ifEligible) {
            request()
            return true
        }
    }

    @discardableResult
    func attemptIfPerformed(ifEligible: () -> Bool = { true }, _ request: () -> Bool) -> Bool {
        guard canRequest, UIApplication.shared.applicationState == .active, ifEligible(), request() else { return false }
        defaults.set(version, forKey: versionKey)
        pending = false
        return true
    }
}

@MainActor
private struct CoreReviewModifier: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var review = CoreReview.shared
    let eligible: Bool
    let request: () -> Bool

    private var ready: Bool { eligible && phase == .active && review.pending }

    func body(content: Content) -> some View {
        content.task(id: ready) {
            guard ready else { return }
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard !Task.isCancelled, ready else { return }
            review.attemptIfPerformed(request)
        }
    }
}

extension View {
    @MainActor
    func reviewAfterCoreAction(when eligible: Bool, alreadyRequested: Bool = false, _ request: @escaping () -> Bool) -> some View {
        modifier(CoreReviewModifier(eligible: eligible && !alreadyRequested, request: request))
    }
}
