import Foundation

// PLAN_PLANNING.md (P0–P2, R9 · R10): due dates, estimates, weekly targets and planned sessions from the calendar.
// The rules live in `Planning` over plain values so `scripts/planning-check.swift` runs them on a copied log, a scratch
// catalogue and the ICS fixtures without the app (compiled with `StudyDay.swift` and `ICSParser.swift`); the Store surface the
// views read is `Model/PlanningStore.swift`.

/// How near a deadline is (§3.1): nothing set · more than a week out · within seven days · today · past.
enum DueState: Equatable {
    case none
    case later(Int)        // days away, > 7
    case soon(Int)         // days away, 1…7
    case today
    case overdue(Int)      // days past, ≥ 1

    var isUrgent: Bool { switch self { case .soon, .today, .overdue: return true; default: return false } }
    var isOverdue: Bool { if case .overdue = self { return true }; return false }
    /// Days from now, negative when past; nil with no due date. The sort key of the "due soon" tier.
    var days: Int? {
        switch self {
        case .none: return nil
        case .later(let d), .soon(let d): return d
        case .today: return 0
        case .overdue(let d): return -d
        }
    }
    /// The chip's word: `due today` · `due Fri` · `due 14 Nov` · `overdue 2 d`.
    func label(due: Date?) -> String? {
        guard let due else { return nil }
        switch self {
        case .none: return nil
        case .today: return "due today"
        case .overdue(let d): return "overdue \(d) d"
        case .soon: return "due " + Planning.weekdayFormat.string(from: due)
        case .later: return "due " + Planning.dayFormat.string(from: due)
        }
    }
}

enum Planning {
    static let weekdayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()
    static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()

    /// A due date is a day (§5 Q1): stored at 23:59 local of that day, so "due today" holds until midnight.
    static func dueDate(forDay d: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 0, of: calendar.startOfDay(for: d)) ?? d
    }

    /// Whole days between the start of `now`'s day and the due day.
    static func dueState(due: Date?, now: Date, calendar: Calendar = .current) -> DueState {
        guard let due else { return .none }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
        if days == 0 { return .today }
        if days < 0 { return .overdue(-days) }
        return days <= 7 ? .soon(days) : .later(days)
    }

    /// The mean of the real sessions — at least 15 minutes, not a B-phase test — rounded to 5 minutes (§3.1, Q4.9); nil with none.
    /// 60 + 77 min → 68.5 → 70 (the proposal objective in the real log).
    static func averageMinutes(seconds: [Int]) -> Int? {
        let real = seconds.filter { $0 >= 900 }
        guard !real.isEmpty else { return nil }
        let mean = Double(real.reduce(0, +)) / Double(real.count) / 60
        return max(5, Int((mean / 5).rounded()) * 5)
    }
    static func isTestGoal(_ goal: String) -> Bool { goal.range(of: #"^B\d+\s"#, options: .regularExpression) != nil }
    /// The hidden objective id test sessions are filed under (§3.7): `sessions()` carries them with this id, so the inbox and every
    /// per-objective reader (figures, Jump back in, the week) leave them out; Progress's test rule hides them already.
    static let testsObjectiveId = "tests"

    /// The study week starts on Monday at the study day's start (K's `StudyDay`, 4 am by default; Progress's rings, §3.1).
    static func weekStart(_ now: Date, calendar: Calendar = .current) -> Date { StudyDay.weekStart(of: now, cal: calendar) }

    // MARK: The calendar matcher (§3.3, P2)

    /// A planned block, before it is dressed: which subject, which objective if any, and the event's span and title.
    struct Match: Equatable { let subjectId: String; let objectiveId: String?; let start: Date; let end: Date; let title: String }
    struct SubjectIn { let id: String; let code: String? }
    struct ObjectiveIn { let id: String; let subjectId: String; let title: String; let open: Bool }

    /// The codes an event may carry for a subject: `PHYS 352/351` also matches `PHYS 352` and `PHYS 351` (§3.3).
    static func codeVariants(_ code: String) -> [String] {
        let parts = code.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count > 1, let first = parts.first else { return [code] }
        let prefix = first.split(separator: " ").dropLast().joined(separator: " ")
        return [code, first] + parts.dropFirst().map { $0.contains(" ") || prefix.isEmpty ? $0 : prefix + " " + $0 }
    }
    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !$0.isEmpty }
    }
    /// An event whose title or location contains a subject's code (case-insensitive) is a planned block for that subject; one that
    /// shares two or more words with an open objective's title is for that objective (and so for its subject). All-day events
    /// are not blocks. Objectives win over a bare code match.
    static func match(title: String, location: String, allDay: Bool, start: Date, end: Date, subjects: [SubjectIn], objectives: [ObjectiveIn]) -> Match? {
        guard !allDay, end > start else { return nil }
        let text = (title + " " + location).lowercased()
        let eventWords = Set(words(text))
        var best: (ObjectiveIn, Int)? = nil
        for o in objectives where o.open {
            let tw = words(o.title)
            guard tw.count >= 2 else { continue }
            let hit = tw.filter { eventWords.contains($0) }.count
            if hit >= 2, hit > (best?.1 ?? 0) { best = (o, hit) }
        }
        if let (o, _) = best { return Match(subjectId: o.subjectId, objectiveId: o.id, start: start, end: end, title: title) }
        for s in subjects {
            guard let code = s.code else { continue }
            if codeVariants(code).contains(where: { text.contains($0.lowercased()) }) { return Match(subjectId: s.id, objectiveId: nil, start: start, end: end, title: title) }
        }
        return nil
    }
}

extension Planning {
    /// `4 h` · `1.5 h` · `45 min` — the estimate and weekly-target pickers' words (§5 Q2: hours in halves).
    static func hours(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : String(format: "%.1f h", Double(m) / 60)
    }
    /// `3 h 10` · `45 min` — the cards' short duration (the strip's recipe).
    static func short(_ seconds: Int) -> String {
        let m = seconds / 60
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : "\(max(1, m)) min"
    }
    /// The pickers' rows (§3.1): `none · 1 h · 2 h · 4 h · 8 h · 16 h` for an estimate, `none · 2 h · 4 h · 6 h · 8 h · 10 h` for a weekly target.
    static let estimateOptions = [60, 120, 240, 480, 960]
    static let targetOptions = [120, 240, 360, 480, 600]
}
