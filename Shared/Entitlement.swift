import Foundation

struct Entitlement: Codable, Equatable {
    var isPro = false
    private(set) var trialTakesUsed = 0
    var remainingTrialTakes: Int { max(0, 3 - trialTakesUsed) }
    var hasProFeatures: Bool { hasProFeatures(free: Launch.isFree) }

    func hasProFeatures(free: Bool = Launch.isFree) -> Bool { free || isPro || remainingTrialTakes > 0 }

    init(isPro: Bool = false, trialTakesUsed: Int = 0) {
        self.isPro = isPro
        self.trialTakesUsed = min(3, max(0, trialTakesUsed))
    }
    enum CodingKeys: String, CodingKey { case isPro, trialTakesUsed, usedVoiceTrials }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(isPro: try values.decodeIfPresent(Bool.self, forKey: .isPro) ?? false,
                  trialTakesUsed: try values.decodeIfPresent(Int.self, forKey: .trialTakesUsed)
                    ?? values.decodeIfPresent(Int.self, forKey: .usedVoiceTrials) ?? 0)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isPro, forKey: .isPro)
        try values.encode(trialTakesUsed, forKey: .trialTakesUsed)
    }
    mutating func finishTake(free: Bool = Launch.isFree) {
        if !free && !isPro { trialTakesUsed = min(3, trialTakesUsed + 1) }
    }
    @discardableResult
    mutating func finishPromptSession(continuousSeconds: TimeInterval, free: Bool = Launch.isFree) -> Int? {
        guard !free, continuousSeconds >= 60, !isPro, remainingTrialTakes > 0 else { return nil }
        finishTake(free: free)
        return trialTakesUsed
    }
}

struct TakeStatistics: Codable, Equatable {
    var voiceTakes = 0
    var cameraSeconds: Double = 0
    var uninterruptedTakes = 0
    var recordedIDs: Set<String> = []

    mutating func record(id: String, seconds: Double, voice: Bool, uninterrupted: Bool, enabled: Bool) {
        guard recordedIDs.insert(id).inserted else { return }
        cameraSeconds += max(0, seconds)
        if voice { voiceTakes += 1 }
        if enabled && voice && uninterrupted { uninterruptedTakes += 1 }
    }
}

struct TakeLedger: Codable, Equatable {
    var entitlement: Entitlement
    var statistics: TakeStatistics
    var trialNumbers: [String: Int] = [:]

    init(entitlement: Entitlement, statistics: TakeStatistics) {
        self.entitlement = entitlement
        self.statistics = statistics
    }
    private enum CodingKeys: String, CodingKey { case entitlement, statistics, trialNumbers }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entitlement = try values.decode(Entitlement.self, forKey: .entitlement)
        statistics = try values.decode(TakeStatistics.self, forKey: .statistics)
        trialNumbers = try values.decodeIfPresent([String: Int].self, forKey: .trialNumbers) ?? [:]
    }
    @discardableResult
    mutating func settleRecording(id: String, seconds: Double, voice: Bool, uninterrupted: Bool, trialEligible: Bool, valid: Bool, free: Bool = Launch.isFree) -> Int? {
        guard valid else { return nil }
        guard !statistics.recordedIDs.contains(id) else { return free ? nil : trialNumbers[id] }
        let number = !free && trialEligible && !entitlement.isPro && entitlement.remainingTrialTakes > 0 ? entitlement.trialTakesUsed + 1 : nil
        statistics.record(id: id, seconds: seconds, voice: voice, uninterrupted: uninterrupted,
                          enabled: free || entitlement.isPro || number != nil)
        if let number { trialNumbers[id] = number; entitlement.finishTake(free: free) }
        return number
    }
}
