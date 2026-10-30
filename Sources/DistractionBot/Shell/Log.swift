import Foundation

/// A plain text log at ~/Library/Logs/Distraction Bot/app.log, for diagnosing the watcher without a debugger.
enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Distraction Bot")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("app.log")
    }()
    private static let queue = DispatchQueue(label: "dbot.log")
    static func write(_ s: String) {
        let line = "\(Date().formatted(date: .numeric, time: .standard)) \(s)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
            else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
    }
}
