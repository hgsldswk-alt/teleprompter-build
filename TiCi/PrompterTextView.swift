import SwiftUI
import UIKit

struct PrompterTextView: UIViewRepresentable {
    let text: String
    let tokens: [VoiceAligner.Token]
    var settings: PromptSettings
    var running: Bool
    var targetOffset: Int
    var onManualSeek: (Int) -> Void
    var onProgress: (Int) -> Void
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = UITextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = false
        view.backgroundColor = .clear
        view.showsVerticalScrollIndicator = false
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.accessibilityIdentifier = "prompterText"
        view.accessibilityLabel = L("提词正文")
        view.accessibilityTraits = .staticText
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        context.coordinator.startDisplayLink()
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.link?.invalidate()
        view.delegate = nil
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PrompterTextView
        weak var view: UITextView?
        var link: CADisplayLink?
        private var timestamp: CFTimeInterval = 0
        private var lastSettings: PromptSettings?
        private var lastText = ""
        private var lastSize: CGSize = .zero
        private var shadedOffset = 0
        private var target: CGFloat?
        private var lastTarget = -1
        private var dragging = false
        private var progress = 0
        private var pointsPerSecond: CGFloat = 0
        private var timingTokens: [VoiceAligner.Token] = []
        private var restoreOffset: Int?

        init(_ parent: PrompterTextView) { self.parent = parent }
        func startDisplayLink() {
            link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link?.add(to: .main, forMode: .common)
        }

