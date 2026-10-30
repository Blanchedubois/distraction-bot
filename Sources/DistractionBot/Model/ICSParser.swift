import Foundation

/// A small iCalendar reader (PLAN_WEEK_CALENDAR §3.6), Foundation only so `scripts/ics-check.swift` compiles it alone.
/// Reads VEVENT: UID, SUMMARY, LOCATION, DTSTART/DTEND (UTC `Z`, `TZID=` zoned, floating = local, `VALUE=DATE` = all-day),
/// DURATION when there is no DTEND, RRULE (FREQ daily/weekly/monthly/yearly · INTERVAL · COUNT · UNTIL · BYDAY for weekly ·
/// BYMONTHDAY for monthly), EXDATE, RECURRENCE-ID overrides, STATUS:CANCELLED. Anything else keeps the first instance only.
/// Expansion is per window (`instances(from:to:)`), never the whole series — Jeff's adapter carries the raw RRULE for the same reason.
struct ICSCalendar: Equatable {
    var name: String?
    var events: [ICSEvent] = []
    var timeZones: [String: String] = [:]       // TZID in the file → an identifier Foundation knows (W3: the VTIMEZONE's own id, or an alias)
}

struct ICSEvent: Equatable {
    struct Rule: Equatable {
        enum Freq: String { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
        var freq: Freq
        var interval = 1
        var count: Int?
        var until: Date?
        var byDay: [Int] = []           // weekly: Calendar weekday numbers (1 = Sunday)
        var byMonthDay: [Int] = []      // monthly
        var unsupported = false         // BYSETPOS, ordinal BYDAY, BYMONTH… → the first instance only
    }
    let uid: String
    let recurrenceId: Date?             // an override of one occurrence of the series with the same UID
    let title: String
    let location: String
    let start: Date
    let end: Date
    let allDay: Bool
    let timeZone: TimeZone              // the zone the series repeats in (DST-safe stepping)
    let rule: Rule?
    let exdates: [Date]
    let cancelled: Bool
}

/// One occurrence on the grid.
struct ICSInstance: Identifiable, Equatable {
    var id: String { key }
    let key: String                     // uid + the occurrence's start
    let uid: String
    let title: String
    let location: String
    let start: Date
    let end: Date
    let allDay: Bool
}

enum ICSParser {
    // MARK: Lines and properties

    struct Property { let name: String; let params: [String: String]; let value: String }

