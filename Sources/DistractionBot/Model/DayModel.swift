import Foundation

/// One row of the event log, as the day model reads it. `Event` conforms; the check script brings its own.
protocol LogRow {
    var ts: Date { get }
    var kind: String { get }
    var app: String { get }
    var detail: String { get }
    // PLAN_TODAY_SCHEDULE D0: the O1 stamps, so a block knows its session and objective (nil on unstamped rows)
    var sessionId: String? { get }
    var objectiveId: String? { get }
    var sessionKind: String? { get }
}
extension LogRow {
    var sessionId: String? { nil }
    var objectiveId: String? { nil }
    var sessionKind: String? { nil }
}

/// The day as the Today card draws it (PLAN_TODAY_TIMELINE.md §3.2): sessions as blocks, distraction
/// periods derived from the warnings, answers and follow-ups, blocks as ticks, and the day's figures.
/// Pure: a function of the rows, the live session and `now`. Nothing here reads the log or the clock.
struct DayModel {
    struct Span: Equatable { let start: Date; let end: Date; let label: String }                     // paused · break · 5 more minutes
    struct Block: Equatable {
        let start: Date; let end: Date; let goal: String; let length: String; let strictness: String
        let ended: Bool                     // false: no session.end was logged (the app was quit, or the test harness)
        let live: Bool
        var pauses: [Span]
        // PLAN_TODAY_SCHEDULE D0 (§3.5): the session's stamps — the view resolves the objective through the catalogue
        var sessionId: String? = nil
        var objectiveId: String? = nil
        var kindTag: String? = nil
        var detours = 0                     // warned periods that began inside the block (false alarms excluded)
        var duration: TimeInterval { end.timeIntervalSince(start) }
        /// The Stats rule (`SessionRecord.isTest`, §5a Q7): a B-phase test goal, or under two minutes and not live.
        var isTest: Bool {
            if goal.range(of: #"^B\d+\s"#, options: .regularExpression) != nil { return true }
            return !live && duration < 120
        }
    }
    enum Outcome: String { case back, blocked, work, snoozed, open }
    enum Kind: Equatable { case site, app, look }
    struct Period: Equatable {
        let start: Date
        var end: Date
        let subject: String                 // the `what` string the rows were joined on
        let front: String                   // the front app at the first signal (the verdict's `app`)
        let kind: Kind
        var outcome: Outcome
        let title: String
        var reason: String
        var blocks: [Date]                  // block ticks inside it
        var answers: [String]
        var duration: TimeInterval { end.timeIntervalSince(start) }
        var falseAlarm: Bool { outcome == .work }
    }
    struct Tick: Equatable { let at: Date; let what: String; let kind: String }                     // block.close · block.shield · web.block
    struct Figures: Equatable {
        var focused: TimeInterval = 0, distracted: TimeInterval = 0, paused: TimeInterval = 0
        var away: TimeInterval = 0                                      // X4: excluded from `focused`, not part of `paused`
        var sessions = 0, detours = 0, falseAlarms = 0, blocks = 0
        // PLAN_TODAY_SCHEDULE D0 (§3.4): progress through the day — sessions done (ended, not tests), the one on, the plan
        var sessionsDone = 0, sessionsLive = 0
        var target: TimeInterval? = nil                                 // the daily target; nil = no plan (a 0-minute day)
        var progress: Double? { target.map { $0 > 0 ? min(1, focused / $0) : 0 } }
        var clean: Double? { focused > 0 ? max(0, min(1, (focused - distracted - paused) / focused)) : nil }
    }
    /// The live session, if one is on: all the model needs of it.
    struct Live { let started: Date }
    /// PLAN_PLANNING §3.3 (P2, R10): a planned block from the calendar — a subject's lecture or an objective's event — drawn dashed.
    /// Built by the caller (`Store.plannedBlocks(day:)` through `rebuildToday`); the model stays pure.
    struct Planned: Equatable, Identifiable {
        let subjectId: String
        let objectiveId: String?
        let start: Date
        let end: Date
        let title: String
        var id: String { "\(subjectId)-\(start.timeIntervalSince1970)" }
        var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
    }

    let day: Date
    let axisStart: Date
    let axisEnd: Date
    let now: Date?
    let blocks: [Block]
    let periods: [Period]
    let ticks: [Tick]
    let looks: [Tick]                   // screen looks (kind look · look.skip), a family of their own, off by default (§5a Q10)
    let figures: Figures
    var planned: [Planned] = []         // P2: planned blocks for the day, filled by the caller after `build`
    var last: Period? { periods.last { !$0.falseAlarm } }

