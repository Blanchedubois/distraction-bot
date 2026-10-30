import Foundation

/// A course's progress for its page (PLAN_SUBJECT_PROGRESS §3.2, S0): the level and what earned XP this study week, the course's own
/// streak and week row, its week score, its latest sessions. Pure — `SessionRecord`s and completion dates in, figures out — so
/// `scripts/scoring-check.swift` judges the code the page runs. The Store surface is `Store.courseProgress(_:)` (`Model/XPStore.swift`).
struct CourseProgress: Equatable {
    var xp = 0
    var level = 0
    var into = 0.0
    var toNext: Int? = nil
    // this study week (Monday first): the XP and its parts — clean minutes × the dial, +30 per finished session, +60 per completed objective
    var weekXP = 0
    var weekClean = 0
    var weekFinished = 0
    var weekCompleted = 0
    var weekTasks = 0          // HUD4: paid task ticks this week (+10 each)
    var weekStrictness: String? = nil      // the one strictness the week's sessions shared; nil when they mixed or there were none
    var weekSeconds = 0                    // focused (the Stats rule: minus away), the live session to now
    // the course's streak (§5a Q2): distinct study days with a session on it, no freezes
    var streak = 0
    var best = 0
    var cells: [WeekCell] = Array(repeating: .future, count: 7)
    var todayIndex = 0
    // the course's week score (§5a Q1): its sessions' own scores this week, weighted by focused time
    var score: Score? = nil
    var scoredSessions = 0
    var weekLosses: [Tally.Loss] = []   // PLAN_GAME_FEEL F2: what the week score lost, weighted as the score is
    var sessions = 0                       // the course's real sessions, all time
    var recent: [SessionRecord] = []       // newest first
    // S4 — the trends row: the last 8 study weeks, the hours of the day, the pace
    var weeks: [Int] = Array(repeating: 0, count: 8)     // focused seconds per study week, oldest first, this week last
    var hours: [Int] = Array(repeating: 0, count: 24)    // focused seconds per clock hour, all time
    var averageClean = 0                   // clean minutes per real session, all time
    var longestClean = 0                   // the longest session's clean minutes
    var finished = 0                       // sessions run to their planned end, all time
    var daysToNext: Int? = nil             // the next level at this week's XP per elapsed day; nil without XP this week or at L5
    // PLAN_GAME_FEEL F4 (§3.4): the two moments a study day can carry
    var leveledToday = false               // today's sessions (or a completion today) carried the course across a band
    var bestToday = false                  // today's longest clean session beats every earlier one on the course (never the course's first)
    /// The busiest run of three clock hours, as its first hour (`21` → 21:00–00:00); nil with no time.
    var peakHour: Int? {
        guard hours.contains(where: { $0 > 0 }) else { return nil }
        func run(_ h: Int) -> Int { hours[h % 24] + hours[(h + 1) % 24] + hours[(h + 2) % 24] }   // split out for CI's compiler (PLAN_PUBLIC_RELEASE P5)
        return (0..<24).max { run($0) < run($1) }
    }

    var todayDone: Bool { cells.indices.contains(todayIndex) && cells[todayIndex] == .session }
    /// The XP the week's minutes earned (the week's XP less the two bonuses).
    var weekMinuteXP: Int { weekXP - 30 * weekFinished - 60 * weekCompleted - SessionTasks.xpEach * weekTasks }   // HUD4: tasks are their own part