    /// Unfold (a line starting with a space or tab continues the previous) and split into properties.
    static func properties(_ text: String) -> [Property] {
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            if raw.hasPrefix(" ") || raw.hasPrefix("\t") { if !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() } }
            else if !raw.isEmpty { lines.append(raw) }
        }
        return lines.compactMap(property)
    }

    /// `NAME;PARAM=V;PARAM2="a:b":VALUE` — the first `:` outside quotes ends the name and params.
    static func property(_ line: String) -> Property? {
        var inQuotes = false
        var split: String.Index?
        for i in line.indices {
            let c = line[i]
            if c == "\"" { inQuotes.toggle() } else if c == ":", !inQuotes { split = i; break }
        }
        guard let split else { return nil }
        let head = String(line[..<split]), value = String(line[line.index(after: split)...])
        var parts = head.components(separatedBy: ";")
        let name = parts.removeFirst().uppercased()
        var params: [String: String] = [:]
        for p in parts {
            guard let eq = p.firstIndex(of: "=") else { continue }
            params[String(p[..<eq]).uppercased()] = String(p[p.index(after: eq)...]).replacingOccurrences(of: "\"", with: "")
        }
        return Property(name: name, params: params, value: value)
    }

    static func unescape(_ s: String) -> String {
        var out = ""; var it = s.makeIterator()
        while let c = it.next() {
            if c == "\\", let n = it.next() {
                switch n { case "n", "N": out.append("\n"); case ",": out.append(","); case ";": out.append(";"); case "\\": out.append("\\"); default: out.append(n) }
            } else { out.append(c) }
        }
        return out
    }

    // MARK: Time zones

    /// Windows and other names a feed may carry, to what Foundation knows. Unknown zones read as floating (local).
    static let aliases: [String: String] = [
        "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago", "Mountain Standard Time": "America/Denver",
        "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage", "Hawaiian Standard Time": "Pacific/Honolulu",
        "GMT Standard Time": "Europe/London", "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
        "Central Europe Standard Time": "Europe/Budapest", "Central European Standard Time": "Europe/Warsaw", "E. Europe Standard Time": "Europe/Bucharest",
        "FLE Standard Time": "Europe/Helsinki", "Russian Standard Time": "Europe/Moscow", "Turkey Standard Time": "Europe/Istanbul",
        "Israel Standard Time": "Asia/Jerusalem", "Arabian Standard Time": "Asia/Dubai", "India Standard Time": "Asia/Kolkata",
        "Singapore Standard Time": "Asia/Singapore", "China Standard Time": "Asia/Shanghai", "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul", "AUS Eastern Standard Time": "Australia/Sydney", "New Zealand Standard Time": "Pacific/Auckland",
        "UTC": "UTC", "GMT": "UTC",
    ]
    static func timeZone(_ tzid: String?, known: [String: String]) -> TimeZone? {
        guard let tzid else { return nil }
        if let id = known[tzid], let tz = TimeZone(identifier: id) { return tz }
        if let tz = TimeZone(identifier: tzid) { return tz }
        if let id = aliases[tzid], let tz = TimeZone(identifier: id) { return tz }
        // "(UTC-05:00) Eastern…" and "GMT+2" shapes
        if let r = tzid.range(of: #"[+-]\d{2}:?\d{2}"#, options: .regularExpression) {
            let s = tzid[r].replacingOccurrences(of: ":", with: ""), sign = s.hasPrefix("-") ? -1 : 1
            if let h = Int(s.dropFirst().prefix(2)), let m = Int(s.suffix(2)) { return TimeZone(secondsFromGMT: sign * (h * 3600 + m * 60)) }
        }
        return nil
    }

    // MARK: Dates

    /// `19970714T170000Z` · `19970714T170000` (floating or TZID) · `19970714` (DATE). Returns the instant and whether it was a date.
    static func date(_ value: String, params: [String: String], known: [String: String], local: TimeZone = .current) -> (Date, Bool)? {
        let v = value.trimmingCharacters(in: .whitespaces)
        let isDate = params["VALUE"] == "DATE" || v.count == 8
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = v.hasSuffix("Z") ? TimeZone(identifier: "UTC")! : (timeZone(params["TZID"], known: known) ?? local)
        guard v.count >= 8, let y = Int(v.prefix(4)), let mo = Int(v.dropFirst(4).prefix(2)), let d = Int(v.dropFirst(6).prefix(2)) else { return nil }
        var c = DateComponents(year: y, month: mo, day: d, hour: 0, minute: 0, second: 0)
        if !isDate, v.count >= 15, v[v.index(v.startIndex, offsetBy: 8)] == "T" {
            c.hour = Int(v.dropFirst(9).prefix(2)); c.minute = Int(v.dropFirst(11).prefix(2)); c.second = Int(v.dropFirst(13).prefix(2))
        }
        guard let date = cal.date(from: c) else { return nil }
        return (date, isDate)
    }

    /// `P1W` · `P2D` · `PT1H30M` · `-PT15M`.
    static func duration(_ s: String) -> TimeInterval? {
        var v = s; var sign: Double = 1
        if v.hasPrefix("-") { sign = -1; v.removeFirst() } else if v.hasPrefix("+") { v.removeFirst() }
        guard v.hasPrefix("P") else { return nil }
        v.removeFirst()
        var total: Double = 0, num = "", inTime = false
        for ch in v {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber { num.append(ch); continue }
            guard let n = Double(num) else { return nil }
            num = ""
            switch ch {
            case "W": total += n * 7 * 86400
            case "D": total += n * 86400
            case "H": total += n * 3600
            case "M": total += inTime ? n * 60 : 0
            case "S": total += n
            default: return nil
            }
        }
        return sign * total
    }

    // MARK: The calendar

    static func parse(_ text: String, local: TimeZone = .current) -> ICSCalendar {
        var cal = ICSCalendar()
        var stack: [String] = []
        var cur: [Property] = []
        var tzBlock: [Property] = []
        for p in properties(text) {
            switch p.name {
            case "BEGIN":
                stack.append(p.value.uppercased())
                if p.value.uppercased() == "VEVENT" { cur = [] }
                if p.value.uppercased() == "VTIMEZONE" { tzBlock = [] }
            case "END":
                let what = p.value.uppercased()
                if what == "VEVENT", let e = event(cur, known: cal.timeZones, local: local) { cal.events.append(e) }
                if what == "VTIMEZONE", let id = tzBlock.first(where: { $0.name == "TZID" })?.value {
                    // the block's own id if Foundation knows it, else the alias table, else X-LIC-LOCATION (Google writes "America/New_York")
                    let lic = tzBlock.first { $0.name == "X-LIC-LOCATION" }?.value
                    cal.timeZones[id] = TimeZone(identifier: id) != nil ? id : (aliases[id] ?? lic ?? id)
                }
                _ = stack.popLast()
            case "X-WR-CALNAME" where stack.last == "VCALENDAR": cal.name = unescape(p.value)
            default:
                if stack.last == "VEVENT" { cur.append(p) }
                else if stack.last == "VTIMEZONE" { tzBlock.append(p) }
            }
        }
        return cal
    }

    static func event(_ ps: [Property], known: [String: String], local: TimeZone) -> ICSEvent? {
        func first(_ n: String) -> Property? { ps.first { $0.name == n } }
        guard let uid = first("UID")?.value, !uid.isEmpty, let ds = first("DTSTART"), let (start, allDay) = date(ds.value, params: ds.params, known: known, local: local) else { return nil }
        let tz = ds.value.hasSuffix("Z") ? TimeZone(identifier: "UTC")! : (timeZone(ds.params["TZID"], known: known) ?? local)
        var end: Date
        if let de = first("DTEND"), let (e, _) = date(de.value, params: de.params, known: known, local: local) { end = e }
        else if let du = first("DURATION").flatMap({ duration($0.value) }) { end = start.addingTimeInterval(du) }
        else { end = start.addingTimeInterval(allDay ? 86400 : 30 * 60) }      // Jeff's `spanOf`: a timed event with no end is 30 min
        if end <= start { end = start.addingTimeInterval(allDay ? 86400 : 30 * 60) }
        var rule: ICSEvent.Rule? = nil
        if let rr = first("RRULE") { rule = parseRule(rr.value, known: known, local: local) }
        var exdates: [Date] = []
        for ex in ps where ex.name == "EXDATE" {
            for v in ex.value.components(separatedBy: ",") { if let (d, _) = date(v, params: ex.params, known: known, local: local) { exdates.append(d) } }
        }
        let rid = first("RECURRENCE-ID").flatMap { date($0.value, params: $0.params, known: known, local: local)?.0 }
        return ICSEvent(uid: uid, recurrenceId: rid, title: unescape(first("SUMMARY")?.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? "(untitled)" : unescape(first("SUMMARY")!.value),
                        location: unescape(first("LOCATION")?.value ?? ""), start: start, end: end, allDay: allDay, timeZone: tz, rule: rule, exdates: exdates,
                        cancelled: first("STATUS")?.value.uppercased() == "CANCELLED")
    }

    static func parseRule(_ s: String, known: [String: String], local: TimeZone) -> ICSEvent.Rule? {
        var parts: [String: String] = [:]
        for kv in s.components(separatedBy: ";") { let p = kv.components(separatedBy: "="); if p.count == 2 { parts[p[0].uppercased()] = p[1].uppercased() } }
        guard let f = parts["FREQ"], let freq = ICSEvent.Rule.Freq(rawValue: f) else { return nil }
        var r = ICSEvent.Rule(freq: freq)
        r.interval = max(1, Int(parts["INTERVAL"] ?? "1") ?? 1)
        r.count = parts["COUNT"].flatMap { Int($0) }
        if let u = parts["UNTIL"], let (d, isDate) = date(u, params: [:], known: known, local: local) { r.until = isDate ? d.addingTimeInterval(86400 - 1) : d }
        let days = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        if let bd = parts["BYDAY"] {
            for d in bd.components(separatedBy: ",") {
                if let n = days[d] { r.byDay.append(n) } else { r.unsupported = true }      // "2MO", "-1FR": ordinal days
            }
            if freq != .weekly { r.unsupported = true }
        }
        if let bm = parts["BYMONTHDAY"] {
            r.byMonthDay = bm.components(separatedBy: ",").compactMap { Int($0) }
            if freq != .monthly || r.byMonthDay.contains(where: { $0 < 1 }) { r.unsupported = true }
        }
        for k in ["BYSETPOS", "BYMONTH", "BYYEARDAY", "BYWEEKNO", "BYHOUR", "BYMINUTE"] where parts[k] != nil { r.unsupported = true }
        return r
    }

    // MARK: Expansion

    static let maxOccurrences = 5000

    /// Every occurrence overlapping `from..<to`, overrides applied, exclusions and cancellations removed, start order.
    static func instances(of cal: ICSCalendar, from: Date, to: Date) -> [ICSInstance] {
        var out: [ICSInstance] = []
        // overrides and cancellations of one occurrence, by series uid → the occurrence instants they replace
        var replaced: [String: Set<Int>] = [:]
        for e in cal.events { if let rid = e.recurrenceId { replaced[e.uid, default: []].insert(Int(rid.timeIntervalSince1970)) } }
        for e in cal.events {
            if e.cancelled { continue }
            if e.recurrenceId != nil {        // an override is a one-off at its own time
                if e.end > from, e.start < to { out.append(instance(e, start: e.start, end: e.end)) }
                continue
            }
            let skip = replaced[e.uid] ?? []
            let ex = Set(e.exdates.map { Int($0.timeIntervalSince1970) }).union(e.exdates.map { dayKey($0, tz: e.timeZone) })
            for s in occurrences(e, until: to) {
                let key = Int(s.timeIntervalSince1970)
                if skip.contains(key) || ex.contains(key) || (e.allDay && ex.contains(dayKey(s, tz: e.timeZone))) { continue }
                let end = s.addingTimeInterval(e.end.timeIntervalSince(e.start))
                if end > from, s < to { out.append(instance(e, start: s, end: end)) }
            }
        }
        return out.sorted { $0.start != $1.start ? $0.start < $1.start : $0.title < $1.title }
    }

    private static func instance(_ e: ICSEvent, start: Date, end: Date) -> ICSInstance {
        ICSInstance(key: e.uid + "@" + String(Int(start.timeIntervalSince1970)), uid: e.uid, title: e.title, location: e.location, start: start, end: end, allDay: e.allDay)
    }
    private static func dayKey(_ d: Date, tz: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return -((c.year ?? 0) * 10000 + (c.month ?? 0) * 100 + (c.day ?? 0))     // negative so it never collides with an epoch key
    }

    /// The series' starts up to `until` (exclusive), stepping in the event's own zone so a 9 am lecture stays 9 am across DST.
    static func occurrences(_ e: ICSEvent, until limit: Date) -> [Date] {
        guard let r = e.rule, !r.unsupported else { return [e.start] }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = e.timeZone
        var out: [Date] = []
        func emit(_ d: Date) -> Bool {       // false: stop
            if let u = r.until, d > u { return false }
            if d >= limit { return false }
            if let c = r.count, out.count >= c { return false }
            if d >= e.start { out.append(d) }
            return out.count < maxOccurrences
        }
        switch r.freq {
        case .daily:
            var d = e.start
            while emit(d) { d = cal.date(byAdding: .day, value: r.interval, to: d)! }
        case .weekly:
            let days = r.byDay.isEmpty ? [cal.component(.weekday, from: e.start)] : r.byDay.sorted()
            // the week of DTSTART, Monday-based like the grid; each step is `interval` weeks
            var weekStart = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: e.start))!
            let clock = cal.dateComponents([.hour, .minute, .second], from: e.start)
            var go = true
            while go {
                for wd in days {
                    let offset = (wd - cal.component(.weekday, from: weekStart) + 7) % 7
                    guard let day = cal.date(byAdding: .day, value: offset, to: weekStart),
                          let d = cal.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: clock.second ?? 0, of: day) else { continue }
                    if d < e.start { continue }
                    if !emit(d) { go = false; break }
                }
                weekStart = cal.date(byAdding: .weekOfYear, value: r.interval, to: weekStart)!
                if weekStart >= limit { go = false }
            }
        case .monthly:
            let days = r.byMonthDay.isEmpty ? [cal.component(.day, from: e.start)] : r.byMonthDay.sorted()
            var month = cal.date(from: cal.dateComponents([.year, .month], from: e.start))!
            let clock = cal.dateComponents([.hour, .minute, .second], from: e.start)
            var go = true
            while go {
                for md in days {
                    guard let day = cal.date(byAdding: .day, value: md - 1, to: month), cal.component(.month, from: day) == cal.component(.month, from: month),
                          let d = cal.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: clock.second ?? 0, of: day) else { continue }
                    if d < e.start { continue }
                    if !emit(d) { go = false; break }
                }
                month = cal.date(byAdding: .month, value: r.interval, to: month)!
                if month >= limit { go = false }
            }
        case .yearly:
            var d = e.start
            while emit(d) { d = cal.date(byAdding: .year, value: r.interval, to: d)! }
        }
        return out
    }
}
