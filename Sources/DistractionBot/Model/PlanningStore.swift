import Foundation

// PLAN_PLANNING.md (P0–P2): the Store surface over `Planning`'s rules — what the cards, the editors and Home read.

// MARK: - Store surface

extension Store {
    /// The real sessions of an objective (≥ 15 min, not tests) averaged and rounded to 5 minutes; nil with none (§3.1).
    func averageMinutes(of o: Objective) -> Int? {
        Planning.averageMinutes(seconds: EventLog.shared.sessions(objective: o.id).filter { !Planning.isTestGoal($0.goal) && $0.endedBy != "live" }.map(\.seconds))
    }
    /// Every minute logged on the objective, the live session counted to now — the effort bar's numerator.
    func spentMinutes(of o: Objective) -> Int {
        let logged = EventLog.shared.sessions(objective: o.id).reduce(0) { $0 + $1.seconds }
        return logged / 60
    }
    /// Focused minutes this study week under a subject (Progress's rule, the live one to now). PLAN_SUBJECT_PROGRESS S1: from the course's
    /// Stats records (tests out, minus away), so the Levels rows, Home's course tile, the subject card and the course page agree.
    func weekMinutes(of s: Catalog.Subject, week: Date = Date()) -> Int {
        let from = Planning.weekStart(week)
        return sessionRecords(in: s).filter { StudyDay.start(of: $0.start) >= from }.reduce(0) { $0 + $1.focusedSeconds } / 60
    }
    func dueState(_ o: Objective, now: Date = Date()) -> DueState { Planning.dueState(due: o.due, now: now) }
    /// The length a start uses (Q4.9): the remembered one; with none (or 0) the average real length; else the Settings default. 0/“until I stop” → nil.
    func startMinutes(for o: Objective) -> Int? { o.startMinutes(settings, average: averageMinutes(of: o)) }
    /// The nearest due open objective under a subject (nil = every subject), within `days` (default: any).
    func nextDue(in subject: String? = nil, now: Date = Date(), within days: Int? = nil) -> Objective? {
        catalog.objectives.filter { o in
            !o.isDone && o.due != nil && (subject == nil || o.subjectId == subject) && (days.map { d in (dueState(o, now: now).days ?? .max) <= d } ?? true)
        }.min { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }
    /// PLAN_PLANNING §3.3 (P2, R10): the feed's instances on the study day holding `day` that match a subject's code or an open
    /// objective's title, as planned blocks, by start. Nothing without a feed.
    func plannedBlocks(day: Date) -> [DayModel.Planned] {
        let from = StudyDay.start(of: day), to = StudyDay.end(of: day)
        let subjects = catalog.subjects.map { Planning.SubjectIn(id: $0.id, code: $0.code) }
        let objectives = catalog.objectives.map { Planning.ObjectiveIn(id: $0.id, subjectId: $0.subjectId, title: $0.title, open: !$0.isDone) }
        return feed.instances(from: from, to: to).compactMap { i in
            Planning.match(title: i.title, location: i.location, allDay: i.allDay, start: i.start, end: i.end, subjects: subjects, objectives: objectives)
                .map { DayModel.Planned(subjectId: $0.subjectId, objectiveId: $0.objectiveId, start: $0.start, end: $0.end, title: $0.title) }
        }.sorted { $0.start < $1.start }
    }
    /// PLAN_PLANNING §3.7 (P4, Q5.3): file the inbox's test groups — a goal matching `^B<n> `, or every session under two minutes —
    /// under the hidden objective id `tests` (`Planning.testsObjectiveId`), so they leave the inbox for good. Returns the session ids filed,
    /// for the toast's undo (`fileSession(_, under: nil)` puts each back).
    @discardableResult
    func dismissTests(_ groups: [UnsortedGroup]) -> [String] {
        let ids = groups.filter { g in Planning.isTestGoal(g.goal) || g.sessions.allSatisfy { $0.seconds < 120 } }.flatMap { $0.sessions.map(\.id) }
        guard !ids.isEmpty else { show("nothing here looks like a test"); return [] }
        for id in ids { EventLog.shared.fileSession(id, under: Planning.testsObjectiveId) }
        reloadLog()
        show("\(ids.count) test session\(ids.count == 1 ? "" : "s") dismissed", undo: { [weak self] in
            for id in ids { EventLog.shared.fileSession(id, under: nil) }
            self?.reloadLog(); self?.show("\(ids.count) back in the inbox")
        })
        return ids
    }
    /// `~4 h` · `2 h 10 of ~4 h`: the estimate and what is spent against it, for the card's figures line; nil without an estimate.
    func effortLabel(of o: Objective) -> String? {
        guard let e = o.estimateMinutes else { return nil }
        let spent = spentMinutes(of: o)
        return spent > 0 ? "\(Planning.short(spent * 60)) of ~\(Planning.hours(e))" : "~\(Planning.hours(e))"
    }
    /// `spent ÷ estimate`, clamped; nil without an estimate.
    func effort(of o: Objective) -> Double? {
        guard let e = o.estimateMinutes, e > 0 else { return nil }
        return min(1, Double(spentMinutes(of: o)) / Double(e))
    }
}