    /// The worked window: an hour before the first block or tick to an hour after the later of the last block's end,
    /// the last tick and now, clamped to the axis. Now rounds up to the quarter hour so a live strip re-fits four times
    /// an hour, not every second. nil when nothing has happened yet (the strip then fits the whole day).
    func workedWindow(now: Date?) -> ClosedRange<Date>? {
        let firsts = blocks.map(\.start) + ticks.map(\.at) + periods.map(\.start) + looks.map(\.at) + planned.map(\.start)   // P2: planned blocks are in the window
        var lasts = blocks.map(\.end) + ticks.map(\.at) + periods.map(\.end) + looks.map(\.at) + planned.map(\.end)
        if let now, blocks.contains(where: { $0.live }) {
            let q = 900.0, t = now.timeIntervalSinceReferenceDate
            lasts.append(Date(timeIntervalSinceReferenceDate: (t / q).rounded(.up) * q))
        }
        guard let a = firsts.min(), let b = lasts.max() else { return nil }
        let lo = max(axisStart, a.addingTimeInterval(-3600)), hi = min(axisEnd, b.addingTimeInterval(3600))
        return lo < hi ? lo...hi : nil
    }

    static let cap: TimeInterval = 600          // an unresolved period is at most 10 minutes (§5a Q4)
    static let snooze: TimeInterval = 600       // a snoozed period is as long as the snooze
    static let grace: TimeInterval = 10         // a verdict within 10 s of an answer is the same thing (Store.judge)
    static let browsers: Set<String> = ["Safari", "Dia", "Google Chrome", "Arc", "Firefox", "Brave Browser", "Microsoft Edge"]

    static func empty(day: Date, now: Date?) -> DayModel {
        struct NoRow: LogRow { let ts = Date(); let kind = "", app = "", detail = "" }
        return build(events: [NoRow](), live: nil, day: day, now: now, threshold: 0.7)
    }

    // MARK: Build