    /// `sessions`: the course's real sessions (tests already out, the live one in) as `Store.sessionRecords(in:)` gives them;
    /// `completedAt`: when each of its completed objectives was completed.
    static func build(sessions: [SessionRecord], completedAt: [Date], now: Date = Date(), recentCount: Int = 6, cal: Calendar = .current) -> CourseProgress {
        var f = CourseProgress()
        let real = sessions.filter { !$0.isTest }
        f.sessions = real.count
        f.xp = XP.course(real, completedObjectives: completedAt.count)
        (f.level, f.into) = XP.level(f.xp)
        f.toNext = XP.toNext(f.xp)

        let monday = StudyDay.weekStart(of: now, cal: cal)
        let week = real.filter { StudyDay.start(of: $0.start, cal: cal) >= monday }
        f.weekFinished = week.filter(\.finished).count
        f.weekCompleted = completedAt.filter { $0 >= monday }.count
        f.weekTasks = week.reduce(0) { $0 + $1.tasksPaid }   // HUD4
        f.weekXP = week.reduce(0) { $0 + XP.earned($1) } + 60 * f.weekCompleted
        f.weekClean = week.reduce(0) { $0 + XP.clean(seconds: $1.focusedSeconds, pausedSeconds: 0, detourSeconds: $1.detourSeconds, awaySeconds: 0) }
        let dials = Set(week.map(\.strictness))
        f.weekStrictness = dials.count == 1 ? dials.first : nil
        f.weekSeconds = week.reduce(0) { $0 + $1.focusedSeconds }

        let days = Set(real.map { StudyDay.start(of: $0.start, cal: cal) })
        let today = StudyDay.start(of: now, cal: cal)
        f.todayIndex = (cal.component(.weekday, from: today) + 5) % 7
        f.cells = (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: monday)!
            return days.contains(d) ? .session : i >= f.todayIndex ? .future : .missed
        }
        var run = 0, prev: Date?
        for d in days.sorted() {
            if let p = prev, cal.date(byAdding: .day, value: 1, to: p) == d { run += 1 } else { run = 1 }
            f.best = max(f.best, run); prev = d
        }
        if let last = days.max(), last == today || last == cal.date(byAdding: .day, value: -1, to: today) { f.streak = run }

        if !week.isEmpty {
            let weight = week.reduce(0) { $0 + max(1, $1.focusedSeconds) }
            func mean(_ part: (Score) -> Int) -> Int {
                Int((Double(week.reduce(0) { $0 + part($1.score) * max(1, $1.focusedSeconds) }) / Double(weight)).rounded())
            }
            f.score = Score(time: mean(\.time), calm: mean(\.calm), follow: mean(\.follow), blocks: mean(\.blocks), kind: .session)
            f.scoredSessions = week.count
            f.weekLosses = Tally.weighted(week, score: f.score!)
        }
        f.recent = Array(real.sorted { $0.start > $1.start }.prefix(recentCount))

        // S4: the trends — 8 weeks of focused time, the hours of the day, the averages and the pace to the next level
        for r in real {
            let wk = StudyDay.weekStart(of: r.start, cal: cal)
            if let n = cal.dateComponents([.day], from: wk, to: monday).day.map({ Int((Double($0) / 7).rounded()) }), (0..<8).contains(n) { f.weeks[7 - n] += r.focusedSeconds }
            var t = r.start, left = r.focusedSeconds
            while left > 0 {
                let h = cal.component(.hour, from: t)
                let toHour = Int(cal.dateInterval(of: .hour, for: t).map { $0.end.timeIntervalSince(t) } ?? 3600)
                let take = max(1, min(left, toHour))
                f.hours[h] += take; left -= take; t = t.addingTimeInterval(TimeInterval(take))
            }
        }
        let cleans = real.map { XP.clean(seconds: $0.focusedSeconds, pausedSeconds: 0, detourSeconds: $0.detourSeconds, awaySeconds: 0) }
        f.averageClean = cleans.isEmpty ? 0 : Int((Double(cleans.reduce(0, +)) / Double(cleans.count)).rounded())
        f.longestClean = cleans.max() ?? 0
        f.finished = real.filter(\.finished).count
        if let n = f.toNext, f.weekXP > 0 { f.daysToNext = Int((Double(n) / (Double(f.weekXP) / Double(f.todayIndex + 1))).rounded(.up)) }
        // F4: the level crossed today, and today's personal best
        let todays = real.filter { StudyDay.start(of: $0.start, cal: cal) == today }, earlier = real.filter { StudyDay.start(of: $0.start, cal: cal) < today }
        let xpBefore = f.xp - todays.reduce(0) { $0 + XP.earned($1) } - 60 * completedAt.filter { StudyDay.start(of: $0, cal: cal) == today }.count
        f.leveledToday = XP.level(xpBefore).level < f.level
        f.bestToday = todays.contains { isBest($0, after: earlier) }
        return f
    }
    /// A session's clean minutes, as XP pays them.
    static func clean(_ r: SessionRecord) -> Int { XP.clean(seconds: r.focusedSeconds, pausedSeconds: 0, detourSeconds: r.detourSeconds, awaySeconds: 0) }
    /// F4 (§5a Q8): the course's longest clean session yet — strictly longer than every earlier one, and never the course's first.
    static func isBest(_ r: SessionRecord, after earlier: [SessionRecord]) -> Bool {
        guard let top = earlier.filter({ !$0.isTest }).map(clean).max() else { return false }
        return clean(r) > top
    }
}
