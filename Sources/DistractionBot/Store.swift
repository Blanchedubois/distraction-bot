import Foundation
import SwiftUI
import AppKit

/// App-wide state. One instance, injected through the environment (Ledger's pattern).
@MainActor
@Observable
final class Store {
    /// The one instance, for the app delegate's quit check (B6).
    static weak var current: Store?
    var screen: Screen? = {
        if let s = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_TAB"], let sc = Screen(legacy: s) { return sc }   // M0: old tab names map
        return .home
    }()
    struct Toast: Equatable {
        var text: String; var error = false
        var undo: (() -> Void)? = nil                 // PLAN_OBJECTIVE_LIFECYCLE §5a Q8: an undo pill on the toast
        static func == (a: Toast, b: Toast) -> Bool { a.text == b.text && a.error == b.error && (a.undo == nil) == (b.undo == nil) }   // HUD7: X3's `nudge` style went with HUD5's alert router
    }
    var toast: Toast?
    /// PLAN_OBJECTIVE_LIFECYCLE: an objective to complete when the running session on it ends (§5a Q2); a delete the menu asked to confirm (§3.5).
    var completeOnEnd: String?
    var pendingDelete: String?
    // Z2–Z3 (PLAN_SCORING): the XP the ended session earned (the end card reads it), the streak freezes in hand
    var lastSessionXP: Int?
    var lastCourseMove: CourseMove?   // G3 (PLAN_GAME_LOOP §3.5): what the ended session moved on its course
    var freezes = 0

    // Status: the judge and the permissions.
    var ollamaOnline = false
    var ollamaModels: [String] = []
    var accessibility = false
    var screenRecording = false

    // Rules and the session (B1).
    var rules = Rules.load() { didSet { rules.save(); Classifier.learned = rules.classes } }   // X1: the watchers read the learned classes without a store
    var settings = AppSettings.load() { didSet { settings.save(); StudyDay.startHour = settings.dayStartHour } }   // K0: the study day follows the setting
    var catalog = Catalog.load() { didSet { catalog.save() } }     // subjects and objectives (PLAN_OBJECTIVES_MODEL O0)
    var openSubject: String?       // a subject page or an objective pane shown instead of the screen (PLAN_OBJECTIVES_TAB U0)
    var openObjective: String?
    // K2 (PLAN_STUDY_DAY §3.4–3.5): the shutdown screen's routing (the study day to close; read by ScreenView above openObjective),
    // the offer flag E's end card and the Home pill read, the ended session's summary for E's card, the study day already reminded.
    var openShutdown: Date?
    var offerShutdown = false
    var lastSessionSummary: SessionSummary?
    var shutdownRemindedFor: Date?
    var session: Session? { didSet { if let s = session { s.save() } else { Session.clear() } } }
    /// A session queued but not started (PLAN_CURRENT_SESSION C0 / PLAN_JUMP_BACK_IN §3.5): the Current Session widget's queued state.
    var queued: QueuedSession? { didSet { if let q = queued { q.save() } else { QueuedSession.clear() } } }
    @ObservationIgnored private(set) lazy var watcher = AppWatcher(store: self)
    @ObservationIgnored private(set) lazy var webWatcher = WebWatcher(store: self)
    let judge = Judge()
    @ObservationIgnored private(set) lazy var screenLook = ScreenLook(store: self)
    var lastJudgedAt: [String: Date] = [:]        // by app name: when text last settled it (the look's skip rule)
    var judgeSnoozedUntil: Date?
    /// Session-scoped (bypass study, §6 B3): sites blocked for the rest of the session; apps shielded for the rest of it;
    /// subjects answered "Back to work" whose next distracted verdict counts as "still here" at once.
    var blockedHosts: Set<String> = []
    var sessionShielded: Set<String> = []
    private var pendingBack: [String: Date] = [:]
    // PLAN_STATS_TAB S5: what the log did not record before — pause time, how long each detour lasted
    private var pausedSeconds = 0
    private var verdictAt: [String: Date] = [:]
    private var detourSeconds = 0

    enum Subject { case app(String), site(String) }
    var recentGoals: [String] = UserDefaults.standard.stringArray(forKey: "dbot.goals") ?? []

    // Today's figures for Home, from the log.
    var blockedToday = 0
    var warningsToday = 0
    var lastWarning: String?
    var focusedTodaySeconds = 0
    var events: [Event] = []
    /// The Today card's model (PLAN_TODAY_TIMELINE §3.2): today's rows, rebuilt on every log change and each second in a session.
    var today = DayModel.empty(day: Date(), now: Date())
    private var todayEvents: [Event] = []

