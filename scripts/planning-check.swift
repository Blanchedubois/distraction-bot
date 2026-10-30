// P0–P2's check (PLAN_PLANNING.md §4): the due-state rule, the average real length and the calendar matcher, over plain values —
// a COPY of the log, a scratch catalogue and the ICS fixtures. Read-only; nothing launched.
//   swiftc -o /tmp/planning-check Sources/DistractionBot/Model/Planning.swift Sources/DistractionBot/Model/StudyDay.swift Sources/DistractionBot/Model/ICSParser.swift scripts/planning-check.swift
//   /tmp/planning-check <subjects.json copy> <log.sqlite copy> [fixtures dir] [a copy of calendar.ics]
import Foundation
import SQLite3

struct SubjectJ: Decodable { let id: String; let name: String; let weeklyTargetMinutes: Int? }
struct ObjectiveJ: Decodable { let id: String; let subjectId: String; let title: String; let completedAt: String?; let archived: Bool?; let due: String?; let estimateMinutes: Int? }
struct CatalogJ: Decodable { let subjects: [SubjectJ]; let objectives: [ObjectiveJ] }

@main struct Check {
    static var failures = 0
    static func expect(_ ok: Bool, _ what: String) { print("  \(ok ? "ok  " : "FAIL") \(what)"); if !ok { failures += 1 } }
    static func code(_ name: String) -> String? {
        for sep in [" - ", ": "] where name.contains(sep) { let p = name.components(separatedBy: sep); if p.count > 1 { return p[0] } }
        return nil
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count > 2 else { print("usage: planning-check <subjects.json> <log.sqlite> [fixtures dir] [calendar.ics copy]"); exit(2) }
        let fixtures = args.count > 3 ? args[3] : "docs/fixtures"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"; df.timeZone = .current
        let now = df.date(from: "2026-10-28 23:00")!
        let cal = Calendar.current
        func day(_ n: Int) -> Date { Planning.dueDate(forDay: cal.date(byAdding: .day, value: n, to: now)!) }

        // 1 · due states for six dates
        print("== dueState · now \(df.string(from: now))")
        let cases: [(Date?, DueState, String)] = [(nil, .none, "no date → none"), (day(0), .today, "today 23:59 → today"), (day(3), .soon(3), "+3 d → soon(3)"),
                                                   (day(7), .soon(7), "+7 d → soon(7)"), (day(10), .later(10), "+10 d → later(10)"), (day(-2), .overdue(2), "−2 d → overdue(2)")]
        for (d, want, what) in cases {
            let got = Planning.dueState(due: d, now: now)
            expect(got == want, "\(what) · got \(got) · label \(got.label(due: d) ?? "—")")
        }
        expect(Planning.dueState(due: day(1), now: now.addingTimeInterval(3600)).days == 0, "a 23:59 due date is still today at 00:00 of its own day")

        // 2 · the average rule
        print("\n== averageMinutes")
        expect(Planning.averageMinutes(seconds: [3600, 4620]) == 70, "60 + 77 min → 68.5 → 70")
        expect(Planning.averageMinutes(seconds: [11, 3600, 4648]) == 70, "an 11 s test is dropped")
        expect(Planning.averageMinutes(seconds: []) == nil && Planning.averageMinutes(seconds: [60]) == nil, "none, or only sub-15-minute sessions → nil")
        expect(Planning.averageMinutes(seconds: [3099, 1191]) == 35, "52 + 20 min → 35.75 → 35")

        // the real log copy: the proposal objective
        guard let data = FileManager.default.contents(atPath: args[1]), let cat = try? JSONDecoder().decode(CatalogJ.self, from: data) else { print("cannot read \(args[1])"); exit(2) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(args[2], &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { print("cannot open \(args[2])"); exit(2) }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT ts, kind, detail, session_id, objective_id FROM events WHERE session_id IS NOT NULL ORDER BY ts", -1, &st, nil)
        struct Row { let ts: Date; let kind: String; let detail: String; let session: String; let objective: String? }
        var rows: [Row] = []
        while sqlite3_step(st) == SQLITE_ROW {
            rows.append(Row(ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)), kind: String(cString: sqlite3_column_text(st, 1)),
                            detail: String(cString: sqlite3_column_text(st, 2)), session: String(cString: sqlite3_column_text(st, 3)), objective: sqlite3_column_text(st, 4).map { String(cString: $0) }))
        }
        sqlite3_finalize(st); sqlite3_close(db)
        var order: [String] = []; var bySession: [String: [Row]] = [:]
        for r in rows { if bySession[r.session] == nil { order.append(r.session) }; bySession[r.session, default: []].append(r) }
        var secondsBy: [String: [Int]] = [:]; var weekBy: [String: Int] = [:]
        let week = Planning.weekStart(now)
        for id in order {
            let es = bySession[id]!
            guard let start = es.first(where: { $0.kind == "session.start" }), let oid = start.objective else { continue }
            guard let end = es.last(where: { $0.kind == "session.end" }), let secs = Int(end.detail) else { continue }   // a live session is not averaged
            let goal = start.detail.components(separatedBy: " · ").first ?? ""
            if Planning.isTestGoal(goal) { continue }
            secondsBy[oid, default: []].append(secs)
            if start.ts >= week { weekBy[cat.objectives.first { $0.id == oid }?.subjectId ?? "", default: 0] += secs }
        }
        print("\n== the log copy · \(order.count) sessions · week from \(df.string(from: week)) (StudyDay start hour \(StudyDay.startHour))")
        for o in cat.objectives {
            let a = Planning.averageMinutes(seconds: secondsBy[o.id] ?? [])
            print("  \(o.title): sessions \((secondsBy[o.id] ?? []).map { $0 / 60 }) min → average \(a.map(String.init) ?? "—")")
        }
        if let proposal = cat.objectives.first(where: { $0.title.lowercased().contains("proposal") }) {
            expect(Planning.averageMinutes(seconds: secondsBy[proposal.id] ?? []) == 70, "the proposal objective averages 70 (60 + 77)")
        }
        for s in cat.subjects { print("  \(code(s.name) ?? s.name): \((weekBy[s.id] ?? 0) / 60) min this week · target \(s.weeklyTargetMinutes.map { Planning.hours($0) } ?? "none")") }
        for o in cat.objectives where o.due != nil || o.estimateMinutes != nil { print("  \(o.title): due \(o.due ?? "—") · estimate \(o.estimateMinutes.map(Planning.hours) ?? "—")") }

        // 3 · the matcher
        print("\n== matcher")
        // a fixture catalogue of its own (the real one may carry the same codes, which would make the ids ambiguous)
        let subjects = [Planning.SubjectIn(id: "fx-phys320", code: "BIO 210"), Planning.SubjectIn(id: "fx-split", code: "PHYS 352/351"), Planning.SubjectIn(id: "fx-nocode", code: nil)]
        let objectives = [Planning.ObjectiveIn(id: "fx-hw8", subjectId: "fx-phys320", title: "Homework #8", open: true), Planning.ObjectiveIn(id: "fx-done", subjectId: "fx-phys320", title: "Homework #7", open: false),
                          Planning.ObjectiveIn(id: "fx-proposal", subjectId: "fx-split", title: "Research Proposal Presentation", open: true)]
        expect(Planning.codeVariants("PHYS 352/351") == ["PHYS 352/351", "PHYS 352", "PHYS 351"], "PHYS 352/351 → PHYS 352 · PHYS 351")
        let t0 = now, t1 = now.addingTimeInterval(3600)
        func m(_ title: String, _ loc: String = "", allDay: Bool = false) -> Planning.Match? { Planning.match(title: title, location: loc, allDay: allDay, start: t0, end: t1, subjects: subjects, objectives: objectives) }
        expect(m("BIO 210 lecture")?.subjectId == "fx-phys320" && m("BIO 210 lecture")?.objectiveId == nil, "a code in the title → the subject, no objective")
        expect(m("Lecture", "Science Hall · phys 351")?.subjectId == "fx-split", "a split code's second half in the location, case-insensitive → the subject")
        expect(m("Homework #8 due")?.objectiveId == "fx-hw8" && m("Homework #8 due")?.subjectId == "fx-phys320", "two title words shared → the objective (and its subject)")
        expect(m("Homework #7")?.objectiveId == nil, "a completed objective is not matched")
        expect(m("Research")?.objectiveId == nil, "one shared word is not an objective match")
        expect(m("BIO 210 lecture", allDay: true) == nil, "an all-day event is not a block")
        expect(m("Fraternity Chapter") == nil, "an unrelated event → nothing")

        for name in ["google", "outlook", "minimal"] {
            guard let text = try? String(contentsOfFile: "\(fixtures)/\(name).ics", encoding: .utf8) else { print("missing \(name).ics"); exit(2) }
            let c = ICSParser.parse(text)
            let d0 = df.date(from: "2026-10-26 00:00")!
            let ins = ICSParser.instances(of: c, from: d0, to: cal.date(byAdding: .day, value: 7, to: d0)!)
            let matched = ins.compactMap { i in Planning.match(title: i.title, location: i.location, allDay: i.allDay, start: i.start, end: i.end, subjects: subjects, objectives: objectives).map { (i, $0) } }
            print("  \(name).ics · \(ins.count) instances · \(matched.count) planned: " + matched.map { "\($0.0.title) → \($0.1.objectiveId ?? $0.1.subjectId)" }.joined(separator: " · "))
            if name == "google" { expect(matched.count == 2 && matched.allSatisfy { $0.1.subjectId == "fx-phys320" }, "google.ics: the lecture and its moved override → BIO 210") }
            else { expect(matched.isEmpty, "\(name).ics: nothing planned") }
        }
        if args.count > 4, let text = try? String(contentsOfFile: args[4], encoding: .utf8) {
            let c = ICSParser.parse(text)
            let from = cal.date(byAdding: .day, value: -60, to: now)!, to = cal.date(byAdding: .day, value: 60, to: now)!
            let real = cat.subjects.map { Planning.SubjectIn(id: $0.id, code: code($0.name)) }
            let realO = cat.objectives.map { Planning.ObjectiveIn(id: $0.id, subjectId: $0.subjectId, title: $0.title, open: $0.completedAt == nil && $0.archived != true) }
            let ins = ICSParser.instances(of: c, from: from, to: to)
            let matched = ins.compactMap { i in Planning.match(title: i.title, location: i.location, allDay: i.allDay, start: i.start, end: i.end, subjects: real, objectives: realO).map { (i, $0) } }
            let tf = DateFormatter(); tf.dateFormat = "EEE d MMM HH:mm"
            print("\n== the real feed copy · \(c.events.count) events · \(ins.count) instances ±60 d · \(matched.count) planned blocks")
            for (i, mm) in matched.prefix(12) { print("  \(tf.string(from: i.start))  \(i.title) → \(cat.objectives.first { $0.id == mm.objectiveId }?.title ?? (code(cat.subjects.first { $0.id == mm.subjectId }?.name ?? "") ?? "?"))") }
        }
        print("\n\(failures == 0 ? "ALL OK" : "\(failures) FAILED")")
        exit(failures == 0 ? 0 : 1)
    }
}
