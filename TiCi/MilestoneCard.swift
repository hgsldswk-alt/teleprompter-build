import SwiftUI
import CoreImage.CIFilterBuiltins

struct MilestoneCard: View {
    var recommendation = false
    @EnvironmentObject private var videos: VideoSaver
    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareItems?
    @State private var message: String?
    private var minutes: Int { Demo.has("-milestone") ? 86 : Int(UserDefaults.standard.double(forKey: "monthSeconds") / 60) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    artwork.frame(maxWidth: 360).aspectRatio(0.75, contentMode: .fit).accessibilityIdentifier("milestonePreview")
                    Button {
                        let renderer = ImageRenderer(content: artwork.frame(width: 900, height: 1200))
                        renderer.scale = 1
                        guard let image = renderer.uiImage else { message = L("分享图片生成失败，请重试。"); return }
                        var items: [Any] = [image, L("#提词器 #口播 #拍视频神器")]
                        if let url = AppSharing.storeURL { items.append(url) }
                        share = ShareItems(items: items)
                    } label: { Label(L("分享"), systemImage: "square.and.arrow.up") }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("shareMilestone")
                    if AppSharing.storeURL == nil { Text(L("商店链接将在上架后提供。")).font(.footnote).foregroundStyle(.secondary) }
                    if let message { Text(message).font(.footnote) }
                }.padding(24)
            }.background(Design.background)
                .navigationTitle(recommendation ? L("推荐给朋友") : L("表达的里程碑")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() }.accessibilityIdentifier("closeMilestone") } }
                .sheet(item: $share) { ActivitySheet(items: $0.items) }
        }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / 360
            VStack(alignment: .leading, spacing: 20 * scale) {
                Image(systemName: "waveform").font(.system(size: 32 * scale, weight: .light)).foregroundStyle(Design.amber)
                Text(recommendation ? L("让表达\n更自然") : L("这个月\n你对着镜头说了"))
                    .font(.system(size: 28 * scale, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if !recommendation {
                    HStack(alignment: .firstTextBaseline, spacing: 10 * scale) {
                        Text(String(minutes)).font(.system(size: 76 * scale, weight: .medium, design: .rounded)).monospacedDigit()
                        Text(L("分钟")).font(.system(size: 22 * scale))
                    }.foregroundStyle(Design.amber)
                } else { Text(L("看着镜头说话，不用背稿。")).font(.system(size: 18 * scale)).foregroundStyle(Design.warmWhite.opacity(0.65)) }
                Spacer(minLength: 8)
                Rectangle().fill(Design.amber).frame(height: scale)
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8 * scale) {
                        Text(L("提词器")).font(.system(size: 22 * scale, weight: .semibold))
                        Text(L("语音跟随 · 提词拍摄")).font(.system(size: 12 * scale)).foregroundStyle(Design.warmWhite.opacity(0.6))
                    }
                    Spacer()
                    if let url = AppSharing.storeURL, let qr = Self.qrCode(url.absoluteString) {
                        Image(uiImage: qr).interpolation(.none).resizable().frame(width: 62 * scale, height: 62 * scale).padding(5 * scale).background(.white)
                    }
                }
            }.padding(28 * scale).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .foregroundStyle(Design.warmWhite).background(Design.ink)
        }.aspectRatio(0.75, contentMode: .fit)
    }

    private static func qrCode(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
