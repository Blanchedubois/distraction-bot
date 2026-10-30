import Foundation
import SQLite3

/// Every block, warning, verdict and answer, in SQLite (§3.7). Nothing else is stored.
struct Event: Identifiable, Equatable {
    let id: Int64
    let ts: Date
    let kind: String        // session.start · session.end · block.close · block.shield · block.warn · block.attempt · skip · …
    let app: String
    let detail: String
    let latencyMs: Int?
    // PLAN_OBJECTIVES_MODEL O1 (§3.5): the session the event happened in, its objective and kind; nil on rows from before O1 until O2 stamps them
    var sessionId: String? = nil
    var objectiveId: String? = nil
    var sessionKind: String? = nil

    init(id: Int64, ts: Date, kind: String, app: String, detail: String, latencyMs: Int?, sessionId: String? = nil, objectiveId: String? = nil, sessionKind: String? = nil) {
        self.id = id; self.ts = ts; self.kind = kind; self.app = app; self.detail = detail; self.latencyMs = latencyMs
        self.sessionId = sessionId; self.objectiveId = objectiveId; self.sessionKind = sessionKind
    }
}

/// One session as the log remembers it (O1 §3.5): read from the stamped rows, for the objective overview and the Progress tab.
struct ObjectiveSession: Identifiable, Equatable {
    let id: String                  // Session.id
    let objectiveId: String?
    let kind: String?
    let goal: String
    let started: Date
    let ended: Date?                // nil: still running, or the app was quit mid-session
    let seconds: Int                // from session.end's detail, else to the last stamped event
    let strictness: String
    let warnings: Int
    let blocks: Int
    let endedBy: String             // finished · ended · by phrase · quit · live
}

@MainActor
final class EventLog {
    static let shared = EventLog()
    private var db: OpaquePointer?

    private init() {
        let path = ProcessInfo.processInfo.environment["DBOT_LOG_PATH"] ?? Store.supportDir.appendingPathComponent("log.sqlite").path   // X0: quiet checks read a scratch copy
        guard sqlite3_open(path, &db) == SQLITE_OK else { db = nil; return }
        exec("CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, kind TEXT NOT NULL, app TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '', latency_ms INTEGER)")
        exec("CREATE INDEX IF NOT EXISTS events_ts ON events(ts)")
        // O1 §3.5: three nullable columns, added once; PRAGMA first so a second launch is a no-op
        let have = columns()
        for c in ["session_id", "objective_id", "kind_tag"] where !have.contains(c) { exec("ALTER TABLE events ADD COLUMN \(c) TEXT") }
        exec("CREATE INDEX IF NOT EXISTS events_session ON events(session_id)")
        stampLegacySessions()
    }

    /// O2 §3.7: rows from before O1 have no session_id. Once, with the Stats span rule (start → its end, else the last event before the
    /// next start), each old session's rows get `legacy-<start event id>`. Rows that already carry an id are never touched, so a
    /// second launch changes nothing; stray rows outside any session stay NULL.
    func stampLegacySessions() {
        let orphans = query("SELECT \(Self.cols) FROM events WHERE session_id IS NULL ORDER BY ts ASC") { _ in }
        guard orphans.contains(where: { $0.kind == "session.start" }) else { return }
        for r in Stats.sessionSpans(events: orphans, live: nil, now: Date()) {
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE events SET session_id = ? WHERE session_id IS NULL AND ts >= ? AND ts <= ?", -1, &st, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(st, 1, "legacy-\(r.id)", -1, Self.T); sqlite3_bind_double(st, 2, r.start.timeIntervalSince1970); sqlite3_bind_double(st, 3, r.end.timeIntervalSince1970)
            sqlite3_step(st); sqlite3_finalize(st)
        }
        Log.write("stamped legacy sessions")
    }

