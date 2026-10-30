// HUD1's check (PLAN_SESSION_HUD.md §4): the session game — accuracy, rank, combo, XP — judged over a COPY of the log, read-only,
// plus hand-built fixtures for each rule. Never starts the app; writes nothing.
//   swiftc -parse-as-library -o /tmp/game-check Sources/DistractionBot/Model/StudyDay.swift Sources/DistractionBot/Model/Stats.swift Sources/DistractionBot/Model/XP.swift Sources/DistractionBot/Model/OverallFigures.swift Sources/DistractionBot/Model/CourseProgress.swift Sources/DistractionBot/Model/Tally.swift Sources/DistractionBot/Model/SessionSpans.swift Sources/DistractionBot/Model/SessionGame.swift Sources/DistractionBot/Model/SessionTasks.swift scripts/shims/ScoringShim.swift scripts/game-check.swift
//   /tmp/game-check <path/to/log.sqlite copy> [--catalog path/to/subjects.json copy]
// Exit code 1 when an expectation fails.
import Foundation
import SQLite3

var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (got().isEmpty ? "" : " · got \(got())"))
    if !ok { failures += 1 }
}
func f1(_ d: Double) -> String { String(format: "%.1f", d) }

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

@main struct GameCheck {
static func main() {
    let G = SessionGame.self
    let args = CommandLine.arguments
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    var nid: Int64 = 1
    func row(_ s: Int, _ kind: String, _ detail: String, app: String = "") -> Event { defer { nid += 1 }; return Event(id: nid, ts: t0.addingTimeInterval(Double(s)), kind: kind, app: app, detail: detail, latencyMs: nil) }

    // MARK: rules on fixtures
    print("== rules ==")
    var st = G.State(); st.clean(3600)
    expect("an hour clean: 100 % · SS · combo 60 min", G.shown(st) == 100 && st.rank == .SS && st.combo == 3600)
    expect("…paid 10 min ×1 + 20 ×2 + 30 ×3 = 140 combo minutes", st.comboMinutes == 140, f1(st.comboMinutes))
    var s3 = G.State(); s3.clean(2400); s3.hit(.slip)
    expect("at ×3 a slip lands at the start of ×2 (combo 10 min)", s3.combo == 600 && s3.multiplier == 2, "\(s3.combo)")
    var s2 = G.State(); s2.clean(900); s2.hit(.slip)
    expect("at ×2 a slip lands at ×1 (combo 0)", s2.combo == 0)
    var sm = G.State(); sm.clean(2400); sm.hit(.miss)
    expect("a miss resets to 0 and ×1", sm.combo == 0 && sm.multiplier == 1)
    var sd = G.State(); sd.clean(700); sd.detour(120)
    expect("a detour freezes the combo (neither grows nor drops)", sd.combo == 700 && sd.cleanSeconds == 700)
    expect("…and costs accuracy: 120 of 820 lost → 85.4 %", G.shown(sd) == 85.4, f1(G.shown(sd)))
    var sc = G.State(); sc.clean(600); sc.detour(60); sc.clean(3000)
    expect("accuracy creeps back: 60 s lost of 3 660 → 98.4 %", G.shown(sc) == 98.4, f1(G.shown(sc)))
    expect("ranks: 98 SS · 97.9 S · 95 S · 94.9 A · 90 A · 89.9 B · 80 B · 79.9 C · 70 C · 69.9 D",
           [98, 97.9, 95, 94.9, 90, 89.9, 80, 79.9, 70, 69.9].map { G.rank($0).rawValue } == ["SS", "S", "S", "A", "A", "B", "B", "C", "C", "D"])
    expect("tiers: 9:59 ×1 · 10:00 ×2 · 29:59 ×2 · 30:00 ×3; next tier from 4 min = 6 min, none at ×3",
           G.multiplier(combo: 599) == 1 && G.multiplier(combo: 600) == 2 && G.multiplier(combo: 1799) == 2 && G.multiplier(combo: 1800) == 3 && G.toNextTier(combo: 240) == 360 && G.toNextTier(combo: 2000) == nil)

    // away and a break freeze everything
    let spansFreeze = [StripSpan(kind: .focus, from: 0, to: 900), StripSpan(kind: .away, from: 900, to: 2100), StripSpan(kind: .paused, from: 2100, to: 2700), StripSpan(kind: .focus, from: 2700, to: 3000)]
    let fr = G.play(spans: spansFreeze, hits: [])
    expect("away (20 min) and a break (10 min) freeze combo and cost no accuracy: combo 20 min, 100 %", fr.combo == 1200 && G.shown(fr) == 100 && fr.possible == 1200, "combo \(fr.combo) · possible \(fr.possible)")
    // HUD3: a 10-min break between two stretches of work freezes accuracy, combo and XP, and is no loss row
    let spansBreak = [StripSpan(kind: .focus, from: 0, to: 1500), StripSpan(kind: .paused, from: 1500, to: 2100), StripSpan(kind: .focus, from: 2100, to: 3000)]
    let br = G.play(spans: spansBreak, hits: []), noBreak = G.play(spans: [StripSpan(kind: .focus, from: 0, to: 2400)], hits: [])
    expect("HUD3: a 10-min break freezes everything — the same accuracy, combo and XP as 40 min straight", br == noBreak, "\(br.combo) vs \(noBreak.combo)")
    expect("…and the break is no loss row", G.losses(spans: spansBreak, hits: [], state: br).isEmpty)
    // the hits from rows: back is a slip, work nothing, ignored + still in front + blocked one miss, the sweep nothing, after follow-up nothing
    let rows = [row(0, "session.start", "fixture · 60 min · strict"),
                row(5, "block.close", "attempt 1", app: "Telegram"),
                row(300, "judge.answer", "back · YouTube — keyboards"),
                row(600, "judge.answer", "work · Overleaf — project.tex"),
                row(900, "judge.answer", "ignored · Reddit — r/all"),
                row(910, "judge.followup", "still in front · reddit.com · blocked for the session"),
                row(930, "web.block", "reddit.com · session block", app: "Dia"),
                row(960, "judge.answer", "back · Reddit — r/all · after follow-up"),
                row(1500, "judge.answer", "snooze · Messages opened"),
                row(2000, "block.shield", "activate · attempt 2", app: "Steam")]
    let hs = G.hits(rows: rows, start: t0, end: t0.addingTimeInterval(3600))
    expect("hits: back, ignored(+still in front+blocked = one miss), snooze, Steam — not the sweep, not work, not after follow-up",
           hs.map { "\($0.kind.rawValue)@\($0.at)" } == ["slip@300", "miss@900", "slip@1500", "miss@2000"], hs.map { "\($0.kind.rawValue)@\($0.at) \($0.what)" }.joined(separator: ", "))
    expect("`this is work` is not a slip (the judge was wrong; nothing happened)", !hs.contains { $0.at == 600 })
    let spansH = [StripSpan(kind: .focus, from: 0, to: 3600)]
    let ph = G.play(spans: spansH, hits: hs)
    let lossesH = G.losses(spans: spansH, hits: hs, state: ph)
    let sumH = lossesH.reduce(0) { $0 + $1.points }
    expect("the losses sum to 100 − accuracy at one decimal", abs(sumH - (100 - G.shown(ph))) < 0.001, "Σ \(f1(sumH)) · accuracy \(f1(G.shown(ph)))")
    print("  fixture: \(f1(G.shown(ph))) % \(ph.rank.rawValue) = 100 − " + lossesH.map { "\(f1($0.points)) \($0.name) · \($0.detail)" }.joined(separator: " − "))

    // MARK: HUD4 — tasks
    print("\n== tasks (HUD4) ==")
    func tick(_ at: Int, _ title: String, undo: Bool = false) -> Event { row(at, undo ? "task.undo" : "task.done", title) }
    let six = (0..<6).map { tick(600 + $0 * 240, "problem \($0 + 1)") }
    expect("six ticks 4 min apart pay five (+10 each, at most 5 a session)", SessionTasks.paid(rows: six, start: t0) == 5, "\(SessionTasks.paid(rows: six, start: t0))")
    let close = [tick(600, "a"), tick(660, "b"), tick(800, "c")]
    expect("ticks under 3 min apart: b, 1 min after a, is not paid; c, 3 min 20 after a, is", SessionTasks.paidTitles(rows: close, start: t0) == ["a", "c"], "\(SessionTasks.paidTitles(rows: close, start: t0).sorted())")
    let undone = [tick(600, "a"), tick(900, "a", undo: true)]
    expect("an untick takes its 10 back", SessionTasks.paid(rows: undone, start: t0) == 0)
    let again = [tick(600, "a"), tick(900, "a", undo: true), tick(1200, "a")]
    expect("…and a later tick, 3 min after the last paid one, pays again", SessionTasks.paid(rows: again, start: t0) == 1)
    let twice = [tick(600, "a"), tick(1200, "a")]
    expect("the same task ticked twice without an untick pays once", SessionTasks.paid(rows: twice, start: t0) == 1)
    var rec = SessionRecord(id: 1, start: t0, end: t0 + 3600, live: false, goal: "x", plannedMinutes: nil, strictness: "strict", subject: nil, objectiveId: nil)
    rec.game = G.play(spans: [StripSpan(kind: .focus, from: 0, to: 3600)], hits: []); rec.endedBy = "ended"
    let base = XP.session(rec); rec.tasksPaid = 3
    expect("task XP is not multiplied: 3 paid ticks add exactly 30 to a strict session (\(base) → \(XP.session(rec)))", XP.session(rec) == base + 30)
    let ts = [SessionTask(title: "problem 1", doneAt: t0), SessionTask(title: "problem 2"), SessionTask(title: "problem 3")]
    expect("the current task is the first unticked; the open ones carry in order", SessionTasks.current(ts) == "problem 2" && SessionTasks.open(ts) == ["problem 2", "problem 3"])
    expect("a title is trimmed to one line of at most 80; an empty one is nothing", SessionTasks.clean("  a\nb ") == "a b" && SessionTasks.clean(String(repeating: "x", count: 99))?.count == 80 && SessionTasks.clean("   ") == nil)
    let json = try! JSONEncoder().encode(ts), back = try! JSONDecoder().decode([SessionTask].self, from: json)
    expect("tasks round-trip through JSON (session.json keeps them)", back == ts)

    // MARK: HUD2 — the live game is the replay
    print("\n== live = replay (HUD2) ==")
    let liveRows = [row(0, "session.start", "live · open · normal"),
                    row(900, "judge.detour", "40 · followed through · YouTube — keyboards"),
                    row(905, "judge.answer", "back · YouTube — keyboards"),
                    row(1500, "session.pause", "10 min"), row(1800, "session.resume", "5 min early")]
    for (built, now) in [(1000, 1400), (1000, 2400), (2000, 3600)] {
        // the Store builds the strip at a refresh (`built` s in) and the HUD adds the tail to `now`; the replay builds at `now`
        let rowsThen = liveRows.filter { $0.ts <= t0.addingTimeInterval(Double(built)) }
        let strip = SessionSpans.build(rows: rowsThen, start: t0, end: t0.addingTimeInterval(Double(built)), planned: nil, pausedTotal: nil)
        let live = G.play(spans: SessionSpans.live(strip.spans, now: now, paused: false, awayFrom: nil), hits: G.hits(rows: rowsThen, start: t0, end: t0.addingTimeInterval(Double(built))))
        let rowsNow = liveRows.filter { $0.ts <= t0.addingTimeInterval(Double(now)) }
        let replay = (built >= 1800 || now < 1500) ? G.replay(rows: rowsNow, start: t0, end: t0.addingTimeInterval(Double(now)), planned: nil, pausedTotal: nil) : nil
        if let replay { expect("built at \(built) s, shown at \(now) s: live = replay (accuracy \(f1(G.shown(live))), combo \(live.combo), combo-paid \(f1(live.comboMinutes)))", live == replay, "replay \(f1(G.shown(replay))) · \(replay.combo)") }
        else { print("  note  built at \(built) s, shown at \(now) s spans a pause row the strip has not read — not compared: in the app every pause row reloads the log, which rebuilds the strip at once") }
    }
    // an away span still open: the HUD draws it over the tail; accuracy and combo hold still while away
    let stripA = SessionSpans.build(rows: liveRows.prefix(3).map { $0 }, start: t0, end: t0.addingTimeInterval(1000), planned: nil, pausedTotal: nil)
    let atAway = G.play(spans: SessionSpans.live(stripA.spans, now: 1200, paused: false, awayFrom: 1100), hits: G.hits(rows: Array(liveRows.prefix(3)), start: t0, end: t0.addingTimeInterval(1000)))
    let later = G.play(spans: SessionSpans.live(stripA.spans, now: 1800, paused: false, awayFrom: 1100), hits: G.hits(rows: Array(liveRows.prefix(3)), start: t0, end: t0.addingTimeInterval(1000)))
    expect("an open away span freezes the live game (same accuracy and combo at 1 200 s and 1 800 s)", atAway == later, "\(f1(G.shown(atAway)))/\(atAway.combo) vs \(f1(G.shown(later)))/\(later.combo)")

    // MARK: the real sessions
    guard args.count > 1, !args[1].hasPrefix("--") else { print(failures == 0 ? "\nALL OK (fixtures only; pass a log copy for the replay)" : "\n\(failures) FAILED"); exit(failures == 0 ? 0 : 1) }
    let events = readLog(args[1])
    let all = Stats.compute(events: events, period: Period(kind: .all, from: .distantPast, to: Date()), live: nil, now: Date(), targetMinutes: { _ in 240 })
    print("\n== the real sessions (tests hidden), \(events.count) rows ==")
    print("  session            · level   · min (judged) · detour · slips · misses · accuracy · lowest · max combo · XP ×1 → combo · at ×1/×2/×3 min · score as now")
    var oldXP = 0, newXP = 0, measured: [String: (Double, Int, Int)] = [:]
    let df = DateFormatter(); df.dateFormat = "EEE dd HH:mm"
    for s in all.sessions where !s.live {
        let es = events.filter { $0.ts >= s.start && $0.ts <= s.end }
        let strip = SessionSpans.build(rows: es, start: s.start, end: s.end, planned: s.plannedMinutes.map { $0 * 60 }, pausedTotal: s.pausedSeconds)
        let h = G.hits(rows: es, start: s.start, end: s.end)
        let g = G.play(spans: strip.spans, hits: h)
        var lowest = 100.0
        let len = Int(s.end.timeIntervalSince(s.start))
        for t in stride(from: 300, through: len, by: 60) { let p = G.play(spans: strip.spans, hits: h, until: t); if p.possible > 0 { lowest = min(lowest, p.accuracy) } }
        let ls = G.losses(spans: strip.spans, hits: h, state: g)
        let sum = ls.reduce(0) { $0 + $1.points }
        if abs(sum - (100 - G.shown(g))) > 0.001 { expect("losses sum for \(df.string(from: s.start))", false, "Σ \(f1(sum)) vs \(f1(100 - G.shown(g)))") }
        let x1 = g.cleanSeconds / 60
        oldXP += x1; newXP += Int(g.comboMinutes)
        measured[df.string(from: s.start)] = (G.shown(g), h.filter { $0.kind == .slip }.count, h.filter { $0.kind == .miss }.count)
        print("  \(df.string(from: s.start)) \(s.goal.prefix(9).padding(toLength: 9, withPad: " ", startingAt: 0)) · \(s.strictness.padding(toLength: 7, withPad: " ", startingAt: 0)) · \(len / 60) (\(g.possible / 60 - (g.slips * G.slipPenalty + g.misses * G.missPenalty) / 60)) · \(g.detourSeconds) s · \(g.slips) · \(g.misses) · \(f1(G.shown(g))) % \(g.rank.rawValue) · \(f1(lowest)) · \(g.bestCombo / 60) min · \(x1) → \(Int(g.comboMinutes)) · \(g.secondsAt[1, default: 0] / 60)/\(g.secondsAt[2, default: 0] / 60)/\(g.secondsAt[3, default: 0] / 60) · \(s.score.total)")
        if !ls.isEmpty { print("      = 100 − " + ls.prefix(5).map { "\(f1($0.points)) \($0.name) · \($0.detail)" }.joined(separator: " − ")) }
    }
    // HUD6: what the results screen and the rows read is the replay, and its losses always add up
    var agree = 0, sums = 0, groups = 0
    for s in all.sessions where !s.live {
        let es = events.filter { $0.ts >= s.start && $0.ts <= s.end }
        let replay = G.replay(rows: es, start: s.start, end: s.end, planned: s.plannedMinutes.map { $0 * 60 }, pausedTotal: s.pausedSeconds)
        if s.game == replay { agree += 1 }
        if let g = s.game, abs(s.gameLosses.reduce(0) { $0 + $1.points } - (100 - G.shown(g))) < 0.001 { sums += 1 }
        let gr = G.grouped(s.gameLosses)
        if gr.count <= 5, abs(gr.reduce(0) { $0 + $1.points } - s.gameLosses.reduce(0) { $0 + $1.points }) < 0.05, Set(gr.flatMap(\.at)) == Set(s.gameLosses.flatMap(\.at)) { groups += 1 }
    }
    let n = all.sessions.filter { !$0.live }.count
    expect("HUD6: every session's record carries the replay's game (\(agree) of \(n))", agree == n)
    expect("HUD6: every record's losses sum to 100 − accuracy (\(sums) of \(n))", sums == n)
    expect("HUD6: grouped to at most 5 rows, the points and the strip spans kept (\(groups) of \(n))", groups == n)
    if let r = all.sessions.first(where: { !$0.live && $0.gameLosses.count >= 3 }), let g = r.game { print("  e.g. \(df.string(from: r.start)): \(G.line(r.gameLosses, g)) · brief \(G.brief(r.gameLosses)) · row \(r.accuracyLabel ?? "")") }
    print("  clean minutes \(oldXP) → with combo \(newXP) · ratio \(String(format: "%.2f", Double(newXP) / Double(max(1, oldXP))))")
    // §2.4's figures, with the one rule the replay changed (a miss episode counts once: ignored → still in front → blocked)
    if let a = measured["Wed 28 21:27"] { expect("Wed 28 21:27 (2 h 44, two slips) → 98.1 %", a.0 == 98.1, f1(a.0)) }
    if let a = measured["Thu 29 15:37"] { expect("Thu 29 15:37 (one slip) → 97.5 %", a.0 == 97.5, f1(a.0)) }
    if let a = measured["Thu 29 17:44"] { expect("Thu 29 17:44 (the rough one) → 6 slips (a `back` after a follow-up is the same episode), 1 miss episode, below 90 %", a.1 == 6 && a.2 == 1 && a.0 < 90, "\(a.1) slips · \(a.2) misses · \(f1(a.0))") }

    // MARK: bands — no course changes level the day this lands (§5a Q7)
    guard let ci = args.firstIndex(of: "--catalog"), args.count > ci + 1, let data = FileManager.default.contents(atPath: args[ci + 1]),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let objectives = obj["objectives"] as? [[String: Any]] else {
        print(failures == 0 ? "\nALL OK (no --catalog: bands not measured)" : "\n\(failures) FAILED"); exit(failures == 0 ? 0 : 1)
    }
    var subjectOf: [String: String] = [:], done: [String: Int] = [:]
    for o in objectives { if let id = o["id"] as? String, let sub = o["subjectId"] as? String { subjectOf[id] = sub; if o["completedAt"] != nil { done[sub, default: 0] += 1 } } }
    let byCourse = Dictionary(grouping: all.sessions.filter { !$0.isTest && $0.objectiveId.flatMap { subjectOf[$0] } != nil }) { subjectOf[$0.objectiveId!]! }
    let oldBands = [180, 540, 1260, 2700, 5400]
    func oldSession(_ r: SessionRecord) -> Int { Int((Double(max(0, (r.focusedSeconds - r.detourSeconds) / 60)) * XP.multiplier(r.strictness)).rounded()) + (r.finished ? 30 : 0) }
    print("\n== courses: XP before → after, level on the old bands → on the new ==")
    var pairs: [(String, Int, Int)] = []
    for (c, ss) in byCourse.sorted(by: { $0.key < $1.key }) {
        let before = ss.reduce(0) { $0 + oldSession($1) } + 60 * (done[c] ?? 0)
        let after = XP.course(ss, completedObjectives: done[c] ?? 0)
        pairs.append((c, before, after))
    }
    for (c, b, a) in pairs { print("  \(c.prefix(10)) · \(b) → \(a) XP · L\(XP.level(b, bands: oldBands).level) → L\(XP.level(a).level) on \(XP.bands)") }
    expect("no course changes level under the new bands (\(XP.bands.map(String.init).joined(separator: " · ")))", pairs.allSatisfy { XP.level($0.1, bands: oldBands).level == XP.level($0.2).level })
    print(failures == 0 ? "\nALL OK" : "\n\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}
}
