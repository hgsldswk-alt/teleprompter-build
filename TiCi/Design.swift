import SwiftUI
import UIKit

enum Design {
    static func readingLineRatio(mirrorVertical: Bool) -> CGFloat { mirrorVertical ? 0.76 : 0.24 }
    static let ink = Color(hex: 0x0E0E10)
    static let warmWhite = Color(hex: 0xF4F1EA)
    static let amber = Color(hex: 0xE3A64A)
    static let record = Color(hex: 0xE5484D)
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.055, green: 0.055, blue: 0.063, alpha: 1) : UIColor(red: 0.969, green: 0.961, blue: 0.941, alpha: 1)
    })
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.105, alpha: 1) : .white
    })
    static let text = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.957, green: 0.945, blue: 0.918, alpha: 1) : UIColor(white: 0.08, alpha: 1)
    })
    static func promptColor(_ value: PromptColor) -> UIColor {
        switch value {
        case .warmWhite: return UIColor(red: 244/255, green: 241/255, blue: 234/255, alpha: 1)
        case .white: return .white
        case .amber: return UIColor(red: 227/255, green: 166/255, blue: 74/255, alpha: 1)
        case .green: return UIColor(red: 0.7, green: 0.94, blue: 0.71, alpha: 1)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).padding(.horizontal, 24).padding(.vertical, 14)
            .foregroundStyle(Design.ink).background(Design.amber, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct RecordButton: View {
    var recording: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 72, height: 72)
                RoundedRectangle(cornerRadius: recording ? 7 : 32)
                    .fill(Design.record).frame(width: recording ? 30 : 58, height: recording ? 30 : 58)
            }
        }
        .accessibilityLabel(recording ? L("停止录制") : L("开始录制"))
        .accessibilityIdentifier("recordButton")
        .animation(.easeInOut(duration: 0.2), value: recording)
    }
}
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.medium))
            .padding(.horizontal, 24).padding(.vertical, 14)
            .foregroundStyle(.primary)
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.35), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}
