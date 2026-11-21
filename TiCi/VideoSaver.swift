import Foundation
import AVFoundation
import Photos
import UIKit
import Combine

struct PendingVideo: Identifiable {
    let url: URL
    var id: String { url.lastPathComponent }
    let needsWatermark: Bool
    var trialNumber: Int? = nil
}

@MainActor
final class VideoSaver: ObservableObject {
    @Published private(set) var pending: [PendingVideo] = []
    @Published private(set) var saving = false
    @Published private(set) var recovering = true
    @Published private(set) var preparingShare = false
    @Published var message: String?
    @Published var shareURL: URL?
    @Published private(set) var lastSavedVideo: PendingVideo?
    var canShareLastSaved: Bool { lastSavedVideo != nil }
    @Published var milestone = false
    @Published private(set) var savedCount: Int
    @Published private(set) var totalSeconds: Double
    private let demo: Bool
    private let defaults: UserDefaults
    private var inFlight: Set<String> = []
    private var reviewReady = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    var onRecorded: ((String, Double, Bool, Bool, Bool) -> Int?)?
    private var shareTasks: [String: Task<URL?, Never>] = [:]
    private struct Metadata: Codable {
        var watermark: Bool
        var duration: Double?
        var saved: Bool?
        var voice: Bool?
        var uninterrupted: Bool?
        var trialEligible: Bool?
    }

    init(demo: Bool = false) {
        self.demo = demo
        defaults = demo ? UserDefaults(suiteName: "TiCi.demo")! : .standard
        savedCount = defaults.integer(forKey: "savedVideos")
        totalSeconds = defaults.double(forKey: "savedSeconds")
        refreshPending()
    }

