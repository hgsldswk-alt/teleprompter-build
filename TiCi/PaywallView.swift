import SwiftUI

struct PaywallView: View {
    @EnvironmentObject private var purchases: PurchaseStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Image(systemName: "waveform").font(.system(size: 48, weight: .light)).foregroundStyle(Design.amber).padding(.top, 20)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("看着镜头说话\n不用背稿")).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
                        Text(L("一次买断，持续使用")).font(.title3).foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        benefit("waveform", L("语音跟随不限次数"), L("卡壳也会等你，读到哪里跟到哪里。"))
                        benefit("video", L("成片去水印"), L("支持设备上的 4K 与 60fps 录制。"))
                        benefit("pip", L("悬浮提词"), L("在其他 App 拍摄时，也能看到稿件。"))
                        benefit("keyboard", L("翻页笔与键盘控制"), L("翻段、开始与暂停，手不用碰屏幕。"))
                    }
                    ValueCounter()
                    if purchases.entitlement.isPro {
                        Label(L("已买断"), systemImage: "checkmark.circle").font(.headline).foregroundStyle(Design.amber).accessibilityIdentifier("proUnlocked")
                    } else {
                        Button { Task { await purchases.purchase() } } label: {
                            Text(purchases.priceText.map { L("一次买断") + " · " + $0 } ?? L("正在获取价格"))
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(PrimaryButtonStyle()).disabled(purchases.busy || purchases.priceText == nil).accessibilityIdentifier("buyPro")
                        if purchases.priceText == nil {
                            Button(L("重新获取价格")) { Task { await purchases.load() } }.accessibilityIdentifier("reloadPrice")
                        }
                    }
                    Text(L("前 3 条全功能体验。录制成功保存，或仅提词连续使用满 60 秒，计为一条。免费录制不限时长、不限次数，稿件随时可导出。")).font(.footnote).foregroundStyle(.secondary)
                    Button(L("恢复购买")) { Task { await purchases.restore() } }.disabled(purchases.busy).accessibilityIdentifier("restorePurchase")
                    if let message = purchases.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                }.padding(28)
            }.background(Design.background)
                .navigationTitle(L("买断解锁")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() }.accessibilityIdentifier("closePaywall") } }
                .onChange(of: purchases.entitlement.isPro) { _, pro in if pro { dismiss() } }
        }
    }
    private func benefit(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon).font(.title3).foregroundStyle(Design.amber).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
