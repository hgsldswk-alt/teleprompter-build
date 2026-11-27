import Foundation
import Combine

enum ScrollMode: String, Codable, CaseIterable { case voice, constant, manual }
enum PromptColor: String, Codable, CaseIterable { case warmWhite, white, amber, green }

struct PromptSettings: Codable, Equatable {
    var fontSize: Double = 34
    var lineSpacing: Double = 12
    var heightRatio: Double = 0.48
    var margin: Double = 24
    var textColor: PromptColor = .warmWhite
    var backgroundOpacity: Double = 0.72
    var mirrorHorizontal = false
    var mirrorVertical = false
    var countdown = true
    var scrollMode: ScrollMode = .voice
    var speed: Double = 1
    var chineseRate: Double = 220
    var englishRate: Double = 140
    var recognitionLanguage: String = "auto"
    var cameraMode = false
    var recordingQuality = "hd30"
    var remoteEnabled = true

    enum CodingKeys: String, CodingKey, CaseIterable {
        case fontSize, lineSpacing, heightRatio, margin, textColor, backgroundOpacity
        case mirrorHorizontal, mirrorVertical, countdown, scrollMode, speed
        case chineseRate, englishRate, recognitionLanguage, cameraMode, recordingQuality, remoteEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? fontSize
        lineSpacing = try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? lineSpacing
        heightRatio = try c.decodeIfPresent(Double.self, forKey: .heightRatio) ?? heightRatio
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? margin
        textColor = try c.decodeIfPresent(PromptColor.self, forKey: .textColor) ?? textColor
        backgroundOpacity = try c.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? backgroundOpacity
        mirrorHorizontal = try c.decodeIfPresent(Bool.self, forKey: .mirrorHorizontal) ?? mirrorHorizontal
        mirrorVertical = try c.decodeIfPresent(Bool.self, forKey: .mirrorVertical) ?? mirrorVertical
        countdown = try c.decodeIfPresent(Bool.self, forKey: .countdown) ?? countdown
        scrollMode = try c.decodeIfPresent(ScrollMode.self, forKey: .scrollMode) ?? scrollMode
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? speed
        chineseRate = try c.decodeIfPresent(Double.self, forKey: .chineseRate) ?? chineseRate
        englishRate = try c.decodeIfPresent(Double.self, forKey: .englishRate) ?? englishRate
        recognitionLanguage = try c.decodeIfPresent(String.self, forKey: .recognitionLanguage) ?? recognitionLanguage
        cameraMode = try c.decodeIfPresent(Bool.self, forKey: .cameraMode) ?? cameraMode
        recordingQuality = try c.decodeIfPresent(String.self, forKey: .recordingQuality) ?? recordingQuality
        remoteEnabled = try c.decodeIfPresent(Bool.self, forKey: .remoteEnabled) ?? remoteEnabled
        clamp()
    }

    mutating func clamp() {
        fontSize = finite(fontSize, 22...72, 34)
        lineSpacing = finite(lineSpacing, 0...36, 12)
        heightRatio = finite(heightRatio, 0.25...0.85, 0.48)
        margin = finite(margin, 8...80, 24)
        backgroundOpacity = finite(backgroundOpacity, 0...1, 0.72)
        speed = finite(speed, 0.5...2, 1)
        chineseRate = finite(chineseRate, 60...600, 220)
        englishRate = finite(englishRate, 60...350, 140)
    }

    private func finite(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}

final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    @Published var value: PromptSettings {
        didSet {
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: "promptSettings") }
        }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.data(forKey: "promptSettings").flatMap { try? JSONDecoder().decode(PromptSettings.self, from: $0) } ?? PromptSettings()
    }
}
