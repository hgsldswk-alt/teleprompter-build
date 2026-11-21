import SwiftUI
import AVFoundation

@MainActor
final class RecordingSaveSession: ObservableObject, Identifiable {
    let id = UUID()
    let video: PendingVideo?
    let trialNumber: Int?
    let interrupted: Bool
    @Published private(set) var handled = false
    @Published private(set) var busy = false
    @Published private(set) var saved = false
    @Published private(set) var savedWithWatermark = false
    @Published private(set) var shareURL: URL?
    @Published private(set) var preparingShare = false
    private var savedShareSource: PendingVideo?
    var canShare: Bool { savedShareSource != nil }
    @Published var error: String?

    init(video: PendingVideo?, trialNumber: Int?, interrupted: Bool = false) {
        self.video = video
        self.trialNumber = trialNumber
        self.interrupted = interrupted
    }

    func save(watermark: Bool, videos: VideoSaver) async {
        guard !handled else { return }
        handled = true
        busy = true
        savedWithWatermark = watermark
        defer { busy = false }
        guard let video else { saved = true; return }
        do {
            let chosen = try videos.chooseWatermark(video, enabled: watermark)
            saved = await videos.save(chosen, interrupted: interrupted)
            if saved {
                if videos.lastSavedVideo?.id == video.id { savedShareSource = videos.lastSavedVideo }
            } else { error = L("视频已保留在待保存，可重试或分享导出。") }
        } catch {
            self.error = L("视频仍保留在应用内，请腾出空间后重试。")
        }
    }

    func prepareShare(videos: VideoSaver) async -> URL? {
        guard let video = savedShareSource, !preparingShare else { return nil }
        preparingShare = true
        defer { preparingShare = false }
        shareURL = await videos.exportForSharing(video)
        return shareURL
    }
}

struct SaveSheet: View {
    @ObservedObject var session: RecordingSaveSession
    @EnvironmentObject private var videos: VideoSaver
    @EnvironmentObject private var purchases: PurchaseStore
    @Environment(\.dismiss) private var dismiss
    @State private var frame: UIImage?
    @State private var loadingFrame = true
    @State private var share: ShareItems?
    private var watermarked: Bool { session.saved ? session.savedWithWatermark : session.trialNumber == nil && !purchases.entitlement.hasProFeatures }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let frame {
                        Image(uiImage: frame).resizable().aspectRatio(contentMode: .fit)
                            .overlay {
                                if watermarked {
                                    GeometryReader { geometry in
                                        let size = geometry.size
                                        let rect = WatermarkLayout.frame(size)
                                        Text(L("提词器 App"))
                                            .font(.system(size: WatermarkLayout.fontSize(size)))
                                            .foregroundStyle(.white.opacity(0.58))
                                            .frame(width: rect.width, height: rect.height, alignment: .topTrailing)
                                            .position(x: rect.midX, y: size.height - rect.midY)
                                    }.allowsHitTesting(false)
                                }
                            }
                            .frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 14))
                            .accessibilityIdentifier("savePreview")
                    } else if loadingFrame { ProgressView().frame(height: 240) }
                    else { Label(L("视频暂时无法读取，原文件已保留。"), systemImage: "video").font(.footnote) }
                    if !Launch.isFree {
                        if let number = session.trialNumber {
                            Text(String(format: L("这条没有水印（体验第 %d 条）"), number)).font(.headline)
                        } else if !purchases.entitlement.isPro {
                            Text(L("保存你的这一条")).font(.headline)
                        }
                    }
                    if session.saved {
                        Label(L("已存到相册"), systemImage: "checkmark.circle").foregroundStyle(Design.amber)
                    } else if !session.handled {
                        if session.trialNumber != nil || purchases.entitlement.hasProFeatures {
                            Button(L("保存到相册")) { Task { await session.save(watermark: false, videos: videos) } }
                                .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("saveClean")
                        } else {
                            Button {
                                Task {
                                    await purchases.purchase()
                                    if purchases.entitlement.hasProFeatures { await session.save(watermark: false, videos: videos) }
                                }
                            } label: {
                                Text(L("去水印保存") + " · " + (purchases.priceText ?? L("正在获取价格")))
                                    .frame(maxWidth: .infinity)
                            }.buttonStyle(PrimaryButtonStyle())
                                .disabled(purchases.busy || purchases.priceText == nil).accessibilityIdentifier("buyAndSave")
                            Button(L("带水印保存")) { Task { await session.save(watermark: true, videos: videos) } }
                                .buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("saveWatermarked")
                            Text(L("前 3 条都没有水印")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if session.busy { ProgressView() }
                    if let error = session.error { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    if !Launch.isFree, let message = purchases.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Button {
                        Task { if let url = await session.prepareShare(videos: videos) { share = ShareItems(items: [url]) } }
                    } label: {
                        if session.preparingShare { ProgressView() }
                        else { Label(L("分享"), systemImage: "square.and.arrow.up") }
                    }.disabled(!session.canShare || session.preparingShare).frame(minHeight: 44).accessibilityIdentifier("shareSavedVideo")
                }.frame(maxWidth: .infinity).padding(20)
            }
            .navigationTitle(L("保存视频")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() }.accessibilityIdentifier("closeSaveSheet") } }
            .sheet(item: $share) { ActivitySheet(items: $0.items) }
            .task {
                if let video = session.video {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 1280, height: 1280)
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    do {
                        let result = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
                        frame = UIImage(cgImage: result.image)
                    } catch {
                        if let result = try? await generator.image(at: .zero) { frame = UIImage(cgImage: result.image) }
                    }
                } else { frame = UIImage(named: "DemoFrame") }
                loadingFrame = false
            }
        }
        .presentationDetents([.fraction(0.82), .large])
        .presentationBackground(Design.background)
        .presentationDragIndicator(.visible)
    }
}

