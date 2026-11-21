import Foundation

struct Script: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var modifiedAt: Date
    var readingOffset: Int
    var languageOverride: String?

    init(id: UUID = UUID(), title: String, body: String, createdAt: Date = Date(),
         modifiedAt: Date = Date(), readingOffset: Int = 0, languageOverride: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.readingOffset = min(max(0, readingOffset), body.utf16.count)
        self.languageOverride = languageOverride
    }

    enum CodingKeys: String, CodingKey {
        case id, title, body, createdAt, modifiedAt, readingOffset, languageOverride
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        let decodedBody = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
        let initialCreatedAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        let storedOffset = try values.decodeIfPresent(Int.self, forKey: .readingOffset) ?? 0
        createdAt = initialCreatedAt
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? initialCreatedAt
        readingOffset = min(max(0, storedOffset), decodedBody.utf16.count)
        languageOverride = try values.decodeIfPresent(String.self, forKey: .languageOverride)
    }

    var wordCount: Int { VoiceAligner.tokenize(body).count }
    var containsHan: Bool { body.unicodeScalars.contains { Self.isHan($0.value) } }

    func estimatedSeconds(chineseRate: Double = 220, englishRate: Double = 140) -> Int {
        let tokens = VoiceAligner.tokenize(body)
        let chinese = tokens.filter { $0.isHan }.count
        let western = tokens.count - chinese
        let chineseSeconds: Double = Double(chinese) / max(1.0, chineseRate) * 60.0
        let westernSeconds: Double = Double(western) / max(1.0, englishRate) * 60.0
        return Int((chineseSeconds + westernSeconds).rounded(.up))
    }

    var recognitionLanguage: String {
        if let languageOverride, !languageOverride.isEmpty { return languageOverride }
        guard containsHan else { return "en-US" }
        let simplified = body.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? body
        return simplified == body ? "zh-CN" : "zh-TW"
    }

    static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x9FFF).contains(value) || (0x20000...0x3134F).contains(value) || (0xF900...0xFAFF).contains(value)
    }
}

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

func durationText(_ seconds: Int) -> String {
    String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
}
