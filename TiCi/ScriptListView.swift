import SwiftUI
import UniformTypeIdentifiers

struct ScriptListView: View {
    @EnvironmentObject private var store: ScriptStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var videos: VideoSaver
    @EnvironmentObject private var purchases: PurchaseStore
    @Environment(\.scenePhase) private var phase
    @State private var editor: Script?
    @State private var selected: Script?
    @State private var importing = false
    @State private var showSettings = false
    @State private var showPaywall = false
    @State private var showPending = false
    @State private var showTrialEnd = false
    @State private var showMilestone = false
    @State private var share: ShareItems?
    @State private var message: String?
    @State private var prepared = false
    @State private var busy = false
    @State private var canPaste = UIPasteboard.general.hasStrings
    @State private var friendStyle: SharedStyle?

    private var reviewHome: Bool {
        prepared && selected == nil && editor == nil && !showSettings && !showPending && !showPaywall
            && !showTrialEnd && !showMilestone && !videos.milestone && !purchases.canPresentTrialEnd
            && !importing && !busy && share == nil && friendStyle == nil && message == nil
            && videos.message == nil && !videos.saving && !videos.preparingShare && !purchases.busy
            && store.errorMessage == nil && videos.reviewScene != nil
    }

    var body: some View {
        NavigationStack {
            List {
                if !videos.pending.isEmpty || Demo.has("-pending") {
                    Button { showPending = true } label: {
                        Label(String(format: L("%d 条视频还没存到相册"), max(Demo.has("-pending") ? 1 : 0, videos.pending.count)), systemImage: "tray.and.arrow.down")
                            .font(.subheadline.weight(.medium)).foregroundStyle(Design.amber)
                    }.accessibilityIdentifier("pendingBanner").listRowBackground(Design.card)
                }
                if store.scripts.isEmpty {
                    ContentUnavailableView(L("写下你的第一篇稿件"), systemImage: "doc.text", description: Text(L("新建、粘贴或导入文件，即可开始提词。")))
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                }
                ForEach(store.scripts) { script in
                    Button { selected = script } label: {
                        ScriptCard(script: script, settings: settings.value)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("script-" + script.id.uuidString)
                    .listRowBackground(RoundedRectangle(cornerRadius: 18).fill(Design.card))
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.delete(script) } label: { Label(L("删除"), systemImage: "trash") }.accessibilityIdentifier("deleteScript")
                    }
                    .contextMenu {
                        Button { editor = script } label: { Label(L("编辑"), systemImage: "pencil") }.accessibilityIdentifier("editScript")
                        Button { var copy = Script(title: script.title + " " + L("副本"), body: script.body); copy.languageOverride = script.languageOverride; store.save(copy) } label: { Label(L("复制稿件"), systemImage: "doc.on.doc") }
                        Button { shareCode(script) } label: { Label(L("分享口令"), systemImage: "text.bubble") }
                        Button { UIPasteboard.general.string = script.body } label: { Label(L("复制正文"), systemImage: "doc.on.clipboard") }
                        Button { export(script) } label: { Label(L("导出 TXT"), systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .listStyle(.insetGrouped).listRowSpacing(12).scrollContentBackground(.hidden)
            .background(Design.background)
            .navigationTitle(L("稿件"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(L("设置")).accessibilityIdentifier("openSettings")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { editor = Script(title: "", body: "") } label: { Image(systemName: "plus") }
                        .accessibilityLabel(L("新建稿件")).accessibilityIdentifier("newScript")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if store.deleted != nil {
                        HStack {
                            Text(L("稿件已删除")).font(.subheadline)
                            Spacer()
                            Button(L("撤销")) { store.restoreDeleted() }.fontWeight(.semibold).accessibilityIdentifier("undoDelete")
                        }.padding().background(Design.card, in: RoundedRectangle(cornerRadius: 16))
                    }
                    HStack(spacing: 10) {
                        Button { importing = true } label: { Label(L("导入文件"), systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                            .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("importFile")
                        if canPaste {
                            PasteButton(payloadType: String.self) { values in if let text = values.first { importText(text) } }
                                .buttonBorderShape(.capsule).tint(Design.card).foregroundStyle(Design.text).labelStyle(.titleAndIcon)
                                .frame(minHeight: 44).accessibilityIdentifier("pasteScript")
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 10).background(.ultraThinMaterial)
            }
            .overlay { if busy { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        }
        .foregroundStyle(Design.text)
        .sheet(item: $editor) { ScriptEditorView(script: $0) }
        .fullScreenCover(item: $selected) { PrompterView(script: $0) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: Binding(get: { !Launch.isFree && showPaywall }, set: { showPaywall = $0 })) { PaywallView() }
        .sheet(isPresented: Binding(get: { !Launch.isFree && showTrialEnd }, set: { showTrialEnd = $0 })) { TrialEndView() }
        .sheet(isPresented: $showPending) { PendingVideosView() }
        .sheet(isPresented: $showMilestone) { MilestoneCard() }
        .sheet(item: $share) { ActivitySheet(items: $0.items) }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes) { result in
            switch result {
            case .success(let url):
                busy = true
                Task {
                    do {
                        let script = try await Task.detached(priority: .userInitiated) { try TextImporter.read(url: url) }.value
                        store.save(script)
                    } catch { message = error.localizedDescription }
                    busy = false
                }
            case .failure(let error): message = error.localizedDescription
            }
        }
        .confirmationDialog(L("套用朋友的文字设置？"), isPresented: Binding(get: { friendStyle != nil }, set: { if !$0 { friendStyle = nil } }), titleVisibility: .visible) {
            Button(L("套用")) { if let style = friendStyle { settings.value = style.applied(to: settings.value) }; friendStyle = nil }.accessibilityIdentifier("applyFriendStyle")
            Button(L("保持我的设置"), role: .cancel) { friendStyle = nil }
        } message: { Text(L("字号、行距、颜色和滚动速度会和朋友一样，随时可以在 Aa 里改回。")) }
        .alert(L("提示"), isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(L("好")) { message = nil }.accessibilityIdentifier("dismissMessage")
        } message: { Text(message ?? "") }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if selected == nil && editor == nil && !showSettings && !showPending && !showPaywall && !showMilestone && !importing && purchases.canPresentTrialEnd {
                showTrialEnd = true
            }
        }
        .onChange(of: store.errorMessage) { _, value in if let value { message = value; store.clearError() } }
        .onChange(of: videos.message) { _, value in if let value, selected == nil { message = value; videos.message = nil } }
        .onChange(of: videos.milestone) { _, value in if value, selected == nil { showMilestone = true; videos.milestone = false } }
        .reviewAfterCoreAction(when: reviewHome, alreadyRequested: videos.reviewedThisVersion) { videos.requestCoreReview() }
        .task(id: reviewHome && phase == .active) {
            guard reviewHome, phase == .active else { return }
            do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
            guard !Task.isCancelled, reviewHome else { return }
            videos.requestReviewIfReady()
        }
        .onChange(of: phase) { _, value in
            if value == .active { canPaste = UIPasteboard.general.hasStrings }
            if value == .active { Task { await purchases.refresh() }; if selected == nil { videos.refreshPending() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in canPaste = UIPasteboard.general.hasStrings }
        .onChange(of: selected) { _, value in
            if value == nil { videos.refreshPending(); if videos.milestone { showMilestone = true; videos.milestone = false } }
        }
        .task {
            guard !prepared else { return }
            prepared = true
            store.recoverUndo()
            if let error = store.errorMessage { message = error; store.clearError() }
            if let code = Demo.argument("-import-code") { importText(code) }
            if Demo.has("-prompter") || Demo.has("-camera") || Demo.has("-settings") || Demo.has("-savesheet") || Demo.has("-trialend") || Demo.has("-trial2") {
                settings.value.cameraMode = Demo.has("-camera")
                settings.value.scrollMode = Demo.has("-voice") ? .voice : .constant
                selected = store.scripts.first(where: { $0.title == L("试一试语音跟随") }) ?? store.scripts.first
            } else if Demo.has("-paywall") { showPaywall = true }
            else if Demo.has("-milestone") { showMilestone = true }
        }
    }

    private static var importTypes: [UTType] {
        [.plainText, .rtf, .pdf] + ["md", "docx"].compactMap { UTType(filenameExtension: $0) }
    }
    private func importText(_ text: String) {
        if let shared = ShareCode.decodeWithStyle(text) {
            store.save(shared.script)
            if let style = shared.style, style.applied(to: settings.value) != settings.value { friendStyle = style }
            return
        }
        if text.contains(ShareCode.marker) || text.contains("#TeleprompterScript#") { message = L("稿件口令无效或过大，请重新复制完整口令。"); return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        editor = Script(title: String(text.split(whereSeparator: \.isNewline).first?.prefix(40) ?? ""), body: text)
    }
    private func shareCode(_ script: Script) {
        guard let code = ShareCode.encode(script, style: SharedStyle(settings.value)) else { message = L("稿件口令超过 200 KB，请改用 TXT 分享。"); return }
        var text = String(format: L("「%@」的提词稿件。复制这整段，打开「提词器」点「粘贴」即可导入，字号和滚动速度也一起带上："), script.title) + "\n" + code
        if let url = AppSharing.storeURL { text += "\n" + String(format: L("还没安装？在 App Store 下载：%@"), url.absoluteString) }
        share = ShareItems(items: [text])
    }
    private func export(_ script: Script) {
        do { share = ShareItems(items: [try AppSharing.textFile(script)]) }
        catch { message = error.localizedDescription }
    }
}

private struct ScriptCard: View {
    let script: Script
    let settings: PromptSettings
    @State private var count = 0
    @State private var seconds = 0
    @ScaledMetric(relativeTo: .headline) private var titleSize: CGFloat = 17
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(script.title.isEmpty ? L("未命名稿件") : script.title).font(.system(size: titleSize, weight: .semibold)).lineLimit(2).accessibilityIdentifier("scriptTitleLabel")
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.right").font(.subheadline).foregroundStyle(Design.amber)
            }
            Text(script.body.prefix(160)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).multilineTextAlignment(.leading)
            HStack(spacing: 6) {
                Text(String(format: script.containsHan ? L("%@ 字") : L("%@ 词"), count.formatted())).accessibilityIdentifier("scriptWordCount")
                Text("·")
                Text(seconds >= 3600 ? String(format: L("约 %d 小时 %d 分"), seconds / 3600, (seconds % 3600) / 60) : String(format: L("约 %d 分 %d 秒"), seconds / 60, seconds % 60))
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task(id: "\(script.modifiedAt.timeIntervalSince1970)-\(settings.chineseRate)-\(settings.englishRate)-\(settings.speed)") {
            let result = await Task.detached(priority: .userInitiated) {
                (script.wordCount, script.estimatedSeconds(chineseRate: settings.chineseRate * settings.speed, englishRate: settings.englishRate * settings.speed))
            }.value
            count = result.0; seconds = result.1
        }
    }
}

struct PendingVideosView: View {
    @EnvironmentObject private var videos: VideoSaver
    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareItems?
    var body: some View {
        NavigationStack {
            List {
                Text(L("视频原文件保存在应用内。允许添加到相册后可重试，也可通过分享导出。")).font(.subheadline).foregroundStyle(.secondary)
                ForEach(videos.pending) { video in
                    VStack(alignment: .leading, spacing: 12) {
                        Label(video.url.lastPathComponent, systemImage: "video").lineLimit(1).font(.caption.monospaced())
                        HStack {
                            Button(L("重试保存")) { Task { await videos.save(video) } }.buttonStyle(.bordered).disabled(videos.saving).accessibilityIdentifier("retrySave")
                            Button(L("分享导出")) { Task { if let url = await videos.exportForSharing(video) { share = ShareItems(items: [url]) } } }.buttonStyle(.bordered).disabled(videos.saving).accessibilityIdentifier("exportPending")
                        }
                    }.padding(.vertical, 8)
                }
                Button(L("去设置打开")) { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            .navigationTitle(L("待保存视频"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } } }
            .sheet(item: $share) { ActivitySheet(items: $0.items) }
            .task { videos.refreshPending() }
        }
    }
}
