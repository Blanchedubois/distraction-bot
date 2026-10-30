import Foundation

/// The study day (PLAN_STUDY_DAY §3.1, K0; IMPACT_ANALYSIS R7): a day starts at `startHour` (default 04:00), so a session
/// that ends at 00:40 belongs to the evening before, and a shutdown filed at 00:30 closes yesterday's study day.
/// A day's identity is its start instant (`day(for:)`), never a calendar midnight. `startHour` 0 reproduces
/// `Calendar.startOfDay` exactly (the K0 regression check). Pure Foundation, so `scripts/studyday-check.swift` can run it.
enum StudyDay {
    /// Set from `AppSettings.dayStartHour` at launch and on change (`Store`), 0…6.
    nonisolated(unsafe) static var startHour: Int = 4

    /// The most recent `startHour` at or before `d`.
    static func start(of d: Date, cal: Calendar = .current) -> Date {
        let h = max(0, min(23, startHour))
        let today = cal.date(bySettingHour: h, minute: 0, second: 0, of: d) ?? cal.startOfDay(for: d)
        if today <= d { return today }
        return cal.date(byAdding: .day, value: -1, to: today) ?? today
    }
    /// `start(of:)` plus one day (the next start, so a DST day is 23 or 25 hours long, as a calendar day is).
    static func end(of d: Date, cal: Calendar = .current) -> Date {
        let s = start(of: d, cal: cal)
        return cal.date(byAdding: .day, value: 1, to: s) ?? s.addingTimeInterval(86400)
    }
    /// The day's identity = its start instant.
    static func day(for d: Date, cal: Calendar = .current) -> Date { start(of: d, cal: cal) }
    /// The study day that begins on the calendar date of `date` (a date picker's or `DBOT_SNAPSHOT_DAY`'s value, which is a
    /// calendar day, not an instant): 28 Oct → 28 Oct 04:00. `start(of:)` would file 28 Oct 00:00 under the 27th.
    static func dayStarting(on date: Date, cal: Calendar = .current) -> Date {
        cal.date(bySettingHour: max(0, min(23, startHour)), minute: 0, second: 0, of: cal.startOfDay(for: date)) ?? cal.startOfDay(for: date)
    }

    static func isToday(_ d: Date, now: Date = Date(), cal: Calendar = .current) -> Bool { start(of: d, cal: cal) == start(of: now, cal: cal) }
    static func isYesterday(_ d: Date, now: Date = Date(), cal: Calendar = .current) -> Bool {
        guard let y = cal.date(byAdding: .day, value: -1, to: start(of: now, cal: cal)) else { return false }
        return start(of: d, cal: cal) == y
    }
    /// Whole study days between `d` and `now`: 0 today, 1 yesterday, … (negative for a future day).
    static func daysAgo(_ d: Date, now: Date = Date(), cal: Calendar = .current) -> Int {
        cal.dateComponents([.day], from: start(of: d, cal: cal), to: start(of: now, cal: cal)).day ?? 0
    }

    /// `Today` · `Yesterday` · `Tue 28 Oct`; `pastMidnight` appends ` (to N am)` when the day's rows run past midnight.
    static func label(_ day: Date, now: Date = Date(), pastMidnight: Bool = false, cal: Calendar = .current) -> String {
        let base = isToday(day, now: now, cal: cal) ? "Today" : isYesterday(day, now: now, cal: cal) ? "Yesterday"
            : start(of: day, cal: cal).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return pastMidnight && startHour > 0 ? "\(base) (to \(startHour) am)" : base
    }
    /// `Tuesday 28 October`, the History title's long form.
    static func longLabel(_ day: Date, now: Date = Date(), pastMidnight: Bool = false, cal: Calendar = .current) -> String {
        let base = isToday(day, now: now, cal: cal) ? "Today" : isYesterday(day, now: now, cal: cal) ? "Yesterday"
            : start(of: day, cal: cal).formatted(.dateTime.weekday(.wide).day().month(.wide))
        return pastMidnight && startHour > 0 ? "\(base) (to \(startHour) am)" : base
    }

    /// Study-day starts from the day holding `from` through the day holding `through`, ascending (for strides).
    static func days(from: Date, through: Date, cal: Calendar = .current) -> [Date] {
        var out: [Date] = []
        var d = start(of: from, cal: cal)
        let last = start(of: through, cal: cal)
        while d <= last {
            out.append(d)
            guard let n = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = n
        }
        return out
    }
    /// The study day `n` days after `day` (negative for before).
    static func shift(_ day: Date, by n: Int, cal: Calendar = .current) -> Date {
        cal.date(byAdding: .day, value: n, to: start(of: day, cal: cal)) ?? day
    }
    /// The Monday that starts the study week holding `d` (Monday first, whatever the locale), as a study-day start.
    static func weekStart(of d: Date, cal: Calendar = .current) -> Date {
        let day = start(of: d, cal: cal)
        let weekday = (cal.component(.weekday, from: day) + 5) % 7        // 0 = Monday … 6 = Sunday
        return cal.date(byAdding: .day, value: -weekday, to: day) ?? day
    }
}
