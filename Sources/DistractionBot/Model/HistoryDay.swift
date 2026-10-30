import Foundation

/// One day as the History tab reads it (PLAN_HISTORY_TAB §3.5): the strip's model and figures, the day's sessions, the
/// Progress tab's score for the day, the previous day's figures for the delta, and the day's rows. Today's model and
/// score are the Store's own (`today`, `statsToday`) so Home and History agree to the point; a past day is built once
/// from the log and is frozen (`now: nil` — no now rule, no live fill).
struct HistoryDay {
    let day: Date                           // the study day's start (K1, PLAN_STUDY_DAY §3.2)
    let model: DayModel                     // the strip and the figures
    let sessions: [ObjectiveSession]        // the day's sessions, newest first (the span rule inside EventLog.sessions)
    let stats: Stats                        // the day's Score, SessionRecords, hiddenTests
    let previous: DayModel.Figures?         // the day before, for the delta (nil before the first logged day)
    let events: [Event]                     // the day's rows, newest first
    var isToday: Bool { StudyDay.isToday(day) }   // K1
    /// K1: rows after clock midnight belong to this study day — the titles say "(to 4 am)" then.
    var pastMidnight: Bool { events.contains { !Calendar.current.isDate($0.ts, inSameDayAs: day) } }
    var isEmpty: Bool { events.isEmpty }

    static func dayEnd(_ day: Date) -> Date { StudyDay.end(of: day) }   // K1

    @MainActor static func load(_ date: Date, store: Store) -> HistoryDay {
        let cal = Calendar.current
        let day = StudyDay.start(of: date)   // K1: a study-day start maps to itself; an instant to its day
        let end = dayEnd(day)
        let today = StudyDay.isToday(day)
        let rows = EventLog.shared.events(from: day, to: end)
        let target = TimeInterval(store.settings.targetMinutes(on: day) * 60)
        let model = today ? store.today
            : DayModel.build(events: rows, live: nil, day: day, now: nil, threshold: store.judge.threshold, target: target)
        let sessions = EventLog.shared.sessions(since: day).filter { $0.started < end }
        let stats: Stats = {
            if today, let s = store.statsToday { return s }
            let period = Period(kind: .today, from: day, to: end - 1)
            let (plan, shutdown) = store.planClosures(from: day, to: end)   // Z1 (PLAN_SCORING §3.2)
            return Stats.compute(events: EventLog.shared.events(from: day - 6 * 3600, to: end), period: period, live: nil, now: end - 1,
                                 targetMinutes: { [settings = store.settings] in settings.targetMinutes(on: $0) }, showTests: !store.settings.hideTestSessions,
                                 subjectOf: { oid in store.subject(store.objective(oid)?.subjectId)?.shortName }, plan: plan, shutdown: shutdown)
        }()
        let before = cal.date(byAdding: .day, value: -1, to: day)!
        let beforeRows = EventLog.shared.events(from: before, to: day)
        let previous: DayModel.Figures? = beforeRows.isEmpty ? nil
            : DayModel.build(events: beforeRows, live: nil, day: before, now: nil, threshold: store.judge.threshold,
                             target: TimeInterval(store.settings.targetMinutes(on: before) * 60)).figures
        return HistoryDay(day: day, model: model, sessions: sessions, stats: stats, previous: previous, events: rows.reversed())
    }

    /// `Today` · `Yesterday` · `Tuesday 27 October` (§3.3, §5a Q10); the year is the caller's to mute when not this one.
    var title: String {
        StudyDay.longLabel(day, pastMidnight: pastMidnight)   // K1: Today · Yesterday · Tuesday 28 October (to 4 am)
    }
    var yearSuffix: String? { Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year) ? nil : day.formatted(.dateTime.year()) }
    /// `Mon 27 Oct` for the Panel title and the toolbar's day menu label.
    var shortTitle: String { StudyDay.label(day) }   // K1
}
