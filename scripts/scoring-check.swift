// Z's check (PLAN_SCORING.md §4): every session, day, objective, freeze and token rule judged over a COPY of the log, read-only,
// with scratch rows added in memory — nothing is written and the app is never launched.
//   swiftc -parse-as-library -o /tmp/scoring-check Sources/DistractionBot/Model/StudyDay.swift Sources/DistractionBot/Model/Stats.swift Sources/DistractionBot/Model/XP.swift Sources/DistractionBot/Model/OverallFigures.swift Sources/DistractionBot/Model/CourseProgress.swift Sources/DistractionBot/Model/Tally.swift Sources/DistractionBot/Model/SessionSpans.swift Sources/DistractionBot/Model/SessionGame.swift Sources/DistractionBot/Model/SessionTasks.swift scripts/shims/ScoringShim.swift scripts/scoring-check.swift
//   /tmp/scoring-check <path/to/log.sqlite copy> [YYYY-MM-DD, default today] [--catalog path/to/subjects.json copy]
//   The Z1 day expectations need a day with sessions: pass 2026-10-28 for the copy of the log they were written against (today's study day may be empty).
// Exit code 1 when an expectation of §4 fails. Expectations marked `expect(...)` print PASS/FAIL.
import Foundation
import SQLite3

var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (got().isEmpty ? "" : " · got \(got())"))
    if !ok { failures += 1 }
}

func readLog(_ path: String) -> [Event] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { print("cannot open \(path)"); exit(2) }
    var st: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT id, ts, kind, app, detail, latency_ms, session_id, objective_id, kind_tag FROM events ORDER BY ts", -1, &st, nil)
    var rows: [Event] = []
    func text(_ i: Int32) -> String? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(st, i)) }
    while sqlite3_step(st) == SQLITE_ROW {
        rows.append(Event(id: sqlite3_column_int64(st, 0), ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)), kind: text(2) ?? "", app: text(3) ?? "", detail: text(4) ?? "",
                          latencyMs: sqlite3_column_type(st, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(st, 5)), sessionId: text(6), objectiveId: text(7), sessionKind: text(8)))
    }
    sqlite3_finalize(st); sqlite3_close(db)
    return rows
}

