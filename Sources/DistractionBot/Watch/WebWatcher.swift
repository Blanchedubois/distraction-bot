import AppKit
import Foundation

/// The web watcher (§3.3): reads the front browser's page every 2 s and on every app switch,
/// applies the site and search-term rules, and warns, blocks or lets it be. Rules only; the judge is B3.
@MainActor
final class WebWatcher {
    unowned let store: Store
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private(set) var active = false
    private var seen: Set<String> = []            // URLs already handled this session
    private var lastWarn: [String: Date] = [:]    // per host
    var snoozedUntil: Date?
    private var lastBlock: [String: Date] = [:]
    private(set) var current: BrowserReader.Page?

    init(store: Store) { self.store = store }

    func start() {
        guard !active else { return }
        active = true; seen = []; lastWarn = [:]; snoozedUntil = nil
        Log.write("web watcher start")
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.look(trigger: "activate") }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.look(trigger: "poll") } }
        look(trigger: "start")
    }

    func stop() {
        Log.write("web watcher stop")
        active = false
        timer?.invalidate(); timer = nil
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }; observer = nil
        Banner.shared.clear()   // HUD0: the session is over — every card, waiting ones too
        current = nil
    }

    private var polls = 0
    func look(trigger: String) {
        polls += 1
        guard active, let session = store.session, !session.paused || session.onBreak,   // HUD3: a break keeps the block list
              let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier, BrowserReader.browsers.contains(id) else { current = nil; return }
        guard let page = BrowserReader.read(front) else { if trigger != "poll" || polls % 5 == 0 { Log.write("web \(trigger) \(front.localizedName ?? id): \(BrowserReader.lastFailure)") }; return }
        current = page
        // §5a Q23: private windows are read and judged like any other (the reader still marks them)
        if page.url.hasPrefix("file://") || page.url.hasPrefix("about:") || page.url.isEmpty { return }   // the blocked page, new tabs, local files: never judged
        if store.blockedHosts.contains(where: { Rules.matches(page.host, $0) }) {
            // blocked for the session (bypass study): every visit, including Back after the redirect
            if let t = lastBlock[page.host], Date().timeIntervalSince(t) < 3 { return }
            lastBlock[page.host] = Date()
            EventLog.shared.add("web.block", app: page.app, detail: "\(page.host) · session block")
            store.noteBlock(); store.reloadLog()
            BrowserActions.block(page: page, store: store)
            return
        }
        let key = page.url
        guard !seen.contains(key) else { return }
        // HUD3 (§5a Q9): on a break only what the block list closes is acted on; anything else is left unseen, so it is judged after
        if session.paused { guard blocksOnBreak(page) else { return } }
        seen.insert(key)
        handle(page, trigger: trigger)
    }

    /// HUD3: a page the block list closes outright (a blocked site or search term), as `handle` would decide it — the break's one rule.
    private func blocksOnBreak(_ page: BrowserReader.Page) -> Bool {
        let host = page.host
        guard store.session?.strictness.profile.enforceBlockList == true, !store.rules.isAllowedSite(host), !store.isSessionAllowed(.site(host)) else { return false }
        if SearchQuery.extract(page.url).flatMap({ store.rules.searchTermHit($0.query) }) != nil { return true }
        if let r = store.rules.siteRule(for: host), r.strength == .close || r.strength == .shield { return true }
        return false
    }

    private func handle(_ page: BrowserReader.Page, trigger: String) {
        let host = page.host
        let search = SearchQuery.extract(page.url)
        var verdict = "allowed"
        var strength: Strength = .allowed
        var why = ""
        if store.rules.isAllowedSite(host) { verdict = "allowed"; why = "allow list" }
        else if store.isSessionAllowed(.site(host)) { verdict = "allowed"; why = "this session" }   // X6a
        else if let hit = search.flatMap({ store.rules.searchTermHit($0.query) }) { strength = .close; verdict = "block"; why = "search term \"\(hit)\"" }
        else if let r = store.rules.siteRule(for: host) {
            strength = r.strength
            switch r.strength { case .warn: verdict = "warn"; case .allowed: verdict = "allowed"; case .judge: verdict = "judge · B3"; default: verdict = "block" }
            why = "site \(r.rule)"
        }
        else { strength = .judge; verdict = "judge"; why = "no rule" }

        let what = (search.map { "\($0.engine): \($0.query)" } ?? (page.title.isEmpty ? host : page.title)) + (page.isPrivate ? " (private window)" : "")
        EventLog.shared.add(search != nil ? "web.search" : "web.visit", app: page.app, detail: "\(what) → \(verdict)\(why.isEmpty ? "" : " · \(why)")")
        Log.write("web \(trigger) \(page.app) \(host) \(search != nil ? "search" : "visit") → \(verdict) (\(why))")
        store.reloadLog()

        switch strength {
        case .warn:
            if let s = snoozedUntil, s > Date() { return }
            if let l = lastWarn[host], Date().timeIntervalSince(l) < 120 { return }
            lastWarn[host] = Date()
            EventLog.shared.add("web.warn", app: page.app, detail: what)
            store.noteWarning(what)
            store.warn(what: what, reason: why, subject: .site(host))
        case .close, .shield:
            EventLog.shared.add("web.block", app: page.app, detail: what)
            store.noteBlock()
            BrowserActions.block(page: page, store: store)
        case .judge:
            if let s = snoozedUntil, s > Date() { return }
            let title = search.map { "search: \($0.query)" } ?? page.title
            Task { await store.judge(front: page.app, kind: "web browser", title: title, url: page.url, what: what, subject: .site(host), pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) }
        default: break
        }
    }

    /// "This is work": the host joins the allow list and is never judged again.
    func allow(host: String) {
        guard !host.isEmpty, !store.rules.allowedSites.contains(host) else { return }
        store.rules.allowedSites.append(host)
        EventLog.shared.add("web.answer", app: "", detail: "this is work · \(host)")
        store.reloadLog()
    }
}
