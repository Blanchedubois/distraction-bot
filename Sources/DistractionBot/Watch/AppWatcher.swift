import AppKit
import Foundation

/// The app watcher (§3.2): NSWorkspace launch/activate events plus a 1-second poll as the backstop.
/// Rules decide; this acts: close, shield (hide + wall), or warn. Never the judge.
/// X1–X4 (PLAN_CATCHER §3.2–3.5): classes route the judge path (utility · communication by budget only), judged keys expire,
/// the switch rate is counted and nudged, idle opens away spans. The arithmetic is in `CatcherMaths.swift`.
@MainActor
final class AppWatcher {
    unowned let store: Store
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private(set) var active = false
    var attempts: [String: Int] = [:]
    /// Apps a close is already in flight for: launch, activate and poll can all fire for the same app in one second.
    private var closing: Set<String> = []
    /// §5a Q17: apps that ignored a quit this session are forced at once from then on; so is a relaunch within 10 s of a close.
    private var ignoredQuit: Set<String> = []
    private var lastClosed: [String: Date] = [:]
    /// "5 more minutes": a bundle id is left alone until this time.
    var allowances: [String: Date] = [:]
    /// E3 (PLAN_OVERLAY §3.4): how many "5 more minutes" each app took this session — the shield shows `· 2nd`, refuses or prices the third.
    var extensions: [String: Int] = [:]
    /// Front app, for the Home "Now" card.
    private(set) var frontName = ""
    private(set) var frontBundle = ""

    init(store: Store) { self.store = store }

