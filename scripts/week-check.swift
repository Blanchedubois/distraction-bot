// W0's check (PLAN_WEEK_CALENDAR.md §4): build the week model from a copy of the log and the catalogue, read-only, and print it.
//   swiftc -o /tmp/week-check Sources/DistractionBot/Design/WeekGeometry.swift Sources/DistractionBot/Model/WeekModel.swift Sources/DistractionBot/Model/ICSParser.swift scripts/shims/TintShim.swift scripts/week-check.swift
//   /tmp/week-check [YYYY-MM-DD in the week] [path/to/log.sqlite] [path/to/subjects.json] [--tests] [--ics=path.ics]   (W4: a fixture feed laid under the sessions)
// Then three hand-built overlap cases against Jeff's packDay.
import Foundation
import SQLite3

struct Ev { let ts: Date; let kind: String; let detail: String; let sessionId: String?; let objectiveId: String? }
struct Subj: Decodable { let id: String; let name: String; let icon: String; let accent: String }
struct Obj: Decodable { let id: String; let subjectId: String; let title: String; let icon: String }
struct Cat: Decodable { let subjects: [Subj]; let objectives: [Obj] }

@main struct Check {
    static func main() {
        let args = CommandLine.arguments.filter { !$0.hasPrefix("--") }
        let showTests = CommandLine.arguments.contains("--tests")
        let icsPath = CommandLine.arguments.first { $0.hasPrefix("--ics=") }.map { String($0.dropFirst(6)) }
        let dayText = args.count > 1 ? args[1] : "2026-10-27"
        let path = args.count > 2 ? args[2] : NSHomeDirectory() + "/Library/Application Support/Distraction Bot/log.sqlite"
        let catPath = args.count > 3 ? args[3] : NSHomeDirectory() + "/Library/Application Support/Distraction Bot/subjects.json"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
        guard let day = df.date(from: dayText) else { print("bad date"); exit(2) }

        // the catalogue, read only
        var who: [String: WeekModel.Who] = [:]
        if let d = try? Data(contentsOf: URL(fileURLWithPath: catPath)), let c = try? JSONDecoder().decode(Cat.self, from: d) {
            for o in c.objectives {
                guard let s = c.subjects.first(where: { $0.id == o.subjectId }) else { continue }
                let code = s.name.contains(" - ") ? s.name.components(separatedBy: " - ")[0] : s.name.contains(": ") ? s.name.components(separatedBy: ": ")[0] : s.name
                who[o.id] = .init(title: o.title, icon: o.icon, code: code, tint: s.accent)
            }
        }

        // the log, read only; sessions grouped by session_id as EventLog.sessions does
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { print("cannot open \(path)"); exit(2) }
        var st: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT ts, kind, detail, session_id, objective_id FROM events WHERE session_id IS NOT NULL ORDER BY ts", -1, &st, nil)
        var evs: [Ev] = []
        func text(_ i: Int32) -> String? { sqlite3_column_type(st, i) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(st, i)) }
        while sqlite3_step(st) == SQLITE_ROW {
            evs.append(Ev(ts: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)), kind: text(1) ?? "", detail: text(2) ?? "", sessionId: text(3), objectiveId: text(4)))
        }
        sqlite3_finalize(st); sqlite3_close(db)
        var order: [String] = []; var by: [String: [Ev]] = [:]
        for e in evs { if by[e.sessionId!] == nil { order.append(e.sessionId!) }; by[e.sessionId!, default: []].append(e) }
        var rows: [WeekModel.Row] = []
        for id in order {
            let es = by[id]!
            guard let s = es.first(where: { $0.kind == "session.start" }) else { continue }
            let end = es.last { $0.kind == "session.end" }
            let parts = s.detail.components(separatedBy: " · ")
            let seconds = end.flatMap { Int($0.detail) } ?? Int((es.last?.ts ?? s.ts).timeIntervalSince(s.ts))
            let warnings = es.filter { $0.kind == "web.warn" || $0.kind == "block.warn" || ($0.kind == "judge.verdict" && $0.detail.hasPrefix("distracted")) }.count
            let blocks = es.filter { ["block.close", "block.shield", "web.block", "judge.close"].contains($0.kind) || ($0.kind == "judge.followup" && $0.detail.contains("blocked")) }.count
            let summary = es.last { $0.kind == "session.summary" }?.detail
            let paused = summary.flatMap { $0.components(separatedBy: " · ").first { $0.hasPrefix("paused ") } }.flatMap { Int($0.dropFirst(7)) }
            rows.append(.init(id: id, objectiveId: s.objectiveId, goal: parts.first ?? s.detail, started: s.ts, ended: end?.ts, seconds: seconds,
                              strictness: parts.count > 2 ? parts[2] : "", warnings: warnings, blocks: blocks, live: false,
                              pauses: es.filter { $0.kind == "session.pause" }.map(\.ts), pausedSeconds: paused))
        }

        let week = WeekModel.start(of: day)
        var feed = WeekModel.Feed()
        if let icsPath, let text = try? String(contentsOfFile: icsPath, encoding: .utf8) {
            let c = ICSParser.parse(text)
            feed = WeekModel.Feed(instances: ICSParser.instances(of: c, from: week, to: Calendar.current.date(byAdding: .day, value: 7, to: week)!), name: c.name, tint: "#8aa0d6", show: true)
        }
        let m = WeekModel.build(sessions: rows, feed: feed, week: week, now: Date(), who: { $0.flatMap { who[$0] } }, showTests: showTests)
        let tf = DateFormatter(); tf.dateFormat = "EEE HH:mm:ss"
        print("WEEK \(m.title) \(m.year) · \(rows.count) sessions in the log · tests \(showTests ? "shown" : "hidden") · holds today \(m.holdsToday)")
        print("landing \(WeekGeometry.landing(dayStarts: m.dayStarts, holdsToday: m.holdsToday, now: Date())) pt")
        for (i, day) in m.days.enumerated() where !m.allDay[i].isEmpty { print("  rail \(tf.string(from: day).prefix(3)): " + m.allDay[i].map(\.title).joined(separator: " · ")) }
        for (i, day) in m.days.enumerated() where !m.blocks[i].isEmpty {
            let packed = WeekGeometry.pack(m.blocks[i].map(\.span))
            print("\n\(tf.string(from: day).prefix(3)) \(m.blocks[i].count) blocks")
            for b in m.blocks[i] {
                let p = packed.first { $0.id == b.id }!
                let pl = WeekGeometry.placement(start: p.start, end: p.end)
                let x = WeekGeometry.frameX(p, colW: 128)
                print(String(format: "  %@  top %6.1f  h %5.1f  col %d/%d  x %5.1f w %5.1f  %@  [%@] %@ · %@ · %@%@",
                             tf.string(from: b.start) as NSString, pl.top, pl.height, p.col, p.cols, x.x, x.width,
                             "\(WeekGeometry.ladder(for: pl.height))".padding(toLength: 5, withPad: " ", startingAt: 0) as NSString,
                             b.tint as NSString, b.title.prefix(34).description as NSString, b.meta as NSString, b.kindWord as NSString,
                             (b.third.map { " · " + $0 } ?? "") as NSString) + (b.pauses.isEmpty ? "" : "  pauses \(b.pauses.count)") + (b.live ? "  LIVE" : ""))
            }
        }

        // Jeff's packDay on three hand-built overlaps (R9 §5)
        print("\nPACK CHECKS")
        func spans(_ s: [(String, Int, Int)]) -> [WeekGeometry.Span] { s.map { .init(id: $0.0, start: $0.1, end: $0.2, title: $0.0) } }
        func show(_ name: String, _ s: [(String, Int, Int)], expect: [String: (Int, Int)]) {
            let out = WeekGeometry.pack(spans(s))
            let ok = expect.allSatisfy { k, v in out.first { $0.id == k }.map { $0.col == v.0 && $0.cols == v.1 } ?? false }
            print("  \(ok ? "ok  " : "FAIL") \(name): " + out.map { "\($0.id) \($0.col)/\($0.cols)" }.joined(separator: "  "))
        }
        show("two overlapping", [("a", 540, 600), ("b", 570, 630)], expect: ["a": (0, 2), "b": (1, 2)])
        show("chain of three, then one apart", [("a", 540, 600), ("b", 570, 630), ("c", 600, 660), ("d", 700, 760)], expect: ["a": (0, 2), "b": (1, 2), "c": (0, 2), "d": (0, 1)])
        show("three at once, longest first", [("short", 540, 560), ("long", 540, 660), ("mid", 540, 600)], expect: ["long": (0, 3), "mid": (1, 3), "short": (2, 3)])
        show("zero span is 30 min", [("z", 540, 540), ("b", 560, 600)], expect: ["z": (0, 2), "b": (1, 2)])
        print("  columns at 896: \(WeekGeometry.columns(available: 896))  at 600: \(WeekGeometry.columns(available: 600))  at 300: \(WeekGeometry.columns(available: 300))")
        print("  placement 9:00–9:50: \(WeekGeometry.placement(start: 540, end: 590))  6 s: \(WeekGeometry.placement(start: 540, end: 540))")
        print("  time: \(WeekGeometry.time(Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: day)!)) · range: \(WeekGeometry.range(Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day)!, Calendar.current.date(bySettingHour: 10, minute: 50, second: 0, of: day)!)) · \(WeekGeometry.range(Calendar.current.date(bySettingHour: 11, minute: 30, second: 0, of: day)!, Calendar.current.date(bySettingHour: 13, minute: 0, second: 0, of: day)!))")
    }
}
