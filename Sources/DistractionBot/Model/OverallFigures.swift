import Foundation

/// The four all-time figures on Home's Overall widget (PLAN_HOME_LAYOUT §3.2, H1), plus this week's focus per day.
/// Pure: built from the whole log in `Store.reloadLog()`. Sessions come from `Stats.sessionSpans` so Home and Progress
/// use one span rule, and test sessions (`SessionRecord.isTest`) are left out as Progress leaves them out.
/// One day of the current study week on the week row (PLAN_GAME_LOOP §3.3, G2).
enum WeekCell: Equatable {
    case session, frozen, missed, future
    var word: String { switch self { case .session: return "a session"; case .frozen: return "frozen"; case .missed: return "missed"; case .future: return "to come" } }
}

struct OverallFigures: Equatable {
    var focusedSeconds = 0            // finished sessions, all time (the live session is added at display time)
    var sessions = 0
    var sessionsThisWeek = 0
    var streak = 0                    // days in a row with a session, ending today or yesterday
    var bestStreak = 0
    var frozen = 0                    // Z3 (PLAN_SCORING §3.4): days inside the current streak bridged by a streak freeze
    var blocked = 0                   // block.close · block.shield · web.block
    var warnings = 0                  // block.warn · web.warn · distracted judge.verdict
    var week: [Int] = Array(repeating: 0, count: 7)   // focused seconds per day, Monday first
    var todayIndex = 0                // which of `week` is today
    var weekCells: [WeekCell] = Array(repeating: .future, count: 7)   // G2 (PLAN_GAME_LOOP §3.3): the week row — session · frozen · missed · to come
    var hasData: Bool { sessions > 0 || blocked > 0 || warnings > 0 }

    static func build(events: [Event], live: Session?, now: Date = Date()) -> OverallFigures {
        var f = OverallFigures()
        let cal = Calendar.current
        let records = Stats.sessionSpans(events: events, live: live, now: now).filter { !$0.isTest }
        let finished = records.filter { !$0.live }
        f.sessions = finished.count
        f.focusedSeconds = finished.reduce(0) { $0 + $1.focusedSeconds }

        // This week, Monday first, whatever the locale's first weekday.
        let today = StudyDay.start(of: now)                                  // K1 (PLAN_STUDY_DAY §3.2): the study day
        let weekday = (cal.component(.weekday, from: today) + 5) % 7        // 0 = Monday … 6 = Sunday
        f.todayIndex = weekday
        let monday = StudyDay.weekStart(of: now)
        for r in records {
            let d = StudyDay.start(of: r.start)
            if d >= monday, let i = cal.dateComponents([.day], from: monday, to: d).day, i >= 0, i < 7 {
                f.week[i] += r.live ? Int(now.timeIntervalSince(r.start)) : r.focusedSeconds
                if !r.live { f.sessionsThisWeek += 1 }
            }
        }

        // Streaks over the distinct days with a session (live counts for today). Z3: a day a `streak.freeze · used · <day>` row covers
        // joins the run as a frozen day (it never counts as a session day anywhere else).
        let sessionDays = Set(records.map { StudyDay.start(of: $0.start) })
        let frozenDays = Set(events.filter { $0.kind == "streak.freeze" && $0.detail.hasPrefix("used · ") }
            .compactMap { ISO8601DateFormatter.ymd.date(from: String($0.detail.dropFirst(7))) }.map { StudyDay.dayStarting(on: $0) }).subtracting(sessionDays)
        let days = sessionDays.union(frozenDays).sorted()   // K1
        // G2: the week row — today without a session is still "to come", not a miss
        f.weekCells = (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: monday)!
            if sessionDays.contains(d) { return .session }
            if frozenDays.contains(d) { return .frozen }
            return i >= weekday ? .future : .missed
        }
        var run = 0, best = 0, prev: Date?, frozenInRun = 0
        for d in days {
            if let p = prev, let n = cal.date(byAdding: .day, value: 1, to: p), n == d { run += 1 } else { run = 1; frozenInRun = 0 }   // K1: study-day starts compare exactly
            if frozenDays.contains(d) { frozenInRun += 1 }
            best = max(best, run); prev = d
        }
        f.bestStreak = best
        if let last = days.last, let yesterday = cal.date(byAdding: .day, value: -1, to: today),
           last == today || last == yesterday { f.streak = run; f.frozen = frozenInRun }

        for e in events {
            switch e.kind {
            case "block.close", "block.shield", "web.block": f.blocked += 1
            case "block.warn", "web.warn": f.warnings += 1
            case "judge.verdict" where e.detail.hasPrefix("distracted"): f.warnings += 1
            default: break
            }
        }
        return f
    }
}
