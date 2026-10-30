import Foundation

// The Progress tab's aggregator (PLAN_STATS_TAB §3.3): pure functions over [Event], so a fixture can test them.
// One place owns the rules: what a session's span is, what counts as a distraction, what counts as a block,
// which sessions are tests, how a web detail becomes a host or a query.

struct Period: Equatable {
    enum Kind: String, CaseIterable, Identifiable { case today, week, month, all; var id: String { rawValue } }
    let kind: Kind
    let from: Date
    let to: Date
    var label: String {
        switch kind { case .today: return "today"; case .week: return "7 days"; case .month: return "30 days"; case .all: return "all" }
    }
    /// The same length of time just before `p` (none for "all").
    static func previous(of p: Period) -> Period? {
        guard p.kind != .all else { return nil }
        let cal = Calendar.current
        let days = p.kind == .today ? 1 : p.kind == .week ? 7 : 30
        let from = cal.date(byAdding: .day, value: -days, to: p.from)!
        return Period(kind: p.kind, from: from, to: p.from - 1)
    }
    static func make(_ kind: Kind, now: Date = Date()) -> Period {
        let cal = Calendar.current
        let today = StudyDay.start(of: now)   // K1 (PLAN_STUDY_DAY §3.2): from = the study day's start
        switch kind {
        case .today: return Period(kind: kind, from: today, to: now)
        case .week: return Period(kind: kind, from: cal.date(byAdding: .day, value: -6, to: today)!, to: now)
        case .month: return Period(kind: kind, from: cal.date(byAdding: .day, value: -29, to: today)!, to: now)
        case .all: return Period(kind: kind, from: .distantPast, to: now)
        }
    }
}

