import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var purchases: PurchaseStore
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false
    @State private var showRemote = false
    @State private var showRecommendation = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !Launch.isFree {
                        Button { showPaywall = true } label: { Label(purchases.entitlement.isPro ? L("已买断") : L("买断解锁"), systemImage: "waveform") }.accessibilityIdentifier("openPaywall")
                        if !purchases.entitlement.isPro {
                            Text(String(format: L("全功能体验 · 还剩 %d 条"), purchases.entitlement.remainingTrialTakes)).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button(L("恢复购买")) { Task { await purchases.restore() } }.disabled(purchases.busy).accessibilityIdentifier("restorePurchase")
                        if let message = purchases.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    }
                    ValueCounter()
                }
                Section(L("预计时长与识别")) {
                    Stepper(value: $settings.value.chineseRate, in: 60...600, step: 10) { Text(String(format: L("中文语速 %.0f 字/分"), settings.value.chineseRate)) }
                    Stepper(value: $settings.value.englishRate, in: 60...350, step: 10) { Text(String(format: L("英文语速 %.0f 词/分"), settings.value.englishRate)) }
                    Picker(L("识别语言"), selection: $settings.value.recognitionLanguage) {
                        Text(L("自动判断")).tag("auto")
                        Text("简体中文").tag("zh-CN")
                        Text("繁體中文").tag("zh-TW")
                        Text("English").tag("en-US")
                    }.accessibilityIdentifier("recognitionLanguage")
                }
                Section(L("拍摄与遥控")) {
                    if purchases.entitlement.hasProFeatures {
                        Picker(L("录制画质"), selection: $settings.value.recordingQuality) {
                            ForEach(RecordingQuality.allCases, id: \.self) { quality in Text(quality.title).tag(quality.rawValue) }
                        }
                        Toggle(L("翻页笔与键盘控制"), isOn: $settings.value.remoteEnabled)
                        Button { showRemote = true } label: { Label(L("测试翻页笔"), systemImage: "keyboard") }.accessibilityIdentifier("testRemote")
                    } else {
                        Button { showPaywall = true } label: {
                            HStack {
                                Label(L("录制画质"), systemImage: "lock.fill")
                                Spacer()
                                Text((RecordingQuality(rawValue: settings.value.recordingQuality) ?? .hd30).title).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("lockedQuality")
                        Button { showPaywall = true } label: {
                            Label(L("翻页笔与键盘控制"), systemImage: "lock.fill")
                        }.accessibilityIdentifier("lockedRemote")
                        Button { showPaywall = true } label: { Label(L("测试翻页笔"), systemImage: "lock.fill") }.accessibilityIdentifier("testRemote")
                        Text(L("你的设置还在，买断后立即恢复")).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button { showRecommendation = true } label: { Label(L("推荐给朋友"), systemImage: "square.and.arrow.up") }.accessibilityIdentifier("recommendApp")
                }
                Section(L("隐私说明")) {
                    Text(Launch.isFree
                         ? L("稿件与视频保存在本机。语音跟随只在手机上识别，不上传音频或稿件。设备端识别不可用时会切换匀速。")
                         : L("稿件与视频保存在本机。语音跟随只在手机上识别，不上传音频或稿件。设备端识别不可用时会切换匀速。购买与恢复通过 Apple 处理。")).font(.footnote).foregroundStyle(.secondary)
                }
                Section(L("关于")) {
                    LabeledContent(L("版本"), value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    Text(L("提词器 · 让表达更自然")).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L("设置"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() }.accessibilityIdentifier("closeSettings") } }
            .sheet(isPresented: Binding(get: { !Launch.isFree && showPaywall }, set: { showPaywall = $0 })) { PaywallView() }
            .sheet(isPresented: $showRemote) { RemoteTestView() }
            .sheet(isPresented: $showRecommendation) { MilestoneCard(recommendation: true) }
        }
    }
}
