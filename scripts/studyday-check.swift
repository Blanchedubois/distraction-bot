// K0's check (PLAN_STUDY_DAY.md §4): StudyDay.start/end/label for 20 instants around midnight and 04:00, with startHour 4 and 0.
//   swiftc -o /tmp/studyday-check Sources/DistractionBot/Model/StudyDay.swift scripts/studyday-check.swift
//   /tmp/studyday-check
// Judged: 23:59 → the same day's start; 00:01 and 03:59 → the previous day's start; 04:00 → the new day;
// with startHour 0 every answer equals Calendar.startOfDay (printed as REGRESSION ok/FAIL).
import Foundation

@main struct Check {
    static func main() {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"; f.timeZone = .current
        let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"; day.timeZone = .current
        // 2026-10-28 is the day the plan was written; the instants straddle its midnight and its 04:00
        let base = day.date(from: "2026-10-28")!
        let instants: [(String, Date)] = [
            ("27th 18:59", base.addingTimeInterval(-5 * 3600 - 60)), ("27th 21:27", base.addingTimeInterval(-2 * 3600 - 33 * 60)),
            ("27th 23:57", base.addingTimeInterval(-3 * 60)), ("27th 23:59", base.addingTimeInterval(-60)), ("27th 23:59:59", base.addingTimeInterval(-1)),
            ("28th 00:00", base), ("28th 00:01", base.addingTimeInterval(60)), ("28th 00:30", base.addingTimeInterval(1800)),
            ("28th 00:40", base.addingTimeInterval(2400)), ("28th 01:00", base.addingTimeInterval(3600)), ("28th 02:00", base.addingTimeInterval(7200)),
            ("28th 03:00", base.addingTimeInterval(3 * 3600)), ("28th 03:59", base.addingTimeInterval(4 * 3600 - 60)), ("28th 03:59:59", base.addingTimeInterval(4 * 3600 - 1)),
            ("28th 04:00", base.addingTimeInterval(4 * 3600)), ("28th 04:01", base.addingTimeInterval(4 * 3600 + 60)), ("28th 07:00", base.addingTimeInterval(7 * 3600)),
            ("28th 12:00", base.addingTimeInterval(12 * 3600)), ("28th 21:27", base.addingTimeInterval(21 * 3600 + 27 * 60)), ("28th 23:30", base.addingTimeInterval(23 * 3600 + 30 * 60)),
        ]
        let now = base.addingTimeInterval(23 * 3600 + 30 * 60)      // "now" for the labels: 28th 23:30
        var failures = 0
        for hour in [4, 0] {
            StudyDay.startHour = hour
            print("== startHour \(hour) · now \(f.string(from: now)) ==")
            print("instant            start               end                 day     today  yest   label")
            for (name, t) in instants {
                let s = StudyDay.start(of: t), e = StudyDay.end(of: t)
                let label = StudyDay.label(t, now: now)
                print("\(name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(f.string(from: s).padding(toLength: 19, withPad: " ", startingAt: 0)) \(f.string(from: e).padding(toLength: 19, withPad: " ", startingAt: 0)) \(day.string(from: StudyDay.day(for: t)).suffix(5))   \(StudyDay.isToday(t, now: now) ? "yes " : "no  ")   \(StudyDay.isYesterday(t, now: now) ? "yes " : "no  ")   \(label)")
                if hour == 0 {
                    let want = cal.startOfDay(for: t)
                    if s != want { failures += 1; print("  REGRESSION FAIL: start \(f.string(from: s)) != startOfDay \(f.string(from: want))") }
                    if cal.isDateInToday(t) != StudyDay.isToday(t) { failures += 1; print("  REGRESSION FAIL: isToday differs at \(name)") }
                    if e != cal.date(byAdding: .day, value: 1, to: want)! { failures += 1; print("  REGRESSION FAIL: end differs at \(name)") }
                }
            }
            if hour == 4 {
                let d28 = cal.date(bySettingHour: 4, minute: 0, second: 0, of: base)!, d27 = cal.date(byAdding: .day, value: -1, to: d28)!
                func check(_ what: String, _ ok: Bool) { print("  \(ok ? "ok  " : "FAIL") \(what)"); if !ok { failures += 1 } }
                check("27th 23:59 → 27th 04:00", StudyDay.start(of: base.addingTimeInterval(-60)) == d27)
                check("28th 00:01 → 27th 04:00", StudyDay.start(of: base.addingTimeInterval(60)) == d27)
                check("28th 03:59 → 27th 04:00", StudyDay.start(of: base.addingTimeInterval(4 * 3600 - 60)) == d27)
                check("28th 04:00 → 28th 04:00", StudyDay.start(of: base.addingTimeInterval(4 * 3600)) == d28)
                check("end(27th 23:59) = 28th 04:00", StudyDay.end(of: base.addingTimeInterval(-60)) == d28)
                check("days(27th 23:00 … 28th 00:30) = [27th]", StudyDay.days(from: base.addingTimeInterval(-3600), through: base.addingTimeInterval(1800)) == [d27])
                check("days(27th 12:00 … 28th 12:00) = [27th, 28th]", StudyDay.days(from: base.addingTimeInterval(-12 * 3600), through: base.addingTimeInterval(12 * 3600)) == [d27, d28])
                check("label(27th, pastMidnight) = 'Yesterday (to 4 am)'", StudyDay.label(d27, now: now, pastMidnight: true) == "Yesterday (to 4 am)")
                check("daysAgo(27th 23:00) = 1 · daysAgo(28th 01:00) = 1 · daysAgo(28th 05:00) = 0",
                      StudyDay.daysAgo(base.addingTimeInterval(-3600), now: now) == 1 && StudyDay.daysAgo(base.addingTimeInterval(3600), now: now) == 1 && StudyDay.daysAgo(base.addingTimeInterval(5 * 3600), now: now) == 0)
                check("weekStart(28th Wed) = Mon 26th 04:00", StudyDay.weekStart(of: now) == cal.date(byAdding: .day, value: -2, to: d28)!)
            }
        }
        print(failures == 0 ? "REGRESSION ok (startHour 0 == startOfDay on every instant)" : "FAILURES \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