    /// `target`: the day's planned focused time (nil or 0 = no plan line, §3.4).
    static func build<R: LogRow>(events rows: [R], live: Live?, day: Date, now: Date?, threshold: Double, target: TimeInterval? = nil) -> DayModel {
        let cal = Calendar.current
        let day0 = StudyDay.start(of: day)          // K1 (PLAN_STUDY_DAY §3.2): the study day, 04:00 → 04:00 by default
        let dayEnd = StudyDay.end(of: day0)
        let rows = rows.filter { $0.ts >= day0 && $0.ts < dayEnd }.sorted { $0.ts < $1.ts }
        let clockEnd = now.map { min($0, dayEnd) } ?? dayEnd

        // ── sessions → blocks: start → the next end, else the last event before the next start (live → now)
        var blocks: [Block] = []
        let starts = rows.indices.filter { rows[$0].kind == "session.start" }
        for (k, i) in starts.enumerated() {
            let s = rows[i]
            let nextStart = k + 1 < starts.count ? starts[k + 1] : rows.count
            let f = fields(s.detail)
            var end = s.ts, ended = false, isLive = false
            if let e = rows[(i + 1)..<nextStart].first(where: { $0.kind == "session.end" }) { end = e.ts; ended = true }
            else if let l = live, abs(l.started.timeIntervalSince(s.ts)) < 2, let n = now { end = n; isLive = true }
            else if let lastRow = rows[(i + 1)..<nextStart].last { end = lastRow.ts }
            let pauses = rows[(i + 1)..<nextStart].indices.compactMap { j -> Span? in
                let r = rows[j]
                switch r.kind {
                case "session.pause": return Span(start: r.ts, end: min(end, r.ts + (minutes(fields(r.detail).first) ?? 600)), label: "paused")
                case "session.break": return Span(start: r.ts, end: min(end, r.ts + (minutes(fields(r.detail).last) ?? 300)), label: "break")
                case "skip": return Span(start: r.ts, end: min(end, r.ts + 300), label: "5 more minutes")
                case "session.away" where r.detail == "start":   // X4 (PLAN_CATCHER §3.5): drawn hatched like a pause, from the open row to its close (else the block's end)
                    let close = rows[(j + 1)..<nextStart].first { $0.kind == "session.away" && $0.detail != "start" }
                    return Span(start: r.ts, end: min(end, close?.ts ?? end), label: "away")
                default: return nil
                }
            }
            blocks.append(Block(start: s.ts, end: max(end, s.ts), goal: f.first ?? "", length: f.count > 1 ? f[1] : "", strictness: f.count > 2 ? f[2] : "",
                                ended: ended, live: isLive, pauses: pauses,
                                sessionId: s.sessionId, objectiveId: s.objectiveId, kindTag: s.sessionKind ?? (f.count > 3 ? f[3] : nil)))
        }

        // ── warnings, answers, follow-ups → periods; blocks → ticks
        var periods: [Period] = []
        var open: [Int] = []                                   // indices into periods, still unresolved
        var closedWork: [(subject: String, front: String, at: Date)] = []
        var ticks: [Tick] = []
        var lastTouched: [Int: Date] = [:]

        func find(subject: String) -> Int? {
            if let i = open.last(where: { periods[$0].subject == subject }) { return i }
            if let i = open.last(where: { subject.hasPrefix(periods[$0].subject) || periods[$0].subject.hasPrefix(subject) }) { return i }
            return nil
        }
        /// Where a new distracted verdict belongs, mirroring Store.judge: the open period for the same subject; the same
        /// front app's period while its card is still unanswered (Store.warn shows one card and dedupes for 2 min); or, when
        /// a "still in front" follow-up is logged in the same second (Store escalated instead of warning), the same front
        /// app's period that was answered "back".
        func attach(subject: String, front: String, at r: R, index k: Int) -> Int? {
            if let i = find(subject: subject) { return i }
            if let i = open.last(where: { periods[$0].front == front && periods[$0].answers.isEmpty && r.ts.timeIntervalSince(lastTouched[$0] ?? periods[$0].start) < 120 }) { return i }
            let escalated = rows[(k + 1)...].prefix { $0.ts.timeIntervalSince(r.ts) < 1.5 }.contains { $0.kind == "judge.followup" && ($0.detail.contains("still in front") || $0.detail.contains("blocked")) }
            if escalated, let i = open.last(where: { periods[$0].front == front && periods[$0].answers.last == "back" }) { return i }
            return nil
        }
        func close(_ i: Int, at: Date, outcome: Outcome?) {
            if let o = outcome { periods[i].outcome = o }
            periods[i].end = max(periods[i].start, at)
            open.removeAll { $0 == i }
        }
        func openPeriod(at r: R, index k: Int, subject: String, front: String, kind: Kind, title: String, reason: String) {
            if let i = attach(subject: subject, front: front, at: r, index: k) { periods[i].reason = periods[i].reason.isEmpty ? reason : periods[i].reason; lastTouched[i] = r.ts; return }
            // a verdict already in flight when "This is work" was pressed is not a new detour
            if closedWork.contains(where: { ($0.subject == subject && r.ts.timeIntervalSince($0.at) < grace) || ($0.front == front && r.ts.timeIntervalSince($0.at) < 2) }) { return }
            periods.append(Period(start: r.ts, end: r.ts, subject: subject, front: front, kind: kind, outcome: .open, title: title, reason: reason, blocks: [], answers: []))
            open.append(periods.count - 1); lastTouched[periods.count - 1] = r.ts
        }

        for (k, r) in rows.enumerated() {
            let f = fields(r.detail)
            switch r.kind {
            case "session.start", "session.end":
                for i in open { close(i, at: r.ts, outcome: periods[i].outcome == .open ? .back : nil) }
            case "judge.verdict":
                guard let head = f.first, head.hasPrefix("distracted") else { continue }
                let conf = Double(head.split(separator: " ").last ?? "") ?? 1
                guard conf >= threshold else { continue }
                let what = f.count > 2 ? f[2...].joined(separator: " · ") : (f.count > 1 ? f[1] : r.app)
                openPeriod(at: r, index: k, subject: what, front: r.app, kind: browsers.contains(r.app) ? .site : .app, title: what, reason: f.count > 1 ? f[1] : "")
            case "web.warn":
                openPeriod(at: r, index: k, subject: r.detail, front: r.app, kind: .site, title: r.detail, reason: "on the warn list")
            case "block.warn":
                openPeriod(at: r, index: k, subject: r.app, front: r.app, kind: .app, title: r.app, reason: "on the warn list")
            case "judge.answer":
                guard let a = f.first else { continue }
                let what = f.count > 1 ? f[1] : ""
                guard let i = find(subject: what) ?? open.last else { continue }
                periods[i].answers.append(a); lastTouched[i] = r.ts
                switch a {
                case "work": close(i, at: r.ts, outcome: .work); closedWork.append((periods[i].subject, periods[i].front, r.ts))
                case "snooze": close(i, at: r.ts + snooze, outcome: .snoozed)
                case "back": if periods[i].outcome == .open { periods[i].outcome = .back }
                case "ignored": periods[i].outcome = .blocked
                default: break
                }
            case "web.answer":
                let host = f.last ?? ""
                if let i = find(subject: host) { close(i, at: r.ts, outcome: .work); closedWork.append((periods[i].subject, periods[i].front, r.ts)) }
            case "judge.followup":
                let what = f.count > 1 ? f[1] : ""
                guard let i = find(subject: what) ?? open.last else { continue }
                lastTouched[i] = r.ts
                if r.detail.hasPrefix("followed through") { close(i, at: r.ts, outcome: periods[i].outcome == .blocked ? .blocked : .back) }
                else if r.detail.contains("shielded") { close(i, at: r.ts, outcome: .blocked) }
                else if r.detail.contains("blocked") { periods[i].outcome = .blocked }
            case "block.close", "block.shield", "web.block":
                let what = r.kind == "web.block" ? (f.first ?? r.app) : r.app
                ticks.append(Tick(at: r.ts, what: what, kind: r.kind))
                if let i = find(subject: what) { periods[i].blocks.append(r.ts); lastTouched[i] = r.ts }
            default: break
            }
        }

        // ── open ends (§5a Q4): the next event on another subject after the period's last row, capped at 10 min;
        //    a period still unresolved at `now`, in a live session, stays open to now
        for i in open {
            let p = periods[i]
            let since = lastTouched[i] ?? p.start
            let next = rows.first { r in
                r.ts > since && ["judge.verdict", "web.warn", "block.warn", "web.visit", "web.search", "look", "session.end", "session.start"].contains(r.kind)
                    && !(subjectOf(r) == p.subject || r.app == p.front && r.kind != "session.end" && r.kind != "session.start")
            }
            var cap = p.start + DayModel.cap
            if p.answers.last == "back" { cap = min(cap, since + 30) }          // "Back to work" with no follow-up logged (before §5a Q22): the 30 s the follow-up would have taken
            if let n = next { periods[i].end = min(n.ts, cap) }
            else if let now, live != nil, now < cap { periods[i].end = now; periods[i].outcome = .open }
            else { periods[i].end = min(cap, clockEnd) }
            if periods[i].outcome == .open, periods[i].end < (now ?? dayEnd) { periods[i].outcome = .back }
        }
        // a period never outlives the session it happened in
        for i in periods.indices { if let b = blocks.last(where: { $0.start <= periods[i].start }), !b.live, periods[i].end > b.end { periods[i].end = max(periods[i].start, b.end) } }
        periods.sort { $0.start < $1.start }
        // each block counts the detours that began inside it
        for p in periods where !p.falseAlarm { if let i = blocks.lastIndex(where: { $0.start <= p.start }), p.start <= blocks[i].end { blocks[i].detours += 1 } }

        // ── figures
        var fig = Figures()
        fig.sessions = blocks.filter { $0.live || !$0.isTest }.count   // R1 (PLAN_REWORK §3.2, D5): the Stats rule, so Home's sentence, head and tiles agree
        fig.sessionsDone = blocks.filter { !$0.live && !$0.isTest }.count
        fig.sessionsLive = blocks.filter(\.live).count
        fig.target = (target ?? 0) > 0 ? target : nil
        fig.away = blocks.reduce(0) { $0 + $1.pauses.filter { $0.label == "away" }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }   // X4
        fig.focused = blocks.reduce(0) { $0 + $1.duration } - fig.away
        fig.paused = blocks.reduce(0) { $0 + $1.pauses.filter { $0.label != "away" }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) } }
        fig.distracted = periods.filter { !$0.falseAlarm }.reduce(0) { $0 + $1.duration }
        fig.detours = periods.filter { !$0.falseAlarm }.count
        fig.falseAlarms = periods.filter { $0.falseAlarm }.count
        fig.blocks = ticks.count

