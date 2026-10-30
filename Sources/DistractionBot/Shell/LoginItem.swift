import Foundation

/// Launch at login, to the menu bar only (§5a Q14): a LaunchAgent that runs the installed app with `--menubar`,
/// the pattern tavern-tts uses on this Mac. SMAppService would need the plist inside a stably signed bundle; this is simpler to see and undo.
enum LoginItem {
    static let label = "com.tejasvin.distraction-bot"
    static let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static let appPath = "/Applications/Distraction Bot.app/Contents/MacOS/DistractionBot"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func install() -> String? {
        guard FileManager.default.fileExists(atPath: appPath) else { return "Install the app to /Applications first (scripts/bundle.sh install)" }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>\(appPath)</string><string>--menubar</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><false/>
          <key>ProcessType</key><string>Interactive</string>
        </dict></plist>
        """
        do { try xml.write(to: plist, atomically: true, encoding: .utf8) } catch { return error.localizedDescription }
        _ = run(["bootstrap", "gui/\(getuid())", plist.path])
        return nil
    }

    static func uninstall() {
        _ = run(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist)
    }

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardOutput = nil; p.standardError = nil
        try? p.run(); p.waitUntilExit(); return p.terminationStatus
    }
}
