import AppKit
import Foundation

/// What "block" does in a browser (§5a Q11): Safari by AppleScript to a local blocked page,
/// Dia by ⌘W sent to its window, the shield as the fallback for either.
@MainActor
enum BrowserActions {
    static let blockedPage: URL = {
        let u = Store.supportDir.appendingPathComponent("blocked.html")
        let html = """
        <!doctype html><meta charset="utf-8"><title>Blocked</title>
        <style>body{margin:0;height:100vh;display:grid;place-items:center;background:#f5f2ec;color:#17150f;font-family:-apple-system,system-ui}
        @media(prefers-color-scheme:dark){body{background:#161511;color:#f3efe6}} .k{font:600 11px ui-monospace,monospace;letter-spacing:.1em;color:#c0392b}
        h1{font-weight:500;font-size:40px;margin:8px 0} p{color:#716c61;max-width:36em;text-align:center}</style>
        <div style="text-align:center"><div class="k">BLOCKED</div><h1>Not during a focus session</h1><p>This site is on your list. The session ends at the time on the menu bar; "5 more minutes" is on the shield if you need it.</p></div>
        """
        try? html.write(to: u, atomically: true, encoding: .utf8)
        return u
    }()

    static func block(page: BrowserReader.Page, store: Store) {
        switch page.bundleID {
        case "com.apple.Safari":
            let script = "tell application \"Safari\" to set URL of current tab of front window to \"\(blockedPage.absoluteString)\""
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let err { Log.write("safari block failed: \(err[NSAppleScript.errorMessage] ?? err) → shield"); fallback(page, store) }
            else { Log.write("safari block: redirected \(page.host)") }
        default:
            // ⌘W to the browser's process; needs Accessibility (granted in B0)
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: page.bundleID).first,
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 13, keyDown: false) else { fallback(page, store); return }
            down.flags = .maskCommand; up.flags = .maskCommand
            down.postToPid(app.processIdentifier); up.postToPid(app.processIdentifier)
            Log.write("\(page.app) block: ⌘W for \(page.host)")
        }
    }

    private static func fallback(_ page: BrowserReader.Page, _ store: Store) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: page.bundleID).first else { return }
        app.hide()
        Shield.shared.show(app: app, name: "\(page.app) · \(page.host)", attempts: 1, mode: .wall)
    }
}
