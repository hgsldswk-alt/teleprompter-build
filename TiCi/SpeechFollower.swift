import Foundation
import Speech
import AVFoundation
import Combine

private final class SpeechAudioMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func replace(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); defer { lock.unlock() }
        request?.endAudio()
        request = next
    }
    func append(_ sample: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.appendAudioSampleBuffer(sample)
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        request?.append(buffer)
    }
}

@MainActor
final class SpeechFollower: NSObject, ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var unavailable = false
    @Published var message: String?
    var onPosition: ((VoiceAligner.Position) -> Void)?
    var onUnavailable: (() -> Void)?
    nonisolated private let mailbox = SpeechAudioMailbox()
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var engine: AVAudioEngine?
    private var timer: Timer?
    private var startTask: Task<Bool, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var tokens: [VoiceAligner.Token] = []
    private var position = 0
    private var running = false
    private var externalAudio = false
    private var interrupted = false
    private var sessionToken: UInt64 = 0
    private var generation: UInt64 = 0
    private var recentErrors = 0
    private var observers: [NSObjectProtocol] = []
    private struct DrainingTask {
        let task: SFSpeechRecognitionTask
        let deadline: TimeInterval
    }
    private var draining: [UInt64: DrainingTask] = [:]
    private var lastHeard: [UInt64: String] = [:]

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                if type == .began {
                    self.interrupted = true
                    self.pauseResources()
                } else if type == .ended, options.contains(.shouldResume) || self.running {
                    self.interrupted = false
                    self.scheduleRecovery()
                }
            }
        })
        for name in [Notification.Name.AVAudioEngineConfigurationChange, AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.routeChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let source = note.object as? AVAudioEngine
                let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                if name == AVAudioSession.routeChangeNotification, reason != .newDeviceAvailable, reason != .oldDeviceUnavailable { return }
                Task { @MainActor [weak self] in
                    guard let self, self.running, !self.interrupted else { return }
                    if name == AVAudioSession.routeChangeNotification, self.externalAudio { return }
                    if let source, source !== self.engine || source.isRunning { return }
                    self.scheduleRecovery()
                }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func recheckPermissions() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let speech = SFSpeechRecognizer.authorizationStatus()
        unavailable = microphone == .denied || microphone == .restricted || speech == .denied || speech == .restricted
    }
    func markMicrophoneUnavailable() { unavailable = true }

    func start(tokens prepared: [VoiceAligner.Token], offset: Int, language: String, externalAudio: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        stop()
        let token = sessionToken
        let work = Task { await self.configure(tokens: prepared, offset: offset, language: language, externalAudio: externalAudio, token: token) }
        startTask = work
        let result = await work.value
        guard token == sessionToken, !Task.isCancelled else {
            if token == sessionToken { stop() }
            return false
        }
        startTask = nil
        return result
    }
    private func isCurrent(_ token: UInt64) -> Bool { token == sessionToken && !Task.isCancelled }

    private func configure(tokens prepared: [VoiceAligner.Token], offset: Int, language: String, externalAudio: Bool, token: UInt64) async -> Bool {
        guard isCurrent(token) else { return false }
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard isCurrent(token) else { return false }
        guard speechStatus == .authorized else { fail(L("语音识别权限未开启，已切换匀速。")); return false }
        var microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { microphone = await AVCaptureDevice.requestAccess(for: .audio) }
        guard isCurrent(token) else { return false }
        guard microphone else { fail(L("麦克风权限未开启，已切换匀速。")); return false }
        let candidates = language == "zh-TW" ? ["zh-TW", "zh-CN"] : [language]
        guard let recognizer = candidates.compactMap({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }).first(where: { $0.supportsOnDeviceRecognition && $0.isAvailable }) else {
            fail(L("此语言的设备端识别不可用，已切换匀速。")); return false
        }
        guard isCurrent(token) else { return false }
        self.tokens = prepared
        position = VoiceAligner.tokenIndex(at: offset, in: prepared)
        self.recognizer = recognizer
        self.externalAudio = externalAudio
        recentErrors = 0
        do {
            if !externalAudio { try installEngine() }
            guard isCurrent(token) else { pauseResources(); return false }
            running = true
            restartRequest()
            guard isCurrent(token) else { pauseResources(); return false }
            active = true
            unavailable = false
            startTimer()
            return true
        } catch { fail(L("麦克风暂不可用，已切换匀速。")); return false }
    }

    private func installEngine() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.allowBluetooth])
        try session.setActive(true)
        let next = AVAudioEngine()
        let input = next.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw EngineError.noInput }
        let sink = mailbox
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in sink.append(buffer) }
        do {
            next.prepare()
            try next.start()
            engine = next
        } catch {
            input.removeTap(onBus: 0)
            next.stop()
            throw error
        }
    }
    private enum EngineError: Error { case noInput }
    private func startTimer() {
        timer?.invalidate()
        let token = sessionToken
        timer = Timer.scheduledTimer(withTimeInterval: 48, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.sessionToken == token else { return }
                self.restartRequest()
            }
        }
    }
    nonisolated func append(_ sample: CMSampleBuffer) { mailbox.append(sample) }

    func manualPosition(_ offset: Int) {
        position = VoiceAligner.tokenIndex(at: offset, in: tokens)
        discardRequests()
        restartRequest()
    }
    private func expireDrainingTasks() {
        let expired = draining.filter { $0.value.deadline <= ProcessInfo.processInfo.systemUptime }.map { $0.key }
        for id in expired { draining.removeValue(forKey: id)?.task.cancel() }
    }
    private func restartRequest() {
        guard running, !interrupted, let recognizer else { return }
        expireDrainingTasks()
        if let task { draining[generation] = DrainingTask(task: task, deadline: ProcessInfo.processInfo.systemUptime + 2) }
        generation &+= 1
        let currentGeneration = generation
        let token = sessionToken
        let next = SFSpeechAudioBufferRecognitionRequest()
        next.requiresOnDeviceRecognition = true
        next.shouldReportPartialResults = true
        next.taskHint = .dictation
        mailbox.replace(next)
        task = recognizer.recognitionTask(with: next) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            let failed = error != nil
            Task { @MainActor [weak self] in
                await self?.handle(text: text, final: final, failed: failed, token: token, generation: currentGeneration)
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.sessionToken == token else { return }
            self.expireDrainingTasks()
        }
    }
    private func accepts(_ id: UInt64, final: Bool) -> Bool {
        id == generation || (final && (draining[id]?.deadline ?? 0) > ProcessInfo.processInfo.systemUptime)
    }
    private func handle(text: String?, final: Bool, failed: Bool, token: UInt64, generation id: UInt64) async {
        guard running, !interrupted, sessionToken == token, accepts(id, final: final) else { return }
        if let text, lastHeard[id] == text {
            if final { if id == generation { restartRequest() } else { draining.removeValue(forKey: id) } }
            return
        }
        if let text { lastHeard = [id: text] }
        if let text {
            let snapshot = tokens
            let from = position
            let aligned = await Task.detached(priority: .userInitiated) { VoiceAligner.align(tokens: snapshot, current: from, recognized: text) }.value
            guard running, !interrupted, sessionToken == token, accepts(id, final: final) else { return }
            recentErrors = 0
            if aligned.tokenIndex > position { position = aligned.tokenIndex; onPosition?(aligned) }
            if final {
                if id == generation { restartRequest() }
                else { draining.removeValue(forKey: id) }
            }
        } else if failed, id == generation {
            recentErrors += 1
            if recentErrors >= 3 { fail(L("设备端识别已中断，已切换匀速。")) }
            else {
                try? await Task.sleep(for: .milliseconds(500))
                guard isCurrent(token), running, id == generation else { return }
                restartRequest()
            }
        }
    }
    private func scheduleRecovery() {
        recoveryTask?.cancel()
        pauseResources()
        let token = sessionToken
        recoveryTask = Task {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard isCurrent(token), running, !interrupted else { return }
            do {
                if externalAudio { try AVAudioSession.sharedInstance().setActive(true) }
                else { try installEngine() }
                guard isCurrent(token) else { pauseResources(); return }
                restartRequest()
                active = true
                startTimer()
            } catch { fail(L("设备端识别已中断，已切换匀速。")) }
        }
    }
    private func discardRequests() {
        generation &+= 1
        mailbox.replace(nil)
        task?.cancel(); task = nil
        draining.values.forEach { $0.task.cancel() }; draining.removeAll()
    }
    private func pauseResources() {
        timer?.invalidate(); timer = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        discardRequests()
        active = false
    }
    private func fail(_ text: String) {
        stop()
        message = text
        unavailable = true
        onUnavailable?()
    }
    func stop() {
        sessionToken &+= 1
        startTask?.cancel(); startTask = nil
        recoveryTask?.cancel(); recoveryTask = nil
        running = false
        interrupted = false
        pauseResources()
        recognizer = nil
    }
}
