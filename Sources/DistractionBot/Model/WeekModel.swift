import Foundation

/// The Calendar tab's model (PLAN_WEEK_CALENDAR §3.3): one week of blocks, pure, Foundation only — the check script
/// compiles this file alone. The Store adapts `ObjectiveSession` rows and the catalogue into `Row`s and `Who`s; the
/// grid resolves `tint` (a family name or `#rrggbb`) through `Theme.accent`. ICS instances join in W4 as a second
/// `Block.Source`.
struct WeekModel: Equatable {
    /// A session as the log tells it (`ObjectiveSession`, flattened).
    struct Row: Equatable {
        let id: String
        let objectiveId: String?
        let goal: String
        let started: Date
        let ended: Date?          // nil: still running (live) or quit mid-session
        let seconds: Int          // ObjectiveSession.seconds: the span rule already applied
        let strictness: String
        let warnings: Int
        let blocks: Int
        let live: Bool
        let pauses: [Date]        // session.pause rows (10 min each)
        let pausedSeconds: Int?   // from session.summary, when S5 wrote one
    }
    /// What the catalogue says about a session's objective: nil when it has none, or the id is an orphan (§3.4).
    struct Who: Equatable { let title: String; let icon: String; let code: String; let tint: String; var subjectId: String? = nil }   // code: the subject's code, else its short name

    struct Block: Identifiable, Equatable {
        enum Source: Equatable { case session(String), feed(String) }      // the session id · the ICS instance key (W4)
        let id: String             // the row id, "-2" suffixed on the part after midnight
        let source: Source
        let start: Date
        let end: Date
        let allDay: Bool
        let title: String
        let meta: String           // "9–9:50am · 48 min" (· live)
        let third: String?         // "2 caught · 1 blocked" / "paused 10 min"
        let kindWord: String       // the subject code, "no subject", or the feed's name
        let symbol: String         // the objective's icon, "target", or "calendar"
        let tint: String           // a family name or "#rrggbb"; "muted" = Theme.muted2
        let subjectId: String?     // the kind word opens the subject's page (§3.7)
        let live: Bool
        let pauses: [ClosedRange<Date>]
        var startMinute: Int { WeekGeometry.minute(of: start) }
        var endMinute: Int { Calendar.current.isDate(end, inSameDayAs: start) ? WeekGeometry.minute(of: end) : 24 * 60 }
        var span: WeekGeometry.Span { .init(id: id, start: startMinute, end: endMinute, title: title) }
    }

    let weekStart: Date
    let days: [Date]                     // seven, Monday first (§5a Q2)
    let blocks: [[Block]]                // per day, in start order; the grid packs them with WeekGeometry.pack
    let allDay: [[Block]]                // per day, the rail (empty until W4)
    var isEmpty: Bool { blocks.allSatisfy(\.isEmpty) && allDay.allSatisfy(\.isEmpty) }
    var holdsToday: Bool { days.contains { Calendar.current.isDateInToday($0) } }
    /// The earliest block start per day in minutes, for the landing scroll.
    var dayStarts: [Int] { blocks.flatMap { $0 }.map(\.startMinute) }

    static let pauseSeconds: TimeInterval = 10 * 60

    /// Monday 00:00 of the week holding `date`, in the current calendar.
    static func start(of date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar; cal.firstWeekday = 2
        let d = cal.startOfDay(for: date)
        let back = (cal.component(.weekday, from: d) - cal.firstWeekday + 7) % 7
        return cal.date(byAdding: .day, value: -back, to: d)!
    }

    static func empty(week: Date) -> WeekModel {
        let cal = Calendar.current
        let days = (0..<7).map { cal.date(byAdding: .day, value: $0, to: week)! }
        return WeekModel(weekStart: week, days: days, blocks: Array(repeating: [], count: 7), allDay: Array(repeating: [], count: 7))
    }