        // ── the axis: 07:00 → the study day's end (04:00 next morning; midnight with startHour 0), growing back to cover an earlier session (§5a Q2)
        var a0 = max(day0, cal.date(bySettingHour: 7, minute: 0, second: 0, of: day0)!)
        var a1 = dayEnd
        if let first = blocks.first?.start, first < a0 { a0 = max(day0, cal.date(bySettingHour: cal.component(.hour, from: first), minute: 0, second: 0, of: first)!) }   // K1: the hour on the block's own date
        if let last = blocks.map(\.end).max(), last > a1 { a1 = last }
        let looks = rows.filter { $0.kind == "look" || $0.kind == "look.skip" }.map { Tick(at: $0.ts, what: $0.app, kind: $0.kind) }
        return DayModel(day: day0, axisStart: a0, axisEnd: a1, now: now, blocks: blocks, periods: periods, ticks: ticks, looks: looks, figures: fig)
    }

    // MARK: Parsing helpers (the log's " · " joined details)

    static func fields(_ detail: String) -> [String] {
        detail.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    /// "10 min" → 600; "open" → nil.
    static func minutes(_ s: String?) -> TimeInterval? {
        guard let s, let n = Double(s.split(separator: " ").first ?? "") else { return nil }
        return n * 60
    }
    /// The subject a row is about, for the "next event on another subject" rule.
    static func subjectOf<R: LogRow>(_ r: R) -> String {
        let f = fields(r.detail)
        switch r.kind {
        case "judge.verdict": return f.count > 2 ? f[2...].joined(separator: " · ") : r.app
        case "web.visit", "web.search": return f.first.map { $0.components(separatedBy: " → ").first ?? $0 } ?? r.app
        case "block.warn", "look": return r.app
        default: return r.detail
        }
    }
}

