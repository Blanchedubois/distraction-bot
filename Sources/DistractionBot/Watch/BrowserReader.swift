import AppKit
import ApplicationServices

/// Reads the front browser's page through Accessibility (§3.3): URL, title, and whether the window
/// looks private. Ported from Jeff 2's AXProbe: Dia (Chromium) needs `AXManualAccessibility` switched on first.
enum BrowserReader {
    static let browsers: Set<String> = ["com.apple.Safari", "company.thebrowser.dia"]

    struct Page: Equatable {
        var bundleID: String
        var app: String
        var url: String
        var title: String
        var windowTitle: String
        var isPrivate: Bool
        var host: String { URL(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? "" }
    }

    private static var manualDone: Set<pid_t> = []
    /// Why the last read gave nothing, for the log.
    static var lastFailure = ""

    /// The page in the focused window of `app`, or nil when it gives none (no window, no web area, a new tab).
    static func read(_ app: NSRunningApplication) -> Page? {
        guard let id = app.bundleIdentifier, browsers.contains(id) else { return nil }
        let pid = app.processIdentifier
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        if id != "com.apple.Safari", !manualDone.contains(pid) {
            AXUIElementSetAttributeValue(ax, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            manualDone.insert(pid)
        }
        guard let w = value(ax, kAXFocusedWindowAttribute) else { lastFailure = "no focused window (AX trusted: \(AXIsProcessTrusted()))"; return nil }
        let window = w as! AXUIElement
        let wtitle = value(window, kAXTitleAttribute) as? String ?? ""
        guard let web = search(window, role: "AXWebArea") else { lastFailure = "no web area under window \"\(wtitle.prefix(40))\" (\(lastSearched) nodes)"; return nil }
        let url = (value(web, kAXURLAttribute) as? URL)?.absoluteString ?? (value(web, kAXURLAttribute) as? String) ?? ""
        let title = value(web, kAXTitleAttribute) as? String ?? ""
        guard !url.isEmpty else { lastFailure = "web area has no url (title \"\(title.prefix(40))\")"; return nil }
        let lower = wtitle.lowercased()
        let isPrivate = lower.contains("private") || lower.contains("incognito")
        return Page(bundleID: id, app: app.localizedName ?? id, url: url, title: title, windowTitle: wtitle, isPrivate: isPrivate)
    }

    /// Breadth-first, bounded: a page's web area sits a few levels into its window.
    private static var lastSearched = 0
    private static func search(_ root: AXUIElement, role: String) -> AXUIElement? {
        var queue = [root], seen = 0
        defer { lastSearched = seen }
        while !queue.isEmpty, seen < 2000 {
            let e = queue.removeFirst()
            seen += 1
            if value(e, kAXRoleAttribute) as? String == role { return e }
            queue += (value(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }

    private static func value(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
    }
}

/// The search query in a results URL, if it is one (§3.3).
enum SearchQuery {
    static func extract(_ urlString: String) -> (engine: String, query: String)? {
        guard let u = URL(string: urlString), let host = u.host?.lowercased(), let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func q(_ names: String...) -> String? { items.first { names.contains($0.name) }?.value?.replacingOccurrences(of: "+", with: " ").trimmingCharacters(in: .whitespaces) }
        if host.contains("google."), u.path.hasPrefix("/search"), let s = q("q") { return ("google", s) }
        if host.contains("youtube.com"), u.path.hasPrefix("/results"), let s = q("search_query") { return ("youtube", s) }
        if host.contains("duckduckgo.com"), let s = q("q") { return ("duckduckgo", s) }
        if host.contains("bing.com"), u.path.hasPrefix("/search"), let s = q("q") { return ("bing", s) }
        if host.contains("reddit.com"), u.path.hasPrefix("/search"), let s = q("q") { return ("reddit", s) }
        if host.contains("amazon."), u.path.hasPrefix("/s"), let s = q("k") { return ("amazon", s) }
        return nil
    }
}
