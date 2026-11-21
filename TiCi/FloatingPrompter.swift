import SwiftUI
import AVKit
import CoreMedia
import CoreVideo

final class FloatingPrompter: NSObject, ObservableObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    let layer = AVSampleBufferDisplayLayer()
    @Published private(set) var active = false
    @Published var message: String?
    static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    private var controller: AVPictureInPictureController?
    private var observation: NSKeyValueObservation?
    private var timer: Timer?
    private var text = ""
    private var settings = PromptSettings()
    private var scrollY: CGFloat = 0
    @Published private(set) var playing = true
    @Published private(set) var requested = false
    private var timebase: CMTimebase?
    private let textStorage = NSTextStorage()
    private let textLayout = NSLayoutManager()
    private let textContainer = NSTextContainer(size: CGSize(width: 552, height: CGFloat.greatestFiniteMagnitude))
    private var pointsPerSecond: CGFloat = 0
    private var textHeight: CGFloat = 0
    private var lastTick: CFTimeInterval = 0
    private var startID: UInt64 = 0
    private var pixelBufferPool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?

    override init() {
        super.init()
        textContainer.lineFragmentPadding = 0
        textLayout.addTextContainer(textContainer)
        textStorage.addLayoutManager(textLayout)
        guard Self.supported else { return }
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            layer.controlTimebase = timebase
            CMTimebaseSetTime(timebase, time: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600))
            CMTimebaseSetRate(timebase, rate: 1)
        }
        layer.videoGravity = .resizeAspect
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        controller = AVPictureInPictureController(contentSource: source)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        observation = controller?.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.startWhenReady() }
        }
    }

    func start(text: String, offset: Int, settings: PromptSettings, tokens: [VoiceAligner.Token]) {
        guard Self.supported else { return }
        self.text = text
        self.settings = settings
        playing = true
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = settings.lineSpacing
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: settings.fontSize, weight: .semibold),
            .foregroundColor: Design.promptColor(settings.textColor), .paragraphStyle: paragraph]
        textStorage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        textLayout.ensureLayout(for: textContainer)
        textHeight = textLayout.usedRect(for: textContainer).height
        pointsPerSecond = ReadingPace.pointsPerSecond(tokens: tokens, layout: textLayout,
                                                     container: textContainer, settings: settings)
        if textStorage.length > 0 {
            let glyph = textLayout.glyphIndexForCharacter(at: min(max(0, offset), textStorage.length - 1))
            scrollY = textLayout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        } else { scrollY = 0 }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch { message = error.localizedDescription; return }
        requested = true
        startID &+= 1
        let id = startID
        drawFrame()
        startTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.startID == id, self.requested, !self.active else { return }
            self.message = L("悬浮提词暂不可用，请在真机上重试。")
            self.stop()
        }
        startWhenReady()
    }

    private func startWhenReady() {
        if requested, controller?.isPictureInPicturePossible == true { controller?.startPictureInPicture() }
    }

    private func advance(to now: CFTimeInterval) {
        let elapsed = max(0, now - lastTick)
        lastTick = now
        scrollY = min(max(0, textHeight - 100), scrollY + pointsPerSecond * CGFloat(elapsed * settings.speed))
    }
    private func startTimer() {
        timer?.invalidate()
        lastTick = CACurrentMediaTime()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.playing else { return }
            self.advance(to: CACurrentMediaTime())
            self.drawFrame()
        }
    }
    private func setPlaying(_ value: Bool) {
        guard playing != value else { return }
        if !value {
            advance(to: CACurrentMediaTime())
            drawFrame()
            timer?.invalidate(); timer = nil
        }
        playing = value
        if value { startTimer() }
    }

    func stop() {
        startID &+= 1
        requested = false
        timer?.invalidate()
        timer = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        active = false
    }

    private func drawFrame() {
        let width = 600
        let height = 340
        var buffer: CVPixelBuffer?
        if pixelBufferPool == nil {
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32ARGB, kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pixelBufferPool) == kCVReturnSuccess else { return }
        }
        guard let pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        context.setFillColor(UIColor(red: 14/255, green: 14/255, blue: 16/255, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        if settings.mirrorHorizontal { context.translateBy(x: CGFloat(width), y: 0); context.scaleBy(x: -1, y: 1) }
        if settings.mirrorVertical { context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1) }
        UIGraphicsPushContext(context)
        let visible = CGRect(x: 0, y: max(0, scrollY), width: CGFloat(width - 48), height: CGFloat(height - 32))
        let glyphs = textLayout.glyphRange(forBoundingRect: visible, in: textContainer)
        textLayout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: 24, y: 16 - scrollY))
        UIGraphicsPopContext()
        if formatDescription == nil {
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &formatDescription) == noErr else { return }
        }
        guard let description = formatDescription else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10), presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if layer.status == .failed { layer.flush() }
        if layer.isReadyForMoreMediaData { layer.enqueue(sample) }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) { setPlaying(playing) }
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange { CMTimeRange(start: .zero, duration: .positiveInfinity) }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { !playing }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { active = true; requested = false }
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) { stop() }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { message = error.localizedDescription; stop() }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { completionHandler(true) }
}

struct FloatingSurface: UIViewRepresentable {
    let floating: FloatingPrompter
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        floating.layer.frame = CGRect(x: 0, y: 0, width: 4, height: 3)
        view.layer.addSublayer(floating.layer)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {}
}
