import Foundation
import StoreKit
import Combine
import Security

private enum TrialKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "com.hgsldswk.teleprompter") + ".trial",
         kSecAttrAccount as String: "takesUsed"]
    }

    static func read() -> Int? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let text = String(data: data, encoding: .utf8),
              let used = Int(text) else { return nil }
        return min(3, max(0, used))
    }

    static func write(_ used: Int) {
        let attributes: [String: Any] = [kSecValueData as String: Data(String(used).utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = attributes[kSecValueData as String]
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }
}

@MainActor
final class PurchaseStore: ObservableObject {
    @Published private(set) var entitlement: Entitlement
    @Published private(set) var statistics: TakeStatistics
    @Published var trialEndPending = false
    @Published private(set) var entitlementsLoaded = false
    var canPresentTrialEnd: Bool { !Launch.isFree && entitlementsLoaded && trialEndPending && !entitlement.hasProFeatures }
    @Published private(set) var product: Product?
    var priceText: String? { product?.displayPrice ?? (Demo.enabled ? L("¥30") : nil) }
    @Published private(set) var busy = false
    @Published var message: String?
    private let defaults: UserDefaults
    private var listener: Task<Void, Never>?
    private var trialNumbers: [String: Int] = [:]
    private let productID = Bundle.main.object(forInfoDictionaryKey: "TiCiProProductID") as? String ?? "com.hgsldswk.teleprompter.pro"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let ledger = defaults.data(forKey: "takeLedger").flatMap { try? JSONDecoder().decode(TakeLedger.self, from: $0) }
        let legacy = defaults.data(forKey: "entitlement").flatMap { try? JSONDecoder().decode(Entitlement.self, from: $0) }
        let stored = ledger?.entitlement ?? legacy
        let localUsed = [ledger?.entitlement.trialTakesUsed ?? 0, legacy?.trialTakesUsed ?? 0,
                         defaults.integer(forKey: "trialTakesUsed"), defaults.integer(forKey: "voiceTrials")].max() ?? 0
        let used = max(localUsed, Demo.enabled ? 0 : (TrialKeychain.read() ?? 0))
        var initial = Entitlement(isPro: stored?.isPro ?? false, trialTakesUsed: used)
        if Demo.enabled { initial.isPro = Demo.has("-pro") }
        let storedStatistics: TakeStatistics? = ledger?.statistics ?? defaults.data(forKey: "takeStatistics").flatMap { try? JSONDecoder().decode(TakeStatistics.self, from: $0) }
        entitlement = initial
        statistics = storedStatistics ?? TakeStatistics()
        trialNumbers = ledger?.trialNumbers ?? [:]
        if Demo.has("-trialend") || Demo.has("-savesheet") {
            entitlement = Entitlement(isPro: Demo.has("-pro"), trialTakesUsed: 3)
            statistics.voiceTakes = 3
            statistics.cameraSeconds = 720
            statistics.uninterruptedTakes = 2
        } else if Demo.has("-trial2") { entitlement = Entitlement(trialTakesUsed: 1) }
        trialEndPending = !Launch.isFree && !entitlement.hasProFeatures && !defaults.bool(forKey: "trialEndShown")
        if Demo.has("-savesheet") { trialEndPending = false }
        persist()
        if !Demo.enabled {
            listener = Task { [weak self] in
                for await update in Transaction.updates {
                    guard let self else { return }
                    if case .verified(let transaction) = update, transaction.productID == self.productID {
                        await transaction.finish()
                        await self.refresh()
                    }
                }
            }
        }
        Task { await load() }
    }
    deinit { listener?.cancel() }

    func load() async {
        await refresh()
        guard !Launch.isFree else { return }
        do { product = try await Product.products(for: [productID]).first }
        catch { message = L("暂时无法连接 App Store，请稍后重试。") }
    }

    func refresh() async {
        if Demo.enabled { entitlementsLoaded = true; return }
        var pro = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result, transaction.productID == productID,
               transaction.revocationDate == nil, !transaction.isUpgraded { pro = true }
        }
        entitlement.isPro = pro
        entitlementsLoaded = true
        if pro { trialEndPending = false }
        persist()
    }

    func purchase() async {
        guard !Launch.isFree, !busy else { return }
        guard let product else { await load(); return }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { message = L("购买验证失败，请重试恢复购买。"); return }
                await transaction.finish()
                await refresh()
            case .pending: message = L("购买正在等待批准。")
            case .userCancelled: break
            @unknown default: break
            }
        } catch { message = error.localizedDescription }
    }

    func restore() async {
        guard !Launch.isFree, !busy else { return }
        busy = true
        defer { busy = false }
        do { try await AppStore.sync(); await refresh(); message = entitlement.isPro ? L("已恢复买断。") : L("此 Apple ID 暂无买断记录。") }
        catch { message = error.localizedDescription }
    }

    @discardableResult
    func settleRecording(id: String, seconds: Double, voice: Bool, uninterrupted: Bool, trialEligible: Bool) -> Int? {
        let wasTrial = entitlement.remainingTrialTakes > 0
        var ledger = TakeLedger(entitlement: entitlement, statistics: statistics)
        ledger.trialNumbers = trialNumbers
        let number = ledger.settleRecording(id: id, seconds: seconds, voice: voice, uninterrupted: uninterrupted,
                                            trialEligible: trialEligible, valid: true)
        entitlement = ledger.entitlement; statistics = ledger.statistics; trialNumbers = ledger.trialNumbers
        persist()
        if wasTrial && !entitlement.hasProFeatures { trialEndPending = !defaults.bool(forKey: "trialEndShown") }
        return number
    }

    @discardableResult
    func finishPromptSession(continuousSeconds: TimeInterval) -> Int? {
        let wasTrial = entitlement.remainingTrialTakes > 0
        let number = entitlement.finishPromptSession(continuousSeconds: continuousSeconds)
        persist()
        if wasTrial && !entitlement.hasProFeatures { trialEndPending = !defaults.bool(forKey: "trialEndShown") }
        return number
    }

    func markTrialEndShown() {
        defaults.set(true, forKey: "trialEndShown")
        trialEndPending = false
    }

    func shouldPromptForRemote() -> Bool {
        guard !Launch.isFree, !defaults.bool(forKey: "lockedFeaturePromptShown") else { return false }
        defaults.set(true, forKey: "lockedFeaturePromptShown")
        return true
    }

    private func persist() {
        defaults.set(entitlement.trialTakesUsed, forKey: "trialTakesUsed")
        if !Demo.enabled { TrialKeychain.write(entitlement.trialTakesUsed) }
        var ledger = TakeLedger(entitlement: entitlement, statistics: statistics)
        ledger.trialNumbers = trialNumbers
        if let data = try? JSONEncoder().encode(ledger) {
            defaults.set(data, forKey: "takeLedger")
        }
    }
}