/// One focus session as the log tells it.
struct SessionRecord: Identifiable, Equatable {
    static func == (a: SessionRecord, b: SessionRecord) -> Bool { a.id == b.id && a.end == b.end && a.caught == b.caught && a.blocked == b.blocked && a.detourSeconds == b.detourSeconds }
    let id: Int64                       // the session.start event id
    let start: Date
    let end: Date
    let live: Bool
    let goal: String
    let plannedMinutes: Int?            // nil = "until I stop"
    let strictness: String
    var subject: String?                // the subject's name, from the stamped objective id through the catalogue (Objectives O1)
    var objectiveId: String?
    /// X4 (PLAN_CATCHER §3.5): away spans are neither focused nor distracted; F3 (PLAN_GAME_FEEL §5a Q5): nor is paused time — one "focused"
    /// for the score, the day and XP (a pause inside an away span is taken out once, as away).
    var focusedSeconds: Int { max(0, Int(end.timeIntervalSince(start)) - awaySeconds - pauseOnlySeconds) }
    var pauseOnlySeconds = 0                                                        // F3: the paused seconds outside away spans
    var awaySeconds = 0                                                             // X4: summed from the session's `session.away · <seconds>` rows
    // S5 records: written at the end of a session (session.summary, usage) and at each detour's end (judge.detour)
    var pausedSeconds = 0
    var detourSeconds = 0
    var hasDetourData = false
    var usage: [(String, Int)] = []    // bundle id · seconds in front, longest first
    var netFocusSeconds: Int { max(0, focusedSeconds - detourSeconds) }   // F3: pauses are already out of `focusedSeconds`
    var caught = 0
    var blocked = 0
    var followUps = 0
    var followedThrough = 0
    var answers: [String: Int] = [:]
    // Z0 (PLAN_SCORING §3.1): what the new session score reads beyond the counts above
    var avgMinutes: Int? = nil          // `avg N` in the start row: the objective's average real length, stamped for an open-ended session
    var switchRate: Int? = nil          // X's `switches · <count> · max10 <n>` row: the worst 10-minute window; nil before X
    var launches = 0                    // block.close / block.shield rows inside the session: a blocked app launched
    var endedBy = ""                    // the summary's last part: finished · ended · ended by phrase; "" before S5 or while live
    var xpRow: Int? = nil               // the `xp · N · …` row written at End (Z2), when present
    /// HUD1 (PLAN_SESSION_HUD §3.1): the session played as a game — accuracy, rank, combo, combo-paid minutes — from its own spans and hits.
    var game: SessionGame.State? = nil
    /// HUD6: the game's losses in accuracy points, for the rows' hover and open line.
    var gameLosses: [SessionGame.Loss] = []
    /// `97.4 % · S`, or nil for a session without a game.
    var accuracyLabel: String? { game.map { "\(String(format: "%.1f", SessionGame.shown($0))) % · \($0.rank.rawValue)" } }
    /// HUD4: the ticks that paid (+10 each, `SessionTasks`), and the tasks ticked at all.
    var tasksPaid = 0
    var tasksDone = 0
    // F0 (PLAN_GAME_FEEL §3.1): what the tally names, one entry per row it may draw
    var detours: [TallyFact] = []       // each `judge.detour`: its site and seconds
    var ignored: [TallyFact] = []       // each follow-up not followed through: its site
    var launchList: [TallyFact] = []    // each block.close / block.shield: the app, `seconds` = seconds after the start
    var finished: Bool { endedBy == "finished" }
    /// The time part's yardstick in minutes: the planned length, else the objective's average, else 25 (§5a Q2).
    var yardstickMinutes: Int { plannedMinutes ?? avgMinutes ?? 25 }
    /// The session's own score (Z0): time 50 × focused ÷ yardstick · calm 10 detour share + 10 switch rate · kept 20 (10 with no
    /// follow-ups, §5a Q7.8) · self-control 10 − 3 per blocked-app launch.
    /// The two halves of calm before rounding (F0: the tally splits calm's loss between detours and restlessness).
    var calmHalves: (share: Double, switches: Double) {
        let hours = Double(focusedSeconds) / 3600
        let rate = hours > 0 ? Double(caught) / hours : 0
        let share: Double = focusedSeconds < 60 ? 0 : hasDetourData
            ? 10 * max(0, 1 - Double(detourSeconds) / Double(max(1, focusedSeconds)) / 0.25)
            : 10 * max(0, 1 - rate / 6)
        let switches: Double = focusedSeconds < 60 ? 0 : switchRate.map { 10 * max(0, 1 - Double(max(0, $0 - 6)) / 12) } ?? 10
        return (share, switches)
    }
    var score: Score {
        let yard = Double(yardstickMinutes * 60)
        let time = min(50, Int((Double(focusedSeconds) / max(60, yard) * 50).rounded()))
        // §5a Q11: once a session has detour durations, the first half of calm is the share of time lost (25 % → 0); before that, the count rate
        let halves = calmHalves
        let calm = Int((halves.share + halves.switches).rounded())
        let kept = followUps == 0 ? 20 : Int((20 * Double(followedThrough) / Double(followUps)).rounded())   // F3 (§5a Q2): no warning raised keeps all 20
        let selfControl = max(0, 10 - 3 * launches)
        return Score(time: time, calm: calm, follow: kept, blocks: selfControl, kind: .session)
    }
    /// A B-phase test, or too short to mean anything (§5a Q6).
    var isTest: Bool {
        if goal.range(of: #"^B\d+\s"#, options: .regularExpression) != nil { return true }
        return !live && focusedSeconds < 120
    }
}

struct DayStats: Identifiable, Equatable {
    var id: Date { day }
    let day: Date
    var focusedSeconds = 0
    var sessions = 0
    var caught = 0
    var blocked = 0
    var followUps = 0
    var followedThrough = 0
}

struct Distractor: Identifiable, Equatable {
    enum Kind: String { case app, site, search }
    var id: String { "\(kind.rawValue):\(name)" }
    let kind: Kind
    let name: String
    var count = 0                       // distractions (verdicts not answered "work", warnings)
    var blocked = 0                     // closes, shields, web blocks, follow-up blocks
    var answers: [String: Int] = [:]
    var lastSeen: Date = .distantPast
    var weekly: [Int] = Array(repeating: 0, count: 12)     // weight per week, the last 12 weeks ending now (index 11 = this week)
    var weight: Int { count + blocked }
}

/// Days in a row, ending today or yesterday (§3.2 Streaks).
struct Streaks: Equatable {
    var sessions = 0        // days with a session
    var calm = 0            // session days with ≤ 2 caught
    var followed = 0        // session days where every back-to-work check was followed through
    var unblocked = 0       // session days with no block attempt
    static func build(days: [DayStats], now: Date = Date()) -> Streaks {
        let cal = Calendar.current
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        func run(_ ok: (DayStats) -> Bool) -> Int {
            var d = StudyDay.start(of: now)   // K1
            // today may still be empty; a streak that ended yesterday is still alive
            if !(byDay[d].map(ok) ?? false) { d = cal.date(byAdding: .day, value: -1, to: d)! }
            var n = 0
            while let s = byDay[d], ok(s) { n += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
            return n
        }
        return Streaks(sessions: run { $0.sessions > 0 },
                       calm: run { $0.sessions > 0 && $0.caught <= 2 },
                       followed: run { $0.sessions > 0 && $0.followedThrough == $0.followUps },
                       unblocked: run { $0.sessions > 0 && $0.blocked == 0 })
    }
}

struct HourBin: Identifiable, Equatable { var id: Int { hour }; let hour: Int; var focusedSeconds = 0; var caught = 0 }

/// The four-part focus score (§5a Q3): 50 · 20 · 20 · 10. The stored names are the original four; Z0 (PLAN_SCORING §3.1–3.2)
/// renames them per `kind` — a session: time · calm · kept · self-control; a day or range: plan · calm · kept · closed.
struct Score: Equatable {
    enum Kind { case session, day }
    let time: Int, calm: Int, follow: Int, blocks: Int
    var kind: Kind = .session                    // Z0
    var total: Int { time + calm + follow + blocks }
    var word: String { total >= 75 ? "On track" : total >= 50 ? "Close" : "Drifting" }
    static let empty = Score(time: 0, calm: 0, follow: 0, blocks: 0)
    // Z0: the new names, so a reader need not remember which stored field means what
    var plan: Int { time }
    var kept: Int { follow }
    var selfControl: Int { blocks }
    var closed: Int { blocks }
    /// Z0: the four lines every surface draws, in order — `(name, value, max)`.
    var parts: [(name: String, value: Int, max: Int)] {
        kind == .day ? [("plan", time, 50), ("calm", calm, 20), ("kept", follow, 20), ("closed", blocks, 10)]
                     : [("time", time, 50), ("calm", calm, 20), ("kept", follow, 20), ("self-control", blocks, 10)]
    }
    /// `plan 25/50 · calm 19/20 · kept 10/20 · closed 0/10`
    var partsLine: String { parts.map { "\($0.name) \($0.value)/\($0.max)" }.joined(separator: " · ") }
    /// `25 + 19 + 10 + 0`
    var sumLine: String { parts.map { "\($0.value)" }.joined(separator: " + ") }
}

/// Z1 (PLAN_SCORING §3.2): where a day's plan yardstick came from.
enum PlanSource: String, Equatable { case shutdown, calendar, target, none }
/// Z1: one day's plan — the seconds the day score measures against and the objectives it named.
struct DayPlan: Equatable {
    var seconds: Int
    var source: PlanSource
    var objectiveIds: [String] = []
}

struct Stats: Equatable {
    let period: Period
    var sessions: [SessionRecord] = []      // ascending, tests already removed unless asked for
    var hiddenTests = 0
    var days: [DayStats] = []              // one per calendar day in the period that has a session or an event
    var distractors: [Distractor] = []     // heaviest first
    var hours: [HourBin] = (0..<24).map { HourBin(hour: $0) }
    var score: Score = .empty
    var targetSeconds = 0                  // the period's summed daily target, for the score's time part
    // Z1 (PLAN_SCORING §3.2): the plan yardstick and the closed part
    var planSeconds = 0                    // Σ over the period's days: the shutdown's plan, else the calendar's blocks, else the target
    var planSource: PlanSource = .none
    var closed = false                     // `.today`: a shutdown was filed for the day; a range: any day was
    var shutdowns = 0                      // shutdowns filed inside the period
    var unplanned = false                  // no plan and a 0 target (a weekend by default): the surfaces show the focused figure, no word (Q7.2)
    var subjects: [String] = []            // every subject seen in the range (before the subject filter)
    var pausedSeconds: Int { sessions.reduce(0) { $0 + $1.pausedSeconds } }
    var awaySeconds: Int { sessions.reduce(0) { $0 + $1.awaySeconds } }   // X4: Z reads
    var detourSeconds: Int { sessions.reduce(0) { $0 + $1.detourSeconds } }
    var hasDetourData: Bool { sessions.contains(where: \.hasDetourData) }
    // the judge's funnel (S4): raw verdicts, answers, follow-up outcomes inside the shown sessions
    var verdictsWork = 0
    var verdictsDistracted = 0             // every distracted verdict, including those answered "this is work"
    var answers: [String: Int] = [:]
    var stillInFront = 0
    var noAnswer = 0
    var focusedSeconds: Int { sessions.reduce(0) { $0 + $1.focusedSeconds } }
    var caught: Int { sessions.reduce(0) { $0 + $1.caught } }
    var blocked: Int { sessions.reduce(0) { $0 + $1.blocked } }
    var followUps: Int { sessions.reduce(0) { $0 + $1.followUps } }
    var followedThrough: Int { sessions.reduce(0) { $0 + $1.followedThrough } }