    func start() {
        guard !active else { return }
        active = true
        Log.write("watcher start")
        attempts = [:]; allowances = [:]; ignoredQuit = []; lastClosed = [:]
        extensions = [:]   // E3
        frontSeconds = [:]; switches = [:]; usageJudged = []; candidate = nil
        window.reset(); history.reset(); judged.reset(); switchLog.reset(); away.reset(); budgetJudgedAt = [:]; keyFrontSince = [:]; currentKey = nil   // X1–X4
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.check(app, trigger: "launch", since: Date()) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.check(app, trigger: "activate", since: Date()) }
        })
        // X4: the lock screen and sleep are away at once; unlock and wake let the next input close the span
        observers.append(nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.forceAway("sleep") } })
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.away.unforce() } })
        let dnc = DistributedNotificationCenter.default()
        distributedObservers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.forceAway("lock") } })
        distributedObservers.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.away.unforce() } })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        poll()
    }

    func stop() {
        Log.write("watcher stop")
        active = false
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        distributedObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        distributedObservers = []
        timer?.invalidate(); timer = nil
        if away.isAway { handle(away.tick(idle: 0, now: Date(), awayAfter: 0, autoPauseAfter: nil)) }   // X4: close an open span at End
        Shield.shared.hide()
        for (id, _) in attempts where store.rules.strength(for: id) == .shield {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.unhide() }
        }
    }

    /// Catches apps already open when the session starts, and anything the notifications missed.
    // §5a Q19 + the usage signal (§5a Music): seconds in front and switches per app this session
    private(set) var frontSeconds: [String: Int] = [:]
    private var switches: [String: [Date]] = [:]
    private var usageJudged: Set<String> = []
    private var candidate: (id: String, title: String, since: Date)?
    static let dwell: TimeInterval = 5
    static let usageMinutes = 10, usageSwitches = 6
    // X1–X4
    private(set) var window = FrontWindow()
    private(set) var history = FrontHistory()
    private var judged = JudgedKeys()
    private(set) var switchLog = SwitchLog()
    private(set) var away = AwayTracker()
    private var budgetJudgedAt: [String: Date] = [:]
    private var keyFrontSince: [String: Date] = [:]
    private var currentKey: String?
    /// The idle source, replaceable by a check.
    var idleSeconds: () -> TimeInterval = { Idle.seconds }
    static let ownBundle = "com.tejasvin.distraction-bot"

    private var polls = 0
    func poll() {
        polls += 1
        let now = Date()
        if polls % 10 == 0 { Log.write("watcher poll #\(polls) active=\(active) front=\(frontBundle)") }
        let sessionOn = active && store.session != nil
        if sessionOn { handle(away.tick(idle: idleSeconds(), now: now, awayAfter: store.session?.strictness.profile.awayAfter ?? 300,
                                        autoPauseAfter: store.settings.autoPauseMinutes > 0 && store.session?.strictness.isHard == false ? Double(store.settings.autoPauseMinutes) * 60 : nil)) }   // X4
        if let f = NSWorkspace.shared.frontmostApplication {
            let id = f.bundleIdentifier ?? ""
            let name = f.localizedName ?? id
            if id != frontBundle {
                switches[id, default: []].append(now); candidate = (id, Self.frontTitle(pid: f.processIdentifier), now)
                history.front(id, name: name, title: candidate?.title ?? "", at: now)                    // X1
                if sessionOn, !away.isAway { switchLog.note(at: now) }                                    // X3
            }
            frontName = name; frontBundle = id
            if sessionOn, !(store.session?.paused ?? false), !away.isAway { frontSeconds[id, default: 0] += 1; window.tick(id, at: now); judgeIfDue(f) }
        }
        if sessionOn {
            let rate = switchLog.rate(minutes: 10, now: now)                                              // X3: published each poll
            if rate != store.switchRate { store.switchRate = rate }
            if !away.isAway, let n = switchLog.nudgeDue(threshold: store.session?.strictness.profile.switchNudge ?? 12, now: now) {
                EventLog.shared.add("judge.nudge", detail: "\(n) switches in 10 min")
                store.nudge(text: "\(n) app switches in 10 minutes — settle on one?")
            }
        }
        guard active, !(store.session?.paused ?? false) || store.session?.onBreak == true else { return }   // HUD3: a break keeps the block list
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, effectiveStrength(id) != .allowed, !app.isTerminated else { continue }
            switch effectiveStrength(id) {
            case .close: check(app, trigger: "poll", since: Date())
            case .shield: if app.isActive { check(app, trigger: "poll", since: Date()) }
            default: break
            }
        }
    }

    /// The judge path (X1 §3.2): utility and communication apps are never judged on dwell, only when their rolling 10-min budget is spent
    /// (once per 10 min); every other class is judged after the dwell, once per `id|title` until the X2 expiry, and once more past the usage budget.
    private func judgeIfDue(_ f: NSRunningApplication) {
        guard let id = f.bundleIdentifier, id != Self.ownBundle, !BrowserReader.browsers.contains(id) else { return }
        let now = Date()
        let title = Self.frontTitle(pid: f.processIdentifier)
        let name = f.localizedName ?? id
        let cls = Classifier.classOf(app: id, name: name)
        let profile = (store.session?.strictness ?? .normal).profile   // O4: dwell and the usage budget per level
        let key = id + "|" + title
        if key != currentKey { currentKey = key; keyFrontSince[key] = now; judged.visited(key, at: now) }
        if store.isSessionAllowed(.app(id)) { return }   // X6a: "this is work · this session"
        let explicitRule = store.rules.apps[id]
        if explicitRule == .allowed || explicitRule == .close || explicitRule == .shield { return }   // an explicit allowed is never judged; blocked apps are acted on, not judged
        if !Classifier.judgedOnDwell(cls) {
            let budget = cls == .utility ? profile.utilityMinutes : profile.communicationMinutes
            let secs10 = window.seconds(id, minutes: 10, now: now)
            guard Double(secs10) >= budget * 60 else { return }
            if let t = budgetJudgedAt[id], now.timeIntervalSince(t) < 600 { return }
            budgetJudgedAt[id] = now
            let usage = "\(name) in front \(secs10 / 60) min \(secs10 % 60) s of the last 10 min (budget \(budget == budget.rounded() ? "\(Int(budget))" : String(format: "%.1f", budget)) min)"
            Log.write("budget \(cls.rawValue) \(name): \(secs10) s of 10 min")
            Task { await store.judge(front: name, kind: "app", title: title, url: nil, what: name, subject: .app(id), pid: f.processIdentifier, usage: usage,
                                     appClass: cls.rawValue, dwell: dwellLine(key: key, id: id, now: now), previous: previousLine(now: now), quiet: cls == .utility) }
            return
        }
        let secs = frontSeconds[id] ?? 0
        let recentSwitches = (switches[id] ?? []).filter { now.timeIntervalSince($0) < 600 }.count
        let overBudget = secs >= profile.usageMinutes * 60 || recentSwitches >= profile.usageSwitches
        if overBudget, !usageJudged.contains(id) {
            usageJudged.insert(id)
            let usage = "\(name) in front \(secs / 60) min this session, switched to \(recentSwitches) times in the last 10 min (budget \(profile.usageMinutes) min / \(profile.usageSwitches) switches)"
            Task { await store.judge(front: name, kind: "app", title: title, url: nil, what: name, subject: .app(id), pid: f.processIdentifier, usage: usage,
                                     appClass: cls.rawValue, dwell: dwellLine(key: key, id: id, now: now), previous: previousLine(now: now)) }
            return
        }
        guard store.rules.strength(for: id) == .judge, let c = candidate, c.id == id, now.timeIntervalSince(c.since) >= profile.dwell else { return }
        if judged.contains(key) { guard judged.due(key, now: now, rejudgeMinutes: profile.rejudgeMinutes) else { return } }   // X2: the expiry
        judged.judged(key, at: now, inFrontSince: keyFrontSince[key] ?? now)
        Task { await store.judge(front: name, kind: "app", title: title, url: nil, what: title.isEmpty ? name : "\(name) — \(title)", subject: .app(id), pid: f.processIdentifier,
                                 appClass: cls.rawValue, dwell: dwellLine(key: key, id: id, now: now), previous: previousLine(now: now)) }
    }

    /// X2/X5: "in front 11 min this session · 3rd visit · last distraction 14 min ago"
    private func dwellLine(key: String, id: String, now: Date) -> String {
        CatcherWords.dwell(inFront: now.timeIntervalSince(keyFrontSince[key] ?? now), visits: max(1, judged.visits(key)),
                           lastDistraction: store.lastDistractionAt.map { now.timeIntervalSince($0) })
    }
    /// X5: "Overleaf — project.tex · work · 2 min ago" — the app before this one
    private func previousLine(now: Date) -> String? {
        guard let p = history.previous, let until = p.until, p.id != Self.ownBundle else { return nil }
        return CatcherWords.previous(name: p.name, title: Rules.privateApps.contains(p.name) ? "" : p.title, verdict: store.verdictWord(appId: p.id), left: now.timeIntervalSince(until))
    }

    // MARK: X4 away

    private func forceAway(_ why: String) {
        guard active, store.session != nil else { return }
        Log.write("away: \(why)")
        handle(away.force(at: Date()))
    }
    private func handle(_ events: [AwayTracker.Event]) {
        for e in events {
            switch e {
            case .opened(let at): EventLog.shared.add("session.away", detail: "start", latencyMs: Int(Date().timeIntervalSince(at) * 1000)); Log.write("away: opened"); store.reloadLog()
            case .closed(let secs): EventLog.shared.add("session.away", detail: "\(secs)"); Log.write("away: closed after \(secs) s"); store.reloadLog()
            case .pause: store.autoPause()
            case .extend: store.extendPause()
            case .resumed(let secs): store.awayReturned(seconds: secs)
            }
        }
    }

    /// The front window's title for a process (Screen Recording gives titles); withheld for the private list.
    static func frontTitle(pid: pid_t) -> String {
        guard let app = NSRunningApplication(processIdentifier: pid), !Rules.privateApps.contains(app.localizedName ?? "") else { return "" }
        let wins = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return wins.first { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }.flatMap { $0[kCGWindowName as String] as? String } ?? ""
    }

    /// The rule, or shield for an app the follow-up shielded this session.
    func effectiveStrength(_ id: String) -> Strength { store.sessionShielded.contains(id) ? .shield : store.rules.strength(for: id) }

    func check(_ app: NSRunningApplication, trigger: String, since: Date) {
        guard active, let id = app.bundleIdentifier, let session = store.session, !session.paused || session.onBreak else { return }
        if let until = allowances[id], until > Date() { return }
        let strength = effectiveStrength(id)
        // HUD3 (§5a Q9): on a break only the block list acts — close and shield where it is enforced; no warnings
        if session.paused { guard session.strictness.profile.enforceBlockList, strength == .close || strength == .shield else { return } }
        guard strength != .allowed, strength != .judge else { return }   // the judge path runs from poll() after the dwell
        if !session.strictness.profile.enforceBlockList && strength != .warn { warn(app, id: id, note: "\(session.strictness.rawValue) session"); return }   // O4: laxed and gentle only warn
        let name = app.localizedName ?? id
        Log.write("check \(trigger) \(name) → \(strength)")
        attempts[id, default: 0] += 1
        let n = attempts[id]!
        switch strength {
        case .close:
            guard !closing.contains(id) else { attempts[id]! -= 1; return }
            closing.insert(id)
            Task { await close(app, id: id, name: name, since: since, attempt: n); closing.remove(id) }
        case .shield:
            app.hide()
            EventLog.shared.add("block.shield", app: name, detail: "\(trigger) · attempt \(n)", latencyMs: Int(Date().timeIntervalSince(since) * 1000))
            store.noteBlock()
            Shield.shared.show(app: app, name: name, attempts: n, mode: .wall)
        case .warn:
            warn(app, id: id, note: trigger)
        case .allowed, .judge: break
        }
    }

    private func warn(_ app: NSRunningApplication, id: String, note: String) {
        // once per app per 2 minutes
        if let last = lastWarn[id], Date().timeIntervalSince(last) < 120 { return }
        lastWarn[id] = Date()
        let name = app.localizedName ?? id
        EventLog.shared.add("block.warn", app: name, detail: note)
        store.warn(what: "\(name) opened", reason: "on your warn list", subject: .app(id))
    }
    private var lastWarn: [String: Date] = [:]

    /// Extreme (O4): close the judged app now, as the block list would — graceful, forced at 3 s.
    func closeOnVerdict(id: String) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return }
        let name = app.localizedName ?? id
        attempts[id, default: 0] += 1
        Task { await close(app, id: id, name: name, since: Date(), attempt: attempts[id]!) }
    }

    private func close(_ app: NSRunningApplication, id: String, name: String, since: Date, attempt: Int) async {
        let react = Int(Date().timeIntervalSince(since) * 1000)   // the watcher's own share: notification → terminate()
        var why = ""
        if ignoredQuit.contains(id) { why = "forced · ignored quit" }
        else if let t = lastClosed[id], Date().timeIntervalSince(t) < 10 { why = "forced · relaunch" }
        if !why.isEmpty {
            app.forceTerminate()
        } else {
            app.terminate()
            let deadline = Date().addingTimeInterval(3)
            while !app.isTerminated && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            if !app.isTerminated { why = "forced · after 3 s"; ignoredQuit.insert(id); app.forceTerminate() }
        }
        let limit = Date().addingTimeInterval(3)
        while !app.isTerminated && Date() < limit { try? await Task.sleep(for: .milliseconds(10)) }
        lastClosed[id] = Date()
        let ms = Int(Date().timeIntervalSince(since) * 1000)
        Log.write("closed \(name) in \(ms) ms (react \(react) ms) \(why.isEmpty ? "graceful" : why)")
        EventLog.shared.add("block.close", app: name, detail: (why.isEmpty ? "" : why + " · ") + "attempt \(attempt) · react \(react) ms", latencyMs: ms)
        store.noteBlock()
        Shield.shared.show(app: app, name: name, attempts: attempt, mode: .notice)
    }

    /// The escape hatch (§5a Q5): leave this app alone for 5 minutes.
    func allow(_ id: String, name: String, minutes: Double = 5) {
        allowances[id] = Date().addingTimeInterval(minutes * 60)
        extensions[id, default: 0] += 1   // E3
        let n = extensions[id]!
        NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.unhide(); $0.activate() }
        EventLog.shared.add("skip", app: name, detail: n == 1 ? "5 more minutes" : "5 more minutes · \(Self.ordinal(n))")   // E3: counted
        Shield.shared.hide()
    }
    /// E3: `2nd` · `3rd` · `4th`.
    static func ordinal(_ n: Int) -> String { n == 1 ? "1st" : n == 2 ? "2nd" : n == 3 ? "3rd" : "\(n)th" }
}
