import Foundation

/// The order rule of Home's "Jump back in" row (PLAN_JUMP_BACK_IN §3.4), over plain values so `scripts/jumpbackin-check.swift`
/// can run it on a copied log without the app: the live session's objective first; **then the objectives due within seven days
/// (or overdue), nearest first (PLAN_PLANNING §3.2, P1)**; then every objective with a session, by the start of its last one,
/// newest first; then the never-started ones in catalogue order. Archived objectives and sessions whose objective is no longer
/// in the catalogue are ignored. "This week" is `Calendar.dateInterval(of: .weekOfYear)`, Progress's rule.
enum JumpBackInOrder {
    struct ObjectiveIn: Equatable {
        let id: String; let subjectId: String; let sort: Int; let archived: Bool
        var due: Date? = nil            // P1: the deadline; nil = none
    }
    static let dueWindowDays = 7
    struct SessionIn: Equatable { let objectiveId: String?; let started: Date; let seconds: Int }
    struct Figures: Equatable {
        let objectiveId: String
        let lastStarted: Date?          // nil: never started
        let sessions: Int
        let weekSeconds: Int            // sessions started this week, the live one counted to now by the caller
        var started: Bool { sessions > 0 }
    }

    static func weekStart(_ now: Date, calendar: Calendar = .current) -> Date {
        StudyDay.weekStart(of: now, cal: calendar)   // K1 (PLAN_STUDY_DAY §3.2): Monday's study-day start
    }

    /// `subjectOrder`: subject ids in the catalogue's order; `objectives` in any order (their `sort` orders them within a subject).
    static func rows(objectives: [ObjectiveIn], subjectOrder: [String], sessions: [SessionIn], live: String?, now: Date, calendar: Calendar = .current) -> [Figures] {
        let week = weekStart(now, calendar: calendar)
        var last: [String: Date] = [:], count: [String: Int] = [:], weekSecs: [String: Int] = [:]
        for s in sessions {
            guard let oid = s.objectiveId else { continue }
            count[oid, default: 0] += 1
            if last[oid].map({ s.started > $0 }) ?? true { last[oid] = s.started }
            if s.started >= week { weekSecs[oid, default: 0] += s.seconds }
        }
        let subjectRank = Dictionary(uniqueKeysWithValues: subjectOrder.enumerated().map { ($1, $0) })
        let figures = objectives.filter { !$0.archived }.map { o in
            (o, Figures(objectiveId: o.id, lastStarted: last[o.id], sessions: count[o.id] ?? 0, weekSeconds: weekSecs[o.id] ?? 0))
        }
        func catalogueOrder(_ a: ObjectiveIn, _ b: ObjectiveIn) -> Bool {
            let ra = subjectRank[a.subjectId] ?? .max, rb = subjectRank[b.subjectId] ?? .max
            return ra != rb ? ra < rb : a.sort != b.sort ? a.sort < b.sort : a.id < b.id
        }
        // P1: the due tier — a deadline within the window (or past) outranks recency; nearer first, ties by the catalogue
        let today = calendar.startOfDay(for: now)
        func dueDays(_ o: ObjectiveIn) -> Int? {
            guard let d = o.due else { return nil }
            let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: d)).day ?? 0
            return days <= dueWindowDays ? days : nil
        }
        return figures.sorted { a, b in
            if a.0.id == live { return true }
            if b.0.id == live { return false }
            switch (dueDays(a.0), dueDays(b.0)) {
            case let (x?, y?): if x != y { return x < y }; return catalogueOrder(a.0, b.0)
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): break
            }
            switch (a.1.lastStarted, b.1.lastStarted) {
            case let (x?, y?): return x != y ? x > y : catalogueOrder(a.0, b.0)
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return catalogueOrder(a.0, b.0)
            }
        }.map(\.1)
    }
}