    // MARK: - The rules

    static let browsers: Set<String> = ["Safari", "Dia", "Google Chrome", "Chrome", "Arc", "Firefox", "Brave Browser", "Microsoft Edge"]
    static let engines: Set<String> = ["google", "youtube", "bing", "duckduckgo", "dia", "yahoo", "kagi"]

    /// Session spans: start → the next session.end, else the last event before the next session.start,
    /// the live session → now. (DayTimeline.spans()' rule, in one place.)
    static func sessionSpans(events: [Event], live: Session?, now: Date) -> [SessionRecord] {
        let sorted = events.sorted { $0.ts < $1.ts }
        var out: [SessionRecord] = []
        var open: (Event, Date)?           // the start event and the last event seen since
        func close(_ o: (Event, Date), at end: Date, live: Bool) {
            let parts = o.0.detail.components(separatedBy: " · ")
            let goal = parts.first ?? ""
            let minutes = parts.count > 1 ? Int(parts[1].replacingOccurrences(of: " min", with: "")) : nil
            let strictness = parts.count > 2 ? parts[2] : "normal"
            var r = SessionRecord(id: o.0.id, start: o.0.ts, end: max(o.0.ts, end), live: live, goal: goal, plannedMinutes: minutes, strictness: strictness,
                                  subject: nil, objectiveId: o.0.objectiveId)
            // Z0: `· avg N` rides at the end of the start row (after the kind); an old `· stake N` is ignored
            for p in parts.dropFirst(3) where p.hasPrefix("avg ") { if let n = Int(p.dropFirst(4)) { r.avgMinutes = n } }
            out.append(r)
        }
        for e in sorted {
            if e.kind == "session.start" {
                if let o = open { close(o, at: o.1, live: false) }
                open = (e, e.ts)
            } else if e.kind == "session.end", let o = open {
                close(o, at: e.ts, live: false); open = nil
            } else if open != nil, !e.kind.hasPrefix("ui.") { open!.1 = e.ts }   // K0 (PLAN_STUDY_DAY §3.8): a UI row never extends a span
        }
        if let o = open {
            let isLive = live.map { abs($0.started.timeIntervalSince(o.0.ts)) < 2 } ?? false
            close(o, at: isLive ? now : o.1, live: isLive)
        }
        return out
    }

    /// The host, the query or the title a web/verdict detail is about, and whether it is a search.
    /// web.visit/search: "what → verdict · why"; web.block: "host · session block" or the query; verdict: "distracted 0.90 · reason · what".
    static func subject(ofWeb detail: String) -> (name: String, search: Bool) {
        var what = detail
        if let r = what.range(of: " → ") { what = String(what[..<r.lowerBound]) }
        else if let r = what.range(of: " · ") { what = String(what[..<r.lowerBound]) }
        return classify(what)
    }
    static func classify(_ what: String) -> (name: String, search: Bool) {
        let w = what.trimmingCharacters(in: .whitespaces)
        if let c = w.range(of: ": "), engines.contains(String(w[..<c.lowerBound]).lowercased()) { return (w, true) }
        return (w, false)
    }
    /// The verdict's `what`: everything after "verdict confidence · reason".
    static func what(ofVerdict detail: String) -> String {
        let parts = detail.components(separatedBy: " · ")
        return parts.count > 2 ? parts[2...].joined(separator: " · ") : (parts.last ?? "")
    }
    /// An answer's (kind, what): "back · what [· after follow-up]".
    static func parse(answer detail: String) -> (String, String) {
        var parts = detail.components(separatedBy: " · ")
        let a = parts.isEmpty ? "" : parts.removeFirst()
        if parts.last == "after follow-up" { parts.removeLast() }
        return (a, parts.joined(separator: " · "))
    }
    static func isBlock(_ e: Event) -> Bool {
        e.kind == "block.close" || e.kind == "block.shield" || e.kind == "web.block" || (e.kind == "judge.followup" && e.detail.contains("blocked"))
    }

