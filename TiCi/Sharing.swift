import SwiftUI
import UIKit

struct ShareItems: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum AppSharing {
    static var storeURL: URL? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        return URL(string: "https://apps.apple.com/app/id" + id)
    }
    static func textFile(_ script: Script) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TextExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let allowed = script.title.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !"/\\:".unicodeScalars.contains($0) }
        let name = String(String.UnicodeScalarView(allowed)).prefix(60)
        let url = directory.appendingPathComponent((name.isEmpty ? L("稿件") : String(name)) + "-" + String(script.id.uuidString.prefix(6))).appendingPathExtension("txt")
        try script.body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
