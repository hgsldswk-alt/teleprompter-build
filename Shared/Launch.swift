import Foundation

enum Launch {
    static let freePeriod = false

    static var isFree: Bool { isFree(arguments: ProcessInfo.processInfo.arguments) }

    static func isFree(arguments: [String], freePeriod: Bool = Launch.freePeriod) -> Bool {
        let paidFlags = ["-paid-mode", "-paywall", "-trialend", "-savesheet", "-trial2"]
        return freePeriod && !paidFlags.contains(where: arguments.contains)
    }
}