    // MARK: - Compute

    /// `events` ascending and covering at least the period (plus the hour before, so a session that began earlier is seen).
    /// Z1: `plan(day)` is the day's plan when one exists (the shutdown's `tomorrow`, else the calendar's blocks), `shutdown(day)` whether
    /// a shutdown was filed for it; both default to "none", which makes the target the yardstick as before.
    static func compute(events all: [Event], period: Period, live: Session?, now: Date = Date(), targetMinutes: (Date) -> Int, showTests: Bool = false,
                        subjectOf: (String?) -> String? = { _ in nil }, subject: String? = nil,
                        plan: (Date) -> DayPlan? = { _ in nil }, shutdown: (Date) -> Bool = { _ in false }) -> Stats {
        let cal = Calendar.current
        var stats = Stats(period: period)
        let events = all.sorted { $0.ts < $1.ts }
        var sessions = sessionSpans(events: events, live: live, now: now).filter { $0.end >= period.from && $0.start <= period.to }
        for i in sessions.indices { sessions[i].subject = subjectOf(sessions[i].objectiveId) }
        stats.subjects = Array(Set(sessions.compactMap(\.subject))).sorted()
        if let subject { sessions.removeAll { $0.subject != subject } }

        // which distracted verdicts were answered "work" (not a distraction, §5a Q5)
        var workAnswered = Set<Int64>()
        let answers = events.filter { $0.kind == "judge.answer" }
        for v in events where v.kind == "judge.verdict" && v.detail.hasPrefix("distracted") {
            let w = what(ofVerdict: v.detail)
            if answers.contains(where: { a in a.ts >= v.ts && a.ts <= v.ts + 60 && { let p = parse(answer: a.detail); return p.0 == "work" && p.1 == w }() }) { workAnswered.insert(v.id) }
        }
        func isDistraction(_ e: Event) -> Bool {
            switch e.kind {
            case "judge.verdict": return e.detail.hasPrefix("distracted") && !workAnswered.contains(e.id)
            case "web.warn", "block.warn": return true
            default: return false
            }
        }

        stats.hiddenTests = sessions.filter(\.isTest).count
        if !showTests { sessions.removeAll(where: \.isTest) }

        // per session counts, and the distractor table
        var distractors: [String: Distractor] = [:]
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        func bump(_ kind: Distractor.Kind, _ name: String, at ts: Date, count: Int = 0, blocked: Int = 0, answer: String? = nil) {
            guard !name.isEmpty else { return }
            var d = distractors["\(kind.rawValue):\(name)"] ?? Distractor(kind: kind, name: name)
            d.count += count; d.blocked += blocked; d.lastSeen = max(d.lastSeen, ts)
            let weeksAgo = Int(thisWeek.timeIntervalSince(cal.dateInterval(of: .weekOfYear, for: ts)?.start ?? ts) / 604800)
            if (0..<12).contains(weeksAgo) { d.weekly[11 - weeksAgo] += count + blocked }
            if let answer { d.answers[answer, default: 0] += 1 }
            distractors[d.id] = d
        }
        let inPeriod = events.filter { $0.ts >= period.from && $0.ts <= period.to }
        for i in sessions.indices {
            let s = sessions[i]
            var pauses: [(Date, String)] = [], resumes: [Date] = [], aways: [(start: Date, end: Date)] = []   // F3
            defer { sessions[i].pauseOnlySeconds = Stats.pauseOutsideAway(pauses: pauses, resumes: resumes, aways: aways, end: s.end, pausedTotal: sessions[i].pausedSeconds) }
            var mine: [Event] = []   // HUD1: the session's own rows, for the game's replay below
            defer { let strip = SessionSpans.build(rows: mine, start: s.start, end: s.end, planned: s.plannedMinutes.map { $0 * 60 }, pausedTotal: s.live ? nil : sessions[i].pausedSeconds)
                    let hits = SessionGame.hits(rows: mine, start: s.start, end: s.end)
                    let g = SessionGame.play(spans: strip.spans, hits: hits)
                    sessions[i].game = g   // HUD1 (the same as `SessionGame.replay`, with the strip kept for the losses)
                    sessions[i].gameLosses = SessionGame.losses(spans: strip.spans, hits: hits, state: g, marks: strip.marks)   // HUD6
                    sessions[i].tasksPaid = SessionTasks.paid(rows: mine, start: s.start)   // HUD4
                    sessions[i].tasksDone = mine.filter { $0.kind == "task.done" }.count - mine.filter { $0.kind == "task.undo" }.count }
            for e in inPeriod where e.ts >= s.start && e.ts <= s.end {
                mine.append(e)
                if isDistraction(e) { sessions[i].caught += 1 }
                if isBlock(e) { sessions[i].blocked += 1 }
                if e.kind == "block.close" || e.kind == "block.shield" {   // Z0: self-control counts launches only
                    let after = Int(e.ts.timeIntervalSince(s.start))
                    if after >= Tally.sweepSeconds { sessions[i].launches += 1 }   // F3 (§5a Q3): the close list's sweep at the start is not a launch
                    sessions[i].launchList.append(TallyFact(site: e.app, seconds: after))   // F0
                }
                if e.kind == "judge.followup" {
                    sessions[i].followUps += 1
                    if e.detail.hasPrefix("followed through") { sessions[i].followedThrough += 1 }
                    else { sessions[i].ignored.append(TallyFact(site: TallyFact.site(e.detail.components(separatedBy: " · ").dropFirst().first { !$0.hasSuffix("for the session") } ?? ""), seconds: 0)) }   // F0: `still in front · <site> · blocked for the session`
                }
                if e.kind == "judge.answer" { sessions[i].answers[parse(answer: e.detail).0, default: 0] += 1 }
                switch e.kind {
                case "session.away":   // X4: "start" opens, "<seconds>" closes
                    if let secs = Int(e.detail) { sessions[i].awaySeconds += secs; aways.append((e.ts.addingTimeInterval(-Double(secs)), e.ts)) }
                case "session.pause": pauses.append((e.ts, e.detail))   // F3
                case "session.resume": resumes.append(e.ts)
                case "judge.detour":
                    sessions[i].hasDetourData = true
                    sessions[i].detourSeconds += Int(e.detail.components(separatedBy: " · ").first ?? "") ?? 0
                    let ps = e.detail.components(separatedBy: " · ")   // F0: `<seconds> · <outcome> · <site>`
                    sessions[i].detours.append(TallyFact(site: TallyFact.site(ps.count > 2 ? ps[2] : ""), seconds: Int(ps.first ?? "") ?? 0))
                case "session.summary":
                    // "paused N · detour N · reason": the larger of the summary's detour total and the per-detour rows' sum. M0 (PLAN_MINUTE_STRIP):
                    // a relaunch mid-session restores the session but restarts the in-memory counter, so the summary can miss detours its rows hold
                    var paused = 0, detour = 0
                    for part in e.detail.components(separatedBy: " · ") {
                        let w = part.split(separator: " ")
                        if w.count == 2, let n = Int(w[1]) { if w[0] == "paused" { paused = n } else if w[0] == "detour" { detour = n } }
                    }
                    sessions[i].pausedSeconds = paused
                    if detour > 0 || sessions[i].hasDetourData { sessions[i].detourSeconds = max(detour, sessions[i].detourSeconds); sessions[i].hasDetourData = true }
                    sessions[i].endedBy = e.detail.components(separatedBy: " · ").last ?? ""   // Z0: finished · ended · ended by phrase
                case "switches":   // X3: `switches · <count> · max10 <n>` — the worst ten minutes
                    let ps = e.detail.components(separatedBy: " · ")
                    if let m = ps.first(where: { $0.hasPrefix("max10 ") }), let n = Int(m.dropFirst(6)) { sessions[i].switchRate = n }
                    else if let n = ps.first.flatMap({ Int($0) }) { sessions[i].switchRate = n }
                case "xp":         // Z2: `xp · <n> · <multiplier> · finished|ended`
                    if let n = e.detail.components(separatedBy: " · ").first.flatMap({ Int($0) }) { sessions[i].xpRow = n }
                case "usage":
                    sessions[i].usage = e.detail.components(separatedBy: " · ").compactMap { part in
                        let kv = part.split(separator: "=", maxSplits: 1); return kv.count == 2 ? (String(kv[0]), Int(kv[1]) ?? 0) : nil
                    }
                default: break
                }
            }
        }
        // the distractor table and the hours count only what happened inside a shown session (a hidden test takes its events with it)
        let shown = inPeriod.filter { e in sessions.contains { e.ts >= $0.start && e.ts <= $0.end } }
        for e in shown {
            if e.kind == "judge.verdict" { if e.detail.hasPrefix("distracted") { stats.verdictsDistracted += 1 } else { stats.verdictsWork += 1 } }
            if e.kind == "judge.answer" { stats.answers[parse(answer: e.detail).0, default: 0] += 1 }
            if e.kind == "judge.followup" { if e.detail.hasPrefix("still in front") { stats.stillInFront += 1 } else if e.detail.hasPrefix("No answer") { stats.noAnswer += 1 } }
            switch e.kind {
            case "judge.verdict" where isDistraction(e):
                let w = what(ofVerdict: e.detail)
                if browsers.contains(e.app), !w.isEmpty {
                    let c = classify(w); bump(c.search ? .search : .site, c.name, at: e.ts, count: 1)
                } else { bump(.app, e.app, at: e.ts, count: 1) }                 // an unnamed page counts against the browser
            case "judge.answer":
                let (a, w) = parse(answer: e.detail)
                let c = classify(w)
                // the answer names what the verdict named; an app answer carries "App — title", a web one the host/title/query
                if c.search { bump(.search, c.name, at: e.ts, answer: a) }
                else if let d = distractors.values.first(where: { $0.name == c.name }) { bump(d.kind, d.name, at: e.ts, answer: a) }
            case "block.close", "block.shield": bump(.app, e.app, at: e.ts, blocked: 1)
            case "block.warn": bump(.app, e.app, at: e.ts, count: 1)
            case "web.warn": let c = Stats.subject(ofWeb: e.detail); bump(c.search ? .search : .site, c.name, at: e.ts, count: 1)
            case "web.block": let c = Stats.subject(ofWeb: e.detail); bump(c.search ? .search : .site, c.name, at: e.ts, blocked: 1)
            case "judge.followup" where e.detail.contains("blocked"):
                // "still in front · host · blocked for the session" names the site; the app form carries the bundle id in `app`
                let parts = e.detail.components(separatedBy: " · ")
                if parts.first == "still in front", parts.count > 1 { bump(.site, parts[1], at: e.ts, blocked: 1) }
                else if !e.app.isEmpty { bump(.app, e.app, at: e.ts, blocked: 1) }
            default: break
            }
        }
        stats.sessions = sessions

        stats.distractors = distractors.values.sorted { ($0.weight, $0.lastSeen) > ($1.weight, $1.lastSeen) }

        // days and hours: sessions split at the study day's start (K1) / on the hour, events by their own day
        var days: [Date: DayStats] = [:]
        for s in sessions {
            var t = max(s.start, period.from); let end = min(s.end, period.to)
            while t < end {
                let dayStart = StudyDay.start(of: t)
                let next = min(end, StudyDay.end(of: dayStart))
                days[dayStart, default: DayStats(day: dayStart)].focusedSeconds += Int(next.timeIntervalSince(t))
                var h = t
                while h < next {
                    let hour = cal.component(.hour, from: h)
                    let hourEnd = min(next, cal.date(bySettingHour: hour, minute: 59, second: 59, of: h)! + 1)
                    stats.hours[hour].focusedSeconds += Int(hourEnd.timeIntervalSince(h))
                    h = hourEnd
                }
                t = next
            }
            days[StudyDay.start(of: s.start), default: DayStats(day: StudyDay.start(of: s.start))].sessions += 1
            let d = StudyDay.start(of: s.start)
            days[d]!.caught += s.caught; days[d]!.blocked += s.blocked; days[d]!.followUps += s.followUps; days[d]!.followedThrough += s.followedThrough
        }
        for e in shown where isDistraction(e) { stats.hours[cal.component(.hour, from: e.ts)].caught += 1 }
        stats.days = days.values.sorted { $0.day < $1.day }

        // the score, over the period (Z1, PLAN_SCORING §3.2): plan 50 · calm 20 · kept 20 · closed 10
        let focused = stats.focusedSeconds
        let dayList = StudyDay.days(from: max(period.from, stats.days.first?.day ?? period.to), through: period.to)   // K1
        let target = dayList.reduce(0) { $0 + targetMinutes($1) } * 60
        stats.targetSeconds = target
        // plan: Σ per day — the day's plan when there is one, else its target; the touched bonus is 5 per planned objective with a session that day
        var planSeconds = 0, touched = 0, shutdowns = 0
        var sources: Set<PlanSource> = []
        let sessionDayIds: [Date: Set<String>] = sessions.reduce(into: [:]) { acc, s in if let o = s.objectiveId { acc[StudyDay.start(of: s.start), default: []].insert(o) } }
        for d in dayList {
            if let p = plan(d), p.seconds > 0 || !p.objectiveIds.isEmpty {
                planSeconds += p.seconds; sources.insert(p.source)
                touched += p.objectiveIds.filter { sessionDayIds[d]?.contains($0) ?? false }.count
            } else {
                let t = targetMinutes(d) * 60
                planSeconds += t; sources.insert(t > 0 ? .target : .none)
            }
            if shutdown(d) { shutdowns += 1 }
        }
        stats.planSeconds = planSeconds
        stats.planSource = sources.contains(.shutdown) ? .shutdown : sources.contains(.calendar) ? .calendar : sources.contains(.target) ? .target : .none
        stats.shutdowns = shutdowns
        stats.closed = shutdowns > 0
        stats.unplanned = stats.planSource == .none && focused > 0
        let planPart = planSeconds > 0 ? min(50, Int((Double(focused) / Double(planSeconds) * 50).rounded()) + 5 * touched) : (focused > 0 ? 50 : 0)
        // calm and kept: the sessions' own parts, weighted by focused seconds
        func weighted(_ part: (SessionRecord) -> Int) -> Int {
            guard focused > 0 else { return 0 }
            return Int((sessions.reduce(0.0) { $0 + Double(part($1)) * Double($1.focusedSeconds) } / Double(focused)).rounded())
        }
        let calm = weighted { $0.score.calm }
        let kept = weighted { $0.score.kept }
        // closed: 10 when the day was shut down; over a range, the share of session days that were
        let sessionDays = max(1, stats.days.filter { $0.sessions > 0 }.count)
        let closed = focused == 0 && shutdowns == 0 ? 0 : period.kind == .today ? (shutdowns > 0 ? 10 : 0) : min(10, Int((10 * Double(shutdowns) / Double(sessionDays)).rounded()))
        stats.score = Score(time: planPart, calm: calm, follow: kept, blocks: closed, kind: .day)
        return stats
    }