    nonisolated static func recordingsDirectory(demo: Bool = false) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(demo ? "DemoRecordings" : "Recordings", isDirectory: true)
    }
    nonisolated static func metadataURL(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("json") }
    nonisolated static func writeMetadata(url: URL, watermark: Bool, duration: Double? = nil, saved: Bool? = nil, voice: Bool? = nil, uninterrupted: Bool? = nil, trialEligible: Bool? = nil) throws {
        try JSONEncoder().encode(Metadata(watermark: watermark, duration: duration, saved: saved, voice: voice, uninterrupted: uninterrupted, trialEligible: trialEligible)).write(to: metadataURL(url), options: .atomic)
    }
    private var pendingDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(demo ? "DemoPending" : "Pending", isDirectory: true)
    }

    func refreshPending() {
        let manager = FileManager.default
        try? manager.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
        let recovered = (try? manager.contentsOfDirectory(at: Self.recordingsDirectory(demo: demo), includingPropertiesForKeys: nil)) ?? []
        var retainedSources: [URL] = []
        for url in recovered where url.pathExtension == "mov" && !inFlight.contains(url.lastPathComponent) {
            let retained = retainPending(url)
            if retained.deletingLastPathComponent() != pendingDirectory { retainedSources.append(retained) }
        }
        let files = (try? manager.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)) ?? []
        pending = (files + retainedSources).filter { ["mov", "mp4"].contains($0.pathExtension) }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            let metadata = readMetadata(url)
            return PendingVideo(url: url, needsWatermark: metadata?.watermark ?? true)
        }
    }

    private func readMetadata(_ url: URL) -> Metadata? {
        (try? Data(contentsOf: Self.metadataURL(url))).flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) }
    }

    @discardableResult
    private func retainPending(_ url: URL) -> URL {
        let destination = pendingDirectory.appendingPathComponent(url.lastPathComponent)
        guard destination != url else { return url }
        do {
            try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
            let source = Self.metadataURL(url)
            let target = Self.metadataURL(destination)
            if FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.copyItem(at: source, to: target)
            }
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: url, to: destination)
            }
            try? FileManager.default.removeItem(at: source)
            return destination
        } catch {
            message = L("视频仍保留在应用内，请腾出空间后重试。")
            return url
        }
    }

    func stage(_ url: URL, duration: TimeInterval, voice: Bool, uninterrupted: Bool, trialEligible: Bool) async -> PendingVideo {
        let watermark = readMetadata(url)?.watermark ?? true
        do {
            try Self.writeMetadata(url: url, watermark: watermark, duration: duration,
                                   voice: voice, uninterrupted: uninterrupted, trialEligible: trialEligible)
        } catch { message = error.localizedDescription }
        let durable = retainPending(url)
        var video = PendingVideo(url: durable, needsWatermark: watermark)
        video.trialNumber = await settleIfValid(video)
        pending.removeAll { $0.id == video.id }
        pending.append(video)
        return video
    }

    func chooseWatermark(_ video: PendingVideo, enabled: Bool) throws -> PendingVideo {
        let old = readMetadata(video.url)
        try Self.writeMetadata(url: video.url, watermark: enabled, duration: old?.duration,
                               voice: old?.voice, uninterrupted: old?.uninterrupted, trialEligible: old?.trialEligible)
        return PendingVideo(url: video.url, needsWatermark: enabled)
    }

    private func settleIfValid(_ video: PendingVideo) async -> Int? {
        let asset = AVURLAsset(url: video.url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric,
              CMTimeGetSeconds(duration) > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        let metadata = readMetadata(video.url)
        return onRecorded?(video.id, CMTimeGetSeconds(duration), metadata?.voice ?? false,
                           metadata?.uninterrupted ?? false, metadata?.trialEligible ?? false)
    }

    func settleRecoveredRecordings() async {
        defer { recovering = false }
        let snapshot = pending
        for video in snapshot {
            _ = await settleIfValid(video)
            if readMetadata(video.url)?.saved == true { removeVideo(video.url) }
        }
        refreshPending()
    }

    @discardableResult
    func save(_ original: PendingVideo, interrupted: Bool = false) async -> Bool {
        var video = original
        if Launch.isFree { video = PendingVideo(url: original.url, needsWatermark: false, trialNumber: original.trialNumber) }
        guard !inFlight.contains(video.id) else { return false }
        inFlight.insert(video.id)
        saving = true
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save recording") { [weak self] in
                Task { @MainActor in self?.endBackgroundTask() }
            }
        }
        defer {
            inFlight.remove(video.id)
            saving = !inFlight.isEmpty
            if !saving { endBackgroundTask() }
            refreshPending()
        }
        let metadata = readMetadata(video.url)
        _ = await settleIfValid(video)
        if metadata?.saved == true { removeVideo(video.url); return true }
        var exported: URL?
        var succeeded = false
        do {
            let asset = AVURLAsset(url: video.url)
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, CMTimeGetSeconds(duration) > 0 else { throw SaverError.invalid }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { throw SaverError.permission }
            let output: URL
            if video.needsWatermark {
                output = try await watermarked(video.url)
                exported = output
            } else { output = video.url }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: output)
            }
            try? Self.writeMetadata(url: video.url, watermark: video.needsWatermark, duration: CMTimeGetSeconds(duration), saved: true, voice: metadata?.voice, uninterrupted: metadata?.uninterrupted, trialEligible: metadata?.trialEligible)
            succeeded = true
            let oldCount = savedCount
            let oldSeconds = totalSeconds
            savedCount += 1
            totalSeconds += CMTimeGetSeconds(duration)
            defaults.set(savedCount, forKey: "savedVideos")
            defaults.set(totalSeconds, forKey: "savedSeconds")
            let month = String(Calendar.current.component(.year, from: Date())) + "-" + String(Calendar.current.component(.month, from: Date()))
            if defaults.string(forKey: "recordingMonth") != month { defaults.set(month, forKey: "recordingMonth"); defaults.set(0.0, forKey: "monthSeconds") }
            defaults.set(defaults.double(forKey: "monthSeconds") + CMTimeGetSeconds(duration), forKey: "monthSeconds")
            let crossedCount = [5, 20, 50].contains { oldCount < $0 && savedCount >= $0 }
            let crossedTime = [1800.0, 6000, 18000].contains { oldSeconds < $0 && totalSeconds >= $0 }
            milestone = (crossedCount || crossedTime) && defaults.double(forKey: "monthSeconds") >= 600
            reviewReady = ReviewGate.recordSavedVideo(count: savedCount, defaults: defaults)
            let id = video.id
            let retained = await Task.detached(priority: .utility) { () -> URL? in
                let directory = Self.cacheDirectory("SavedShareSources")
                let target = directory.appendingPathComponent(id)
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    for old in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: old) }
                    try FileManager.default.moveItem(at: output, to: target)
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                    return target
                } catch { return nil }
            }.value
            lastSavedVideo = retained.map { PendingVideo(url: $0, needsWatermark: false) }
            shareURL = nil
            removeVideo(video.url)
            message = interrupted ? L("录制被打断，已保存") + " " + durationText(Int(CMTimeGetSeconds(duration))) : L("已存到相册")
        } catch {
            _ = retainPending(video.url)
            message = L("视频已保留在待保存，可重试或分享导出。") + "\n" + error.localizedDescription
        }
        if let exported { try? FileManager.default.removeItem(at: exported) }
        return succeeded
    }

    func exportForSharing(_ original: PendingVideo) async -> URL? {
        let video = Launch.isFree ? PendingVideo(url: original.url, needsWatermark: false, trialNumber: original.trialNumber) : original
        let key = video.id + (video.needsWatermark ? "-watermarked" : "-clean")
        if let task = shareTasks[key] { return await task.value }
        preparingShare = true
        let work = Task { await self.prepareShare(video, key: key) }
        shareTasks[key] = work
        let result = await work.value
        shareTasks.removeValue(forKey: key)
        preparingShare = !shareTasks.isEmpty
        shareURL = result
        return result
    }

    func prepareLastSavedShare() async -> URL? {
        guard let video = lastSavedVideo else { return nil }
        return await exportForSharing(video)
    }

    private func prepareShare(_ video: PendingVideo, key: String) async -> URL? {
        if !video.needsWatermark { return video.url }
        let target = Self.cacheDirectory("VideoShares").appendingPathComponent(key).appendingPathExtension("mov")
        let exists = await Task.detached(priority: .utility) { FileManager.default.fileExists(atPath: target.path) }.value
        if exists { return target }
        var exported: URL?
        do {
            let source: URL
            if video.needsWatermark { source = try await watermarked(video.url); exported = source }
            else { source = video.url }
            let temporary = exported
            return try await Task.detached(priority: .utility) {
                let manager = FileManager.default
                defer { if let temporary { try? manager.removeItem(at: temporary) } }
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let staging = target.appendingPathExtension("partial")
                try? manager.removeItem(at: staging)
                do {
                    try manager.moveItem(at: source, to: staging)
                    try manager.moveItem(at: staging, to: target)
                    try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
                    return target
                } catch { try? manager.removeItem(at: staging); throw error }
            }.value
        } catch {
            message = L("水印导出失败，原片已保留。") + "\n" + error.localizedDescription
            return video.url
        }
    }

    nonisolated private static func cacheDirectory(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }
    nonisolated static func cleanExpiredCaches() async {
        await Task.detached(priority: .utility) {
            let manager = FileManager.default
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            for name in ["VideoShares", "WatermarkExports", "SavedShareSources"] {
                let urls = (try? manager.contentsOfDirectory(at: cacheDirectory(name), includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
                for url in urls {
                    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                          values.isRegularFile == true, let modified = values.contentModificationDate, modified < cutoff else { continue }
                    try? manager.removeItem(at: url)
                }
            }
            let legacy = (try? manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in legacy where url.pathExtension == "mov" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil {
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff {
                    try? manager.removeItem(at: url)
                }
            }
        }.value
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid }
    }

    private func removeVideo(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: Self.metadataURL(url))
    }

    func requestReviewIfReady() {
        guard reviewReady, UIApplication.shared.applicationState == .active,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        ReviewGate.request(in: scene, defaults: defaults)
        reviewReady = false
    }

    private func watermarked(_ url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw SaverError.invalid }
        let duration = try await asset.load(.duration)
        let naturalSize = try await source.load(.naturalSize)
        let transform = try await source.load(.preferredTransform)
        let nominalFrameRate = try await source.load(.nominalFrameRate)
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw SaverError.invalid }
        try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        for sourceAudio in try await asset.loadTracks(withMediaType: .audio) {
            if let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try audio.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceAudio, at: .zero)
            }
        }
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let size = CGSize(width: abs(bounds.width), height: abs(bounds.height))
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        layerInstruction.setTransform(transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]
        let rendering = AVMutableVideoComposition()
        rendering.instructions = [instruction]
        rendering.renderSize = size
        rendering.frameDuration = CMTime(value: 1, timescale: nominalFrameRate >= 50 ? 60 : 30)
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        let movie = CALayer()
        movie.frame = parent.bounds
        parent.addSublayer(movie)
        let watermark = CATextLayer()
        watermark.string = L("提词器 App")
        watermark.fontSize = WatermarkLayout.fontSize(size)
        watermark.foregroundColor = UIColor.white.withAlphaComponent(0.58).cgColor
        watermark.alignmentMode = .right
        watermark.contentsScale = 2
        watermark.shadowOpacity = 0.4
        watermark.shadowRadius = 2
        watermark.frame = WatermarkLayout.frame(size)
        parent.addSublayer(watermark)
        rendering.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: movie, in: parent)
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw SaverError.invalid }
        let output = try await Task.detached(priority: .utility) {
            let directory = Self.cacheDirectory("WatermarkExports")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        }.value
        exporter.outputURL = output
        exporter.outputFileType = .mov
        exporter.videoComposition = rendering
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in exporter.exportAsynchronously { continuation.resume() } }
        guard exporter.status == .completed else {
            await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: output) }.value
            throw exporter.error ?? SaverError.export
        }
        return output
    }
}

private enum SaverError: LocalizedError {
    case invalid, permission, export
    var errorDescription: String? {
        switch self {
        case .invalid: return L("视频暂时无法读取，原文件已保留。")
        case .permission: return L("相册添加权限未开启。")
        case .export: return L("水印导出失败，原片已保留。")
        }
    }
}

enum WatermarkLayout {
    static func fontSize(_ size: CGSize) -> CGFloat { min(size.width, size.height) * 0.025 }
    static func frame(_ size: CGSize) -> CGRect {
        let inset = min(size.width, size.height) * 0.022
        return CGRect(x: size.width * 0.45, y: inset, width: size.width * 0.55 - inset, height: fontSize(size) * 1.6)
    }
}
