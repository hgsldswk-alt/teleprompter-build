import SwiftUI
import AVFoundation

@MainActor
struct PrompterView: View {
    let script: Script
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var store: ScriptStore
    @EnvironmentObject private var purchases: PurchaseStore
    @EnvironmentObject private var videos: VideoSaver
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @StateObject private var camera = CameraRecorder()
    @StateObject private var speech = SpeechFollower()
    @StateObject private var floating = FloatingPrompter()
    @State private var running = false
    @State private var starting = false
    @State private var countdownValue = 0
    @State private var startTask: Task<Void, Never>?
    @State private var voiceStartTask: Task<Void, Never>?
    @State private var voiceStartID: UInt64 = 0
    @State private var pageVisible = false
    @State private var stagingRecording = false
    @State private var showAppearance = false
    @State private var showPaywall = false
    @State private var showRemote = false
    @State private var showMilestone = false
    @State private var showSpaceWarning = false
    @State private var lowSpaceMinutes = 0
    @State private var offset = 0
    @State private var targetOffset = 0
    @State private var tokens: [VoiceAligner.Token] = []
    @State private var tokenizationReady = false
    @State private var recordingStart: Date?
    @State private var now = Date()
    @State private var continuousStart: Date?
    @State private var promptCharged = false
    @State private var sessionHasPro = false
    @State private var takeTrialNumber: Int?
    @State private var takeUsedVoice = false
    @State private var takeUninterrupted = false
    @State private var saveSession: RecordingSaveSession?
    @State private var showSave = false
    @State private var showTrialEnd = false
    @State private var voiceSession = false
    @State private var completed = false
    @State private var completionEligible = false
    @State private var closing = false
    @State private var notice: String?
    @State private var share: ShareItems?

    private var cameraMode: Bool { settings.value.cameraMode }
    private var quality: RecordingQuality { RecordingQuality(rawValue: settings.value.recordingQuality) ?? .hd30 }
    private var effectiveQuality: RecordingQuality { purchases.entitlement.hasProFeatures && camera.supportedQualities.contains(quality) ? quality : .hd30 }
    private var textSettings: PromptSettings {
        var value = settings.value
        if value.scrollMode == .voice && !purchases.entitlement.hasProFeatures && !sessionHasPro { value.scrollMode = .constant }
        return value
    }
    private var timerText: String { durationText(Int(now.timeIntervalSince(recordingStart ?? now))) }
    private var keepScreenAwake: Bool {
        pageVisible && !closing && phase == .active && (camera.isRecording ||
            (running && offset < (tokens.last?.end ?? 0) &&
                (textSettings.scrollMode == .constant || (textSettings.scrollMode == .voice && speech.active))) ||
            (floating.active && floating.playing))
    }
    private var showTrialBadge: Bool {
        !Launch.isFree && !purchases.entitlement.isPro && purchases.entitlement.remainingTrialTakes > 0
    }
    private var paywallShown: Binding<Bool> {
        Binding(get: { !Launch.isFree && showPaywall }, set: { showPaywall = $0 })
    }
    private var trialEndShown: Binding<Bool> {
        Binding(get: { !Launch.isFree && showTrialEnd }, set: { showTrialEnd = $0 })
    }
    private var actionBlocked: Bool {
        showRemote || starting || stagingRecording || camera.isFinishing || camera.isSwitchingCamera ||
            videos.saving || videos.recovering || showSave || floating.active || floating.requested || closing
    }