    /// F3 (PLAN_GAME_FEEL §5a Q5): the paused seconds that are not also away. An auto-pause (`10 min · away`) runs inside the away span that
    /// triggered it, so it is taken out once, as away; a chosen pause (`N min`) outside any away span is taken out as itself. Spans from the
    /// session's own rows (a pause ends at its length, an early `session.resume`, the next pause or the session's end; an auto-pause at its
    /// away span's end); capped at the summary's paused total. No pause rows → the whole total (nothing to overlap).
    static func pauseOutsideAway(pauses: [(Date, String)], resumes: [Date], aways: [(start: Date, end: Date)], end: Date, pausedTotal: Int) -> Int {
        guard pausedTotal > 0 else { return 0 }
        guard !pauses.isEmpty else { return pausedTotal }
        var total = 0.0
        for (s, e) in pauseIntervals(pauses: pauses, resumes: resumes, aways: aways, end: end) {
            var len = e.timeIntervalSince(s)
            for a in aways { let o = min(e, a.end).timeIntervalSince(max(s, a.start)); if o > 0 { len -= o } }
            total += max(0, len)
        }
        return min(pausedTotal, Int(total))
    }
    /// Each pause's span by the rule above, before away is taken out.
    static func pauseIntervals(pauses: [(Date, String)], resumes: [Date], aways: [(start: Date, end: Date)], end: Date) -> [(Date, Date)] {
        pauses.enumerated().compactMap { i, p in
            let mins = Double(p.1.split(separator: " ").first.flatMap { Int($0) } ?? 10)
            var e = p.0.addingTimeInterval(mins * 60)
            if p.1.hasSuffix("away"), let a = aways.first(where: { $0.start <= p.0.addingTimeInterval(1) && $0.end >= p.0 }) { e = a.end }
            if let r = resumes.first(where: { $0 > p.0 }), r < e { e = r }
            if i + 1 < pauses.count, pauses[i + 1].0 < e { e = pauses[i + 1].0 }
            e = min(e, end)
            return e > p.0 ? (p.0, e) : nil
        }
    }
    /// F3: a session's focused seconds from its own rows, as `SessionRecord.focusedSeconds` reads them — for the `xp` row written at End,
    /// before the session's record exists.
    static func focused(rows: [Event], start: Date, end: Date, pausedTotal: Int) -> Int {
        var aways: [(start: Date, end: Date)] = [], pauses: [(Date, String)] = [], resumes: [Date] = []
        for e in rows.sorted(by: { $0.ts < $1.ts }) where e.ts >= start && e.ts <= end {
            if e.kind == "session.away", let secs = Int(e.detail) { aways.append((e.ts.addingTimeInterval(-Double(secs)), e.ts)) }
            if e.kind == "session.pause" { pauses.append((e.ts, e.detail)) }
            if e.kind == "session.resume" { resumes.append(e.ts) }
        }
        let away = aways.reduce(0) { $0 + Int($1.end.timeIntervalSince($1.start)) }
        return max(0, Int(end.timeIntervalSince(start)) - away - pauseOutsideAway(pauses: pauses, resumes: resumes, aways: aways, end: end, pausedTotal: pausedTotal))
    }