    /// Filing (O2): every row of the session gets the objective (nil unfiles). The kind tag is left as it was.
    func fileSession(_ id: String, under objective: String?) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE events SET objective_id = ? WHERE session_id = ?", -1, &st, nil) == SQLITE_OK else { return }
        if let objective { sqlite3_bind_text(st, 1, objective, -1, Self.T) } else { sqlite3_bind_null(st, 1) }
        sqlite3_bind_text(st, 2, id, -1, Self.T)
        sqlite3_step(st); sqlite3_finalize(st)
    }

    private func columns() -> Set<String> {
        var st: OpaquePointer?; var out: Set<String> = []
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(events)", -1, &st, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { out.insert(String(cString: sqlite3_column_text(st, 1))) }
        return out
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    func add(_ kind: String, app: String = "", detail: String = "", latencyMs: Int? = nil) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO events (ts, kind, app, detail, latency_ms, session_id, objective_id, kind_tag) VALUES (?, ?, ?, ?, ?, ?, ?, ?)", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_double(st, 1, Date().timeIntervalSince1970)
        sqlite3_bind_text(st, 2, kind, -1, T); sqlite3_bind_text(st, 3, app, -1, T); sqlite3_bind_text(st, 4, detail, -1, T)
        if let l = latencyMs { sqlite3_bind_int(st, 5, Int32(l)) } else { sqlite3_bind_null(st, 5) }
        // stamped from the live session (O1); session.end is written while the session is still set, so it is stamped too
        let s = Store.current?.session
        for (i, v) in [(6, s?.id), (7, s?.objectiveId), (8, s?.kind?.rawValue)] { if let v { sqlite3_bind_text(st, Int32(i), v, -1, T) } else { sqlite3_bind_null(st, Int32(i)) } }
        sqlite3_step(st)
    }

    /// K0 (PLAN_STUDY_DAY §3.8, IMPACT_ANALYSIS R0): the UI usage log — `ui.tab` · `ui.open` · `ui.door` · `ui.overlay` · `ui.reminder`.
    /// No content, no titles, no hosts: a kind and one short word. Off with Settings → Data → UI usage. Stamped like every row.
    func ui(_ kind: String, _ detail: String) {
        guard Store.current?.settings.uiLog ?? true else { return }
        add("ui." + kind, detail: detail)
    }

    func recent(limit: Int = 300, since: Date? = nil) -> [Event] {
        var st: OpaquePointer?
        let sql = "SELECT id, ts, kind, app, detail, latency_ms FROM events WHERE ts >= ? ORDER BY ts DESC LIMIT ?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_double(st, 1, (since ?? .distantPast).timeIntervalSince1970); sqlite3_bind_int(st, 2, Int32(limit))
        var out: [Event] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append(Event(id: sqlite3_column_int64(st, 0), ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                             kind: String(cString: sqlite3_column_text(st, 2)), app: String(cString: sqlite3_column_text(st, 3)),
                             detail: String(cString: sqlite3_column_text(st, 4)),
                             latencyMs: sqlite3_column_type(st, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(st, 5))))
        }
        return out
    }

    /// Every event between two instants, ascending, no limit (the Today timeline and the Progress tab read whole days).
    /// Reads the stamped columns too (PLAN_TODAY_SCHEDULE D0), so `objectiveId` / `sessionId` reach the day model.
    func events(from: Date, to: Date) -> [Event] {
        query("SELECT \(Self.cols) FROM events WHERE ts >= ? AND ts <= ? ORDER BY ts ASC") {
            sqlite3_bind_double($0, 1, from.timeIntervalSince1970); sqlite3_bind_double($0, 2, to.timeIntervalSince1970)
        }
    }

    private static let cols = "id, ts, kind, app, detail, latency_ms, session_id, objective_id, kind_tag"
    private func row(_ st: OpaquePointer?) -> Event {
        func text(_ i: Int32) -> String? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(st, i)) }
        return Event(id: sqlite3_column_int64(st, 0), ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 1)),
                     kind: text(2) ?? "", app: text(3) ?? "", detail: text(4) ?? "",
                     latencyMs: sqlite3_column_type(st, 5) == SQLITE_NULL ? nil : Int(sqlite3_column_int(st, 5)),
                     sessionId: text(6), objectiveId: text(7), sessionKind: text(8))
    }
    private func query(_ sql: String, _ bind: (OpaquePointer?) -> Void) -> [Event] {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        bind(st)
        var out: [Event] = []
        while sqlite3_step(st) == SQLITE_ROW { out.append(row(st)) }
        return out
    }
    private static let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Every event of one session, ascending (O1).
    /// Every event stamped with an objective inside a range, oldest first (the overview's day strips, V2).
    func events(objective id: String, from: Date, to: Date) -> [Event] {
        query("SELECT \(Self.cols) FROM events WHERE objective_id = ? AND ts >= ? AND ts <= ? ORDER BY ts ASC") {
            sqlite3_bind_text($0, 1, id, -1, Self.T); sqlite3_bind_double($0, 2, from.timeIntervalSince1970); sqlite3_bind_double($0, 3, to.timeIntervalSince1970)
        }
    }

    /// K2 (PLAN_STUDY_DAY §3.3): every row of one kind in a range, ascending — the `day.shutdown` records.
    func events(kind: String, from: Date, to: Date) -> [Event] {
        query("SELECT \(Self.cols) FROM events WHERE kind = ? AND ts >= ? AND ts <= ? ORDER BY ts ASC") {
            sqlite3_bind_text($0, 1, kind, -1, Self.T); sqlite3_bind_double($0, 2, from.timeIntervalSince1970); sqlite3_bind_double($0, 3, to.timeIntervalSince1970)
        }
    }

    func events(session id: String) -> [Event] {
        query("SELECT \(Self.cols) FROM events WHERE session_id = ? ORDER BY ts ASC") { sqlite3_bind_text($0, 1, id, -1, Self.T) }
    }

    /// Stamped sessions, newest first, for one objective, one subject (through the catalogue) or all (O1 §3.5).
    /// Only rows with a session_id count; O2 stamps the rows from before.
    func sessions(objective: String? = nil, subject: String? = nil, since: Date? = nil) -> [ObjectiveSession] {
        let subjectObjectives: Set<String>? = subject.map { sid in Set(Store.current?.catalog.objectives.filter { $0.subjectId == sid }.map(\.id) ?? []) }
        let rows = query("SELECT \(Self.cols) FROM events WHERE session_id IS NOT NULL AND ts >= ? ORDER BY ts ASC") { sqlite3_bind_double($0, 1, (since ?? .distantPast).timeIntervalSince1970) }
        var bySession: [String: [Event]] = [:]; var order: [String] = []
        for e in rows { if bySession[e.sessionId!] == nil { order.append(e.sessionId!) }; bySession[e.sessionId!, default: []].append(e) }
        let live = Store.current?.session
        var out: [ObjectiveSession] = []
        for id in order {
            let es = bySession[id]!
            guard let start = es.first(where: { $0.kind == "session.start" }) else { continue }
            let oid = start.objectiveId
            if let objective, oid != objective { continue }
            if let subjectObjectives, !(oid.map { subjectObjectives.contains($0) } ?? false) { continue }
            let parts = start.detail.components(separatedBy: " · ")
            let end = es.last { $0.kind == "session.end" }
            let isLive = live?.id == id
            var seconds = end.flatMap { Int($0.detail) } ?? Int((isLive ? Date() : (es.last { !$0.kind.hasPrefix("ui.") }?.ts ?? start.ts)).timeIntervalSince(start.ts))   // K0: a tab switch is not study
            seconds = max(0, seconds - es.filter { $0.kind == "session.away" }.compactMap { Int($0.detail) }.reduce(0, +))   // X4: minus the away spans
            let warnings = es.filter { $0.kind == "web.warn" || $0.kind == "block.warn" || ($0.kind == "judge.verdict" && $0.detail.hasPrefix("distracted")) }.count
            let blocks = es.filter { ["block.close", "block.shield", "web.block", "judge.close"].contains($0.kind) || ($0.kind == "judge.followup" && $0.detail.contains("blocked")) }.count
            let endedBy: String = isLive ? "live" : end == nil ? "quit" : es.contains { $0.kind == "session.escape" && $0.detail.hasPrefix("phrase typed") } ? "by phrase"
                : (start.ends(parts).map { $0 <= (end!.ts.addingTimeInterval(2)) } ?? false) ? "finished" : "ended"
            out.append(ObjectiveSession(id: id, objectiveId: oid, kind: start.sessionKind ?? (parts.count > 3 ? parts[3] : nil), goal: parts.first ?? start.detail,
                                        started: start.ts, ended: end?.ts, seconds: seconds, strictness: parts.count > 2 ? parts[2] : "", warnings: warnings, blocks: blocks, endedBy: endedBy))
        }
        return out.reversed()
    }

    /// What pulled you away over an objective's sessions, grouped by app or host (O1 §3.5; the overview's §3.4).
    struct Distraction: Identifiable, Equatable { var id: String { key }; let key: String; let isHost: Bool; var count: Int; var last: Date; var answers: [String: Int]; var blocked: Int }
    /// The app or host a distraction event is about (O2 §3.7; shared with the overview's severity line, V3).
    static func distractionKey(_ e: Event) -> (key: String, isHost: Bool)? {
        func host(_ detail: String) -> String { detail.components(separatedBy: " · ").first.map { $0.components(separatedBy: " → ").first ?? $0 } ?? detail }
        var key: String?; var isHost = false
        switch e.kind {
        case "judge.verdict" where e.detail.hasPrefix("distracted"): key = e.app
        case "web.warn", "web.block": key = host(e.detail); isHost = true
        case "block.close", "block.shield", "block.warn", "judge.close": key = e.app
        case "judge.followup" where e.detail.contains("blocked"): key = e.detail.components(separatedBy: " · ").dropFirst().first; isHost = true
        default: break
        }
        guard let key, !key.isEmpty else { return nil }
        return (key, isHost)
    }

    func distractions(objective: String) -> [Distraction] {
        let es = query("SELECT \(Self.cols) FROM events WHERE objective_id = ? ORDER BY ts ASC") { sqlite3_bind_text($0, 1, objective, -1, Self.T) }
        var out: [String: Distraction] = [:]
        for e in es {
            guard let (key, isHost) = Self.distractionKey(e) else { continue }
            var d = out[key] ?? Distraction(key: key, isHost: isHost, count: 0, last: e.ts, answers: [:], blocked: 0)
            d.count += 1; d.last = e.ts
            if ["block.close", "block.shield", "web.block", "judge.close"].contains(e.kind) || e.kind == "judge.followup" { d.blocked += 1 }
            out[key] = d
        }
        // answers ride on judge.answer "<answer> · <what>": matched to an item whose key appears in <what>
        for e in es where e.kind == "judge.answer" || e.kind == "web.answer" {
            let parts = e.detail.components(separatedBy: " · "); guard parts.count >= 2 else { continue }
            let what = parts[1]
            for k in out.keys where what.localizedCaseInsensitiveContains(k) { out[k]!.answers[parts[0] == "this is work" ? "work" : parts[0], default: 0] += 1 }
        }
        return out.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
    }

    func clear() { exec("DELETE FROM events") }

    /// The first logged study day (its start; K1), for the History tab's bounds (PLAN_HISTORY_TAB Y1); nil on an empty log.
    func firstDay() -> Date? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MIN(ts) FROM events", -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, sqlite3_column_type(st, 0) != SQLITE_NULL else { return nil }
        return StudyDay.start(of: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)))   // K1
    }

    func count(_ kindPrefix: String, since: Date) -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM events WHERE kind LIKE ? AND ts >= ?", -1, &st, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, kindPrefix + "%", -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)); sqlite3_bind_double(st, 2, since.timeIntervalSince1970)
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int(st, 0)) : 0
    }

    /// Seconds of finished sessions since `since` (session.end carries its length in detail).
    func focusedSeconds(since: Date) -> Int {
        recent(limit: 1000, since: since).filter { $0.kind == "session.end" }.compactMap { Int($0.detail) }.reduce(0, +)
    }
}

extension Event: LogRow {}

private extension Event {
    /// The planned end of a session from its start line's "<N> min" part, for "finished" vs "ended".
    func ends(_ parts: [String]) -> Date? {
        guard parts.count > 1, parts[1].hasSuffix(" min"), let m = Int(parts[1].dropLast(4)) else { return nil }
        return ts.addingTimeInterval(Double(m) * 60)
    }
}