    private var stage: some View {
        GeometryReader { geometry in
            ZStack {
                Design.ink.ignoresSafeArea()
                cameraBackdrop
                column(geometry)
                if countdownValue > 0 {
                    Text(String(countdownValue)).font(.system(size: 100, weight: .semibold, design: .rounded))
                        .foregroundStyle(Design.amber).shadow(radius: 20).id(countdownValue).transition(.opacity.combined(with: .scale))
                        .accessibilityIdentifier("countdown")
                }
                FloatingSurface(floating: floating).frame(width: 4, height: 3).opacity(0.02).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var cameraBackdrop: some View {
        if cameraMode {
            if camera.isAvailable { CameraPreview(camera: camera).ignoresSafeArea() }
            else if Demo.has("-camera") {
                GeometryReader { g in
                    Image("DemoFrame").resizable().scaledToFill().frame(width: g.size.width, height: g.size.height).clipped()
                }.ignoresSafeArea()
            } else {
                LinearGradient(colors: [Color(hex: 0x1D282E), Color(hex: 0x101216), Color(hex: 0x352B21)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
                if !Demo.has("-camera") {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.slash").font(.largeTitle)
                        Text(camera.cameraDenied ? L("请允许相机访问，或切换仅提词。") : L("此设备没有可用摄像头，可使用仅提词。"))
                        if camera.cameraDenied { Button(L("去设置打开")) { openSystemSettings() } }
                    }.font(.subheadline).multilineTextAlignment(.center).padding().frame(maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }

    private func column(_ geometry: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            header
            if showTrialBadge {
                Text(String(format: L("全功能体验 · 还剩 %d 条"), purchases.entitlement.remainingTrialTakes))
                    .font(.caption).foregroundStyle(Design.amber.opacity(0.9))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .overlay(Capsule().strokeBorder(Design.amber.opacity(0.45), lineWidth: 0.7))
                    .accessibilityIdentifier("trialBadge")
            }
            ZStack(alignment: .top) {
                PrompterTextView(text: script.body, tokens: tokens, settings: textSettings, running: running, targetOffset: targetOffset,
                    onManualSeek: { value in completionEligible = false; takeUninterrupted = false; offset = value; targetOffset = value; speech.manualPosition(value) },
                    onProgress: { offset = $0 }, onTap: { if running || camera.isRecording { Task { await toggleScroll() } } })
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                                 .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                    .background(Design.ink.opacity(cameraMode ? settings.value.backgroundOpacity : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                GeometryReader { region in
                    Rectangle().fill(Design.amber.opacity(0.8)).frame(height: 1)
                        .padding(.horizontal, 12).offset(y: region.size.height * Design.readingLineRatio(mirrorVertical: settings.value.mirrorVertical))
                }.allowsHitTesting(false)
            }
            .frame(height: geometry.size.width > geometry.size.height ? nil : max(80, min(geometry.size.height * settings.value.heightRatio, geometry.size.height - 280)))
            .frame(minHeight: 50)
            if geometry.size.width <= geometry.size.height { Spacer(minLength: 0) }
            if let notice {
                HStack(alignment: .top, spacing: 8) {
                    Text(notice).font(.caption).lineLimit(geometry.size.width > geometry.size.height ? 2 : 4).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { self.notice = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel(L("关闭提示"))
                }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            if completed {
                HStack {
                    Text(L("一遍过！")).font(.headline)
                    Spacer()
                    if videos.canShareLastSaved {
                        Button {
                            Task { if let url = await videos.prepareLastSavedShare() { share = ShareItems(items: [url]) } }
                        } label: {
                            if videos.preparingShare { ProgressView() } else { Text(L("分享成片")) }
                        }.disabled(videos.preparingShare)
                    }
                }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            controls
        }.padding(.horizontal, geometry.size.width > 600 ? 32 : 16).padding(.vertical, 8)
    }

    private var remoteControl: some View {
        let sheetsOpen = showAppearance || showPaywall || showTrialEnd
        return RemoteControl(cameraEnabled: cameraMode && camera.isAvailable && !showRemote && !actionBlocked && !sheetsOpen,
            keysEnabled: !actionBlocked && !sheetsOpen,
            onKey: handleKey, onCapture: { if allowRemote() { primaryAction() } }).frame(width: 1, height: 1)
    }

    private var decorated: some View {
        stage
        .foregroundStyle(Design.warmWhite).preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear { pageVisible = true }
        .onChange(of: keepScreenAwake, initial: true) { _, _ in updateIdleTimer() }
        .background(remoteControl)
        .sheet(isPresented: $showAppearance) { AppearanceSettingsView() }
        .sheet(isPresented: paywallShown) { PaywallView() }
        .sheet(isPresented: $showSave, onDismiss: saveSheetDismissed) { if let session = saveSession { SaveSheet(session: session) } }
        .sheet(isPresented: trialEndShown) { TrialEndView() }
        .sheet(isPresented: $showRemote) { RemoteTestView() }
        .sheet(isPresented: $showMilestone) { MilestoneCard() }
        .sheet(item: $share) { ActivitySheet(items: $0.items) }
        .confirmationDialog(L("剩余空间可能不够"), isPresented: $showSpaceWarning, titleVisibility: .visible) {
            Button(L("继续录制")) { beginStart() }
            Button(L("取消"), role: .cancel) {}
        } message: { Text(String(format: L("按当前画质估算，剩余空间约可录 %d 分钟。"), lowSpaceMinutes)) }
    }

    private func saveSheetDismissed() {
        guard let session = saveSession else { return }
        Task {
            await session.save(watermark: session.trialNumber == nil && !purchases.entitlement.hasProFeatures, videos: videos)
            presentTrialEndIfReady()
            if closing { dismiss() }
        }
    }

    private func setUp() async {
        offset = script.readingOffset
        targetOffset = script.readingOffset
        speech.recheckPermissions()
        tokens = await Task.detached(priority: .userInitiated) { VoiceAligner.tokenize(script.body) }.value
        guard !Task.isCancelled else { return }
        tokenizationReady = true
        speech.onPosition = { position in
            guard running, pageVisible, !closing else { return }
            offset = position.characterOffset
            targetOffset = offset
            if position.tokenIndex >= tokens.count, completionEligible, !completed {
                completed = true
                if !UserDefaults.standard.bool(forKey: "firstVoiceCompletion") {
                    UserDefaults.standard.set(true, forKey: "firstVoiceCompletion")
                    notice = L("一遍过！录完后可以分享成片。")
                }
            }
        }
        speech.onUnavailable = { takeUninterrupted = false; pauseVoice(); settings.value.scrollMode = .constant }
        camera.setAudioHandler { [weak speech] in speech?.append($0) }
        camera.onFinished = { url, duration, interrupted in
            running = false
            endVoiceSession()
            recordingStart = nil
            sessionHasPro = false
            stagingRecording = true
            let voice = takeUsedVoice
            let uninterrupted = takeUninterrupted && completionEligible && completed && !interrupted
            let eligible = takeTrialNumber != nil
            Task {
                let video = await videos.stage(url, duration: duration, voice: voice,
                                               uninterrupted: uninterrupted, trialEligible: eligible)
                saveSession = RecordingSaveSession(video: video, trialNumber: video.trialNumber, interrupted: interrupted)
                stagingRecording = false
                showSave = true
            }
        }
        camera.setQuality(effectiveQuality)
        if Demo.has("-settings") { showAppearance = true }
        if Demo.has("-savesheet") {
            saveSession = RecordingSaveSession(video: nil, trialNumber: nil)
            showSave = true
        }
        if Demo.has("-trialend") { showTrialEnd = true }
        if settings.value.scrollMode == .voice && !purchases.entitlement.hasProFeatures { settings.value.scrollMode = .constant }
    }

    private func pageClosed() {
        pageVisible = false
        running = false
        updateIdleTimer()
        startTask?.cancel()
        finishContinuousPrompt()
        endVoiceSession()
        floating.stop()
        if camera.isRecording { camera.stop() }
        camera.stopPreview()
        store.updatePosition(id: script.id, offset: offset)
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + DispatchTimeInterval.seconds(1)) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        AppDelegate.lock(nil)
    }

    var body: some View {
        decorated
        .task { await setUp() }
        .task(id: cameraMode) {
            if cameraMode { await camera.prepare(); if !Task.isCancelled { camera.preview() } }
            else { camera.stopPreview() }
        }
        .onChange(of: settings.value.scrollMode) { _, mode in
            takeUninterrupted = false
            endVoiceSession()
            if running, mode == .voice { scheduleVoiceStart() }
        }
        .onChange(of: settings.value.recognitionLanguage) { _, _ in
            takeUninterrupted = false
            if running, settings.value.scrollMode == .voice { pauseVoice(); scheduleVoiceStart() }
        }
        .onChange(of: settings.value.cameraMode) { _, _ in startTask?.cancel(); finishContinuousPrompt(); running = false; endVoiceSession() }
        .onChange(of: phase) { _, value in
            if value == .active { speech.recheckPermissions() }
            if value == .background, !floating.active {
                startTask?.cancel()
                finishContinuousPrompt()
                running = false; takeUninterrupted = false; endVoiceSession()
                if camera.isRecording { camera.stop() }
                store.updatePosition(id: script.id, offset: offset)
            }
            if value == .active, cameraMode, !camera.isRecording, !floating.active {
                Task { await camera.prepare(); camera.preview() }
            }
        }
        .onChange(of: floating.playing) { _, value in
            if floating.active {
                if value && purchases.entitlement.hasProFeatures { continuousStart = Date(); promptCharged = false }
                else if value { floating.stop(); showPaywall = true }
                else { finishContinuousPrompt() }
            }
        }
        .onChange(of: floating.active) { _, value in
            if value { continuousStart = Date(); promptCharged = false }
            else { finishContinuousPrompt() }
            if !value, phase == .active, cameraMode, !closing { camera.preview() }
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            now = value
            chargePromptIfNeeded()
            presentTrialEndIfReady()
        }
        .onChange(of: camera.message) { _, message in notice = message }
        .onChange(of: settings.value.recordingQuality) { _, _ in camera.setQuality(effectiveQuality) }
        .onChange(of: purchases.entitlement.hasProFeatures) { _, enabled in
            if !camera.isRecording { camera.setQuality(effectiveQuality) }
            if !enabled && !sessionHasPro && settings.value.scrollMode == .voice { settings.value.scrollMode = .constant }
        }
        .onChange(of: camera.supportedQualities) { _, _ in camera.setQuality(effectiveQuality) }
        .onChange(of: speech.message) { _, message in notice = message }
        .onChange(of: floating.message) { _, message in notice = message }
        .onChange(of: videos.message) { _, message in notice = message; videos.message = nil }
        .onDisappear(perform: pageClosed)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { close() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle()) }
                .accessibilityLabel(L("关闭提词")).accessibilityIdentifier("closePrompter")
            Picker(L("提词模式"), selection: $settings.value.cameraMode) {
                Text(L("拍摄")).tag(true)
                Text(L("仅提词")).tag(false)
            }.pickerStyle(.segmented).disabled(camera.isRecording || camera.isFinishing || starting).accessibilityIdentifier("promptMode")
            if cameraMode {
                Button { camera.switchCamera() } label: { Image(systemName: "arrow.triangle.2.circlepath.camera").frame(width: 44, height: 44) }
                    .disabled(camera.isRecording || camera.isFinishing || camera.isSwitchingCamera || starting).accessibilityLabel(L("切换摄像头")).accessibilityIdentifier("switchCamera")
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    scrollOption(.voice, title: L("语音跟随"))
                    scrollOption(.constant, title: L("匀速"))
                    scrollOption(.manual, title: L("手动"))
                }.padding(3).background(Design.ink.opacity(0.65), in: Capsule())
                    .accessibilityElement(children: .contain).accessibilityIdentifier("scrollMode")
                Button { showAppearance = true } label: { Text("Aa").font(.title3.weight(.medium)).frame(width: 44, height: 44) }
                    .accessibilityLabel(L("文字设置")).accessibilityIdentifier("openAppearance")
            }
            if textSettings.scrollMode == .constant {
                HStack(spacing: 12) {
                    Image(systemName: "speedometer").accessibilityHidden(true)
                    Slider(value: $settings.value.speed, in: 0.5...2, step: 0.05).accessibilityLabel(L("滚动速度")).accessibilityIdentifier("scrollSpeed")
                    Text(String(format: script.containsHan ? L("约 %.0f 字/分") : L("约 %.0f wpm"),
                                       (script.containsHan ? settings.value.chineseRate : settings.value.englishRate) * settings.value.speed))
                        .font(.caption.monospacedDigit()).fixedSize()
                }.frame(minHeight: 44)
            }
            HStack {
                Menu {
                    Button { if purchases.entitlement.hasProFeatures { showRemote = true } else { showPaywall = true } } label: {
                        Label(L("测试翻页笔"), systemImage: purchases.entitlement.hasProFeatures ? "keyboard" : "lock.fill")
                    }
                    if !purchases.entitlement.hasProFeatures {
                        Button(L("你的设置还在，买断后立即恢复")) { showPaywall = true }
                    }
                    if cameraMode {
                        ForEach(camera.supportedQualities, id: \.self) { candidate in
                            Button {
                                if candidate == .hd30 || purchases.entitlement.hasProFeatures {
                                    settings.value.recordingQuality = candidate.rawValue
                                    camera.setQuality(effectiveQuality)
                                } else { showPaywall = true }
                            } label: {
                                Label(candidate.title, systemImage: candidate != .hd30 && !purchases.entitlement.hasProFeatures ? "lock.fill" : quality == candidate ? "checkmark" : "camera")
                            }.disabled(camera.isRecording || camera.isFinishing)
                        }
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "ellipsis.circle")
                        if cameraMode {
                            HStack(spacing: 3) {
                                Text(camera.isRecording ? camera.actualQuality.title : quality.title)
                                if quality != .hd30 && !purchases.entitlement.hasProFeatures { Image(systemName: "lock.fill") }
                            }.font(.system(size: 10).monospacedDigit())
                        }
                    }.frame(width: 72, height: 44)
                }.accessibilityLabel(L("更多控制")).accessibilityIdentifier("moreControls")
                Spacer(minLength: 8)
                if cameraMode {
                    VStack(spacing: 4) {
                        RecordButton(recording: camera.isRecording, action: primaryAction)
                            .disabled(!camera.isAvailable || actionBlocked || !tokenizationReady)
                        if camera.isRecording {
                            HStack(spacing: 5) {
                                Circle().fill(Design.record).frame(width: 6, height: 6).opacity(Int(now.timeIntervalSince1970) % 2 == 0 ? 1 : 0.25)
                                Text(timerText).monospacedDigit()
                            }.font(.caption)
                        }
                    }
                    if camera.isRecording {
                        Button { Task { await toggleScroll() } } label: { Image(systemName: running ? "pause" : "play").frame(width: 44, height: 44) }
                            .accessibilityLabel(running ? L("暂停提词") : L("继续提词")).accessibilityIdentifier("pauseScroll")
                    }
                } else {
                    Button { primaryAction() } label: {
                        Label(running ? L("暂停") : L("开始"), systemImage: running ? "pause" : "play").frame(minWidth: 72)
                    }.buttonStyle(PrimaryButtonStyle()).disabled(starting || !tokenizationReady).accessibilityIdentifier("startScroll")
                }
                Spacer(minLength: 8)
                if FloatingPrompter.supported {
                    Button {
                        guard purchases.entitlement.hasProFeatures else { showPaywall = true; return }
                        if camera.isRecording || camera.isFinishing { notice = L("请先结束录制，再开启悬浮提词。"); return }
                        finishContinuousPrompt()
                        running = false
                        endVoiceSession()
                        camera.stopPreview()
                        notice = L("悬浮提词使用匀速滚动，其他 App 可使用麦克风。")
                        floating.start(text: script.body, offset: offset, settings: settings.value, tokens: tokens)
                    } label: { VStack(spacing: 4) {
                        HStack(spacing: 3) {
                            Image(systemName: "pip.enter")
                            if !purchases.entitlement.hasProFeatures { Image(systemName: "lock.fill").font(.caption2) }
                        }
                        Text(L("悬浮")).font(.caption2)
                    }.frame(width: 72, height: 44) }
                        .disabled(!tokenizationReady || starting || stagingRecording || floating.requested).accessibilityLabel(L("悬浮提词")).accessibilityIdentifier("startFloating")
                } else { Color.clear.frame(width: 72, height: 1) }
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
    }

    private func primaryAction() {
        guard !actionBlocked, !showAppearance, !showPaywall, !showTrialEnd else { return }
        if camera.isRecording { running = false; endVoiceSession(); camera.stop(); return }
        if running { finishContinuousPrompt(); running = false; endVoiceSession(); return }
        if cameraMode, let space = camera.availableMinutes(quality: effectiveQuality), space.bytes < 1_000_000_000 {
            lowSpaceMinutes = space.minutes; showSpaceWarning = true; return
        }
        beginStart()
    }

    private func beginStart() {
        guard tokenizationReady, pageVisible, !actionBlocked else { return }
        starting = true
        startTask = Task {
            defer { starting = false; countdownValue = 0 }
            if settings.value.countdown, !camera.isRecording {
                for count in stride(from: 3, through: 1, by: -1) {
                    withAnimation(.easeOut(duration: 0.2)) { countdownValue = count }
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
            guard !Task.isCancelled else { return }
            sessionHasPro = purchases.entitlement.hasProFeatures
            completed = false
            completionEligible = offset == 0
            if cameraMode, !camera.isRecording {
                takeTrialNumber = !Launch.isFree && !purchases.entitlement.isPro && purchases.entitlement.remainingTrialTakes > 0 ? purchases.entitlement.trialTakesUsed + 1 : nil
                takeUsedVoice = false
                takeUninterrupted = offset == 0 && settings.value.scrollMode == .voice
                camera.setQuality(effectiveQuality)
                let audio = await camera.enableAudio()
                guard !Task.isCancelled else { return }
                if !audio { speech.markMicrophoneUnavailable(); notice = L("麦克风权限未开启，本次录制无声。"); settings.value.scrollMode = .constant }
                if settings.value.scrollMode == .voice { await startVoice() }
                guard !Task.isCancelled else { return }
                let orientation = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.interfaceOrientation ?? .portrait
                guard await camera.start(orientation: orientation, watermark: !sessionHasPro, trialEligible: takeTrialNumber != nil) else { endVoiceSession(); return }
                guard !Task.isCancelled else { camera.stop(); return }
                recordingStart = Date()
            }
            running = true
            if !cameraMode, settings.value.scrollMode == .voice { await startVoice() }
            guard !Task.isCancelled else { return }
            if !cameraMode { continuousStart = Date(); promptCharged = false }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func toggleScroll() async {
        guard !actionBlocked, pageVisible, !Task.isCancelled else { return }
        if running { finishContinuousPrompt(); running = false; takeUninterrupted = false; endVoiceSession() }
        else {
            running = true
            if !cameraMode { sessionHasPro = purchases.entitlement.hasProFeatures }
            if settings.value.scrollMode == .voice { await startVoice() }
            if !cameraMode, running, pageVisible, !closing { continuousStart = Date(); promptCharged = false }
        }
    }

    private func startVoice() async {
        let id = voiceStartID
        guard !Task.isCancelled, pageVisible, !closing, phase != .background else { return }
        guard purchases.entitlement.hasProFeatures || sessionHasPro else {
            settings.value.scrollMode = .constant
            return
        }
        if cameraMode {
            guard camera.isAvailable else { settings.value.scrollMode = .constant; notice = L("此设备没有可用摄像头，可使用仅提词。"); return }
            let enabled = await camera.enableAudio()
            guard id == voiceStartID, !Task.isCancelled else { return }
            guard enabled else { speech.markMicrophoneUnavailable(); settings.value.scrollMode = .constant; notice = L("麦克风权限未开启，已切换匀速。"); return }
        }
        let override = settings.value.recognitionLanguage
        let language = override == "auto" ? script.recognitionLanguage : override
        let started = await speech.start(tokens: tokens, offset: offset, language: language, externalAudio: cameraMode)
        guard id == voiceStartID, !Task.isCancelled else { return }
        if started {
            if !voiceSession { completionEligible = offset == 0 }
            voiceSession = true
            if cameraMode { takeUsedVoice = true }
        } else { settings.value.scrollMode = .constant }
    }

    private func scheduleVoiceStart() {
        voiceStartTask?.cancel()
        voiceStartTask = Task { await startVoice() }
    }
    private func pauseVoice() {
        voiceStartID &+= 1
        voiceStartTask?.cancel(); voiceStartTask = nil
        speech.stop()
    }
    private func endVoiceSession() { pauseVoice(); voiceSession = false }
    private func updateIdleTimer() { UIApplication.shared.isIdleTimerDisabled = keepScreenAwake }

    private func chargePromptIfNeeded() {
        guard !promptCharged, let continuousStart, Date().timeIntervalSince(continuousStart) >= 60 else { return }
        purchases.finishPromptSession(continuousSeconds: Date().timeIntervalSince(continuousStart))
        promptCharged = true
    }
    private func finishContinuousPrompt() {
        chargePromptIfNeeded()
        continuousStart = nil
        sessionHasPro = false
        if !cameraMode && !purchases.entitlement.hasProFeatures && settings.value.scrollMode == .voice {
            endVoiceSession()
            settings.value.scrollMode = .constant
        }
    }
    private func presentTrialEndIfReady() {
        guard purchases.canPresentTrialEnd, !showSave, !showPaywall, !showAppearance, !showRemote,
              !camera.isRecording, !actionBlocked, !running else { return }
        showTrialEnd = true
    }
    private func allowRemote() -> Bool {
        if purchases.entitlement.hasProFeatures { return settings.value.remoteEnabled }
        if purchases.shouldPromptForRemote() { showPaywall = true }
        return false
    }

    private func scrollOption(_ mode: ScrollMode, title: String) -> some View {
        let locked = mode == .voice && !purchases.entitlement.hasProFeatures
        let selected = textSettings.scrollMode == mode
        return Button {
            if locked { showPaywall = true }
            else if mode == .voice && speech.unavailable { notice = L("麦克风权限未开启，已切换匀速。") }
            else { settings.value.scrollMode = mode }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if locked { Image(systemName: "lock.fill").font(.caption2) }
            }.font(.caption.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(selected ? Design.amber : Design.warmWhite.opacity(0.7))
                .overlay(Capsule().strokeBorder(selected ? Design.amber.opacity(0.65) : .clear, lineWidth: 0.7))
        }.buttonStyle(.plain).accessibilityIdentifier("scroll-" + mode.rawValue)
            .accessibilityLabel(title + (locked ? " · " + L("买断解锁") : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func handleKey(_ key: String) {
        guard !actionBlocked, !showAppearance, !showPaywall, !showTrialEnd, allowRemote() else { return }
        if key == "\r" {
            if cameraMode { Task { await toggleScroll() } }
            else { primaryAction() }
            return
        }
        let ns = script.body as NSString
        let location = min(max(0, offset), ns.length)
        let next: Int
        let paragraph = ns.paragraphRange(for: NSRange(location: min(location, max(0, ns.length - 1)), length: 0))
        if key == UIKeyCommand.inputUpArrow || key == UIKeyCommand.inputPageUp {
            next = ns.paragraphRange(for: NSRange(location: max(0, paragraph.location - 1), length: 0)).location
        } else {
            next = min(ns.length, NSMaxRange(paragraph))
        }
        offset = next; targetOffset = next; speech.manualPosition(next)
        completionEligible = false
        takeUninterrupted = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    private func close() {
        startTask?.cancel()
        finishContinuousPrompt()
        running = false
        endVoiceSession()
        floating.stop()
        store.updatePosition(id: script.id, offset: offset)
        if camera.isRecording { closing = true; camera.stop() }
        else if camera.isFinishing || videos.saving || stagingRecording { closing = true }
        else { dismiss() }
    }
    private func openSystemSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    settingSlider(L("字号"), value: $settings.value.fontSize, range: 22...72, step: 1, id: "fontSize")
                    settingSlider(L("行距"), value: $settings.value.lineSpacing, range: 0...36, step: 1, id: "lineSpacing")
                    settingSlider(L("文字区域高度"), value: $settings.value.heightRatio, range: 0.25...0.85, step: 0.05, id: "textHeight")
                    settingSlider(L("左右边距"), value: $settings.value.margin, range: 8...80, step: 2, id: "textMargin")
                    settingSlider(L("背景透明度"), value: $settings.value.backgroundOpacity, range: 0...1, step: 0.05, id: "backgroundOpacity")
                    Picker(L("文字颜色"), selection: $settings.value.textColor) {
                        Text(L("暖白")).tag(PromptColor.warmWhite)
                        Text(L("纯白")).tag(PromptColor.white)
                        Text(L("琥珀金")).tag(PromptColor.amber)
                        Text(L("浅绿")).tag(PromptColor.green)
                    }
                }
                Section {
                    Toggle(L("水平镜像"), isOn: $settings.value.mirrorHorizontal).accessibilityIdentifier("mirrorHorizontal")
                    Toggle(L("垂直镜像"), isOn: $settings.value.mirrorVertical).accessibilityIdentifier("mirrorVertical")
                    Toggle(L("开始前倒计时"), isOn: $settings.value.countdown).accessibilityIdentifier("countdownToggle")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(L("文字设置")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("完成")) { dismiss() }.accessibilityIdentifier("closeAppearance") } }
        }
        .presentationDetents([.fraction(0.45), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.45)))
        .presentationBackground(.ultraThinMaterial)
        .presentationDragIndicator(.visible)
    }
    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title); Spacer(); Text(range.upperBound <= 1 ? String(format: "%.0f%%", value.wrappedValue * 100) : String(format: "%.0f", value.wrappedValue)).foregroundStyle(.secondary).monospacedDigit() }
            Slider(value: value, in: range, step: step).accessibilityLabel(title).accessibilityIdentifier(id)
        }.padding(.vertical, 4)
    }
}
