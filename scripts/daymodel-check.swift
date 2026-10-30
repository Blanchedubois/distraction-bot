// T0's check (PLAN_TODAY_TIMELINE.md §4): build the day model from the real log, read-only, and print it.
//   swiftc -o /tmp/daymodel-check Sources/DistractionBot/Model/StudyDay.swift Sources/DistractionBot/Model/DayModel.swift scripts/daymodel-check.swift
//   (PLAN_STUDY_DAY K1: the day is a study day — DBOT_DAY_START=<hour> sets its start, default 4; 0 = clock midnight, the pre-K1 figures)
//   /tmp/daymodel-check [YYYY-MM-DD] [path/to/log.sqlite] [target minutes, default 240]   (PLAN_TODAY_SCHEDULE D0 adds the stamps and the plan)
import Foundation
import SQLite3

struct Row: LogRow { let ts: Date; let kind: String; let app: String; let detail: String; let sessionId: String?; let objectiveId: String?; let sessionKind: String? }

@main struct Check {
    static func main() {
        let args = CommandLine.arguments
        let dayText = args.count > 1 ? args[1] : "2026-10-26"
        let path = args.count > 2 ? args[2] : NSHomeDirectory() + "/Library/Application Support/Distraction Bot/log.sqlite"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
        guard let date = df.date(from: dayText) else { print("bad date"); exit(2) }
        StudyDay.startHour = Int(ProcessInfo.processInfo.environment["DBOT_DAY_START"] ?? "4") ?? 4   // K1
        let day = StudyDay.dayStarting(on: date)
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { print("cannot open \(path)"); exit(2) }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT ts, kind, app, detail, session_id, objective_id, kind_tag FROM events ORDER BY ts", -1, &st, nil)
        var rows: [Row] = []
        func text(_ i: Int32) -> String? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(st, i)) }
        while sqlite3_step(st) == SQLITE_ROW {
            rows.append(Row(ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)), kind: String(cString: sqlite3_column_text(st, 1)),
                            app: String(cString: sqlite3_column_text(st, 2)), detail: String(cString: sqlite3_column_text(st, 3)),
                            sessionId: text(4), objectiveId: text(5), sessionKind: text(6)))
        }
        sqlite3_finalize(st); sqlite3_close(db)
        let targetMin = args.count > 3 ? Double(args[3]) ?? 240 : 240
        let m = DayModel.build(events: rows, live: nil, day: day, now: nil, threshold: 0.7, target: targetMin * 60)
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        func t(_ d: Date) -> String { tf.string(from: d) }
        func dur(_ s: TimeInterval) -> String { s >= 60 ? String(format: "%d min %02d s", Int(s) / 60, Int(s) % 60) : "\(Int(s)) s" }
        let bf = DateFormatter(); bf.dateFormat = "EEE d MMM HH:mm"
        let inDay = rows.filter { $0.ts >= day && $0.ts < StudyDay.end(of: day) }
        let pastMidnight = inDay.filter { !Calendar.current.isDate($0.ts, inSameDayAs: day) }.count
        print("DAY \(dayText) · study day \(bf.string(from: day)) → \(bf.string(from: StudyDay.end(of: day))) (start hour \(StudyDay.startHour)) · axis \(t(m.axisStart))–\(t(m.axisEnd)) · \(inDay.count) rows, \(pastMidnight) past midnight · label \(StudyDay.label(day, pastMidnight: pastMidnight > 0))")
        print("\nBLOCKS (\(m.blocks.count))")
        for b in m.blocks { print("  \(t(b.start))–\(t(b.end))  \(dur(b.duration).padding(toLength: 12, withPad: " ", startingAt: 0)) \(b.ended ? "ended" : "no end ") · \(b.length) · \(b.strictness) · \(b.goal.prefix(40))  [\(b.isTest ? "test" : "done") · \(b.detours) detours · obj \(b.objectiveId ?? "—") · \(b.kindTag ?? "—") · sid \((b.sessionId ?? "—").prefix(8))]" + (b.pauses.isEmpty ? "" : " · pauses \(b.pauses.map { "\(t($0.start))–\(t($0.end)) \($0.label)" })")) }
        print("\nPERIODS (\(m.periods.count))")
        for p in m.periods { print("  \(t(p.start))–\(t(p.end))  \(dur(p.duration).padding(toLength: 12, withPad: " ", startingAt: 0)) \(p.outcome.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(p.kind == .site ? "site" : "app ") \(p.front.padding(toLength: 8, withPad: " ", startingAt: 0)) \(p.title.prefix(44))  answers \(p.answers)  blocks inside \(p.blocks.count)") }
        print("\nTICKS (\(m.ticks.count))")
        var byWhat: [String: Int] = [:]; for k in m.ticks { byWhat[k.what + " " + k.kind, default: 0] += 1 }
        for (k, v) in byWhat.sorted(by: { $0.value > $1.value }) { print("  \(v) × \(k)") }
        let f = m.figures
        print("\nFIGURES  focused \(dur(f.focused)) in \(f.sessions) sessions · distracted \(dur(f.distracted)) in \(f.detours) detours · false alarms \(f.falseAlarms) · paused \(dur(f.paused)) · blocks \(f.blocks) · clean \(f.clean.map { String(format: "%.0f %%", $0 * 100) } ?? "—")")
        print("PLAN     done \(f.sessionsDone) · live \(f.sessionsLive) · target \(f.target.map { dur($0) } ?? "none") · progress \(f.progress.map { String(format: "%.2f", $0) } ?? "—")")
        if let w = m.workedWindow(now: m.now) { print("WORKED   \(t(w.lowerBound)) – \(t(w.upperBound))") }
        if let l = m.last { print("LAST     \(l.title.prefix(40)) · \(t(l.start))") }
    }
}
