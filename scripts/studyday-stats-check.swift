// K1's regression check (PLAN_STUDY_DAY.md §4): the Progress aggregate for a day, computed over a COPY of the log with the study day
// starting at 04:00 and at midnight (the pre-K1 rule), printed side by side — the same figures `DBOT_STATS_CHECK=<day>` prints, without
// launching the app. Nothing is written.
//   swiftc -parse-as-library -o /tmp/studyday-stats-check Sources/DistractionBot/Model/StudyDay.swift Sources/DistractionBot/Model/Stats.swift Sources/DistractionBot/Model/Tally.swift Sources/DistractionBot/Model/SessionSpans.swift Sources/DistractionBot/Model/SessionGame.swift Sources/DistractionBot/Model/SessionTasks.swift Sources/DistractionBot/Model/OverallFigures.swift scripts/shims/ScoringShim.swift scripts/studyday-stats-check.swift
//   /tmp/studyday-stats-check <path/to/log.sqlite copy> [YYYY-MM-DD …]
import Foundation
import SQLite3

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
        guard args.count > 1 else { print("usage: studyday-stats-check <log copy> [YYYY-MM-DD …]"); exit(2) }
        let all = readLog(args[1])
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        let bf = DateFormatter(); bf.dateFormat = "EEE d MMM HH:mm"
        let days = args.count > 2 ? Array(args[2...]) : ["2026-10-26", "2026-10-27", "2026-10-28"]
        for dayText in days {
            guard let date = f.date(from: dayText) else { print("bad date \(dayText)"); continue }
            print("== \(dayText) ==")
            var lines: [Int: [String]] = [:]
            for hour in [0, 4] {
                StudyDay.startHour = hour
                let day = StudyDay.dayStarting(on: date)
                let now = min(Date(), StudyDay.end(of: day) - 1)
                let period = Period(kind: .today, from: day, to: now)
                let events = all.filter { $0.ts >= period.from - 3600 * 6 && $0.ts <= now }
                var out: [String] = ["start \(hour): \(bf.string(from: day)) → \(bf.string(from: StudyDay.end(of: day)))"]
                for showTests in [false, true] {
                    let s = Stats.compute(events: events, period: period, live: nil, now: now, targetMinutes: { _ in 240 }, showTests: showTests)
                    out.append("  tests \(showTests ? "shown " : "hidden"): sessions \(s.sessions.count) (hidden \(s.hiddenTests)) · focused \(s.focusedSeconds) s · caught \(s.caught) · blocked \(s.blocked) · followed \(s.followedThrough)/\(s.followUps) · score \(s.score.total) = \(s.score.time)+\(s.score.calm)+\(s.score.follow)+\(s.score.blocks) · days \(s.days.map { bf.string(from: $0.day) })")
                    let busy = s.hours.filter { $0.focusedSeconds > 0 || $0.caught > 0 }
                    out.append("    hours: " + busy.map { "\($0.hour):\($0.focusedSeconds / 60)m/\($0.caught)" }.joined(separator: " "))
                }
                lines[hour] = out
            }
            for hour in [0, 4] { lines[hour]!.forEach { print($0) } }
            func strip(_ l: String) -> String { l.components(separatedBy: " · days ").first ?? l }   // the day label differs by design
            let same = lines[0]!.dropFirst().map(strip).elementsEqual(lines[4]!.dropFirst().map(strip))
            print(same ? "SAME figures at 0 and 4" : "DIFFERENT figures at 0 and 4 (see the rows between midnight and 04:00)")
        }
    }
}