    // MARK: - Z1: the shutdown rows, read without K's types (PLAN_STUDY_DAY §3.3: kind `day.shutdown`, detail = one-line JSON with
    // `day` and `tomorrow[].minutes / objectiveId`). Pure, so `scripts/scoring-check.swift` judges the same code the app runs.

    /// The `day` a shutdown row closes, from its JSON (an ISO-8601 string, or seconds since 2001 as JSONEncoder writes a Date by default).
    static func shutdownDay(_ e: Event) -> Date? {
        guard e.kind == "day.shutdown", let data = e.detail.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let v = obj["day"] else { return nil }
        if let s = v as? String { return ISO8601DateFormatter().date(from: s) ?? ISO8601DateFormatter.ymd.date(from: s) }
        if let n = v as? Double { return Date(timeIntervalSinceReferenceDate: n) }
        return nil
    }
    /// The latest shutdown row that closes `day` (clock day; K's study day when it lands).
    static func shutdownRow(in events: [Event], for day: Date) -> Event? {
        let target = StudyDay.start(of: day)   // K1: a shutdown's `day` is a study-day start
        return events.filter { $0.kind == "day.shutdown" && shutdownDay($0).map { StudyDay.start(of: $0) == target } ?? false }.max { $0.ts < $1.ts }
    }
    static func hasShutdown(in events: [Event], for day: Date) -> Bool { shutdownRow(in: events, for: day) != nil }
    /// The plan for `day`: the `tomorrow` items of the shutdown that closed the day before, as a `DayPlan` (nil with none or an empty list).
    static func shutdownPlan(in events: [Event], for day: Date) -> DayPlan? {
        let before = StudyDay.shift(day, by: -1)
        guard let row = shutdownRow(in: events, for: before),
              let data = row.detail.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["tomorrow"] as? [[String: Any]], !items.isEmpty else { return nil }
        let minutes = items.reduce(0) { $0 + (($1["minutes"] as? Int) ?? ($1["minutes"] as? Double).map { Int($0) } ?? 0) }
        return DayPlan(seconds: minutes * 60, source: .shutdown, objectiveIds: items.compactMap { $0["objectiveId"] as? String })
    }

