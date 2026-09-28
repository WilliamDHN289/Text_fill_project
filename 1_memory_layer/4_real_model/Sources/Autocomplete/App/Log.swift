import Foundation
import os

/// Simple logger that writes to both os_log (Console.app) and a log file
enum Log {
    private static let subsystem = "com.autocomplete.app"
    private static let osLog = OSLog(subsystem: subsystem, category: "general")
    private static let logFileURL: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".autocomplete.log")
        // Truncate on launch
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }()

    static func info(_ message: String) {
        os_log(.info, log: osLog, "%{public}@", message)
        appendToFile("[INFO] \(message)")
    }

    static func error(_ message: String) {
        os_log(.error, log: osLog, "%{public}@", message)
        appendToFile("[ERROR] \(message)")
    }

    static func debug(_ message: @autoclosure () -> String) {
        #if DEBUG
        let msg = message()
        os_log(.debug, log: osLog, "%{public}@", msg)
        appendToFile("[DEBUG] \(msg)")
        #endif
    }

    /// Maps a provider identifier to a short code for production logs so the
    /// user-facing log file doesn't reveal which cloud vendor is in use.
    /// `local` (and any unrecognized value) is returned unchanged.
    static func providerCode(_ provider: String) -> String {
        switch provider {
        case "openai": return "A"
        case "openrouter": return "B"
        default: return provider
        }
    }

    private static func appendToFile(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        if let data = line.data(using: .utf8),
           let handle = try? FileHandle(forWritingTo: logFileURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }
    }
}