struct ValueCounter: View {
    @EnvironmentObject private var purchases: PurchaseStore
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(String(format: L("语音跟随帮你一遍过 %d 条"), purchases.statistics.uninterruptedTakes))
                .font(.subheadline).monospacedDigit().accessibilityIdentifier("valueCounter")
            if !purchases.entitlement.hasProFeatures {
                Text(L("已暂停统计")).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("valueCounterPaused")
            }
        }
    }
}

struct TrialEndView: View {
    @EnvironmentObject private var purchases: PurchaseStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(L("这 3 条，你已经体验过了")).font(.largeTitle.bold())
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(format: L("你用语音跟随拍了 %d 条"), purchases.statistics.voiceTakes))
                        Text(String(format: L("累计对着镜头说了 %.1f 分钟"), purchases.statistics.cameraSeconds / 60))
                        Text(String(format: L("其中 %d 条一次读完没有中断"), purchases.statistics.uninterruptedTakes))
                    }.monospacedDigit()
                    Text(L("体验结束，以下功能将暂停")).font(.headline)
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L("语音跟随"), systemImage: "waveform")
                        Label(L("成片去水印"), systemImage: "video")
                        Label(L("悬浮提词"), systemImage: "pip")
                        Label(L("翻页笔与键盘控制"), systemImage: "keyboard")
                        Label("4K / 60fps", systemImage: "camera")
                    }.foregroundStyle(Design.amber)
                    ValueCounter()
                    Button { Task { await purchases.purchase() } } label: {
                        Text(purchases.priceText.map { L("一次买断") + " · " + $0 } ?? L("正在获取价格"))
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(PrimaryButtonStyle()).disabled(purchases.busy || purchases.priceText == nil).accessibilityIdentifier("trialEndBuy")
                    Button(L("先用免费版")) { dismiss() }.frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("continueFree")
                    if let message = purchases.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }.padding(24)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() } } }
            .onAppear { purchases.markTrialEndShown() }
            .onChange(of: purchases.entitlement.isPro) { _, value in if value { dismiss() } }
        }
        .interactiveDismissDisabled(false)
    }
}