    // MARK: - Dev aids

    /// DBOT_STATS_CHECK=1: print today's figures so they can be diffed against sqlite3, then quit.
    @MainActor static func checkRun() -> String? {
        guard let arg = ProcessInfo.processInfo.environment["DBOT_STATS_CHECK"] else { return nil }
        // "1" = today; "yyyy-MM-dd" = that whole day
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let day = f.date(from: arg).map { StudyDay.dayStarting(on: $0) } ?? StudyDay.start(of: Date())   // K1: the study day beginning on that date
        let now = min(Date(), StudyDay.end(of: day) - 1)
        let period = Period(kind: .today, from: day, to: now)
        let events = EventLog.shared.events(from: period.from - 3600 * 6, to: now)
        var lines: [String] = []
        for showTests in [false, true] {
            let s = compute(events: events, period: period, live: nil, now: now, targetMinutes: { _ in 240 }, showTests: showTests)
            lines.append("== today, tests \(showTests ? "shown" : "hidden") ==")
            lines.append("sessions \(s.sessions.count) (hidden tests \(s.hiddenTests)) · focused \(s.focusedSeconds) s · caught \(s.caught) · blocked \(s.blocked) · followed through \(s.followedThrough)/\(s.followUps)")
            lines.append("score \(s.score.total) = \(s.score.partsLine) · \(s.score.word) · plan \(s.planSeconds / 60) min from \(s.planSource.rawValue)\(s.closed ? " · closed" : "")\(s.unplanned ? " · unplanned" : "")")   // Z1
            for x in s.sessions {
                let span = "\(clock(x.start))–\(clock(x.end))" + (x.live ? " live" : "")
                let plan = x.plannedMinutes.map { "\($0) min" } ?? "open"
                let head = "  \(span) \(x.focusedSeconds) s · \(x.goal.prefix(28)) · \(plan) · \(x.strictness)"
                lines.append(head + " · caught \(x.caught) · blocked \(x.blocked) · answers \(x.answers)")
            }
            lines.append("distractors:")
            for d in s.distractors { lines.append("  \(d.kind.rawValue) \(d.name.prefix(40)) · \(d.count) + \(d.blocked) blocked · \(d.answers)") }
            let busy = s.hours.filter { $0.focusedSeconds > 0 || $0.caught > 0 }
            let hourWords: [String] = busy.map { h in "\(h.hour):\(h.focusedSeconds / 60)m/\(h.caught)" }
            lines.append("hours: " + hourWords.joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// DBOT_STATS_FIXTURE=1: six weeks of plausible events, deterministic, so the tab can be laid out before the log has a history.
    static func fixture(now: Date = Date()) -> [Event] {
        var seed: UInt64 = 0x5eed
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        let cal = Calendar.current
        var out: [Event] = []
        var id: Int64 = 1
        func add(_ kind: String, _ ts: Date, app: String = "", detail: String = "", ms: Int? = nil) { out.append(Event(id: id, ts: ts, kind: kind, app: app, detail: detail, latencyMs: ms)); id += 1 }
        let goals = ["BIO 210 project part A: random-walk simulation", "ARTS 201 problem set 4", "Senior project proposal draft", "BIO 210 lab write-up"]
        let sites = ["youtube.com", "reddit.com", "dbrand » Official Shop", "x.com", "news.ycombinator.com"]
        let apps = ["Steam", "Spotify", "Messages", "Claude", "Figma"]
        let searches = ["youtube: best mechanical keyboards 2026", "google: standing desk", "google: advance auto parts", "youtube: lofi beats"]
        for back in stride(from: 41, through: 0, by: -1) {
            let day = StudyDay.shift(now, by: -back)   // K1
            let weekday = cal.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            if rnd() < (weekend ? 0.45 : 0.1) { continue }                                   // a day off
            let n = weekend ? 1 : 2 + (rnd() < 0.5 ? 1 : 0)
            var t = day.addingTimeInterval(TimeInterval(9 * 3600 + Int(rnd() * 3 * 3600)))
            for _ in 0..<n {
                guard t < now else { break }
                let minutes = [25, 50, 50, 90][Int(rnd() * 4)]
                let goal = goals[Int(rnd() * Double(goals.count))]
                add("session.start", t, detail: "\(goal) · \(minutes) min · normal")
                let end = min(now, t.addingTimeInterval(TimeInterval(minutes * 60) * (0.6 + rnd() * 0.4)))
                let creep = Double(41 - back) / 41                                            // youtube creeps up over the weeks
                var detour = 0
                var k = t.addingTimeInterval(120)
                while k < end - 60 {
                    k = k.addingTimeInterval(TimeInterval(300 + rnd() * 900))
                    guard k < end - 60 else { break }
                    let r = rnd()
                    if r < 0.35 + 0.25 * creep {
                        let site = r < 0.2 ? "youtube.com" : sites[Int(rnd() * Double(sites.count))]
                        add("web.visit", k, app: "Safari", detail: "\(site) → judge · no rule")
                        add("judge.verdict", k + 2, app: "Safari", detail: "distracted 0.90 · unrelated to the goal · \(site)", ms: 1400 + Int(rnd() * 600))
                        let a = rnd(); let ans = a < 0.6 ? "back" : a < 0.75 ? "work" : a < 0.9 ? "ignored" : "snooze"
                        add("judge.answer", k + 8, detail: "\(ans) · \(site)")
                        if ans == "back" {
                            let kept = rnd() < 0.7
                            add("judge.followup", k + 38, detail: kept ? "followed through · \(site)" : "still in front · \(site) · blocked for the session")
                            let secs = kept ? 36 + Int(rnd() * 60) : 38
                            detour += secs; add("judge.detour", k + 38, detail: "\(secs) · \(kept ? "followed through" : "blocked") · \(site)")
                        }
                    } else if r < 0.6 {
                        let app = apps[Int(rnd() * Double(apps.count))]
                        if app == "Steam" { add("block.close", k, app: app, detail: "forced · attempt 1 · react 0 ms", ms: 4500) }
                        else {
                            add("judge.verdict", k, app: app, detail: "distracted 0.80 · \(app) is unrelated to the goal · \(app) — window", ms: 1500)
                            add("judge.answer", k + 6, detail: "\(rnd() < 0.7 ? "back" : "work") · \(app) — window")
                        }
                    } else if r < 0.72 {
                        let q = searches[Int(rnd() * Double(searches.count))]
                        add("web.search", k, app: "Dia", detail: "\(q) → judge · no rule")
                        add("judge.verdict", k + 2, app: "Dia", detail: "distracted 0.90 · searching unrelated to the goal · \(q)", ms: 1600)
                        add("judge.answer", k + 7, detail: "back · \(q)")
                    } else {
                        add("judge.verdict", k, app: "Code", detail: "work 0.90 · working on the project file · Code — PartA.tex", ms: 1450)
                    }
                }
                // S5 rows, as the app writes them since 2026-10-27: what was in front, then the summary, then the end
                let total = Int(end.timeIntervalSince(t))
                let codeShare = 0.55 + rnd() * 0.3
                add("usage", end - 2, detail: "com.microsoft.VSCode=\(Int(Double(total) * codeShare)) · company.thebrowser.dia=\(Int(Double(total) * (0.9 - codeShare))) · com.apple.Music=\(Int(Double(total) * 0.1))")
                let paused = rnd() < 0.25 ? 600 : 0
                add("session.summary", end - 1, detail: "paused \(paused) · detour \(detour) · \(rnd() < 0.8 ? "finished" : "ended")")
                add("session.end", end, detail: "\(total)")
                t = end.addingTimeInterval(TimeInterval(1200 + rnd() * 5400))
            }
        }
        return out.sorted { $0.ts < $1.ts }
    }
}