    /// The Progress tab's test rule (Stats.SessionRecord.isTest): a "B<n> " goal, or under two minutes and not live.
    static func isTest(_ r: Row) -> Bool { r.goal.range(of: #"^B\d+\s"#, options: .regularExpression) != nil || (!r.live && r.seconds < 120) }

    /// Your calendar's occurrences (W4, §3.5): timed ones are blocks in the second register, all-day ones go on the rail.
    struct Feed: Equatable { var instances: [ICSInstance] = []; var name: String? = nil; var tint: String = "#8aa0d6"; var show = true }

    static func build(sessions: [Row], feed: Feed = Feed(), week: Date, now: Date, who: (String?) -> Who?, showTests: Bool) -> WeekModel {
        let cal = Calendar.current
        var m = empty(week: week)
        let weekEnd = cal.date(byAdding: .day, value: 7, to: week)!
        var blocks = m.blocks
        var allDay = m.allDay
        func dayIndex(_ d: Date) -> Int? { let i = cal.dateComponents([.day], from: week, to: cal.startOfDay(for: d)).day ?? -1; return (0..<7).contains(i) ? i : nil }
        if feed.show {
            let kind = (feed.name?.isEmpty == false ? feed.name! : "calendar")
            for i in feed.instances where i.end > week && i.start < weekEnd {
                if i.allDay {
                    // one capsule per day the event covers (a DATE end is exclusive)
                    var d = max(cal.startOfDay(for: i.start), week)
                    while d < min(i.end, weekEnd) {
                        if let di = dayIndex(d) {
                            allDay[di].append(Block(id: i.key + "@" + String(di), source: .feed(i.key), start: d, end: cal.date(byAdding: .day, value: 1, to: d)!, allDay: true,
                                                    title: i.title, meta: "all day", third: i.location.isEmpty ? nil : i.location, kindWord: kind, symbol: "calendar",
                                                    tint: feed.tint, subjectId: nil, live: false, pauses: []))
                        }
                        d = cal.date(byAdding: .day, value: 1, to: d)!
                    }
                    continue
                }
                var s = max(i.start, week); var n = 1
                while s < min(i.end, weekEnd) {
                    let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: s))!
                    let e = min(i.end, midnight)
                    if let di = dayIndex(s) {
                        blocks[di].append(Block(id: n == 1 ? i.key : i.key + "-\(n)", source: .feed(i.key), start: s, end: e, allDay: false,
                                                title: i.title, meta: WeekGeometry.range(s, e), third: i.location.isEmpty ? nil : i.location, kindWord: kind, symbol: "calendar",
                                                tint: feed.tint, subjectId: nil, live: false, pauses: []))
                    }
                    s = e; n += 1
                }
            }
        }
        for r in sessions where showTests || !isTest(r) {
            let end = r.ended ?? (r.live ? now : r.started.addingTimeInterval(TimeInterval(r.seconds)))
            guard end > week, r.started < weekEnd else { continue }
            let w = who(r.objectiveId)
            let caught = r.warnings, blocked = r.blocks
            // the third line: the length, then what was caught or how long it paused (Jeff's `.loc` slot)
            var figures: [String] = []
            if let p = r.pausedSeconds, p > 0 { figures.append("paused \(p / 60) min") }
            else if caught + blocked > 0 { figures.append("\(caught) caught" + (blocked > 0 ? " · \(blocked) blocked" : "")) }
            // a pause stamped after the session's computed end (a session cut off without its end row) is dropped — `start...end` would trap
            let pauses: [ClosedRange<Date>] = r.pauses.filter { $0 <= end }.map { $0...min(end, $0.addingTimeInterval(pauseSeconds)) }
            // a session crossing midnight is split at midnight: one id, "-2" on the second part (§3.3)
            var parts: [(Date, Date, String)] = []
            var s = max(r.started, week)
            var n = 1
            while s < min(end, weekEnd) {
                let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: s))!
                let e = min(end, midnight)
                parts.append((s, e, n == 1 ? r.id : r.id + "-\(n)")); s = e; n += 1
            }
            for (ps, pe, pid) in parts {
                let length = Int(end.timeIntervalSince(r.started))
                let meta = WeekGeometry.range(ps, pe) + (r.live ? " · live" : "")
                let third: String? = ([Self.minutesText(length)] + figures).joined(separator: " · ")
                let b = Block(id: pid, source: .session(r.id), start: ps, end: pe, allDay: false,
                              title: w?.title ?? String(r.goal.prefix(60)), meta: meta, third: third,
                              kindWord: w?.code ?? "no subject", symbol: w?.icon ?? "target",
                              tint: w?.tint ?? "muted", subjectId: w?.subjectId, live: r.live && pe == end, pauses: pauses.filter { $0.lowerBound < pe && $0.upperBound > ps })
                let di = cal.dateComponents([.day], from: week, to: cal.startOfDay(for: ps)).day ?? 0
                if (0..<7).contains(di) { blocks[di].append(b) }
            }
        }
        for i in 0..<7 { blocks[i].sort { $0.start < $1.start }; allDay[i].sort { $0.title < $1.title } }
        m = WeekModel(weekStart: week, days: m.days, blocks: blocks, allDay: allDay)
        return m
    }

    static func minutesText(_ seconds: Int) -> String {
        let m = seconds / 60
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60)") : (m > 0 ? "\(m) min" : "\(seconds) s")
    }

    /// The bar's title: "27 Oct – 2 Nov" or "27 Oct – 2 Nov 2026" across a year; the year in muted-2 is the grid's.
    var title: String {
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return f.string(from: days[0]) + " – " + f.string(from: days[6])
    }
    var year: String {
        let f = DateFormatter(); f.dateFormat = "yyyy"
        let a = f.string(from: days[0]), b = f.string(from: days[6])
        return a == b ? a : a + "/" + b.suffix(2)
    }
}
