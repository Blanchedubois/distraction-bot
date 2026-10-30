// J0's check (PLAN_JUMP_BACK_IN.md §4): the Jump back in order rule over a COPY of the log and the catalogue, read-only, printed.
//   swiftc -o /tmp/jumpbackin-check Sources/DistractionBot/Model/JumpBackInOrder.swift Sources/DistractionBot/Model/StudyDay.swift scripts/jumpbackin-check.swift   (StudyDay since K1)
//   /tmp/jumpbackin-check <subjects.json> <log.sqlite> [now: YYYY-MM-DD HH:mm] [live objective id]
// The session rule here is the short form of EventLog.sessions(): rows grouped by session_id, started at session.start,
// seconds from session.end's detail, else to the session's last row (a live session: to now).
import Foundation
import SQLite3

struct SubjectJ: Decodable { let id: String; let name: String; let sort: Int? }
struct ObjectiveJ: Decodable { let id: String; let subjectId: String; let title: String; let sort: Int?; let archived: Bool?; let completedAt: String?; let due: String? }   // P1: due, completedAt
struct CatalogJ: Decodable { let subjects: [SubjectJ]; let objectives: [ObjectiveJ] }

@main struct Check {
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 2 else { print("usage: jumpbackin-check <subjects.json> <log.sqlite> [now 'YYYY-MM-DD HH:mm'] [live objective id]"); exit(2) }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"; df.timeZone = .current
        let now = args.count > 3 ? (df.date(from: args[3]) ?? { print("bad date"); exit(2) }()) : Date()
        let live = args.count > 4 ? args[4] : nil

        guard let data = FileManager.default.contents(atPath: args[1]), let cat = try? JSONDecoder().decode(CatalogJ.self, from: data) else { print("cannot read \(args[1])"); exit(2) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(args[2], &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { print("cannot open \(args[2])"); exit(2) }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT ts, kind, detail, session_id, objective_id FROM events WHERE session_id IS NOT NULL ORDER BY ts", -1, &st, nil)
        struct Row { let ts: Date; let kind: String; let detail: String; let session: String; let objective: String? }
        var rows: [Row] = []
        while sqlite3_step(st) == SQLITE_ROW {
            rows.append(Row(ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)), kind: String(cString: sqlite3_column_text(st, 1)),
                            detail: String(cString: sqlite3_column_text(st, 2)), session: String(cString: sqlite3_column_text(st, 3)),
                            objective: sqlite3_column_text(st, 4).map { String(cString: $0) }))
        }
        sqlite3_finalize(st); sqlite3_close(db)

        var order: [String] = []; var bySession: [String: [Row]] = [:]
        for r in rows { if bySession[r.session] == nil { order.append(r.session) }; bySession[r.session, default: []].append(r) }
        var sessions: [JumpBackInOrder.SessionIn] = []
        for id in order {
            let es = bySession[id]!
            guard let start = es.first(where: { $0.kind == "session.start" }) else { continue }
            let end = es.last { $0.kind == "session.end" }
            let isLive = live != nil && start.objective == live && end == nil
            let seconds = end.flatMap { Int($0.detail) } ?? Int((isLive ? now : (es.last?.ts ?? start.ts)).timeIntervalSince(start.ts))
            sessions.append(.init(objectiveId: start.objective, started: start.ts, seconds: seconds))
        }

        let subjects = cat.subjects.sorted { ($0.sort ?? 0) < ($1.sort ?? 0) }
        let iso = ISO8601DateFormatter()
        let objectives = cat.objectives.map { JumpBackInOrder.ObjectiveIn(id: $0.id, subjectId: $0.subjectId, sort: $0.sort ?? 0, archived: ($0.archived ?? false) || $0.completedAt != nil, due: $0.due.flatMap { iso.date(from: $0) }) }
        let dueOf = Dictionary(uniqueKeysWithValues: cat.objectives.map { ($0.id, $0.due.flatMap { iso.date(from: $0) }) })
        let figures = JumpBackInOrder.rows(objectives: objectives, subjectOrder: subjects.map(\.id), sessions: sessions, live: live, now: now)
        let titles = Dictionary(uniqueKeysWithValues: cat.objectives.map { ($0.id, $0.title) })
        let subjectName = Dictionary(uniqueKeysWithValues: cat.subjects.map { ($0.id, $0.name) })
        let subjectOf = Dictionary(uniqueKeysWithValues: cat.objectives.map { ($0.id, subjectName[$0.subjectId] ?? "?") })
        let tf = DateFormatter(); tf.dateFormat = "EEE d MMM HH:mm"
        func mins(_ s: Int) -> String { s >= 3600 ? "\(s / 3600) h \(s % 3600 / 60) min" : s >= 60 ? "\(s / 60) min" : "\(s) s" }
        let known = Set(cat.objectives.map(\.id))
        let stray = Set(sessions.compactMap(\.objectiveId)).subtracting(known)
        print("NOW \(tf.string(from: now)) · week from \(tf.string(from: JumpBackInOrder.weekStart(now))) · \(sessions.count) sessions, \(sessions.filter { $0.objectiveId == nil }.count) free-text, \(stray.count) on objectives no longer in the catalogue\(live.map { " · live \($0.prefix(8))" } ?? "")")
        print("")
        for (i, f) in figures.enumerated() {
            let line = f.started ? "last \(tf.string(from: f.lastStarted!)) · \(f.sessions) session\(f.sessions == 1 ? "" : "s") · this week \(f.weekSeconds > 0 ? mins(f.weekSeconds) : "—")" : "not started yet"
            let due = (dueOf[f.objectiveId] ?? nil).map { "  due \(tf.string(from: $0))" } ?? ""
            print("\(i + 1). \(titles[f.objectiveId] ?? f.objectiveId)  [\(subjectOf[f.objectiveId] ?? "?")]\(f.objectiveId == live ? "  ● in session" : "")\(due)")
            print("   \(line)")
        }
    }
}
