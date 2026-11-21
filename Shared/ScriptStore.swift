import Foundation
import Combine

@MainActor
final class ScriptStore: ObservableObject {
    @Published private(set) var scripts: [Script] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var deleted: Script?
    private let directory: URL
    private var filePaths: [UUID: URL] = [:]

    init(directory: URL? = nil, seed: Bool = true) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scripts", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            let urls = try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            var damaged = false
            scripts = urls.compactMap {
                do {
                    let url = $0
                    var script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: url))
                    if filePaths[script.id] != nil { script.id = UUID() }
                    filePaths[script.id] = url
                    return script
                }
                catch { damaged = true; return nil }
            }.sorted { $0.modifiedAt > $1.modifiedAt }
            if damaged { errorMessage = L("部分稿件读取失败，原文件已保留。") }
            let marker = self.directory.appendingPathComponent(".seeded")
            if seed, scripts.isEmpty, !FileManager.default.fileExists(atPath: marker.path), urls.isEmpty {
                let script = Self.example()
                try JSONEncoder().encode(script).write(to: fileURL(script.id), options: .atomic)
                scripts = [script]
            }
            if seed { try Data().write(to: marker, options: .atomic) }
        } catch { errorMessage = error.localizedDescription }
    }

    private func fileURL(_ id: UUID) -> URL { filePaths[id] ?? directory.appendingPathComponent(id.uuidString).appendingPathExtension("json") }

    @discardableResult
    func save(_ script: Script) -> Bool {
        do {
            try JSONEncoder().encode(script).write(to: fileURL(script.id), options: .atomic)
            filePaths[script.id] = fileURL(script.id)
            if let index = scripts.firstIndex(where: { $0.id == script.id }) { scripts[index] = script }
            else { scripts.insert(script, at: 0) }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func updatePosition(id: UUID, offset: Int) {
        guard var script = scripts.first(where: { $0.id == id }) else { return }
        script.readingOffset = min(max(0, offset), script.body.utf16.count)
        save(script)
    }

    func delete(_ script: Script) {
        do {
            try JSONEncoder().encode(script).write(to: directory.appendingPathComponent(".undo"), options: .atomic)
            try FileManager.default.removeItem(at: fileURL(script.id))
            filePaths[script.id] = nil
            deleted = script
            scripts.removeAll { $0.id == script.id }
        } catch { errorMessage = error.localizedDescription }
    }

    func restoreDeleted() {
        let script = deleted ?? (try? Data(contentsOf: directory.appendingPathComponent(".undo"))).flatMap { try? JSONDecoder().decode(Script.self, from: $0) }
        guard let script, save(script) else { return }
        deleted = nil
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(".undo"))
    }

    func recoverUndo() {
        deleted = (try? Data(contentsOf: directory.appendingPathComponent(".undo"))).flatMap { try? JSONDecoder().decode(Script.self, from: $0) }
    }

    func clearError() { errorMessage = nil }

    static func example() -> Script {
        Script(title: L("试一试语音跟随"), body: L("示例稿正文"))
    }
}