@main struct Check {
static func main() {
    let args = CommandLine.arguments
    guard args.count > 1 else { print("usage: scoring-check <log.sqlite copy> [YYYY-MM-DD] [--catalog subjects.json]"); exit(2) }
    let logPath = args[1]
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
    let cal = Calendar.current
    let dayArg = args.dropFirst(2).first { !$0.hasPrefix("--") }
    let day = dayArg.flatMap { df.date(from: $0) }.map { StudyDay.dayStarting(on: $0) } ?? StudyDay.start(of: Date())   // K1: study days
    let catalogPath = args.firstIndex(of: "--catalog").flatMap { args.count > $0 + 1 ? args[$0 + 1] : nil }
    let events = readLog(logPath)
    var nextId: Int64 = (events.map(\.id).max() ?? 0) + 1
    func row(_ ts: Date, _ kind: String, _ detail: String, app: String = "", session: String? = nil, objective: String? = nil) -> Event {
        defer { nextId += 1 }
        return Event(id: nextId, ts: ts, kind: kind, app: app, detail: detail, latencyMs: nil, sessionId: session, objectiveId: objective)
    }
    print("log \(logPath) · \(events.count) rows · day \(df.string(from: day))\n")

    // MARK: Z0 — the session score

    let allPeriod = Period(kind: .all, from: .distantPast, to: Date())
    let all = Stats.compute(events: events, period: allPeriod, live: nil, now: Date(), targetMinutes: { _ in 240 })
    print("== Z0 · sessions (tests hidden) ==")
    for s in all.sessions {
        let sc = s.score
        print("  \(df.string(from: s.start)) \(clock(s.start)) · \(minutes(Double(s.focusedSeconds)).padding(toLength: 12, withPad: " ", startingAt: 0)) · \(s.goal.prefix(30).padding(toLength: 30, withPad: " ", startingAt: 0)) · plan \(s.plannedMinutes.map { "\($0)" } ?? "open") avg \(s.avgMinutes.map { "\($0)" } ?? "—") → yard \(s.yardstickMinutes) · \(sc.partsLine) = \(sc.total) \(sc.word) · \(s.endedBy.isEmpty ? "—" : s.endedBy) · launches \(s.launches) · detour \(s.detourSeconds) s")
    }
    let proposal60 = all.sessions.first { $0.plannedMinutes == 60 && $0.goal.hasPrefix("Research Proposal") }
    expect("60-min finished proposal session (planned 60) → time 50", proposal60?.score.time == 50, "\(proposal60?.score.time ?? -1)")
    expect("…and it reads finished", proposal60?.finished == true, proposal60?.endedBy ?? "nil")
    let proposal77 = all.sessions.first { $0.plannedMinutes == nil && $0.goal.hasPrefix("Research Proposal") && $0.focusedSeconds > 4000 }
    expect("77-min open proposal session, avg absent → yardstick 25 → time 50", proposal77?.yardstickMinutes == 25 && proposal77?.score.time == 50, "yard \(proposal77?.yardstickMinutes ?? -1) time \(proposal77?.score.time ?? -1)")
    expect("kept = 20 with no follow-ups (F3, PLAN_GAME_FEEL §5a Q2)", all.sessions.filter { $0.followUps == 0 }.allSatisfy { $0.score.kept == 20 })
    // a scratch 20-min open session on an objective averaging 70, with one Steam launch
    let t0 = day.addingTimeInterval(6 * 3600)   // 10:00 on a 04:00 study day
    let scratch: [Event] = [
        row(t0, "session.start", "Research Proposal Presentation · open · normal · presentation · avg 70", session: "z-scratch", objective: "68818C5F-5F7B-466F-AE0B-141EA8E2C355"),
        row(t0 + 300, "block.close", "attempt 1 · react 0 ms", app: "Steam", session: "z-scratch", objective: "68818C5F-5F7B-466F-AE0B-141EA8E2C355"),
        row(t0 + 1199, "session.summary", "paused 0 · detour 0 · ended", session: "z-scratch", objective: "68818C5F-5F7B-466F-AE0B-141EA8E2C355"),
        row(t0 + 1200, "session.end", "1200", session: "z-scratch", objective: "68818C5F-5F7B-466F-AE0B-141EA8E2C355"),
    ]
    let withScratch = Stats.compute(events: events + scratch, period: allPeriod, live: nil, now: Date(), targetMinutes: { _ in 240 })
    let s20 = withScratch.sessions.first { $0.start == t0 }
    expect("20-min open session on an objective averaging 70 → time 14", s20?.score.time == 14, "\(s20?.score.time ?? -1) (yard \(s20?.yardstickMinutes ?? -1))")
    expect("one Steam launch → self-control 7", s20?.score.selfControl == 7, "\(s20?.score.selfControl ?? -1)")
    expect("Score.parts names a session's lines time · calm · kept · self-control", s20?.score.parts.map(\.name) == ["time", "calm", "kept", "self-control"])

    // MARK: Z1 — the day score

    func dayStats(_ evs: [Event], day: Date, target: Int, plan: @escaping (Date) -> DayPlan? = { _ in nil }, shutdown: @escaping (Date) -> Bool = { _ in false }) -> Stats {
        let end = StudyDay.end(of: day) - 1
        let now = min(Date(), end)
        let period = Period(kind: .today, from: day, to: now)
        return Stats.compute(events: evs, period: period, live: nil, now: now, targetMinutes: { _ in target }, plan: plan, shutdown: shutdown)
    }
    func planFrom(_ evs: [Event]) -> (Date) -> DayPlan? { { Stats.shutdownPlan(in: evs, for: $0) } }
    func shutdownFrom(_ evs: [Event]) -> (Date) -> Bool { { Stats.hasShutdown(in: evs, for: $0) } }
    print("\n== Z1 · day score \(df.string(from: day)) ==")
    let dayNoPlan = dayStats(events, day: day, target: 240, plan: planFrom(events), shutdown: shutdownFrom(events))
    print("  no plan, target 240: \(dayNoPlan.score.partsLine) = \(dayNoPlan.score.total) \(dayNoPlan.score.word) · plan \(dayNoPlan.planSeconds / 60) min from \(dayNoPlan.planSource.rawValue) · closed \(dayNoPlan.closed) · focused \(minutes(Double(dayNoPlan.focusedSeconds)))")
    expect("no plan and target 240 → planSource target", dayNoPlan.planSource == .target, dayNoPlan.planSource.rawValue)
    expect("Score.parts names a day's lines plan · calm · kept · closed", dayNoPlan.score.parts.map(\.name) == ["plan", "calm", "kept", "closed"])
    // a scratch shutdown filed the evening before, planning 90 min on the objective worked today
    let before = StudyDay.shift(day, by: -1)
    let touchedId = dayNoPlan.sessions.compactMap(\.objectiveId).first ?? "68818C5F-5F7B-466F-AE0B-141EA8E2C355"
    let iso = ISO8601DateFormatter()
    let planRow = row(cal.date(bySettingHour: 23, minute: 0, second: 0, of: before)!, "day.shutdown",
                      "{\"day\":\"\(iso.string(from: before))\",\"rating\":4,\"note\":\"\",\"objectives\":[],\"tomorrow\":[{\"objectiveId\":\"\(touchedId)\",\"goal\":\"x\",\"minutes\":90}],\"startAt\":null}")
    let planned = events + [planRow]
    let dayPlanned = dayStats(planned, day: day, target: 240, plan: planFrom(planned), shutdown: shutdownFrom(planned))
    print("  plan 90 min (scratch shutdown): \(dayPlanned.score.partsLine) = \(dayPlanned.score.total) · plan \(dayPlanned.planSeconds / 60) min from \(dayPlanned.planSource.rawValue) · closed \(dayPlanned.closed)")
    let focusedOver90 = dayPlanned.focusedSeconds >= 90 * 60
    expect("scratch plan of 90 min → planSource shutdown, plan \(focusedOver90 ? "50 (capped: 50 + 5 touched)" : "time share + 5 touched")", dayPlanned.planSource == .shutdown && dayPlanned.planSeconds == 5400 && dayPlanned.score.plan == (focusedOver90 ? 50 : min(50, Int((Double(dayPlanned.focusedSeconds) / 5400 * 50).rounded()) + 5)), "plan \(dayPlanned.score.plan) from \(dayPlanned.planSource.rawValue) \(dayPlanned.planSeconds) s")
    let realShutdown = events.contains { Stats.shutdownDay($0).map { StudyDay.start(of: $0) == day } ?? false }   // G0: the real log may hold one now
    expect("…closed \(realShutdown ? "10 — the log holds a shutdown for the day" : "0 without a shutdown for the day")", dayPlanned.score.closed == (realShutdown ? 10 : 0) && dayPlanned.closed == realShutdown)
    let closeRow = row(cal.date(bySettingHour: 23, minute: 30, second: 0, of: day)!, "day.shutdown", "{\"day\":\"\(iso.string(from: day))\",\"rating\":5,\"note\":\"\",\"objectives\":[],\"tomorrow\":[],\"startAt\":null}")
    let closedEvents = planned + [closeRow]
    let dayClosed = dayStats(closedEvents, day: day, target: 240, plan: planFrom(closedEvents), shutdown: shutdownFrom(closedEvents))
    print("  …with a scratch shutdown for the day: \(dayClosed.score.partsLine) = \(dayClosed.score.total) · closed \(dayClosed.closed)")
    expect("scratch shutdown → closed 10", dayClosed.score.closed == 10 && dayClosed.closed, "\(dayClosed.score.closed)")
    // a weekend with target 0 and no plan → unplanned
    let weekendDay = dayStats(events, day: day, target: 0)
    expect("target 0 and no plan → unplanned (focused > 0)", weekendDay.unplanned == (weekendDay.focusedSeconds > 0) && weekendDay.planSource == .none, "unplanned \(weekendDay.unplanned) source \(weekendDay.planSource.rawValue) focused \(weekendDay.focusedSeconds)")
    // 28 Oct's real evening: the analysis measured 71 against a 4-h target with the old rules; the new rules keep the time share (25/50) and recount the rest
    if let oct28 = df.date(from: "2026-10-28") {
        let d = dayStats(events, day: StudyDay.dayStarting(on: oct28), target: 240)
        print("  2026-10-28 (target 240, as the analysis measured): \(d.score.partsLine) = \(d.score.total) \(d.score.word) · focused \(minutes(Double(d.focusedSeconds)))")
    }

    // MARK: Z2 / G1 — XP per session, levels per course (PLAN_GAME_LOOP §3.1)

    print("\n== G1 · XP per course ==")
    var subjectOf: [String: String] = [:], titles: [String: String] = [:], completed: Set<String> = [], completedOn: [String: Date] = [:]
    if let catalogPath, let data = FileManager.default.contents(atPath: catalogPath), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let objectives = obj["objectives"] as? [[String: Any]] {
        for o in objectives { if let id = o["id"] as? String { titles[id] = o["title"] as? String; subjectOf[id] = o["subjectId"] as? String; if o["completedAt"] != nil { completed.insert(id) }
            if let c = o["completedAt"] as? String, let d = ISO8601DateFormatter().date(from: c) { completedOn[id] = d } } }
    }
    let byObjective = Dictionary(grouping: all.sessions.filter { $0.objectiveId != nil }) { $0.objectiveId! }
    let byCourse = Dictionary(grouping: all.sessions.filter { $0.objectiveId.flatMap { subjectOf[$0] } != nil }) { subjectOf[$0.objectiveId!]! }
    for (course, ss) in byCourse.sorted(by: { $0.key < $1.key }) {
        let done = completed.filter { subjectOf[$0] == course }.count
        let xp = XP.course(ss, completedObjectives: done)
        let lines = ss.map { "\((titles[$0.objectiveId!] ?? "?").prefix(14)) \(minutes(Double($0.focusedSeconds))) \($0.strictness) \($0.endedBy.isEmpty ? "live" : $0.endedBy) → \(XP.earned($0))" }.joined(separator: ", ")
        print("  course \(course.prefix(8)) · \(XP.label(xp)) · into \(String(format: "%.2f", XP.level(xp).into)) · \(done) completed · [\(lines)]")
    }
    let proposalId = "68818C5F-5F7B-466F-AE0B-141EA8E2C355", homeworkId = "E6367BF9-274F-4E55-A2D3-F3D212B809AE"
    if let course = subjectOf[proposalId], let ss = byCourse[course] {
        let sum = ss.reduce(0) { $0 + XP.earned($1) }
        let done = completed.filter { subjectOf[$0] == course }.count
        expect("the proposal's course = Σ its sessions' XP (\(sum)) + 60 × \(done) completed", XP.course(ss, completedObjectives: done) == sum + 60 * done, "\(XP.course(ss, completedObjectives: done))")
        expect("HUD1: …the proposal objective alone — 18:59 combo 117 + 30 finished, 20:04 combo 110 — ≈ 257 of it", (250...265).contains(byObjective[proposalId].map { $0.reduce(0) { $0 + XP.earned($1) } } ?? -1), "\(byObjective[proposalId].map { $0.reduce(0) { $0 + XP.earned($1) } } ?? -1)")
    }
    if let course = subjectOf[homeworkId], let ss = byCourse[course] {
        let strictOnly = ss.allSatisfy { $0.strictness == "strict" }
        let clean = ss.reduce(0) { $0 + XP.clean(seconds: $1.focusedSeconds, pausedSeconds: 0, detourSeconds: $1.detourSeconds, awaySeconds: 0) }
        let rows = ss.filter { $0.xpRow != nil }.count
        let xp = XP.course(ss, completedObjectives: 0)
        let combo = ss.reduce(0.0) { $0 + ($1.game?.comboMinutes ?? 0) }   // HUD1: each clean minute at its combo multiplier
        let finishedN = ss.filter { $0.finished }.count
        expect("HUD1: Homework #8's course (strict × 1.1) = Σ combo minutes × 1.1 from its sessions (+ 30 per finished, + the xp rows as written)", strictOnly && abs(xp - Int((combo * 1.1).rounded())) <= ss.count + 30 * (rows + finishedN), "\(xp) from \(clean) clean min, \(Int(combo)) with the combo · sessions \(ss.count) · \(rows) with an xp row")
        expect("…and it sits at L1 (300 ≤ xp < 1 080) on the HUD1 bands", XP.level(xp).level == 1, XP.label(xp))
    }
    // HUD1 (PLAN_SESSION_HUD §5a Q7): the bands moved with the combo — 300 · 1 080 · 2 520 · 5 400 · 10 800 (were 180 · 540 · 1 260 · 2 700 · 5 400)
    expect("course bands: 299 → L0, 300 → L1, 2 520 → L3, 10 800 → L5 into 1", XP.level(299).level == 0 && XP.level(300).level == 1 && XP.level(2520).level == 3 && XP.level(10800) == (5, 1))
    expect("level(690).into = 0.5 (half-way from 300 to 1 080)", XP.level(690).into == 0.5)
    expect("label: 1 500 → `L2 · 1500 XP · 1020 to L3`", XP.label(1500) == "L2 · 1500 XP · 1020 to L3", XP.label(1500))
    expect("multiplier: laxed 0.8 … extreme 1.25, unknown 1.0", XP.multiplier("laxed") == 0.8 && XP.multiplier("extreme") == 1.25 && XP.multiplier("?") == 1.0)
    expect("a 50-min finished normal session with 2 min of detours → 48 + 30 = 78 XP", XP.session(seconds: 3000, detourSeconds: 120, awaySeconds: 0, strictness: "normal", finished: true) == 78)
    expect("F3: a session with its summary is paid by the rule from its rows, whatever its xp row says", { var r = s20!; r.xpRow = 999; return XP.earned(r) == XP.session(r) }())
    expect("…a session with no summary (older) is paid by its xp row", { var r = s20!; r.xpRow = 999; r.endedBy = ""; return XP.earned(r) == 999 }())
    expect("a completed objective adds 60 to its course, a test session nothing", XP.course([s20!], completedObjectives: 1) == XP.earned(s20!) + 60)

    // MARK: S0 — the course page's figures (PLAN_SUBJECT_PROGRESS §3.2): the week's XP and its parts, the course streak, the week score

    print("\n== S0 · course progress (now = Thu 29 Oct 12:00) ==")
    let nowS0 = cal.date(bySettingHour: 12, minute: 0, second: 0, of: df.date(from: "2026-10-29")!)!
    // F5 (PLAN_GAME_FEEL): S0, S4 and F4 judge the courses as the log stood at their pinned moment, so a copy taken later (with the
    // user's newer sessions in it) still checks the same figures — the sessions and completions after `nowS0` are left out here.
    let asOf = byCourse.mapValues { $0.filter { $0.start < nowS0 } }
    let completedAsOf = completedOn.filter { $0.value < nowS0 }
    func progress(_ course: String, now: Date = nowS0, extra: [SessionRecord] = []) -> CourseProgress {
        CourseProgress.build(sessions: (asOf[course] ?? []) + extra, completedAt: completedAsOf.filter { subjectOf[$0.key] == course }.map(\.value), now: now)
    }
    func describe(_ p: CourseProgress) -> String {
        "\(XP.label(p.xp)) · week +\(p.weekXP) (\(p.weekMinuteXP) from \(p.weekClean) clean min × \(p.weekStrictness ?? "the dial") · \(p.weekFinished) finished · \(p.weekCompleted) completed) · streak \(p.streak) best \(p.best) · [\(p.cells.map { $0 == .session ? "s" : $0 == .missed ? "·" : "○" }.joined(separator: " "))] today \(p.todayIndex) · score \(p.score.map { "\($0.total) (\($0.partsLine))" } ?? "—") over \(p.scoredSessions) · recent \(p.recent.count)"
    }
    if let course = subjectOf[homeworkId] {
        let p = progress(course)
        print("  CS 150 · \(describe(p))")
        let week = asOf[course] ?? []
        let w = week.reduce(0) { $0 + max(1, $1.focusedSeconds) }
        let mean = Int((Double(week.reduce(0) { $0 + $1.score.total * max(1, $1.focusedSeconds) }) / Double(w)).rounded())
        expect("HUD1: CS 150: the page's XP is the course's (609 with the combo; 256 at ×1) and all of it came this week", p.xp == XP.course(week, completedObjectives: 0) && p.xp == 609 && p.weekXP == 609, "\(p.xp) · week \(p.weekXP)")
        expect("…from 233 clean min with the combo × strict, none finished, none completed", p.weekClean == 233 && p.weekStrictness == "strict" && p.weekFinished == 0 && p.weekCompleted == 0 && p.weekMinuteXP == 609, describe(p))
        expect("…streak 2 (Tue, Wed), best 2, the row · s s ○ ○ ○ ○ with today Thursday (index 3)", p.streak == 2 && p.best == 2 && p.todayIndex == 3 && p.cells == [.missed, .session, .session, .future, .future, .future, .future])
        expect("…the week score is the time-weighted mean of its 3 sessions (\(mean)) and reads 98", p.scoredSessions == 3 && abs((p.score?.total ?? -1) - mean) <= 2 && p.score?.total == 98, "\(p.score?.total ?? -1)")
        expect("…recent: its 3 real sessions, newest first (tests out)", p.recent.count == 3 && p.recent.first?.start == week.map(\.start).max())
        let sunday = progress(course, now: nowS0.addingTimeInterval(3 * 86400))
        expect("…on Sunday with nothing since Wednesday the streak is 0, best 2, Thu–Sat missed", sunday.streak == 0 && sunday.best == 2 && sunday.cells[3...5].allSatisfy { $0 == .missed } && sunday.cells[6] == .future, describe(sunday))
        print("  trends · weeks \(p.weeks.map { $0 / 60 }) min · peak \(p.peakHour.map { "\($0):00" } ?? "—") · avg \(p.averageClean) min · longest \(p.longestClean) · finished \(p.finished) · L2 in \(p.daysToNext.map { "\($0)" } ?? "—") days")
        expect("S4: the last of the 8 weeks is this week's focused time, the 7 before are empty", p.weeks.last == p.weekSeconds && p.weeks.dropLast().allSatisfy { $0 == 0 }, "\(p.weeks)")
        expect("S4: the hours sum to the course's focused time, the busiest three start in the evening", p.hours.reduce(0, +) == week.reduce(0) { $0 + $1.focusedSeconds } && (19...23).contains(p.peakHour ?? -1), "peak \(p.peakHour ?? -1)")
        expect("S4: average 78 clean min (233 / 3), longest 163, none finished", p.averageClean == 78 && p.longestClean == 163 && p.finished == 0, "avg \(p.averageClean) longest \(p.longestClean)")
        expect("HUD1: S4: at 609 XP over 4 days (Mon–Thu) the 471 to L2 take 4 more days", p.daysToNext == 4, "\(p.daysToNext ?? -1)")
        let nextWeek = progress(course, now: nowS0.addingTimeInterval(7 * 86400))
        expect("S4: a week later the weeks shift — this week empty, last week's time one bar back; no pace", nextWeek.weeks.last == 0 && nextWeek.weeks[6] == p.weekSeconds && nextWeek.daysToNext == nil, "\(nextWeek.weeks)")
        expect("…a week later: no XP this week, no score, the level kept", nextWeek.weekXP == 0 && nextWeek.score == nil && nextWeek.xp == 609, describe(nextWeek))
    }
    if let course = subjectOf[proposalId] {
        let p = progress(course)
        print("  PHYS 352/351 · \(describe(p))")
        expect("HUD1: PHYS 352/351: 318 XP = 258 from sessions with the combo (one finished, +30) + 60 for the completed proposal, all this week", p.xp == 318 && p.weekXP == 318 && p.weekFinished == 1 && p.weekCompleted == 1 && p.weekStrictness == "normal", describe(p))
        expect("…streak 0 on Thursday (last session Tuesday), best 1", p.streak == 0 && p.best == 1)
    }
    if let course = subjectOf[homeworkId], let base = asOf[course]?.first {
        // a scratch Friday–Sunday run on the same course, one 50-min normal finished session a day, plus four more on Sunday → recent caps at 6
        let fri = StudyDay.dayStarting(on: df.date(from: "2026-10-30")!)
        var extra: [SessionRecord] = []
        for (i, n) in [(0, 1), (1, 1), (2, 5)] { for k in 0..<n {
            let t = StudyDay.shift(fri, by: i).addingTimeInterval(TimeInterval(6 * 3600 + k * 3700))
            var r = SessionRecord(id: Int64(900_000 + i * 10 + k), start: t, end: t + 3000, live: false, goal: base.goal, plannedMinutes: 50, strictness: "normal", subject: base.subject, objectiveId: base.objectiveId)
            r.endedBy = "finished"; r.game = SessionGame.play(spans: [StripSpan(kind: .focus, from: 0, to: 3000)], hits: []); extra.append(r)   // HUD1: played, so the combo pays it
        } }
        let p = progress(course, now: StudyDay.shift(fri, by: 2).addingTimeInterval(14 * 3600), extra: extra)
        print("  CS 150 + a scratch Fri–Sun · \(describe(p))")
        expect("scratch: Tue–Wed and Fri–Sun are two runs → streak 3, best 3; 7 finished 50-min sessions × (110 with the combo + 30) added to the week", p.streak == 3 && p.best == 3 && p.weekFinished == 7 && p.weekXP == 609 + 7 * 140, describe(p))
        expect("…recent caps at 6, newest first; the strictness is mixed → `the dial`", p.recent.count == 6 && p.recent.first!.start > p.recent.last!.start && p.weekStrictness == nil)
    }

    // MARK: Z3 — streak freezes (OverallFigures bridges a `streak.freeze · used · <day>` day; Store.reloadScoring earns and applies them)

    print("\n== Z3 · freezes ==")
    let d0 = StudyDay.dayStarting(on: df.date(from: "2026-11-02")!)   // a scratch week: Mon 2 Nov … with sessions on 2, 3, 4, (gap 5), 6
    func scratchSession(_ day: Date, _ n: Int) -> [Event] {
        let t = day.addingTimeInterval(TimeInterval(8 * 3600 + n * 7200)), id = "z-\(df.string(from: day))-\(n)"
        return [row(t, "session.start", "Homework #8 · 50 min · strict · homework", session: id, objective: homeworkId),
                row(t + 2999, "session.summary", "paused 0 · detour 0 · finished", session: id, objective: homeworkId),
                row(t + 3000, "session.end", "3000", session: id, objective: homeworkId)]
    }
    func shutdownRow(_ day: Date) -> Event { row(day.addingTimeInterval(16 * 3600), "day.shutdown", "{\"day\":\"\(iso.string(from: day))\",\"rating\":4,\"note\":\"\",\"objectives\":[],\"tomorrow\":[],\"startAt\":null}") }
    var week: [Event] = []
    for i in [0, 1, 2, 4] { week += scratchSession(StudyDay.shift(d0, by: i), 0) }
    for i in 0..<5 { week.append(shutdownRow(StudyDay.shift(d0, by: i))) }   // 5 shutdowns in the week → 1 freeze earned
    let now3 = StudyDay.shift(d0, by: 4).addingTimeInterval(20 * 3600)
    let shutdownDays = Set((events + week).compactMap(Stats.shutdownDay))
    let weeks = Dictionary(grouping: shutdownDays) { StudyDay.weekStart(of: $0) }.filter { $0.value.count >= 5 }
    expect("a scratch week of 5 shutdowns earns 1 freeze (the earn rule: ≥ 5 shutdown days per study week)", weeks.count == 1 && weeks.first?.key == StudyDay.weekStart(of: d0), "\(weeks.map { "\(df.string(from: $0.key)) × \($0.value.count)" })")
    let noFreeze = OverallFigures.build(events: events + week, live: nil, now: now3)
    expect("the gap day (5 Nov) breaks the run without a freeze → streak 1", noFreeze.streak == 1 && noFreeze.frozen == 0, "streak \(noFreeze.streak) frozen \(noFreeze.frozen)")
    let used = row(StudyDay.shift(d0, by: 4).addingTimeInterval(3600), "streak.freeze", "used · \(ISO8601DateFormatter.ymd.string(from: StudyDay.shift(d0, by: 3)))")
    let bridged = OverallFigures.build(events: events + week + [used], live: nil, now: now3)
    expect("a `used` row for the gap bridges it once → streak 5 · 1 frozen (the tile reads `5 days · 1 frozen`)", bridged.streak == 5 && bridged.frozen == 1, "streak \(bridged.streak) frozen \(bridged.frozen)")
    expect("a frozen day is not a session day: sessions still 4 in the scratch week", bridged.sessions == noFreeze.sessions)
    let twoGaps = OverallFigures.build(events: events + week + [used], live: nil, now: StudyDay.shift(d0, by: 6).addingTimeInterval(20 * 3600))   // 5 Nov frozen, 6 Nov a session, 7 Nov nothing, now 8 Nov
    expect("a second gap (7 Nov) with no freeze breaks: streak 0 on 8 Nov", twoGaps.streak == 0, "\(twoGaps.streak)")

    // MARK: G2 — the freeze rule (pure) and the week row (PLAN_GAME_LOOP §3.3)
    print("\n== G2 · freezes per 5 shutdowns · the week row ==")
    expect("5, 9 and 10 shutdowns earn 1, 1, 2 freezes; 15 → 3 (the Store writes the 3rd only while fewer than 2 are in hand)",
           XP.freezesEarned(shutdowns: 5) == 1 && XP.freezesEarned(shutdowns: 9) == 1 && XP.freezesEarned(shutdowns: 10) == 2 && XP.freezesEarned(shutdowns: 15) == 3 && XP.freezeCap == 2)
    let realCells = OverallFigures.build(events: events, live: nil, now: Date()).weekCells
    let todayIdx = (cal.component(.weekday, from: StudyDay.start(of: Date())) + 5) % 7
    print("  this week on the log copy: \(realCells.map { $0.word }.joined(separator: " · ")) · today index \(todayIdx)")
    expect("the week row has 7 cells and every day after today is `to come`", realCells.count == 7 && realCells.enumerated().allSatisfy { $0.offset <= todayIdx || $0.element == .future })
    expect("the scratch week (sessions 2, 3, 4 Nov, 5 Nov frozen, 6 Nov a session; now 6 Nov) reads s s s frozen s · ·", {
        let f = OverallFigures.build(events: events + week + [used], live: nil, now: now3)
        let week0 = StudyDay.weekStart(of: d0)
        let want: [WeekCell] = (0..<7).map { i in
            let off = cal.dateComponents([.day], from: week0, to: cal.date(byAdding: .day, value: i, to: week0)!).day! - (cal.dateComponents([.day], from: week0, to: d0).day ?? 0)
            if (0...2).contains(off) || off == 4 { return .session }
            if off == 3 { return .frozen }
            return off > 4 ? .future : .missed
        }
        print("  scratch week: \(f.weekCells.map { $0.word }.joined(separator: " · "))")
        return f.weekCells == want
    }(), "see the printed row")
    // MARK: F0 — the tally (PLAN_GAME_FEEL §3.1): every score is 100 minus its rows, to the point

    print("\n== F0 · the tally ==")
    func rows(_ ls: [Tally.Loss]) -> String { ls.map { "\($0.name) \($0.points)" }.joined(separator: " · ") }
    for s in all.sessions {
        let t = Tally.session(s)
        print("  \(df.string(from: s.start)) \(clock(s.start)) · \(s.score.total) · \(Tally.line(t, total: s.score.total))")
        expect("  rows sum to 100 − \(s.score.total)", t.reduce(0) { $0 + $1.points } == 100 - s.score.total, "\(t.reduce(0) { $0 + $1.points })")
    }
    let wed = all.sessions.first { df.string(from: $0.start) == "2026-10-28" && (clock($0.start).hasPrefix("9:06") || clock($0.start).hasPrefix("21:06")) }
    if let w = wed {
        let t = Tally.session(w)
        expect("F3: Wed 21:06 reads short 10 · caught 10 = 80 (Telegram's sweep at its first second is free and not a row)", rows(t) == "short 10 · caught 10" && w.score.total == 80, "\(w.score.total) · \(rows(t))")
    } else { expect("Wed 21:06 session found in the log copy", false) }
    // the fixture of §3.1: 60 min planned, ended at 52, a 3-min detour, 1 of 2 warnings ignored, Steam launched once → 78
    let f0 = day.addingTimeInterval(8 * 3600)
    let fx: [Event] = [
        row(f0, "session.start", "Homework #8 · 60 min · strict · homework", session: "f-fixture"),
        row(f0 + 600, "judge.followup", "followed through · Spotify — a song", session: "f-fixture"),
        row(f0 + 900, "judge.detour", "180 · followed through · YouTube — best keyboards", session: "f-fixture"),
        row(f0 + 1500, "judge.followup", "still in front · Reddit — r/physics · blocked for the session", session: "f-fixture"),
        row(f0 + 2000, "block.shield", "attempt 1", app: "Steam", session: "f-fixture"),
        row(f0 + 3119, "session.summary", "paused 0 · detour 180 · ended", session: "f-fixture"),
        row(f0 + 3120, "session.end", "3120", session: "f-fixture"),
    ]
    let withFx = Stats.compute(events: events + fx, period: allPeriod, live: nil, now: Date(), targetMinutes: { _ in 240 })
    if let r = withFx.sessions.first(where: { $0.start == f0 }) {
        let t = Tally.session(r)
        print("  fixture · \(r.score.partsLine) = \(r.score.total) · \(Tally.line(t, total: r.score.total))")
        expect("fixture → 78 = ended early 7 · detour 2 · warning ignored 10 · launched 3", r.score.total == 78 && rows(t) == "ended early 7 · detour 2 · warning ignored 10 · launched 3", "\(r.score.total) · \(rows(t))")
        expect("…the detour row names YouTube · 3 min, the warning Reddit", t.first { $0.name == "detour" }?.detail == "YouTube · 3 min" && t.first { $0.name == "warning ignored" }?.detail == "Reddit")
    } else { expect("fixture session built", false) }
    // a clean 30-min session: today's rule takes 10 for no warnings (F3 gives them back); with one warning kept it is 100 and nothing is taken off
    let c0 = day.addingTimeInterval(10 * 3600), k0 = day.addingTimeInterval(11 * 3600)
    let clean: [Event] = [
        row(c0, "session.start", "Clean · 30 min · normal", session: "f-clean"),
        row(c0 + 1799, "session.summary", "paused 0 · detour 0 · finished", session: "f-clean"),
        row(c0 + 1800, "session.end", "1800", session: "f-clean"),
        row(k0, "session.start", "Kept · 30 min · normal", session: "f-kept"),
        row(k0 + 600, "judge.followup", "followed through · Discord", session: "f-kept"),
        row(k0 + 1799, "session.summary", "paused 0 · detour 0 · finished", session: "f-kept"),
        row(k0 + 1800, "session.end", "1800", session: "f-kept"),
    ]
    let withClean = Stats.compute(events: events + clean, period: allPeriod, live: nil, now: Date(), targetMinutes: { _ in 240 })
    let cs = withClean.sessions.first { $0.start == c0 }, ks = withClean.sessions.first { $0.start == k0 }
    expect("F3: a clean session with no warnings → 100, nothing taken off", cs.map { $0.score.total == 100 && Tally.session($0).isEmpty } ?? false, cs.map { "\($0.score.total) · \(rows(Tally.session($0)))" } ?? "nil")
    expect("…one warning kept → 100, nothing taken off", ks.map { $0.score.total == 100 && Tally.session($0).isEmpty && Tally.line([], total: 100) == "100 · nothing taken off" } ?? false)
    // seven detours: the tally draws five rows, the sum kept
    let g0 = day.addingTimeInterval(12 * 3600)
    let seven = [row(g0, "session.start", "Seven · 60 min · normal", session: "f-seven")]
        + (1...7).map { i in row(g0 + Double(i * 400), "judge.detour", "\(i * 40) · followed through · Site\(i)", session: "f-seven") }
        + [row(g0 + 3599, "session.summary", "paused 0 · detour 1120 · finished", session: "f-seven"), row(g0 + 3600, "session.end", "3600", session: "f-seven")]
    if let r = Stats.compute(events: events + seven, period: allPeriod, live: nil, now: Date(), targetMinutes: { _ in 240 }).sessions.first(where: { $0.start == g0 }) {
        let t = Tally.session(r), g = Tally.grouped(t)
        print("  seven detours · \(rows(t)) → \(rows(g))")
        expect("seven detours sum to 100 − \(r.score.total) and group to five rows with the same sum", t.reduce(0) { $0 + $1.points } == 100 - r.score.total && g.count <= 5 && g.reduce(0) { $0 + $1.points } == t.reduce(0) { $0 + $1.points }, "\(g.count) rows")
    }
    // the day: Wed 28 Oct as the log holds it (its plan, its shutdown)
    if let oct28 = df.date(from: "2026-10-28") {
        let d = dayStats(events, day: StudyDay.dayStarting(on: oct28), target: 240, plan: planFrom(events), shutdown: shutdownFrom(events))
        let t = Tally.day(d)
        print("  day 2026-10-28 · \(d.score.partsLine) = \(d.score.total) · \(Tally.line(t, total: d.score.total))")
        expect("the day's rows sum to 100 − \(d.score.total)", t.reduce(0) { $0 + $1.points } == 100 - d.score.total, rows(t))
        let open = dayStats(events, day: StudyDay.dayStarting(on: oct28), target: 240, plan: planFrom(events))
        expect("…without its shutdown the day carries open 10", Tally.day(open).last.map { $0.name == "open" && $0.points == 10 } ?? false, rows(Tally.day(open)))
    }
    expect("a day with nothing focused has no tally", Tally.day(dayStats([], day: day, target: 240)).isEmpty)

    // MARK: F3 — one "focused" (PLAN_GAME_FEEL §5a Q5): elapsed − (away ∪ paused), for the score and XP alike

    print("\n== F3 · one focused ==")
    if let p = all.sessions.first(where: { $0.goal.hasPrefix("Research Proposal") && $0.pausedSeconds == 600 }) {
        expect("27 Oct 20:04: its chosen 10-min pause is out of focused (77 → 67 min); HUD1: XP 110 with the combo (30 min ×1 · 30 ×2 · 6 ×3), the pause paid nothing", p.focusedSeconds / 60 == 67 && XP.session(p) == 110, "\(p.focusedSeconds / 60) min · \(XP.session(p)) XP")
    } else { expect("27 Oct 20:04 session found", false) }
    // the shape of the user's 29 Oct 14:20 session: 64 min, away 14:34:58–15:24:30 with the auto-pause inside it, plus a scratch chosen pause
    let a0 = day.addingTimeInterval(14 * 3600)
    let awayRows: [Event] = [
        row(a0, "session.start", "Homework #8 · open · strict · homework · avg 80", session: "f-away"),
        row(a0 + 252, "session.pause", "5 min", session: "f-away"),              // a chosen 5-min pause at 4 min in, outside the away span
        row(a0 + 852, "session.away", "start", session: "f-away"),
        row(a0 + 1452, "session.pause", "10 min · away", session: "f-away"),     // the auto-pause, 10 min into the away span
        row(a0 + 3824, "session.away", "2972", session: "f-away"),
        row(a0 + 3826, "session.summary", "paused 3240 · detour 0 · ended", session: "f-away"),   // 300 chosen + 2940 auto, as Store counts it
        row(a0 + 3826, "session.end", "3826", session: "f-away"),
    ]
    if let r = Stats.compute(events: events + awayRows, period: allPeriod, live: nil, now: Date(), targetMinutes: { _ in 240 }).sessions.first(where: { $0.start == a0 }) {
        expect("away 2972 s and paused 3240 s overlap: only the chosen 300 s pause is taken out beside the away → focused 554 s", r.awaySeconds == 2972 && r.pauseOnlySeconds == 300 && r.focusedSeconds == 554, "away \(r.awaySeconds) · pause-only \(r.pauseOnlySeconds) · focused \(r.focusedSeconds)")
        expect("…XP on 9 clean min × strict 1.1 = 10 (the installed build's row paid 15 on this shape)", XP.session(r) == 10, "\(XP.session(r))")
        expect("…the tally names short, away and the chosen pause, summing to 100 − \(r.score.total)", Set(Tally.session(r).map(\.name)).isSuperset(of: ["short", "away", "paused"]) && Tally.session(r).reduce(0) { $0 + $1.points } == 100 - r.score.total, rows(Tally.session(r)))
        expect("…and the End-time reader agrees with the record", Stats.focused(rows: awayRows, start: a0, end: a0 + 3826, pausedTotal: 3240) == r.focusedSeconds, "\(Stats.focused(rows: awayRows, start: a0, end: a0 + 3826, pausedTotal: 3240))")
    } else { expect("away fixture built", false) }
    expect("no pause rows → the summary's whole paused total comes out", Stats.pauseOutsideAway(pauses: [], resumes: [], aways: [], end: Date(), pausedTotal: 600) == 600)
    expect("a resumed pause comes out only for the minutes it ran", Stats.pauseOutsideAway(pauses: [(a0, "10 min")], resumes: [a0 + 240], aways: [], end: a0 + 3600, pausedTotal: 240) == 240)

    // MARK: F4 — the level crossed today and the personal best (PLAN_GAME_FEEL §3.4)

    print("\n== F4 · level-up and the personal best ==")
    func fake(_ start: Date, minutes m: Int) -> SessionRecord {
        var r = SessionRecord(id: 990_000 + Int64(m), start: start, end: start.addingTimeInterval(Double(m * 60)), live: false, goal: "Homework #8", plannedMinutes: nil, strictness: "strict", subject: nil, objectiveId: homeworkId)
        r.endedBy = "ended"; r.game = SessionGame.play(spans: [StripSpan(kind: .focus, from: 0, to: m * 60)], hits: []); return r   // HUD1: played
    }
    if let course = subjectOf[homeworkId] {
        let thursday6 = StudyDay.start(of: nowS0).addingTimeInterval(2 * 3600)   // 06:00 on the pinned Thursday
        let long = progress(course, extra: [fake(thursday6, minutes: 280)])        // HUD1: 609 + (10 + 40 + 250 × 3) × 1.1 = 1 489 ≥ 1 080
        expect("a 4 h 40 strict session today carries CS 150 from L1 to L2 → leveledToday, and it is the longest yet → bestToday", long.level == 2 && long.leveledToday && long.bestToday, "L\(long.level) · leveled \(long.leveledToday) · best \(long.bestToday)")
        let short = progress(course, extra: [fake(thursday6, minutes: 100)])
        expect("…a 100-min one: no level crossed, not longer than 163 → neither", !short.leveledToday && !short.bestToday, "leveled \(short.leveledToday) · best \(short.bestToday)")
        let none = progress(course)
        expect("…with nothing today: neither", !none.leveledToday && !none.bestToday)
        expect("…a course's first session is never a best", !CourseProgress.build(sessions: [fake(thursday6, minutes: 300)], completedAt: [], now: nowS0).bestToday)
        let tied = (asOf[course] ?? []).map(CourseProgress.clean).max() ?? 0
        expect("…a session as long as the longest is not a best (strictly longer)", !CourseProgress.isBest({ var r = fake(thursday6, minutes: tied); r.detourSeconds = 0; return r }(), after: asOf[course] ?? []), "longest \(tied)")
    }

    // MARK: M0 — the minute strip's spans (PLAN_MINUTE_STRIP §3.1)

    print("\n== M0 · the minute strip's spans ==")
    var tiled = true, focusOK = true, awayOK = true, pausedOK = true, marksOK = true, built = 0
    for r in all.sessions where !r.live {
        let st = SessionSpans.build(rows: events, start: r.start, end: r.end, planned: r.plannedMinutes.map { $0 * 60 }, pausedTotal: r.pausedSeconds)
        built += 1
        let elapsed = Int(r.end.timeIntervalSince(r.start))
        let body = st.spans.filter { $0.kind != .short }
        let tiles = body.first?.from == 0 && body.last?.to == elapsed && zip(body, body.dropFirst()).allSatisfy { $0.to == $1.from } && body.allSatisfy { $0.to > $0.from }
        let focus = st.total(.focus) - st.unplacedPaused, away = st.total(.away), paused = st.total(.paused) + st.unplacedPaused
        let bad = [tiles ? nil : "tiles", abs(focus - r.netFocusSeconds) <= 1 ? nil : "focus \(focus) ≠ net \(r.netFocusSeconds) (detours drawn \(st.total(.detour)) · counted \(r.detourSeconds))",
                   abs(away - r.awaySeconds) <= 1 ? nil : "away \(away) ≠ \(r.awaySeconds)", abs(paused - r.pauseOnlySeconds) <= 1 ? nil : "paused \(paused) ≠ \(r.pauseOnlySeconds)",
                   st.marks.count == r.launches ? nil : "marks \(st.marks.count) ≠ launches \(r.launches)"].compactMap { $0 }
        if !bad.isEmpty { print("      \(df.string(from: r.start)) \(clock(r.start)) \(r.goal.prefix(24)): " + bad.joined(separator: " · ")) }
        tiled = tiled && tiles; focusOK = focusOK && !bad.contains { $0.hasPrefix("focus") }
        awayOK = awayOK && !bad.contains { $0.hasPrefix("away") }; pausedOK = pausedOK && !bad.contains { $0.hasPrefix("paused") }; marksOK = marksOK && !bad.contains { $0.hasPrefix("marks") }
    }
    expect("every session's spans tile 0 → its end with no overlap (\(built) sessions)", tiled)
    expect("Σ focus = netFocusSeconds, to the second (the strip never disagrees with the score)", focusOK)
    expect("Σ away = awaySeconds", awayOK)
    expect("Σ paused (+ the summary's unplaced pause) = pauseOnlySeconds", pausedOK)
    expect("marks = launches after the sweep", marksOK)
    if let long = all.sessions.first(where: { $0.awaySeconds > 3000 }) {
        let st = SessionSpans.build(rows: events, start: long.start, end: long.end, planned: long.plannedMinutes.map { $0 * 60 }, pausedTotal: long.pausedSeconds)
        expect("the 55-min away session draws its 10-min auto-pause as away only", st.total(.paused) == 0 && st.total(.away) == long.awaySeconds, st.spans.map { "\($0.kind) \($0.seconds)" }.joined(separator: " · "))
    }
    // a scratch session: 30 min planned, a heeded and a blocked detour, a pause, a launch in the sweep and one after
    let m0 = Date(timeIntervalSince1970: 1_900_000_000)
    let rowsM0 = [Event(id: 1, ts: m0.addingTimeInterval(3), kind: "block.close", app: "Telegram", detail: "", latencyMs: nil),
                  Event(id: 2, ts: m0.addingTimeInterval(300), kind: "judge.detour", app: "", detail: "60 · followed through · YouTube — a video", latencyMs: nil),
                  Event(id: 3, ts: m0.addingTimeInterval(600), kind: "session.pause", app: "", detail: "2 min", latencyMs: nil),
                  Event(id: 4, ts: m0.addingTimeInterval(900), kind: "judge.detour", app: "", detail: "30 · blocked · Steam", latencyMs: nil),
                  Event(id: 5, ts: m0.addingTimeInterval(1000), kind: "block.shield", app: "Steam", detail: "", latencyMs: nil)]
    let sm = SessionSpans.build(rows: rowsM0, start: m0, end: m0.addingTimeInterval(1200), planned: 1800, pausedTotal: 120)
    expect("scratch: focus · detour YouTube (heeded) · focus · paused 2 min · focus · detour Steam (ignored) · focus · short 10 min",
           sm.spans.map(\.kind) == [.focus, .detour, .focus, .paused, .focus, .detour, .focus, .short] && sm.spans[1].site == "YouTube" && sm.spans[1].heeded && !sm.spans[5].heeded
           && sm.spans[1].from == 240 && sm.spans[3].seconds == 120 && sm.spans[7].seconds == 600 && sm.length == 1800,
           sm.spans.map { "\($0.kind) \($0.from)–\($0.to)" }.joined(separator: " · "))
    expect("scratch: Telegram at 3 s is the sweep, Steam at 1000 s is a mark", sm.marks == [StripMark(at: 1000, site: "Steam")], "\(sm.marks)")
    // M1: the live tail — focus or paused since the last refresh, an open away span drawn over everything from its start
    let builtM1 = SessionSpans.build(rows: Array(rowsM0.prefix(2)), start: m0, end: m0.addingTimeInterval(400), planned: nil, pausedTotal: nil).spans
    let tail = SessionSpans.live(builtM1, now: 600, paused: false, awayFrom: nil)
    expect("M1: 200 s after a refresh at 400 s the focus run reaches 600 s", tail.last == StripSpan(kind: .focus, from: 300, to: 600), "\(tail.last.map { "\($0.kind) \($0.from)–\($0.to)" } ?? "—")")
    let awayTail = SessionSpans.live(builtM1, now: 600, paused: true, awayFrom: 280)
    expect("M1: an away span open since 280 s cuts the detour and covers 280–600", awayTail.map(\.kind) == [.focus, .detour, .away] && awayTail[1].to == 280 && awayTail[2] == StripSpan(kind: .away, from: 280, to: 600),
           awayTail.map { "\($0.kind) \($0.from)–\($0.to)" }.joined(separator: " · "))

    // MARK: M2 — every tally row points at what it was taken for (PLAN_MINUTE_STRIP §3.5)

    print("\n== M2 · the tally points at the strip ==")
    let want: [String: Set<StripSpan.Kind>] = ["short": [.short], "ended early": [.short], "away": [.away], "paused": [.paused], "detour": [.detour], "detours": [.detour], "warning ignored": [.detour]]
    var kindsOK = true, noneOK = true, launchesOK = true, detoursOK = true, pointed = 0
    for r in all.sessions where !r.live {
        let st = SessionSpans.build(rows: events, start: r.start, end: r.end, planned: r.plannedMinutes.map { $0 * 60 }, pausedTotal: r.pausedSeconds)
        for l in Tally.point(Tally.session(r), st) {
            pointed += l.at.isEmpty ? 0 : 1
            if let k = want[l.name], !l.at.allSatisfy({ $0 < st.spans.count && k.contains(st.spans[$0].kind) }) { kindsOK = false; print("      \(clock(r.start)) \(l.name): \(l.at)") }
            if ["restless", "too short", "caught"].contains(l.name), !l.at.isEmpty { noneOK = false }
            if l.name == "launched", !(l.at.count == 1 && l.at[0] >= st.spans.count) { launchesOK = false; print("      \(clock(r.start)) launched \(l.detail): \(l.at)") }
            if l.name == "detour", l.at.count != 1 { detoursOK = false; print("      \(clock(r.start)) detour \(l.detail): \(l.at)") }
        }
    }
    expect("every row with a place points only at spans of its kind (\(pointed) rows pointed)", kindsOK)
    expect("restless, too short and caught point at nothing", noneOK)
    expect("each launch row points at one mark", launchesOK)
    expect("each detour row points at exactly one detour span", detoursOK)
    let fxRows = [Event(id: 1, ts: m0.addingTimeInterval(900), kind: "judge.detour", app: "", detail: "180 · followed through · YouTube — a video", latencyMs: nil),
                  Event(id: 2, ts: m0.addingTimeInterval(1860), kind: "judge.detour", app: "", detail: "60 · blocked · Reddit", latencyMs: nil),
                  Event(id: 3, ts: m0.addingTimeInterval(2400), kind: "block.shield", app: "Steam", detail: "", latencyMs: nil)]
    let fxStrip = SessionSpans.build(rows: fxRows, start: m0, end: m0.addingTimeInterval(52 * 60), planned: 3600, pausedTotal: 0)
    let fxLosses = Tally.point([Tally.Loss(name: "ended early", detail: "52 of 60 min", points: 7, part: .time), Tally.Loss(name: "detour", detail: "YouTube · 3 min", points: 2, part: .calm),
                                Tally.Loss(name: "warning ignored", detail: "Reddit", points: 10, part: .kept), Tally.Loss(name: "launched", detail: "Steam", points: 3, part: .control)], fxStrip)
    expect("the end card's fixture: ended early → the short span, detour → YouTube, warning ignored → Reddit (blocked), launched → Steam's mark",
           fxLosses.map(\.at) == [[5], [1], [3], [6]] && fxStrip.spans[1].site == "YouTube" && !fxStrip.spans[3].heeded,
           fxLosses.map { "\($0.name) \($0.at)" }.joined(separator: " · ") + " | " + fxStrip.spans.map { "\($0.kind)" }.joined(separator: " "))
    expect("grouped's `N more` row (restless and away, the two smallest of six) points at the union of what they point at: away's [9]",
           Tally.grouped(fxLosses + [Tally.Loss(name: "restless", detail: "", points: 1, part: .calm), Tally.Loss(name: "away", detail: "1 min", points: 1, part: .time, at: [9])]).last?.at == [9],
           Tally.grouped(fxLosses + [Tally.Loss(name: "restless", detail: "", points: 1, part: .calm), Tally.Loss(name: "away", detail: "1 min", points: 1, part: .time, at: [9])]).last.map { "\($0.name) \($0.at)" } ?? "—")

    print("\n\(failures) failure\(failures == 1 ? "" : "s")")
    if failures > 0 { exit(1) }
}
}
