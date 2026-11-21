import SwiftUI
import AVKit

struct RemoteControl: UIViewRepresentable {
    var cameraEnabled: Bool
    var keysEnabled = true
    var onKey: (String) -> Void
    var onCapture: () -> Void

    final class Receiver: UIView {
        var onKey: (String) -> Void = { _ in }
        var onCapture: () -> Void = {}
        override var canBecomeFirstResponder: Bool { true }
        override var keyCommands: [UIKeyCommand]? {
            [UIKeyCommand.inputDownArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputPageDown, UIKeyCommand.inputPageUp, " ", "\r"].map {
                let command = UIKeyCommand(input: $0, modifierFlags: [], action: #selector(receive(_:)))
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
        @objc func receive(_ command: UIKeyCommand) { if let input = command.input { onKey(input) } }
        override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { becomeFirstResponder() } }
        @available(iOS 17.2, *)
        func enableCapture(_ enabled: Bool) {
            if let interaction = interactions.compactMap({ $0 as? AVCaptureEventInteraction }).first { interaction.isEnabled = enabled }
            else if enabled {
                let interaction = AVCaptureEventInteraction { [weak self] event in
                    if event.phase == .ended { self?.onCapture() }
                }
                addInteraction(interaction)
            }
        }
    }
    func makeUIView(context: Context) -> Receiver {
        let view = Receiver()
        view.onKey = onKey
        view.onCapture = onCapture
        if #available(iOS 17.2, *) { view.enableCapture(cameraEnabled) }
        return view
    }
    func updateUIView(_ view: Receiver, context: Context) {
        view.onKey = onKey
        view.onCapture = onCapture
        if keysEnabled, view.window != nil, !view.isFirstResponder { view.becomeFirstResponder() }
        if !keysEnabled, view.isFirstResponder { view.resignFirstResponder() }
        if #available(iOS 17.2, *) { view.enableCapture(cameraEnabled) }
    }
    static func name(_ key: String) -> String {
        switch key {
        case UIKeyCommand.inputDownArrow: return "↓"
        case UIKeyCommand.inputUpArrow: return "↑"
        case UIKeyCommand.inputPageDown: return "Page Down"
        case UIKeyCommand.inputPageUp: return "Page Up"
        case " ": return L("空格")
        case "\r": return L("回车")
        default: return key
        }
    }
}

struct RemoteTestView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var lastKey = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "keyboard").font(.system(size: 48)).foregroundStyle(Design.amber)
                Text(L("按一下翻页笔或键盘")).font(.title2.bold())
                Text(lastKey.isEmpty ? L("等待按键") : lastKey).font(.title.monospaced()).accessibilityIdentifier("lastRemoteKey")
                Text(L("拍摄模式支持音量键遥控（iOS 17.2 及以上）。")).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RemoteControl(cameraEnabled: false, onKey: { lastKey = RemoteControl.name($0) }, onCapture: {} ).frame(width: 1, height: 1))
                .navigationTitle(L("测试翻页笔"))
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() }.accessibilityIdentifier("closeRemoteTest") } }
        }
    }
}