    init() {
        Store.current = self
        Classifier.learned = rules.classes   // X1
        StudyDay.startHour = settings.dayStartHour   // K0 (PLAN_STUDY_DAY §3.1): before anything reads a "today"
        Shield.shared.store = self
        MiniPanel.shared.attach(store: self)   // C3: the mini panel watches the session and the app's activation
        if let s = Session.load() { session = s; watcher.start(); webWatcher.start() }
        else { queued = QueuedSession.load(catalog: catalog) }   // C0: the queue survives a relaunch (§5a Q3); a live session outranks it
        prefillQueueFromPlan()   // K2 (PLAN_STUDY_DAY §3.7): no queue, no session, a plan for today → its first item is queued
        // hard mode (B6): a resumed hard session keeps its guard; anything else drops a guard left behind
        // R1 (PLAN_REWORK §3.2, D22): a render or a quiet check (any `--flag`) loads a scratch session file and must never touch the real guard
        let quietRun = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] != nil || CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
        if session?.strictness.isHard == true { HardMode.arm() } else if !quietRun { HardMode.disarm() }
        Banner.shared.hard = session?.strictness.isHard == true
        _ = BrowserActions.blockedPage
        reloadLog()
        if let f = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_ICS"] { feed.loadFixture(path: f); reloadWeek() }   // W4: a render with a fixture feed, no network
        else if !quietRun { feedLoop() }   // W3: no network from an offscreen render, nor (2026-10-29) from a quiet `--check` run: those runs fetched the real feed until Google answered 429
        Log.write("store init session=\(session != nil)")
        Task { @MainActor [weak self] in
            var ticks = 0
            while let self {
                try? await Task.sleep(for: .seconds(1))
                self.tick()
                ticks += 1
                if ticks % 20 == 0 { await self.refreshStatus() }
            }
        }
    }

    static let supportDir: URL = {
        let u = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Distraction Bot")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    func go(_ s: Screen) {
        if screen != s || openSubject != nil || openObjective != nil || openShutdown != nil { EventLog.shared.ui("tab", s.rawValue) }   // K0 (PLAN_STUDY_DAY §3.8): one row per navigation
        screen = s; openSubject = nil; openObjective = nil; openShutdown = nil   // K2: a tab closes the shutdown screen too
    }
    /// Progress → Log (PLAN_STATS_TAB §5a Q8): open Log filtered to an app, host or query, over a range.
    struct LogQuery: Equatable { var text: String; var from: Date; var to: Date? = nil; var title: String? = nil }
    var logQuery: LogQuery?
    /// PLAN_HISTORY_TAB Y1 → M2: the Calendar tab's window subtitle — the week's range or the shown day (set by the screen; the outer `.navigationSubtitle` wins over an inner one).
    var calendarSubtitle = ""
    /// M2 (PLAN_STRUCTURE §3.3): Calendar draws the week or one day. The mode is remembered in `AppSettings.calendarMode`;
    /// `DBOT_SNAPSHOT_TAB=history` renders the Day view, `DBOT_SNAPSHOT_DAY=yyyy-MM-dd` picks the day.
    enum CalendarMode: String { case week, day }
    var calendarMode: CalendarMode = {
        if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_TAB"] == "history" { return .day }
        return CalendarMode(rawValue: AppSettings.load().calendarMode) ?? .week
    }() { didSet { if settings.calendarMode != calendarMode.rawValue { settings.calendarMode = calendarMode.rawValue } } }
    /// The study day the Day view shows (start of day); today unless a door or the toolbar picked another.
    var calendarDay: Date = {
        if let d = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_DAY"], let date = ISO8601DateFormatter.ymd.date(from: d) { return StudyDay.dayStarting(on: date) }   // K1: the study day beginning on that date
        return StudyDay.start(of: Date())
    }()
    /// A door to one day of the Calendar (Home's tiles, the sessions lists): lands in Day mode on that day.
    func go(_ s: Screen, day: Date) { calendarDay = StudyDay.start(of: day); calendarMode = .day; go(s) }   // K1: `day` is an instant or a study-day start (a week-grid date at midnight: use StudyDay.dayStarting(on:) first)
    func go(_ s: Screen, query: String, from: Date, to: Date? = nil, title: String? = nil) { logQuery = LogQuery(text: query, from: from, to: to, title: title); screen = s }
    /// M1 (PLAN_STRUCTURE §3.2): a door that opens the Log on one of its filter pills (`web` from Rules, `look` from Judge); the Log reads it once and clears it.
    var logFilter: String? = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_FILTER"]   // M1: a render lands on that pill
    func go(_ s: Screen, filter: String) { logFilter = filter; go(s) }
    /// Progress → Week in review: one calendar week, `offset` weeks back from this one.
    func weekStats(offset: Int) -> Stats {
        let cal = Calendar.current
        let now = Date()
        let thisWeek = StudyDay.weekStart(of: now)   // K1: Monday's study-day start
        let from = cal.date(byAdding: .weekOfYear, value: -offset, to: thisWeek)!
        let to = min(now, cal.date(byAdding: .weekOfYear, value: 1, to: from)! - 1)
        let period = Period(kind: .week, from: from, to: to)
        let fixture = ProcessInfo.processInfo.environment["DBOT_STATS_FIXTURE"] != nil ? Stats.fixture(now: now) : nil
        let events = fixture ?? EventLog.shared.events(from: from - 6 * 3600, to: to)
        let (plan, shutdown) = planClosures(from: from, to: to)   // Z1
        return Stats.compute(events: events, period: period, live: offset == 0 ? session : nil, now: to, targetMinutes: { [settings] in settings.targetMinutes(on: $0) }, showTests: !settings.hideTestSessions,
                             subjectOf: { [self] oid in subject(objective(oid)?.subjectId)?.shortName }, subject: statsSubject, plan: plan, shutdown: shutdown)
    }
    func show(_ text: String) { toast = Toast(text: text); dismissToast() }
    func show(_ text: String, undo: @escaping () -> Void) { toast = Toast(text: text, undo: undo); dismissToast(after: 6) }
    func fail(_ text: String) { toast = Toast(text: text, error: true); dismissToast() }
    private func dismissToast(after seconds: Int = 3) { let t = toast; Task { try? await Task.sleep(for: .seconds(seconds)); if toast == t { toast = nil } } }

    // MARK: Sessions (§3.2)

    /// `objective`/`kind` (PLAN_OBJECTIVES_MODEL O1): the session carries the ids and every event is stamped with them;
    /// the goal is already composed by `startSession(objective:…)`. A free-text goal leaves them nil and joins the recent list.
    func startSession(goal: String, minutes: Int?, strictness: Strictness, objective: Objective? = nil, kind: SessionKind? = nil) {
        let g = goal.trimmingCharacters(in: .whitespaces)
        // HUD4: the tasks come from the queue that is being started, else the objective's open ones; they move off the objective
        let q = queued
        let fromQueue = q.map { $0.objective?.id == objective?.id && (objective != nil || $0.goal == g) } ?? false
        let startTasks = (fromQueue ? q?.tasks : objective?.openTasks) ?? []
        session = Session(goal: g, started: Date(), ends: minutes.map { Date().addingTimeInterval(Double($0) * 60) }, strictness: strictness,
                          subjectId: objective?.subjectId, objectiveId: objective?.id, kind: kind)
        if (statsToday?.focusedSeconds ?? 0) > 0 { session?.dayScoreAtStart = statsToday?.score.total }   // G3: where the day stood
        if objective == nil, !g.isEmpty { recentGoals = ([g] + recentGoals.filter { $0 != g }).prefix(5).map { $0 }; UserDefaults.standard.set(recentGoals, forKey: "dbot.goals") }
        // Z0 (PLAN_SCORING §3.1): an open-ended objective session carries the objective's average real length as its yardstick (P's averageMinutes)
        var tail: [String] = []
        if let objective, minutes == nil, let avg = averageMinutes(of: objective) { tail.append("avg \(avg)") }
        EventLog.shared.add("session.start", detail: ([g, minutes.map { "\($0) min" } ?? "open", strictness.rawValue] + (kind.map { [$0.rawValue] } ?? []) + tail).joined(separator: " · "))
        lastWarnAt = [:]; blockedHosts = []; sessionShielded = []; pendingBack = [:]; lastJudgedAt = [:]
        sessionAllowed = []; ladders.values.forEach { $0.cancel() }; ladders = [:]; verdictWords = [:]; lastDistractionAt = nil; switchRate = 0   // X3 · X6
        pausedSeconds = 0; verdictAt = [:]; detourSeconds = 0
        toldLines = []   // E0
        lockUntil = nil; breakMinutesUsed = 0   // HUD3
        // HUD4: the starting tasks, each a `task.add` row inside the span; the objective keeps none while they are in play
        session?.tasks = startTasks.prefix(SessionTasks.maxTasks).map { SessionTask(title: $0) }
        for t in session?.tasks ?? [] { EventLog.shared.add("task.add", detail: t.title) }
        if let o = objective, let i = catalog.objectives.firstIndex(where: { $0.id == o.id }), !catalog.objectives[i].openTasks.isEmpty { catalog.objectives[i].openTasks = [] }
        queued = nil   // C0: any start, from anywhere, drops the queue (PLAN_JUMP_BACK_IN §3.5's rule)
        Banner.shared.hard = strictness.isHard
        if strictness.isHard { HardMode.arm(); EventLog.shared.add("session.hard", detail: "guard armed · phrase required to end") }
        watcher.start(); webWatcher.start()
        Task { await judge.warm() }
        show("Focus session started")
        reloadLog()
    }

    /// What every End button and menu item calls: a hard session asks for the phrase first (B6).
    func requestEnd() {
        guard let s = session else { return }
        if s.strictness.isHard {
            EscapeCard.shared.show(title: "End the session?", phrase: settings.escapePhrase, goal: s.goal) { [weak self] in self?.endSession(reason: "ended by phrase") }
        } else { endSession() }
    }

    /// ⌘Q or Quit: refused during a hard session unless the phrase is typed, which ends the session and then quits.
    /// Returns true when the app may quit now.
    func mayQuit() -> Bool {
        guard let s = session, s.strictness.isHard, ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] == nil else { return true }
        EventLog.shared.add("session.quit-refused", detail: "hard mode")
        Log.write("quit refused: hard session")
        EscapeCard.shared.show(title: "Quit Distraction Bot?", phrase: settings.escapePhrase, goal: s.goal) { [weak self] in
            self?.endSession(reason: "ended by phrase"); NSApp.terminate(nil)
        }
        return false
    }

    func endSession(reason: String = "ended") {
        guard let s = session else { return }
        // S5: the session's summary rows go in before session.end, so every span rule keeps them inside the session
        let usage = watcher.frontSeconds.filter { $0.value >= 30 }.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key)=\($0.value)" }
        if !usage.isEmpty { EventLog.shared.add("usage", detail: usage.joined(separator: " · ")) }
        EventLog.shared.add("switches", detail: "\(watcher.switchLog.total) · max10 \(watcher.switchLog.max10)")   // X3: Z reads the per-session switch figures
        ladders.values.forEach { $0.cancel() }; ladders = [:]   // X6b: the session's end cancels every follow-up
        EventLog.shared.add("session.summary", detail: "paused \(min(pausedSeconds, Int(s.elapsed))) · detour \(detourSeconds) · \(reason)")
        // HUD4 (§3.4): the tasks left open go back to the objective (HUD6's results screen gives the choice); `task.carry` rows
        let open = SessionTasks.open(s.tasks)
        if let oid = s.objectiveId, let i = catalog.objectives.firstIndex(where: { $0.id == oid }), !open.isEmpty {
            catalog.objectives[i].openTasks = open
            for t in open { EventLog.shared.add("task.carry", detail: t) }
        }
        noteSessionEnd(s, reason: reason, paused: min(pausedSeconds, Int(s.elapsed)), detour: detourSeconds)   // Z2 (PLAN_SCORING §3.3): the xp row
        EventLog.shared.add("session.end", detail: "\(Int(s.elapsed))")
        watcher.stop(); webWatcher.stop()
        session = nil
        Banner.shared.hard = false
        if s.strictness.isHard { HardMode.disarm() }
        reloadLog()
        noteSessionEnded(s, reason: reason)   // K3 (PLAN_STUDY_DAY §3.5): `lastSessionSummary` and `offerShutdown`, before E's card reads them
        // E2 (PLAN_OVERLAY §3.3, §5a Q8.4): the end card in the toast's place — the figures, the score, Z's XP rows when present
        if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] == nil, HUDRules.showsResults(elapsed: s.elapsed) { EndCard.shared.show(summary: endSummary(for: s, reason: reason), onNext: { MiniPanel.shared.openApp() }, onShutdown: { [weak self] in MiniPanel.shared.openApp(); self?.openShutdown() }) }   // K3: the card's `shut down the day` door
        if let id = completeOnEnd { completeOnEnd = nil; complete(id) }   // PLAN_OBJECTIVE_LIFECYCLE §5a Q2
    }

    /// E2: what the end card shows, from the log's record of the session just ended (K's `lastSessionSummary` can replace the lookup once it lands).
    func endSummary(for s: Session, reason: String) -> EndCard.Summary {
        let record = (statsToday?.sessions ?? []).last { abs($0.start.timeIntervalSince(s.started)) < 2 }
        var sum = EndCard.Summary(title: s.goal, reason: reason, seconds: Int(s.elapsed), score: .empty, hard: s.strictness.isHard)
        sum.offerShutdown = offerShutdown   // K3 (PLAN_STUDY_DAY §3.5): set by `noteSessionEnded` just before this
        sum.strictness = s.strictness.rawValue
        sum.scored = record != nil
        if let r = record {
            sum.seconds = r.focusedSeconds; sum.score = r.score
            sum.losses = Tally.session(r)   // F1 (PLAN_GAME_FEEL §3.1): the tally the card tells
            // M2 (PLAN_MINUTE_STRIP §3.4): the session's strip from its rows, and each loss pointed at its span
            let strip = SessionSpans.build(rows: EventLog.shared.events(session: s.id), start: r.start, end: r.end,
                                           planned: s.ends.map { Int($0.timeIntervalSince(s.started)) }, pausedTotal: r.pausedSeconds)
            sum.strip = strip; sum.losses = Tally.point(sum.losses, strip)
            sum.cleanMinutes = XP.clean(seconds: r.focusedSeconds, pausedSeconds: 0, detourSeconds: r.detourSeconds, awaySeconds: 0)
            sum.finished = r.finished
            sum.xp = r.xpRow
        }
        // F1: the streak's week row after this session; `lit` when this session made today a session day (nothing was focused before it)
        sum.cells = overall.weekCells; sum.today = overall.todayIndex; sum.streak = overall.streak
        sum.lit = s.dayScoreAtStart == nil && record.map { !$0.isTest } == true
        // F4: the course's longest clean session yet (never its first)
        if let r = record, let c = subject(s.subjectId), CourseProgress.isBest(r, after: sessionRecords(in: c).filter { $0.start < r.start }) {
            sum.best = "longest \(c.code ?? c.shortName) session yet"
        }
        if let x = lastSessionXP { sum.xp = x }   // Z's own figure for this End wins over the row read back
        sum.course = lastCourseMove   // G3 (PLAN_GAME_LOOP §3.5): the course line; the day's landing from the session's start
        sum.dayBefore = s.dayScoreAtStart
        sum.dayAfter = (statsToday?.focusedSeconds ?? 0) > 0 ? statsToday?.score.total : nil
        sum.next = queued?.goal
        // HUD6 (PLAN_SESSION_HUD §3.6): the results — the session replayed as a game, its losses pointed at the strip, XP by source, tasks
        if let r = record, let g = r.game {
            let rows = EventLog.shared.events(session: s.id)
            let strip = sum.strip ?? SessionSpans.build(rows: rows, start: r.start, end: r.end, planned: s.ends.map { Int($0.timeIntervalSince(s.started)) }, pausedTotal: r.pausedSeconds)
            sum.game = g
            sum.gameLosses = SessionGame.losses(spans: strip.spans, hits: SessionGame.hits(rows: rows, start: r.start, end: r.end), state: g, marks: strip.marks)
            sum.comboXP = Int((g.comboMinutes * XP.multiplier(r.strictness)).rounded())
            sum.cleanMinutes = g.cleanSeconds / 60
            sum.taskXP = SessionTasks.xpEach * r.tasksPaid
        }
        sum.tasksTotal = s.tasks.count; sum.tasksDone = s.tasks.filter(\.done).count
        sum.openTasks = SessionTasks.open(s.tasks); sum.objectiveId = s.objectiveId
        sum.objectiveDone = completeOnEnd != nil && completeOnEnd == s.objectiveId
        return sum
    }
    /// HUD6: the results screen's `carry to next time` — the open tasks on the objective, or off it (`task.carry` / `task.uncarry` rows).
    func setCarry(objectiveId: String, tasks: [String], on: Bool) {
        guard let i = catalog.objectives.firstIndex(where: { $0.id == objectiveId }) else { return }
        catalog.objectives[i].openTasks = on ? tasks : []
        for t in tasks { EventLog.shared.add(on ? "task.carry" : "task.uncarry", detail: t) }
    }

    // X3 (PLAN_CATCHER §3.4): the switch rate, published by the watcher each poll; the word for the live card's Now line (E and M draw it).
    var switchRate = 0
    var switchWord: String { SwitchLog.word(rate: switchRate, nudge: (session?.strictness ?? .normal).profile.switchNudge) }
    /// The quiet nudge (X3): the watcher logs `judge.nudge` before calling; HUD5 routes it like any alert (HUD line · menu bar · notification · off).
    /// HUD5: the catcher's restless nudge, routed like every alert (the HUD's line, the menu bar when it is hidden, or a notification).
    func nudge(text: String) { Alerts.shared.fire(.restless, text) }
    /// HUD5: an alert's text borrowed by the menu-bar title while the HUD cannot show it.
    var menuBarAlert: String?
    // X1/X5: the last verdict word per subject key and the last distracted verdict, for the PREVIOUS and DWELL lines
    private var verdictWords: [String: (String, Date)] = [:]
    var lastDistractionAt: Date?
    func verdictWord(appId: String) -> String? { verdictWords["app:" + appId]?.0 }
    // X4 (§3.5): idle ≥ the auto-pause threshold pauses the session 10 min, extended each minute while still idle; input back → a line with resume
    func autoPause() {
        guard let s = session, !s.strictness.isHard, !s.paused else { return }
        session?.pausedUntil = Date().addingTimeInterval(600); pausedSeconds += 600
        EventLog.shared.add("session.pause", detail: "10 min · away")
        Log.write("away: auto-paused")
    }
    func extendPause() {
        guard let s = session, s.paused else { return }
        session?.pausedUntil = Date().addingTimeInterval(600); pausedSeconds += 60
    }
    func awayReturned(seconds: Int) {
        guard session?.paused == true else { return }
        // R2 (D16): the line goes where the user is looking — the panel (its drawer has `resume`), else the window's toast with ⌘Z
        if MiniPanel.shared.visible { MiniPanel.shared.attention("away \(minutes(Double(seconds))) — paused · resume below", seconds: 10) }
        else { show("Away \(minutes(Double(seconds))) — paused · ⌘Z resumes", undo: { [weak self] in self?.resumeSession() }) }
    }

    /// HUD3: every pause the user asks for (the drawer, the menus, ⌃⌥B, the Current Session card) is a break now.
    func pauseSession(minutes m: Double = 10) { takeBreak(minutes: Int(m)) }

    // MARK: HUD3 — breaks (PLAN_SESSION_HUD §3.3, §5a Q8–Q9)

    /// A break: the session's clock runs on, accuracy, combo and XP are frozen (the pause row is an off span), the judge rests and the
    /// block list holds (the watchers read `onBreak`); nothing is charged. Hard and extreme take one only from the earned bank.
    @discardableResult
    func takeBreak(minutes m: Int) -> Bool {
        guard let s = session, !s.paused else { return false }
        let bank = breakBank(s)
        guard HUDRules.mayBreak(minutes: m, hard: s.strictness.isHard, bank: bank) else {
            fail(bank > 0 ? "Hard mode: \(bank) min of break earned" : "Hard mode: a break is earned by 25 clean minutes"); return false
        }
        session?.pausedUntil = Date().addingTimeInterval(Double(m) * 60)
        session?.onBreak = true; breakStartedAt = Date()
        pausedSeconds += m * 60
        Shield.shared.hide(); Banner.shared.clear()   // HUD0: a break clears every card, the waiting ones too
        EventLog.shared.add("session.pause", detail: "\(m) min · break")
        if HUDRules.route(.breakOver, settings: settings.alerts) == .notify { Alerts.shared.prepare() }   // HUD5: ask now, not when it runs out
        reloadLog()
        if !MiniPanel.shared.visible { show("Break · \(m) min") }
        return true
    }
    /// Minutes of break taken this session (from its `· break` pause rows), for the hard-mode bank.
    var breakMinutesUsed = 0
    /// When the break on now began (the HUD's ring); nil when none.
    var breakStartedAt: Date?
    /// The bank in hand: 5 min per 25 clean minutes, at most 20, less what was taken.
    func breakBank(_ s: Session) -> Int { HUDRules.breakBank(cleanSeconds: liveGame(s).cleanSeconds, usedMinutes: breakMinutesUsed) }
    /// The strict ladder's five minutes on the goal (HUD0 B5's card is gone); the judge stays on.
    var lockUntil: Date?
    var locked: Bool { lockUntil.map { $0 > Date() } ?? false }

    /// E1 (PLAN_OVERLAY §3.2): the mini panel's `resume` — the pause ends now; the paused seconds not taken are given back.
    func resumeSession() {
        guard let s = session, let p = s.pausedUntil, p > Date() else { return }
        pausedSeconds = max(0, pausedSeconds - Int(p.timeIntervalSinceNow))
        session?.pausedUntil = nil; session?.onBreak = false   // HUD3
        EventLog.shared.add("session.resume", detail: "\(Int(p.timeIntervalSinceNow / 60)) min early")
        show("Resumed")
    }

    /// Called every second by the window: ends a timed session when its time is up.
    func tick() {
        if let s = session, let e = s.ends, e <= Date() { endSession(reason: "finished") }
        if session != nil { screenLook.tick(); rebuildToday() }
        // HUD3: a break that ran out ends by itself — one line on the HUD and the one default sound (§5a Q16)
        if let s = session, s.onBreak, !s.paused {
            session?.onBreak = false
            EventLog.shared.ui("overlay", "break over")
            Alerts.shared.fire(.breakOver, "break over · back to \(s.goal.isEmpty ? "it" : s.goal)", seconds: 8)   // HUD5: routed (a notification by default)
            if HUDRules.route(.breakOver, settings: settings.alerts) != .off { playSound() }
        }
        // C0 (PLAN_CURRENT_SESSION §3.8): the score moves during a session — the aggregate is otherwise rebuilt only on log events
        MiniPanel.shared.tick()   // C3: the pointer's screen, a session's end, a flipped setting
        if session != nil, Date().timeIntervalSince(statsTickedAt) >= 60 { statsTickedAt = Date(); reloadStats(); refreshLiveStrip(); Log.write("stats ticked · score \(statsToday?.score.total ?? 0)") }
        // P2 (PLAN_PLANNING §3.3, Q4.6): the schedule's auto-start is gone — planned sessions come from the calendar; `AppSettings.schedule` stays decodable.
        // K3 (PLAN_STUDY_DAY §3.5): once a minute, the shutdown offer and the one reminder
        if Date().timeIntervalSince(shutdownTickedAt) >= 60 { shutdownTickedAt = Date(); recomputeShutdownOffer(); shutdownReminderTick() }
    }
    private var shutdownTickedAt = Date.distantPast
    private var statsTickedAt = Date()

    func playSound() { if settings.soundOn { NSSound(named: NSSound.Name(settings.soundName))?.play() } }

    /// Strict (§3.5): three warnings of any kind in 15 minutes → a 5-minute break card with the goal on it.
    private func strictLadder() {
        guard session?.strictness.profile.ladder == true else { return }   // O4: strict, hard, extreme
        let recent = EventLog.shared.recent(limit: 50, since: Date().addingTimeInterval(-900)).filter { $0.kind == "judge.verdict" && $0.detail.hasPrefix("distracted") || $0.kind == "web.warn" || $0.kind == "block.warn" }
        guard recent.count >= 3, breakUntil.map({ $0 < Date() }) ?? true else { return }
        breakUntil = Date().addingTimeInterval(300)
        EventLog.shared.add("session.break", detail: "three detours in 15 min · 5 min")
        // HUD3 (PLAN_SESSION_HUD §3.3): five minutes on the goal, drawn by the HUD (shown again if it was hidden) — no card, no timer
        // that can close someone else's card. The warning that tripped it is asked first, as before.
        lockUntil = Date().addingTimeInterval(HUDRules.lockSeconds)
        if MiniPanel.shared.isHidden { MiniPanel.shared.showAgain() }
    }
    private var breakUntil: Date?

    func exportCSV() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "distraction-bot-log.csv"; panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows: [String] = EventLog.shared.recent(limit: 100_000).map { e in
            let cells: [String] = [e.ts.ISO8601Format(), e.kind, e.app, e.detail, e.latencyMs.map(String.init) ?? ""]
            return cells.map(quoted).joined(separator: ",")
        }
        try? (["time,kind,app,detail,latency_ms"] + rows).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        show("Log exported")
    }
    func clearLog() { EventLog.shared.clear(); reloadLog(); show("Log cleared") }

    func noteBlock() { blockedToday += 1 }

    // MARK: The judge (§3.5, §5a Q19)

    /// Judges what is in front against the goal; a confident "distracted" becomes a warning with the three answers.
    /// X1/X2/X5 (PLAN_CATCHER): `appClass` · `dwell` · `previous` are logged in `judge.facts` and sent when the X5 flags are on; `quiet` = no sound (a utility budget card).
    func judge(front: String, kind: String, title: String, url: String?, what: String, subject: Subject, pid: pid_t, usage: String? = nil, screen: String? = nil,
               appClass: String? = nil, dwell: String? = nil, previous: String? = nil, quiet: Bool = false) async {
        guard let s = session, !s.paused else { return }
        lastJudgedAt[front] = Date()
        if let z = judgeSnoozedUntil, z > Date() { return }
        var allowed = rules.pinnedNames + rules.allowedSites
        allowed += rules.apps.filter { $0.value == .allowed }.keys.compactMap { id in NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName ?? id.split(separator: ".").last.map(String.init) }
        let facts = Judge.Facts(goal: s.goal + (Judge.sendTask ? SessionTasks.current(s.tasks).map { " — now: \($0)" } ?? "" : ""), minutesIn: Int(s.elapsed / 60), strictness: s.strictness.rawValue, allowed: allowed,
                                frontApp: front, frontKind: kind, title: title, url: url, screen: screen,
                                behind: Judge.behind(excluding: pid, privateApps: Rules.privateApps), recent: recentAnswers(front: front, url: url), usage: usage,   // X6a
                                subject: subjectLine, kind: s.kind.map { "\($0.rawValue) — \($0.hint)" }, leniency: s.strictness.profile.judgeLine,
                                dwell: dwell, appClass: appClass ?? { if case .site(let h) = subject { return Classifier.classOf(host: h).rawValue }; return nil }(), previous: previous)
        EventLog.shared.add("judge.facts", app: front, detail: Judge.factsLine(facts))   // X0 (PLAN_CATCHER §3.1): what the prompt said, for an exact replay; never SCREEN
        guard let v = await judge.judge(facts) else { return }
        // X1 §3.2 the return grace: the app was in front < 60 s and the person is back where they came from — not a verdict
        if case .app(let id) = subject, kind == "app", v.distracted, watcher.history.returned(from: id) {
            EventLog.shared.add("judge.returned", app: front, detail: "\(v.reason) · \(what)"); Log.write("judge: returned from \(front), verdict dropped"); reloadLog(); return
        }
        verdictWords[key(subject)] = (v.distracted ? "distracted" : "work", Date()); if v.distracted { lastDistractionAt = Date() }   // X5
        EventLog.shared.add("judge.verdict", app: front, detail: "\(v.distracted ? "distracted" : "work") \(String(format: "%.2f", v.confidence)) · \(v.reason) · \(what)", latencyMs: Int(v.seconds * 1000))
        reloadLog()
        // O4 §5a Q13: the Judge screen's threshold overrides normal only; every other level takes its profile
        let threshold = s.strictness == .normal ? judge.threshold : s.strictness.profile.threshold
        // HUD5 (§5a Q13): a lean towards a detour below the card's threshold is a quiet question, not a card
        if HUDRules.isDrifting(distracted: v.distracted, confidence: v.confidence, threshold: threshold) {
            Alerts.shared.fire(.drifting, "drifting? \(what.prefix(40)) — still \(s.goal.isEmpty ? "on it" : s.goal)?", key: what, seconds: 8)
        }
        guard v.distracted && v.confidence >= threshold else { return }
        if s.strictness.profile.closeOnVerdict { closeOnVerdict(what: what, subject: subject, reason: v.reason, pid: pid); return }
        // a verdict already in flight when Back to work was pressed is not evidence: 10 s of grace, then the next one counts (the 30-s follow-up covers the rest)
        if let t = pendingBack[key(subject)], Date().timeIntervalSince(t) < 600 {
            if Date().timeIntervalSince(t) >= 10 { escalate(what: what, subject: subject, why: "you said back to work \(Int(Date().timeIntervalSince(t))) s ago") }
            else { Log.write("verdict within 10 s of back to work: not counted") }
        }
        else {
            verdictAt[key(subject)] = Date()
            // X1 §5a Q1: a pinned app (Discord by default) is budgeted, never blocked — the card says so and its answers never block
            if case .app(let id) = subject, rules.isPinned(id) { warn(what: what, reason: "\(front) is never blocked — is this work? · \(v.reason)", subject: subject, quiet: quiet, noBlock: true) }
            else { warn(what: what, reason: v.reason, subject: subject, quiet: quiet) }
        }
    }

    /// Extreme (O4 §3.10, §5a Q11): a confident distracted verdict acts at once — the app is closed and shielded for the session, a site is
    /// blocked — then the card says so; "This is work" is the one answer that undoes it (the app is re-allowed, not relaunched).
    func closeOnVerdict(what: String, subject: Subject, reason: String, pid: pid_t) {
        let k = key(subject)
        lastWarnAt[k] = Date(); noteWarning(what); playSound()
        verdictAt[k] = Date(); noteDetour(subject, what: what, how: "closed on verdict")
        switch subject {
        case .site(let host):
            blockedHosts.insert(host)
            if let f = NSWorkspace.shared.frontmostApplication, let page = BrowserReader.read(f), Rules.matches(page.host, host) { BrowserActions.block(page: page, store: self) }
            EventLog.shared.add("judge.close", app: "", detail: "\(host) · blocked for the session · \(reason)")
        case .app(let id):
            sessionShielded.insert(id)
            EventLog.shared.add("judge.close", app: NSRunningApplication(processIdentifier: pid)?.localizedName ?? id, detail: "closed for the session · \(reason)")
            watcher.closeOnVerdict(id: id)
        }
        Banner.shared.show(title: "Closed", text: what, reason: "closed: \(reason)", timeout: session?.strictness.profile.answerSeconds, key: k) { [weak self] a in   // HUD0: keyed by subject
            guard let self else { return }
            EventLog.shared.add("judge.answer", detail: "\(a) · \(what) · after close")
            switch (a, subject) {
            case ("work", .site(let host)): blockedHosts.remove(host); webWatcher.allow(host: host); show("\(host) is allowed again")
            case ("work", .app(let id)): sessionShielded.remove(id); rules.apps[id] = .allowed; show("\(what) is allowed from now on")
            default: break   // the close holds
            }
            reloadLog()
        }
        reloadLog()
    }

    /// S5: how long a detour lasted, from the distracted verdict to the moment it ended (followed through, blocked, or answered).
    private func noteDetour(_ subject: Subject, what: String, how: String) {
        guard let t = verdictAt[key(subject)] else { return }
        verdictAt[key(subject)] = nil
        let secs = Int(Date().timeIntervalSince(t))
        detourSeconds += secs
        EventLog.shared.add("judge.detour", detail: "\(secs) · \(how) · \(what)")
    }

    private func key(_ subject: Subject) -> String { switch subject { case .app(let id): return "app:" + id; case .site(let h): return "site:" + h } }

    private var lastWarnAt: [String: Date] = [:]

    /// The banner with its three answers; "This is work" teaches (allow list or an explicit allowed app).
    /// One warning per site or app per 2 minutes, whatever path raised it.
    /// X1: `quiet` = no sound (a utility budget card); `noBlock` = the answers never escalate or follow up (an always-allowed app's budget card).
    func warn(what: String, reason: String, subject: Subject, quiet: Bool = false, noBlock: Bool = false) {
        let key = key(subject)
        if let t = lastWarnAt[key], Date().timeIntervalSince(t) < 120 { Log.write("warn skipped (\(key) warned \(Int(Date().timeIntervalSince(t))) s ago)"); return }
        lastWarnAt[key] = Date()
        noteWarning(what)
        if !quiet, !Banner.isBudgetCard(judge.lastFacts, judgedAt: judge.lastFacts.flatMap { lastJudgedAt[$0.frontApp] }) { playSound() }   // E0 §3.1: no sound for a budget card (X's utility/communication classes)
        strictLadder()
        let profile = (session?.strictness ?? .normal).profile                       // O4: the level's weights instead of literals
        let timeout: TimeInterval = profile.answerSeconds ?? 30                        // laxed: the card fades at 30 s and nothing follows
        Banner.shared.show(title: "Looks like a detour", text: what, reason: reason, timeout: timeout, key: key) { [weak self] a in   // HUD0: keyed by subject
            guard let self else { return }
            EventLog.shared.add("judge.answer", detail: "\(a) · \(what)" + Banner.shared.answerSuffix)   // E0: `· scope <s>` / `· <n> min` (X's row format)
            switch (a, subject) {
            case ("cleared", _): verdictAt[key] = nil   // E0: the re-run after a told line said work — no detour, nothing taught
            case ("ignored", _):
                if !profile.ignoredBlocks || noBlock { Banner.shared.hide() }   // X1: an always-allowed app's card never blocks
                else { escalate(what: what, subject: subject, why: "No answer in \(Int(timeout)) s", title: "Blocked") }
            case ("back", _): pendingBack[key] = Date(); if profile.followUp, !noBlock { followUp(what: what, subject: subject) } else { noteDetour(subject, what: what, how: "back") }
            case ("work", _): verdictAt[key] = nil; cancelLadder(key); teach(subject, what: what, scope: AnswerScope(banner: Banner.shared.lastScope))   // X6a: scoped
            case ("snooze", _):
                let m = Banner.shared.snoozeMinutes   // E0: the snooze menu's 5 · 10 · 25
                noteDetour(subject, what: what, how: "snoozed")
                judgeSnoozedUntil = Date().addingTimeInterval(Double(m) * 60); webWatcher.snoozedUntil = judgeSnoozedUntil; show("Warnings snoozed for \(m) minutes")
            default: break
            }
            reloadLog()
        }
    }

    // E0 (PLAN_OVERLAY §3.1): tell the judge — the person's own words become a RECENT line and the one verdict is re-run.
    /// The told lines of this session (X: fold into the 14-day `recentAnswers` reader; the row is `judge.answer · told · <text>`).
    var toldLines: [String] = []
    func told(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        toldLines.append(t)
        EventLog.shared.add("judge.answer", detail: "told · \(t)")
        reloadLog()
    }
    /// Re-runs the judge once on the stored facts with the fresh RECENT lines; the card's reason updates in place, or the card clears on `work`.
    func rejudgeLast() {
        guard var f = judge.lastFacts, let s = session else { return }
        f.recent = recentAnswers()
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let v = await judge.judge(f) else { Banner.shared.reason = "the judge did not answer · the card stays"; return }
            EventLog.shared.add("judge.verdict", app: f.frontApp, detail: "\(v.distracted ? "distracted" : "work") \(String(format: "%.2f", v.confidence)) · \(v.reason) · re-run after told", latencyMs: Int(v.seconds * 1000))
            let threshold = s.strictness == .normal ? judge.threshold : s.strictness.profile.threshold
            if v.distracted && v.confidence >= threshold { Banner.shared.reason = "still a detour: \(v.reason)" } else { Banner.shared.answer("cleared") }
            reloadLog()
        }
    }

    // MARK: X6a scoped teaching (PLAN_CATCHER §3.7)

    /// How far a "This is work" answer reaches: a RECENT line only · not judged again this session · the allow list (and `Rules.taught`).
    enum AnswerScope: String, CaseIterable { case once, session, always
        init(banner s: Banner.Scope?) { self = s.flatMap { AnswerScope(rawValue: String(describing: $0)) } ?? .session }
    }
    /// Keys (`app:<bundle>` · `site:<host>`) answered "work · this session": not judged again until End.
    var sessionAllowed: Set<String> = []
    /// The card's answer with a scope (E draws the pills and calls this): `work` with a scope, `snooze` with minutes, `back`, `ignored`.
    func answer(_ a: String, scope: AnswerScope = .session, minutes: Int? = nil) {
        Banner.shared.lastScope = Banner.Scope.allCases.first { String(describing: $0) == scope.rawValue }
        if let m = minutes { Banner.shared.snoozeMinutes = m }
        Banner.shared.answer(a)
    }
    func isSessionAllowed(_ subject: Subject) -> Bool { sessionAllowed.contains(key(subject)) }
    private func teach(_ subject: Subject, what: String, scope: AnswerScope) {
        switch (scope, subject) {
        case (.once, _): show("Noted for this one")
        case (.session, .site(let host)): sessionAllowed.insert(key(subject)); blockedHosts.remove(host); show("\(host) is allowed for this session")
        case (.session, .app(let id)): sessionAllowed.insert(key(subject)); sessionShielded.remove(id); show("\(what) is allowed for this session")
        case (.always, .site(let host)): blockedHosts.remove(host); webWatcher.allow(host: host); rules.taught[host] = Date(); show("\(host) is allowed from now on")
        case (.always, .app(let id)): sessionShielded.remove(id); rules.apps[id] = .allowed; rules.taught[id] = Date(); show("\(what) is allowed from now on")
        }
    }
    /// The Rules tab's `forget`: the host or app is judged again, the date goes.
    func forgetTaught(_ key: String) {
        rules.taught.removeValue(forKey: key)
        rules.allowedSites.removeAll { $0 == key }
        if rules.apps[key] == .allowed { rules.apps.removeValue(forKey: key) }
    }

    // MARK: X6b the follow-up ladder (§3.8)

    private var ladders: [String: Task<Void, Never>] = [:]
    private func cancelLadder(_ key: String) { ladders[key]?.cancel(); ladders[key] = nil }
    /// §5a Q22 + X6b: after "Back to work", three checks at 30 s · 3 min · 10 min (each ± 20 %), cancelled by a `work` answer or End.
    /// The 3- and 10-min checks look for the same *class* (an entertainment host or app in front), not only the key; the first positive escalates and stops.
    func followUp(what: String, subject: Subject) { followUps(what: what, subject: subject) }
    func followUps(what: String, subject: Subject) {
        let k = key(subject)
        cancelLadder(k)
        ladders[k] = Task { @MainActor [weak self] in
            var elapsed = 0.0
            for (base, label) in [(30.0, "30 s"), (180.0, "3 min"), (600.0, "10 min")] {
                let at = base * Double.random(in: 0.8...1.2)
                try? await Task.sleep(for: .seconds(max(1, at - elapsed))); elapsed = at
                guard !Task.isCancelled, let self, session != nil else { return }
                let front = NSWorkspace.shared.frontmostApplication
                let page = front.flatMap { BrowserReader.read($0) }
                let sameKey: Bool = { switch subject { case .site(let host): return page.map { Rules.matches($0.host, host) } ?? false; case .app(let id): return front?.bundleIdentifier == id } }()
                let sameClass = base > 30 && ((page.map { Classifier.classOf(host: $0.host) == .entertainment } ?? false)
                                              || (front.flatMap { f in f.bundleIdentifier.map { Classifier.classOf(app: $0, name: f.localizedName ?? "") == .entertainment } } ?? false))
                if sameKey || sameClass {
                    ladders[k] = nil
                    escalate(what: what, subject: subject, why: sameKey ? "You said back to work \(label) ago" : "You said back to work \(label) ago and this is more of the same")
                    return
                }
                EventLog.shared.add("judge.followup", detail: "followed through · \(what) · at \(label)")
                if base == 30 { noteDetour(subject, what: what, how: "followed through"); pendingBack[k] = nil }
                reloadLog()
            }
            ladders[k] = nil
        }
    }

    /// "Still here": block the site for the rest of the session (every later visit is blocked before the judge),
    /// or hide the app behind the shield for the rest of the session. The card explains; Back to work on it re-arms the follow-up.
    func escalate(what: String, subject: Subject, why: String, title: String = "Still here") {
        pendingBack[key(subject)] = nil
        lastWarnAt[key(subject)] = nil
        noteDetour(subject, what: what, how: "blocked")
        switch subject {
        case .site(let host):
            blockedHosts.insert(host)
            EventLog.shared.add("judge.followup", app: "", detail: "still in front · \(host) · blocked for the session")
            if let f = NSWorkspace.shared.frontmostApplication, let page = BrowserReader.read(f), Rules.matches(page.host, host) { BrowserActions.block(page: page, store: self) }
            Banner.shared.show(title: title, text: what, reason: "\(why); \(host) is blocked for the rest of the session.", timeout: nil, key: key(subject)) { [weak self] a in   // HUD0: replaces this subject's card in place
                self?.answerAfterFollowUp(a, what: what, subject: subject)
            }
        case .app(let id):
            sessionShielded.insert(id)
            EventLog.shared.add("judge.followup", app: id, detail: "\(why) · shielded for the session")
            Banner.shared.hide()
            if let f = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                f.hide()
                Shield.shared.show(app: f, name: f.localizedName ?? id, attempts: 1, mode: .wall)
            }
        }
        reloadLog()
    }
    private func answerAfterFollowUp(_ a: String, what: String, subject: Subject) {
        EventLog.shared.add("judge.answer", detail: "\(a) · \(what) · after follow-up")
        switch (a, subject) {
        case ("work", .site(let host)): blockedHosts.remove(host); webWatcher.allow(host: host)
        case ("snooze", _): judgeSnoozedUntil = Date().addingTimeInterval(600); webWatcher.snoozedUntil = judgeSnoozedUntil
        default: break   // the session block already holds
        }
        reloadLog()
    }

    /// The person's own answers as few-shot lines for the judge. X6a (§3.7): the last **14 days**, the ones about the current front app or
    /// host first, then the newest, ≤ 8 lines; the told lines of this session after them (E0).
    func recentAnswers(front: String? = nil, url: String? = nil) -> [String] {
        guard session != nil else { return [] }
        let host = url.flatMap { URL(string: $0)?.host }?.replacingOccurrences(of: "www.", with: "") ?? ""
        let rows = EventLog.shared.recent(limit: 400, since: Date().addingTimeInterval(-14 * 86400)).filter { $0.kind == "judge.answer" }
        var lines: [(String, Bool)] = []   // (line, about the front)
        var seen: Set<String> = []
        for e in rows {
            let (a, what) = Replay.parse(answer: e.detail)
            guard !what.isEmpty else { continue }
            let line: String
            switch a { case "work": line = "\(what) → you said: work"; case "back", "ignored": line = "\(what) → you said: distraction"; default: continue }
            guard !seen.contains(line) else { continue }; seen.insert(line)
            let about = (front.map { !$0.isEmpty && what.localizedCaseInsensitiveContains($0) } ?? false) || (!host.isEmpty && what.localizedCaseInsensitiveContains(host))
            lines.append((line, about))
        }
        let ordered = lines.filter(\.1).map(\.0) + lines.filter { !$0.1 }.map(\.0)
        return Array(ordered.prefix(8)) + toldLines.suffix(3).map { "you said: \"\($0)\"" }   // E0: the told lines
    }
    func noteWarning(_ text: String) { warningsToday += 1; lastWarning = text }

    func reloadLog() {
        let day = StudyDay.start(of: Date())   // K1 (PLAN_STUDY_DAY §3.2): today's rows run from the study day's start
        events = EventLog.shared.recent(limit: 300)
        blockedToday = EventLog.shared.count("block.close", since: day) + EventLog.shared.count("block.shield", since: day)
        warningsToday = EventLog.shared.count("block.warn", since: day) + EventLog.shared.count("web.warn", since: day) + EventLog.shared.count("judge.verdict", since: day)
        lastWarning = events.first { $0.kind == "block.warn" || $0.kind == "web.warn" || ($0.kind == "judge.verdict" && $0.detail.hasPrefix("distracted")) }.map { "\($0.detail.isEmpty ? $0.app : $0.detail) · \(clock($0.ts))" }
        focusedTodaySeconds = EventLog.shared.focusedSeconds(since: day)
        todayEvents = EventLog.shared.events(from: day, to: StudyDay.end(of: day))
        rebuildToday()
        reloadScoring()   // Z3 (PLAN_SCORING §3.4): earn and apply freezes — before the streak is built
        overall = OverallFigures.build(events: EventLog.shared.events(from: .distantPast, to: Date()), live: session)   // Home's Overall widget (H1)
        reloadStats()
        reloadWeek()
        refreshLiveStrip()
    }
    // PLAN_MINUTE_STRIP M1 (§3.3): the live session's strip, rebuilt with the log (every detour, away and pause row reloads it) and once a
    // minute; the cards add the tail since with `SessionSpans.live`.
    var liveStrip = SessionSpans.Strip()
    var liveStripRows: [Event]? = nil   // a render's fixture rows in place of the log's
    func refreshLiveStrip() {
        guard let s = session else { liveStrip = .init(); liveHits = []; return }
        let rows = liveStripRows ?? EventLog.shared.events(session: s.id)
        liveStrip = SessionSpans.build(rows: rows, start: s.started, end: Date(), planned: nil, pausedTotal: nil)
        liveHits = SessionGame.hits(rows: rows, start: s.started, end: Date())   // HUD2: the same rows, so the live game is the replay
        liveTaskPaid = SessionTasks.paidTitles(rows: rows, start: s.started)   // HUD4
        breakMinutesUsed = rows.filter { $0.kind == "session.pause" && $0.detail.hasSuffix("· break") }.compactMap { Int($0.detail.split(separator: " ").first ?? "") }.reduce(0, +)   // HUD3
    }
    // HUD2 (PLAN_SESSION_HUD §3.2): the session played live — the strip's spans with their tail, and the hits from the same rows.
    // `SessionGame.play` over these is exactly what the replay of the ended session will give (`scripts/game-check.swift` judges it).
    var liveHits: [SessionGame.Hit] = []
    func liveGame(_ s: Session, now: Date = Date()) -> SessionGame.State { SessionGame.play(spans: liveSpans(s, now: now), hits: liveHits) }
    /// The XP the session has earned so far: combo-paid minutes × the dial, + 10 per paid task (the +30 for finishing comes at the end).
    func liveXP(_ s: Session, _ g: SessionGame.State) -> Int { Int((g.comboMinutes * XP.multiplier(s.strictness.rawValue)).rounded()) + SessionTasks.xpEach * liveTaskPaid.count }

    // MARK: HUD4 — tasks (PLAN_SESSION_HUD §3.4)

    /// The titles whose tick paid this session (the rule in `SessionTasks.paidTitles`, over the session's rows).
    var liveTaskPaid: Set<String> = []
    func addTask(_ title: String) {
        guard session != nil, let t = SessionTasks.clean(title), (session?.tasks.count ?? 0) < SessionTasks.maxTasks else { return }
        session?.tasks.append(SessionTask(title: t))
        EventLog.shared.add("task.add", detail: t); reloadLog()
        MiniPanel.shared.refreshFrame()
    }
    func toggleTask(_ id: String) {
        guard let i = session?.tasks.firstIndex(where: { $0.id == id }), let t = session?.tasks[i] else { return }
        let before = liveTaskPaid
        session?.tasks[i].doneAt = t.done ? nil : Date()
        EventLog.shared.add(t.done ? "task.undo" : "task.done", detail: t.title)
        reloadLog()
        if !t.done, !before.contains(t.title), liveTaskPaid.contains(t.title) { MiniPanel.shared.attention("+\(SessionTasks.xpEach) XP · \(t.title)", seconds: 3) }
    }
    func removeTask(_ id: String) {
        guard let i = session?.tasks.firstIndex(where: { $0.id == id }), let t = session?.tasks[i] else { return }
        session?.tasks.remove(at: i)
        EventLog.shared.add("task.remove", detail: t.title); reloadLog()
        MiniPanel.shared.refreshFrame()
    }
    /// The queue's tasks, set on the Current Session card before a start.
    func addQueuedTask(_ title: String) {
        guard var q = queued, let t = SessionTasks.clean(title), q.tasks.count < SessionTasks.maxTasks else { return }
        q.tasks.append(t); queued = q
    }
    func removeQueuedTask(at i: Int) { guard var q = queued, q.tasks.indices.contains(i) else { return }; q.tasks.remove(at: i); queued = q }
    /// §5a Q20: the longest combo on this session's course before today's session, the best to chase (nil with no history).
    func courseBestCombo(_ s: Session) -> Int? {
        guard let sub = s.subjectId else { return nil }
        return (statsAll?.sessions ?? []).filter { !$0.live && objective($0.objectiveId)?.subjectId == sub }.compactMap { $0.game?.bestCombo }.max()
    }
    /// The live strip at `now`: the built spans, the tail, an away span still open.
    func liveSpans(_ s: Session, now: Date) -> [StripSpan] {
        SessionSpans.live(liveStrip.spans, now: max(0, Int(now.timeIntervalSince(s.started))), paused: s.paused,
                          awayFrom: watcher.away.awaySince.map { Int($0.timeIntervalSince(s.started)) })
    }
    /// The strip's full width: the plan, or for an open session the longer of its yardstick and the time so far (§5a Q3).
    func liveStripLength(_ s: Session, now: Date) -> Int {
        let elapsed = max(1, Int(now.timeIntervalSince(s.started)))
        if let e = s.ends { return max(elapsed, Int(e.timeIntervalSince(s.started))) }
        let yard = (objective(s.objectiveId).flatMap { averageMinutes(of: $0) } ?? 25) * 60
        return max(elapsed, yard)
    }
    // PLAN_WEEK_CALENDAR W0: the Calendar tab's week, rebuilt with the log and when the week changes
    var weekStart: Date = WeekModel.start(of: ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_WEEK"].flatMap { ISO8601DateFormatter.ymd.date(from: $0) } ?? Date()) { didSet { reloadWeek() } }
    var week = WeekModel.empty(week: WeekModel.start(of: Date()))
    /// Your calendar (W3): the feed, its cache read at init, refreshed by `feedLoop` every minute's check against the interval.
    let feed = ICSFeed()
    private func feedLoop() {
        feed.loadCache(for: settings.icsURL)
        Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                if !self.settings.icsURL.isEmpty, self.feed.isStale(interval: self.settings.icsRefreshMinutes) {
                    await self.feed.refresh(url: self.settings.icsURL, interval: self.settings.icsRefreshMinutes)
                    self.reloadWeek()
                }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }
    /// Settings: a new address fetches at once; an emptied one forgets the cache (the two files this feature wrote).
    func feedURLChanged() {
        if settings.icsURL.trimmingCharacters(in: .whitespaces).isEmpty { feed.clear(); reloadWeek(); return }
        Task { @MainActor in await feed.refresh(url: settings.icsURL); reloadWeek() }
    }
    /// The "fetch now" button: the one place a failure is shown as a toast (§5a Q12).
    func fetchFeedNow() {
        Task { @MainActor in
            if let e = await feed.refresh(url: settings.icsURL) { fail("calendar: \(e)") } else { show("calendar fetched · \(feed.eventCount) events") }
            reloadWeek()
        }
    }
    func reloadWeek() {
        let cal = Calendar.current
        let from = cal.date(byAdding: .day, value: -1, to: weekStart)!, to = cal.date(byAdding: .day, value: 8, to: weekStart)!
        let rows: [WeekModel.Row] = EventLog.shared.sessions(since: from).filter { $0.started < to }.map { s in
            let es = EventLog.shared.events(session: s.id)
            let paused = es.last { $0.kind == "session.summary" }?.detail.components(separatedBy: " · ").first { $0.hasPrefix("paused ") }.flatMap { Int($0.dropFirst(7)) }
            return WeekModel.Row(id: s.id, objectiveId: s.objectiveId, goal: s.goal, started: s.started, ended: s.ended, seconds: s.seconds, strictness: s.strictness,
                                 warnings: s.warnings, blocks: s.blocks, live: s.endedBy == "live", pauses: es.filter { $0.kind == "session.pause" }.map(\.ts), pausedSeconds: paused)
        }
        today.planned = plannedBlocks(day: Date())   // P2: a fetched feed updates the Today strip's planned blocks too
        let feedModel = WeekModel.Feed(instances: feed.instances(from: from, to: to), name: feed.name, tint: settings.icsColor, show: settings.showFeed && settings.icsURL.isEmpty == false || feed.fixture)
        week = WeekModel.build(sessions: rows, feed: feedModel, week: weekStart, now: Date(), who: { [self] oid in
            guard let o = objective(oid), let s = subject(o.subjectId) else { return nil }
            return WeekModel.Who(title: o.title, icon: o.icon, code: s.code ?? s.shortName, tint: s.accent, subjectId: s.id)
        }, showTests: !settings.hideTestSessions || ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_TESTS"] != nil)   // the env: a render with tests shown, prefs untouched
    }
    var overall = OverallFigures()
    /// The Progress tab (PLAN_STATS_TAB): the chosen range, the last 7 days (sparklines, the pace average) and today (the pace chart).
    var statsPeriod: Period.Kind = Period.Kind(rawValue: ProcessInfo.processInfo.environment["DBOT_STATS_PERIOD"] ?? "") ?? .today { didSet { reloadStats() } }
    var stats: Stats?
    var statsWeek: Stats?
    var statsToday: Stats?
    var statsPrevious: Stats?        // the same length of time before the range, for trend arrows
    var statsAll: Stats?             // everything, for the heatmap, the year strip, creep and streaks
    var statsSubject: String? { didSet { reloadStats() } }     // S5: the subject pill; nil = every subject
    func reloadStats() {
        let now = Date()
        let fixture = ProcessInfo.processInfo.environment["DBOT_STATS_FIXTURE"] != nil ? Stats.fixture(now: now) : nil
        // Z5: DBOT_SNAPSHOT_UNPLANNED=1 renders the unplanned day (target 0, no plan) without touching prefs.json
        let target: (Date) -> Int = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_UNPLANNED"] != nil ? { _ in 0 } : { [settings] in settings.targetMinutes(on: $0) }
        let subjectOf: (String?) -> String? = { [self] oid in subject(objective(oid)?.subjectId)?.shortName }
        let (plan, shutdown) = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_UNPLANNED"] != nil ? ({ _ in nil }, { _ in false }) : planClosures(from: .distantPast, to: now)   // Z1 (PLAN_SCORING §3.2): the day's plan and its shutdown, once for every range
        func make(_ kind: Period.Kind, filtered: Bool = true) -> Stats {
            let p = Period.make(kind, now: now)
            let events = fixture ?? EventLog.shared.events(from: p.from == .distantPast ? .distantPast : p.from - 6 * 3600, to: now)
            return Stats.compute(events: events, period: p, live: session, now: now, targetMinutes: target, showTests: !settings.hideTestSessions,
                                 subjectOf: subjectOf, subject: filtered ? statsSubject : nil, plan: plan, shutdown: shutdown)
        }
        statsToday = make(.today)
        statsAll = make(.all, filtered: false)          // unfiltered: the subject rings and the pills need every subject
        statsWeek = statsPeriod == .week ? nil : make(.week)
        stats = statsPeriod == .today ? statsToday : make(statsPeriod)
        if statsPeriod == .week { statsWeek = stats }
        if let p = stats.flatMap({ Period.previous(of: $0.period) }) {
            let events = fixture ?? EventLog.shared.events(from: p.from - 6 * 3600, to: p.to)
            statsPrevious = Stats.compute(events: events, period: p, live: nil, now: p.to, targetMinutes: target, showTests: !settings.hideTestSessions, subjectOf: subjectOf, subject: statsSubject,
                                          plan: plan, shutdown: shutdown)   // Z1
        } else { statsPrevious = nil }
    }
    func rebuildToday() {
        defer { today.planned = plannedBlocks(day: Date()) }   // P2 (PLAN_PLANNING §3.3): the calendar's planned blocks ride on the model
        today = DayModel.build(events: todayEvents, live: session.map { DayModel.Live(started: $0.started) }, day: Date(), now: Date(), threshold: judge.threshold,
                               target: TimeInterval(settings.targetMinutes(on: Date()) * 60))      // PLAN_TODAY_SCHEDULE D0: the plan line
    }
    var focusedTodayText: String { minutes(Double(focusedTodaySeconds + Int(session?.elapsed ?? 0))) }

    // MARK: Status

    func refreshStatus() async {
        accessibility = Permissions.accessibilityTrusted
        screenRecording = Permissions.screenRecordingGranted
        // status.json: what macOS grants this bundle, as the app itself sees it (a terminal launch is attributed to the terminal, so it cannot check)
        let status = "{\"accessibility\": \(accessibility), \"screenRecording\": \(screenRecording), \"checked\": \"\(Date().ISO8601Format())\"}\n"
        // a render (DBOT_SNAPSHOT) leaves the installed app's folder alone (PLAN_PUBLIC_RELEASE P1)
        if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] == nil { try? status.write(to: Self.supportDir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8) }
        let (online, models) = await Ollama.status()
        ollamaOnline = online; ollamaModels = models
    }
}
