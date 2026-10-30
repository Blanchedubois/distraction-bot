// W3's check (PLAN_WEEK_CALENDAR.md §4): parse the three fixtures and print the instances in one week, with expectations.
//   swiftc -o /tmp/ics-check Sources/DistractionBot/Model/ICSParser.swift Sources/DistractionBot/Model/FeedBackoff.swift scripts/ics-check.swift
//   /tmp/ics-check [YYYY-MM-DD in the week] [fixtures dir]
// Expectations are stated for the week of 26 Oct – 1 Nov 2026 with the local zone America/New_York; other zones shift the clock
// times of the zoned events but not the counts.
import Foundation

@main struct Check {
    static func main() {
        // R1 (PLAN_REWORK §4): the backoff rule — 429 · 429 · 200: the second try waits ≥ 15 min, the third ≥ 30; Retry-After 120 is honoured; a success resets
        do {
            let now = Date()
            let w1 = FeedBackoff.wait(failures: 1, intervalMinutes: 30, retryAfter: nil, now: now)
            let w2 = FeedBackoff.wait(failures: 2, intervalMinutes: 30, retryAfter: nil, now: now)
            let w9 = FeedBackoff.wait(failures: 9, intervalMinutes: 30, retryAfter: nil, now: now)
            let wShort = FeedBackoff.wait(failures: 1, intervalMinutes: 1, retryAfter: nil, now: now)
            let wAsked = FeedBackoff.wait(failures: 1, intervalMinutes: 1, retryAfter: "7200", now: now)
            let wDate = FeedBackoff.retryAfterSeconds("Wed, 29 Oct 2026 05:00:00 GMT", now: ISO8601DateFormatter().date(from: "2026-10-29T04:58:00Z")!) ?? -1
            let ok = w1 == 1800 && w2 == 3600 && w9 == 7200 && wShort == 900 && wAsked == 7200 && wDate == 120 && FeedBackoff.retryAfterSeconds("soon", now: now) == nil
            print("backoff: 1st \(Int(w1 / 60)) min · 2nd \(Int(w2 / 60)) · 9th \(Int(w9 / 60)) (cap) · interval 1 → \(Int(wShort / 60)) (floor) · Retry-After 7200 → \(Int(wAsked / 60)) · a date → \(Int(wDate)) s · garbage → nil ·", ok ? "OK" : "FAIL")
        }
        let args = CommandLine.arguments
        let dayText = args.count > 1 ? args[1] : "2026-10-27"
        let dir = args.count > 2 ? args[2] : "docs/fixtures"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
        guard let day = df.date(from: dayText) else { print("bad date"); exit(2) }
        var cal = Calendar.current; cal.firstWeekday = 2
        let d0 = cal.startOfDay(for: day)
        let back = (cal.component(.weekday, from: d0) - 2 + 7) % 7
        let from = cal.date(byAdding: .day, value: -back, to: d0)!, to = cal.date(byAdding: .day, value: 7, to: from)!
        let tf = DateFormatter(); tf.dateFormat = "EEE d HH:mm"
        var failures = 0
        func expect(_ ok: Bool, _ what: String) { print("  \(ok ? "ok  " : "FAIL") \(what)"); if !ok { failures += 1 } }

        for name in ["google", "outlook", "minimal"] {
            guard let text = try? String(contentsOfFile: "\(dir)/\(name).ics", encoding: .utf8) else { print("missing \(name).ics"); exit(2) }
            let c = ICSParser.parse(text)
            let ins = ICSParser.instances(of: c, from: from, to: to)
            print("\n== \(name).ics · \(c.name ?? "(no name)") · \(c.events.count) events · zones \(c.timeZones) · \(ins.count) instances \(tf.string(from: from))–\(tf.string(from: to))")
            for i in ins { print("  \(tf.string(from: i.start))–\(tf.string(from: i.end))\(i.allDay ? " all day" : "")  \(i.title)\(i.location.isEmpty ? "" : " @ " + i.location)") }
            let titles = ins.map(\.title)
            switch name {
            case "google":
                expect(titles.filter { $0 == "BIO 210 lecture" }.count == 1, "lecture MO/WE/FR: Mon kept, Wed EXDATEd, Fri replaced by the override → 1 plain instance")
                expect(titles.contains("BIO 210 lecture (moved)"), "the RECURRENCE-ID override appears at its own time")
                expect(ins.first { $0.title == "BIO 210 lecture (moved)" }.map { Calendar.current.component(.hour, from: $0.start) } == 14 || TimeZone.current.identifier != "America/New_York", "the override is at 2 pm local (if local is New York)")
                expect(ins.contains { $0.allDay && $0.title == "Reading day" }, "VALUE=DATE is all-day")
                expect(ins.contains { $0.title == "Study group (floating)" && Calendar.current.component(.hour, from: $0.start) == 19 }, "a floating event keeps its wall-clock time locally")
                expect(!titles.contains("Office hours (cancelled)"), "STATUS:CANCELLED is dropped")
                expect(ins.contains { $0.title == "Weekly review; notes & plan" }, "SUMMARY unescaped (\\; → ;)")
                expect(c.timeZones["America/New_York"] == "America/New_York", "VTIMEZONE registered")
            case "outlook":
                expect(c.timeZones["Eastern Standard Time"] == "America/New_York", "Windows TZID aliased")
                expect(ins.contains { $0.title == "Teams: project sync" && $0.end.timeIntervalSince($0.start) == 5400 }, "DURATION PT1H30M")
                expect(!titles.contains("Second Monday (unsupported ordinal)"), "an unsupported rule keeps its first instance only (12 Oct, outside the week)")
                expect(c.events.first { $0.uid.hasPrefix("second-monday") }?.rule?.unsupported == true, "…and is marked unsupported")
            case "minimal":
                expect(titles.filter { $0 == "Daily standup ×3" }.count == 3, "COUNT=3 daily → 3")
                expect(titles.filter { $0 == "Fortnightly, until Nov 10" }.count == 1, "INTERVAL=2 weekly from 13 Oct → 27 Oct in this week (UNTIL honoured later)")
                expect(titles.filter { $0 == "Monthly on the 1st and 15th" }.count == 1, "BYMONTHDAY=1,15 → the 1st (Sunday) in this week")
                expect(ins.contains { $0.title == "No DTEND (30 min)" && $0.end.timeIntervalSince($0.start) == 1800 }, "no DTEND → 30 min")
                expect(ins.contains { $0.title == "Offset-only TZID" }, "(UTC+02:00) TZID parsed as an offset")
                expect(!titles.contains("A VTODO is skipped") && !titles.contains("No UID is skipped"), "VTODO and UID-less rows skipped")
            default: break
            }
        }
        // the next fortnight for the UNTIL rule: 10 Nov is the last; 24 Nov must not appear
        if let text = try? String(contentsOfFile: "\(dir)/minimal.ics", encoding: .utf8) {
            let c = ICSParser.parse(text)
            let later = ICSParser.instances(of: c, from: to, to: Calendar.current.date(byAdding: .day, value: 35, to: to)!)
            let f = later.filter { $0.title.hasPrefix("Fortnightly") }
            print("\n== minimal.ics, the five weeks after: fortnightly on \(f.map { tf.string(from: $0.start) })")
            expect(f.count == 1, "UNTIL=20261110 → one more (10 Nov), none on 24 Nov")
        }
        print("\n\(failures == 0 ? "ALL OK" : "\(failures) FAILED")")
        exit(failures == 0 ? 0 : 1)
    }
}
