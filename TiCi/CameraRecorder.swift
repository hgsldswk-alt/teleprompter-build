import Foundation
import AVFoundation
import UIKit
import SwiftUI
import Combine

enum RecordingQuality: String, CaseIterable {
    case hd30, hd60, uhd30, uhd60
    var title: String {
        switch self { case .hd30: return "1080p · 30"; case .hd60: return "1080p · 60"; case .uhd30: return "4K · 30"; case .uhd60: return "4K · 60" }
    }
    var fps: Int32 { self == .hd60 || self == .uhd60 ? 60 : 30 }
    var width: Int32 { self == .uhd30 || self == .uhd60 ? 3840 : 1920 }
    var bitrate: Int { width == 3840 ? (fps == 60 ? 60_000_000 : 40_000_000) : (fps == 60 ? 20_000_000 : 12_000_000) }
}

final class CameraRecorder: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published private(set) var isAvailable = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var isRecording = false
    @Published private(set) var isFinishing = false
    @Published private(set) var isSwitchingCamera = false
    @Published private(set) var actualQuality: RecordingQuality = .hd30
    @Published private(set) var supportedQualities: [RecordingQuality] = [.hd30]
    @Published var message: String?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var previewFrozen = false
    private var captureCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureDeviceID: String?

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        queue.async {
            let device = self.cameraInput?.device
            DispatchQueue.main.async { self.rebuildRotationCoordinator(device) }
        }
    }

    private func rebuildRotationCoordinator(_ device: AVCaptureDevice?) {
        rotationObservation = nil
        rotationCoordinator = nil
        guard let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async {
                guard let self, !self.previewFrozen, self.rotationCoordinator === coordinator else { return }
                self.updatePreviewAngle(angle)
            }
        }
    }
    private func updatePreviewAngle(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection else { return }
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }
    var onFinished: ((URL, TimeInterval, Bool) -> Void)?
    private var onAudioSample: ((CMSampleBuffer) -> Void)?
    private let queue = DispatchQueue(label: "TiCi.capture", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var cameraInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var writer: AVAssetWriter?
    private var videoWriter: AVAssetWriterInput?
    private var audioWriter: AVAssetWriterInput?
    private var startTime: CMTime?
    private var lastTime: CMTime?
    private var outputURL: URL?
    private var recording = false
    private var finishing = false
    private var interrupted = false
    private var failureHandled = false
    private var observers: [NSObjectProtocol] = []
    private var position: AVCaptureDevice.Position = .front
    private var quality: RecordingQuality = .hd30
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [AVCaptureSession.wasInterruptedNotification, UIApplication.didEnterBackgroundNotification,
                     AVAudioSession.interruptionNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in self?.finish(interruption: true) }
            })
        }
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            if reason == .oldDeviceUnavailable { self?.queue.async { [weak self] in self?.finish(interruption: true) } }
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func prepare() async {
        #if targetEnvironment(simulator)
        DispatchQueue.main.async { self.isAvailable = false }
        return
        #else
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        var allowed = status == .authorized
        if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        guard allowed else { DispatchQueue.main.async { self.cameraDenied = true }; return }
        guard !Task.isCancelled else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.configureCamera()
                continuation.resume()
            }
        }
        #endif
    }

    private func configureCamera() {
        guard !recording, !finishing else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let cameraInput { session.removeInput(cameraInput); self.cameraInput = nil }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            DispatchQueue.main.async { self.isAvailable = false; self.rebuildRotationCoordinator(nil) }; return
        }
        session.addInput(input)
        cameraInput = input
        captureCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        captureDeviceID = device.uniqueID
        session.automaticallyConfiguresApplicationAudioSession = false
        if session.outputs.isEmpty {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            videoOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        }
        let supported = RecordingQuality.allCases.filter { candidate in self.format(for: candidate, device: device) != nil }
        if !supported.contains(quality) { quality = .hd30 }
        if session.canSetSessionPreset(.inputPriority) { session.sessionPreset = .inputPriority }
        applyQuality(device)
        DispatchQueue.main.async { self.isAvailable = true; self.cameraDenied = false; self.supportedQualities = supported; self.rebuildRotationCoordinator(device) }
    }

    private func format(for quality: RecordingQuality, device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats.first { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == quality.width && size.height == quality.width * 9 / 16 &&
                format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= Double(quality.fps) && $0.maxFrameRate >= Double(quality.fps) }
        }
    }

    private func applyQuality(_ device: AVCaptureDevice) {
        guard let format = format(for: quality, device: device) else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: quality.fps)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let fps = 1 / CMTimeGetSeconds(device.activeVideoMinFrameDuration)
            let actual: RecordingQuality = dimensions.width >= 3840 ? (fps >= 50 ? .uhd60 : .uhd30) : (fps >= 50 ? .hd60 : .hd30)
            DispatchQueue.main.async { self.actualQuality = actual }
        } catch { DispatchQueue.main.async { self.message = error.localizedDescription } }
    }

    func preview() { queue.async { if self.cameraInput != nil, !self.session.isRunning { self.session.startRunning() } } }
    func setAudioHandler(_ handler: @escaping (CMSampleBuffer) -> Void) { queue.async { self.onAudioSample = handler } }
    func stopPreview() {
        queue.async {
            guard !self.recording, !self.finishing else { return }
            if self.session.isRunning { self.session.stopRunning() }
            if let input = self.audioInput {
                self.session.beginConfiguration()
                self.session.removeInput(input)
                self.session.removeOutput(self.audioOutput)
                self.audioInput = nil
                self.session.commitConfiguration()
            }
        }
    }
    @MainActor func switchCamera() {
        guard !isRecording, !isFinishing, !isSwitchingCamera else { return }
        isSwitchingCamera = true
        queue.async {
            guard !self.recording, !self.finishing else {
                DispatchQueue.main.async { self.isSwitchingCamera = false }; return
            }
            self.position = self.position == .front ? .back : .front
            self.configureCamera()
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.isSwitchingCamera = false }
        }
    }
    func setQuality(_ value: RecordingQuality) {
        queue.async {
            guard !self.recording, !self.finishing, let device = self.cameraInput?.device else { return }
            self.quality = self.format(for: value, device: device) == nil ? .hd30 : value
            self.session.beginConfiguration()
            self.applyQuality(device)
            self.session.commitConfiguration()
        }
    }

    func enableAudio() async -> Bool {
        var allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
        guard allowed, !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                do {
                    let audio = AVAudioSession.sharedInstance()
                    try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker, .allowBluetooth])
                    try audio.setActive(true)
                    if self.audioInput == nil {
                        guard let mic = AVCaptureDevice.default(for: .audio) else { continuation.resume(returning: false); return }
                        let input = try AVCaptureDeviceInput(device: mic)
                        self.session.beginConfiguration()
                        guard self.session.canAddInput(input), self.session.canAddOutput(self.audioOutput) else {
                            self.session.commitConfiguration(); continuation.resume(returning: false); return
                        }
                        self.session.addInput(input)
                        self.session.addOutput(self.audioOutput)
                        self.audioOutput.setSampleBufferDelegate(self, queue: self.queue)
                        self.audioInput = input
                        self.session.commitConfiguration()
                    }
                    continuation.resume(returning: true)
                } catch { DispatchQueue.main.async { self.message = error.localizedDescription }; continuation.resume(returning: false) }
            }
        }
    }

    func availableMinutes(quality: RecordingQuality) -> (bytes: Int64, minutes: Int)? {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        guard let bytes = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage else { return nil }
        return (bytes, max(0, Int(Double(bytes) * 8 / Double(quality.bitrate + 128_000) / 60)))
    }

    func start(orientation: UIInterfaceOrientation, watermark: Bool, trialEligible: Bool) async -> Bool {
        guard await MainActor.run(body: { !self.isSwitchingCamera }), !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            queue.async {
                guard !self.recording, !self.finishing, let device = self.cameraInput?.device else { continuation.resume(returning: false); return }
                if self.captureDeviceID != device.uniqueID || self.captureCoordinator == nil {
                    self.captureCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
                    self.captureDeviceID = device.uniqueID
                }
                guard let captureAngle = self.captureCoordinator?.videoRotationAngleForHorizonLevelCapture else { continuation.resume(returning: false); return }
                do {
                    let directory = VideoSaver.recordingsDirectory(demo: Demo.enabled)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                    try VideoSaver.writeMetadata(url: url, watermark: watermark, trialEligible: trialEligible)
                    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                    writer.movieFragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)
                    self.writer = writer
                    self.outputURL = url
                    self.videoWriter = nil
                    self.audioWriter = nil
                    self.startTime = nil
                    self.lastTime = nil
                    self.interrupted = false
                    self.failureHandled = false
                    if let connection = self.videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(captureAngle) {
                        connection.videoRotationAngle = captureAngle
                        if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
                    }
                    self.recording = true
                    DispatchQueue.main.async {
                        self.previewFrozen = true
                        if let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelPreview { self.updatePreviewAngle(angle) }
                        AppDelegate.lock(orientation); self.isRecording = true
                    }
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume(returning: true)
                } catch { DispatchQueue.main.async { self.message = error.localizedDescription }; continuation.resume(returning: false) }
            }
        }
    }

    func stop() { queue.async { self.finish(interruption: false) } }

    private func finish(interruption: Bool) {
        guard recording, !finishing else { return }
        recording = false
        finishing = true
        interrupted = interruption
        DispatchQueue.main.async {
            self.isRecording = false
            self.isFinishing = true
            AppDelegate.lock(nil)
            self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Finish recording") { [weak self] in
                guard let self, self.backgroundTask != .invalid else { return }
                UIApplication.shared.endBackgroundTask(self.backgroundTask)
                self.backgroundTask = .invalid
            }
        }
        guard let writer, let url = outputURL else { complete(nil, duration: 0, interruption: interruption); return }
        let duration = startTime.flatMap { start in lastTime.map { max(0, CMTimeGetSeconds($0 - start)) } } ?? 0
        if writer.status == .writing {
            videoWriter?.markAsFinished()
            audioWriter?.markAsFinished()
            writer.finishWriting {
                self.queue.async { self.complete(url, duration: duration, interruption: interruption || writer.status != .completed) }
            }
        } else {
            if writer.status == .unknown { writer.cancelWriting() }
            complete(url, duration: duration, interruption: interruption || writer.status == .failed)
        }
    }

    private func complete(_ url: URL?, duration: Double, interruption: Bool) {
        let writerError = writer?.error
        writer = nil; videoWriter = nil; audioWriter = nil; finishing = false
        DispatchQueue.main.async {
            self.isFinishing = false
            self.previewFrozen = false
            if let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelPreview { self.updatePreviewAngle(angle) }
            if let writerError { self.message = L("录制写入中断，已保留文件。") + "\n" + writerError.localizedDescription }
            if let url { self.onFinished?(url, duration, interruption) }
            if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let isVideo = output === videoOutput
        if !isVideo { onAudioSample?(sampleBuffer) }
        guard recording, let writer else { return }
        if writer.status == .failed || writer.status == .cancelled { failWritingOnce(); return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if writer.status == .unknown, isVideo {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
            let size = CMVideoFormatDescriptionGetDimensions(description)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: quality.bitrate, AVVideoExpectedSourceFrameRateKey: quality.fps]])
            video.expectsMediaDataInRealTime = true
            guard writer.canAdd(video) else { failWritingOnce(); return }
            writer.add(video)
            videoWriter = video
            if audioInput != nil {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128000])
                audio.expectsMediaDataInRealTime = true
                if writer.canAdd(audio) { writer.add(audio); audioWriter = audio }
            }
            guard writer.startWriting() else { failWritingOnce(); return }
            writer.startSession(atSourceTime: time)
            startTime = time
        }
        guard writer.status == .writing, let startTime, time >= startTime else { return }
        let input = isVideo ? videoWriter : audioWriter
        if let input, input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) { failWritingOnce(); return }
            if isVideo { lastTime = time }
        }
        if writer.status == .failed || writer.status == .cancelled { failWritingOnce() }
    }

    private func failWritingOnce() {
        guard !failureHandled else { return }
        failureHandled = true
        finish(interruption: true)
    }
}

struct CameraPreview: UIViewRepresentable {
    let camera: CameraRecorder
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.preview.videoGravity = .resizeAspectFill
        view.preview.session = camera.session
        camera.attachPreview(view.preview)
        return view
    }
    func updateUIView(_ view: Surface, context: Context) {}
}