        func update() {
            guard let view else { return }
            let old = lastSettings
            let changedText = lastText != parent.text
            let changedTypography = old?.fontSize != parent.settings.fontSize || old?.lineSpacing != parent.settings.lineSpacing || old?.textColor != parent.settings.textColor
            let changedLayout = changedTypography || old?.margin != parent.settings.margin || old?.mirrorVertical != parent.settings.mirrorVertical
            if changedText { restoreOffset = parent.targetOffset }
            else if changedLayout { restoreOffset = parent.settings.scrollMode == .voice ? parent.targetOffset : currentOffset() }
            if changedText || changedTypography {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = parent.settings.lineSpacing
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: parent.settings.fontSize, weight: .semibold),
                    .foregroundColor: Design.promptColor(parent.settings.textColor), .paragraphStyle: paragraph]
                let saved = view.contentOffset
                view.attributedText = NSAttributedString(string: parent.text, attributes: attributes)
                view.contentOffset = saved
                lastText = parent.text
                shadedOffset = 0
                shade(to: restoreOffset ?? parent.targetOffset)
            }
            if changedText || timingTokens.count != parent.tokens.count {
                timingTokens = parent.tokens
                lastSize = .zero
            }
            if changedLayout { lastSize = .zero }
            view.transform = CGAffineTransform(scaleX: parent.settings.mirrorHorizontal ? -1 : 1, y: parent.settings.mirrorVertical ? -1 : 1)
            if changedText || changedLayout || old?.chineseRate != parent.settings.chineseRate || old?.englishRate != parent.settings.englishRate {
                lastSize = .zero
            }
            lastSettings = parent.settings
        }

        private var readingY: CGFloat {
            guard let view else { return 0 }
            return view.bounds.height * Design.readingLineRatio(mirrorVertical: parent.settings.mirrorVertical)
        }

        private func updateInsets() {
            guard let view, view.bounds.size != lastSize || view.textContainerInset.left != parent.settings.margin else { return }
            if restoreOffset == nil { restoreOffset = parent.settings.scrollMode == .voice ? parent.targetOffset : progress }
            lastSize = view.bounds.size
            view.textContainerInset = UIEdgeInsets(top: readingY, left: parent.settings.margin, bottom: view.bounds.height, right: parent.settings.margin)
            view.layoutManager.ensureLayout(for: view.textContainer)
            pointsPerSecond = ReadingPace.pointsPerSecond(tokens: timingTokens, layout: view.layoutManager,
                                                         container: view.textContainer, settings: parent.settings)
            lastTarget = -1
        }

        private func y(for offset: Int) -> CGFloat {
            guard let view, view.textStorage.length > 0 else { return 0 }
            let index = min(max(0, offset), view.textStorage.length - 1)
            let glyph = view.layoutManager.glyphIndexForCharacter(at: index)
            let rect = view.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return min(max(0, rect.minY + view.textContainerInset.top - readingY), max(0, view.contentSize.height - view.bounds.height))
        }

        private func currentOffset() -> Int {
            guard let view else { return 0 }
            let point = CGPoint(x: view.textContainerInset.left + 2, y: view.contentOffset.y + readingY + 2)
            guard let position = view.closestPosition(to: point) else { return 0 }
            return view.offset(from: view.beginningOfDocument, to: position)
        }

        private func shade(to raw: Int) {
            guard let view else { return }
            let offset = min(max(0, raw), view.textStorage.length)
            guard offset != shadedOffset else { return }
            let lower = min(offset, shadedOffset)
            let length = abs(offset - shadedOffset)
            let color = Design.promptColor(parent.settings.textColor)
            view.textStorage.addAttribute(.foregroundColor, value: offset > shadedOffset ? color.withAlphaComponent(0.4) : color,
                                          range: NSRange(location: lower, length: length))
            shadedOffset = offset
        }

        @objc func tick(_ display: CADisplayLink) {
            let elapsed = timestamp == 0 ? 0 : min(0.05, display.timestamp - timestamp)
            timestamp = display.timestamp
            guard let view, view.bounds.height > 0 else { return }
            updateInsets()
            if let restoreOffset, !dragging {
                target = y(for: restoreOffset)
                progress = restoreOffset
                lastTarget = parent.targetOffset
                self.restoreOffset = nil
            }
            if !dragging, lastTarget != parent.targetOffset {
                lastTarget = parent.targetOffset
                target = y(for: parent.targetOffset)
            }
            if !dragging, let target {
                let difference = target - view.contentOffset.y
                if abs(difference) < 0.5 { self.target = nil; view.contentOffset.y = target }
                else { view.contentOffset.y += difference * min(1, elapsed * 9) }
            } else if parent.running, parent.settings.scrollMode == .constant, !dragging {
                view.contentOffset.y = min(max(0, view.contentSize.height - view.bounds.height), view.contentOffset.y + elapsed * pointsPerSecond * parent.settings.speed)
                let offset = currentOffset()
                if abs(offset - progress) >= 4 {
                    progress = offset
                    parent.onProgress(offset)
                }
            }
            let offset = dragging ? currentOffset() : parent.settings.scrollMode == .constant ? progress : parent.targetOffset
            if abs(offset - shadedOffset) >= 4 { shade(to: offset) }
        }

        @objc func tapped() { parent.onTap() }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { dragging = true; target = nil }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishDragging() }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishDragging() }
        private func finishDragging() {
            restoreOffset = nil
            progress = currentOffset()
            parent.onManualSeek(progress)
            lastTarget = progress
            dragging = false
        }
    }
}

enum ReadingPace {
    static func pointsPerSecond(tokens: [VoiceAligner.Token], layout: NSLayoutManager,
                                container: NSTextContainer, settings: PromptSettings) -> CGFloat {
        guard !tokens.isEmpty else { return 0 }
        let glyphs = layout.glyphRange(for: container)
        var lineCount = 0
        layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in lineCount += 1 }
        guard lineCount > 0 else { return 0 }
        let han = tokens.filter(\.isHan).count
        let minutes = Double(han) / settings.chineseRate + Double(tokens.count - han) / settings.englishRate
        guard minutes > 0 else { return 0 }
        let averageUnitsPerLine = Double(tokens.count) / Double(lineCount)
        let averageLineHeight = layout.usedRect(for: container).height / CGFloat(lineCount)
        let unitsPerSecond = Double(tokens.count) / (minutes * 60)
        return averageLineHeight * CGFloat(unitsPerSecond / averageUnitsPerLine)
    }
}
