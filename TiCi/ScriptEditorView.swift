import SwiftUI

struct ScriptEditorView: View {
    @EnvironmentObject private var store: ScriptStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State var script: Script
    @State private var count = 0
    @State private var seconds = 0
    @State private var message: String?
    @FocusState private var focused: Field?
    private enum Field { case title, body }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextField(L("标题"), text: $script.title).font(.title2.weight(.semibold)).focused($focused, equals: .title).submitLabel(.next).onSubmit { focused = .body }.accessibilityIdentifier("scriptTitle")
                Divider()
                TextEditor(text: $script.body).font(.body).scrollContentBackground(.hidden).focused($focused, equals: .body).accessibilityIdentifier("scriptBody")
                HStack {
                    Text(String(format: L("%d 字 / 词"), count))
                    Spacer()
                    Text(L("预计时长") + " " + durationText(seconds)).monospacedDigit()
                }.font(.footnote).foregroundStyle(.secondary)
            }.padding(24).background(Design.background)
                .navigationTitle(L("编辑稿件")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L("取消")) { dismiss() }.accessibilityIdentifier("cancelEditor") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("保存")) {
                            script.title = script.title.trimmingCharacters(in: .whitespacesAndNewlines)
                            if script.title.isEmpty { script.title = L("未命名稿件") }
                            script.readingOffset = min(script.readingOffset, script.body.utf16.count)
                            script.modifiedAt = Date()
                            if store.save(script) { dismiss() } else { message = store.errorMessage }
                        }.fontWeight(.semibold).disabled(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("saveScript")
                    }
                }
                .task {
                    guard script.body.isEmpty else { return }
                    do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                    focused = .body
                }
                .task(id: script.body) {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    let snapshot = script
                    let rates = settings.value
                    let metrics = await Task.detached(priority: .userInitiated) { (snapshot.wordCount, snapshot.estimatedSeconds(chineseRate: rates.chineseRate * rates.speed, englishRate: rates.englishRate * rates.speed)) }.value
                    guard !Task.isCancelled else { return }
                    count = metrics.0; seconds = metrics.1
                }
                .alert(L("无法保存"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button(L("好")) { message = nil } } message: { Text(message ?? "") }
        }
    }
}
