import Foundation

// K2–K3 (PLAN_STUDY_DAY §3.3–3.5): how the Store and the log read and write `Shutdown` records; the record itself is Model/Shutdown.swift.

/// What E's session-end card shows (PLAN_STUDY_DAY §3.5, IMPACT_ANALYSIS §8.4 R13): set by `Store.endSession` before its toast.
struct SessionSummary: Equatable {
    var sessionId: String
    var title: String                  // the objective's title, else the goal
    var objectiveId: String?
    var started: Date
    var ended: Date
    var seconds: Int
    var plannedMinutes: Int?
    var caught: Int                    // the session's distractions, the Stats rule
    var blocked: Int
    var clean: Double?                 // 0…1, nil when no detour data
    var score: Score
    var reason: String                 // finished · ended · ended by phrase
    var offerShutdown: Bool            // the card's `shut down the day` button
    // Z's figure for this End (PLAN_SCORING), from `Store.lastSessionXP`
    var xp: Int? = nil
}

extension EventLog {
    /// Every shutdown filed between two instants, oldest first (K2).
    func shutdowns(from: Date, to: Date) -> [Shutdown] { events(kind: Shutdown.kind, from: from, to: to).compactMap { Shutdown.parse($0.detail) } }
    /// The latest shutdown that closes the study day holding `day` (latest wins, §5a Q1); nil when the day was not shut down.
    func shutdown(for day: Date) -> Shutdown? {
        let d = StudyDay.start(of: day)
        // rows are filed within the day or in the hours after it; a wide window keeps a late filing (next noon) in reach
        return events(kind: Shutdown.kind, from: d, to: StudyDay.end(of: d).addingTimeInterval(36 * 3600)).compactMap { Shutdown.parse($0.detail) }
            .filter { StudyDay.start(of: $0.day) == d }.last
    }
}

extension Store {
    /// Tomorrow's plan as the shutdown left it (K2): the `tomorrow` items of the shutdown that closed the study day before `day`.
    /// Z reads this for the day score's yardstick; Home's greeting quotes it. Empty with no shutdown (§5 Q3: no carry-forward).
    func plan(for day: Date) -> [Shutdown.PlannedItem] { EventLog.shared.shutdown(for: StudyDay.shift(day, by: -1))?.tomorrow ?? [] }
    /// The shutdown filed for the study day holding `day`, if any.
    func shutdown(for day: Date) -> Shutdown? { EventLog.shared.shutdown(for: day) }

    /// Open the shutdown screen for a study day (today by default): the Session menu, the mini panel's drawer (E), Home's pill, History's `shut it down now ↗`.
    func openShutdown(day: Date = Date()) {
        guard session == nil else { fail("End the session first"); return }
        openShutdown = StudyDay.start(of: day)
        EventLog.shared.ui("open", "shutdown")
    }

    /// File the record (K2 §3.4 ¶5): the row, the queue pre-filled with tomorrow's first item, the screen closed, the closing card, the toast.
    /// `quiet`: no card (the `--shutdown-check`).
    func fileShutdown(_ s: Shutdown, quiet: Bool = false) {
        guard session == nil else { fail("End the session first"); return }
        var record = s; record.day = StudyDay.start(of: s.day)
        // G4 (PLAN_GAME_LOOP §3.6): where the day stood before the filing — the score, the freezes, the main course's XP
        let dayIsToday = StudyDay.isToday(record.day)
        let statsBefore = dayIsToday ? statsToday : HistoryDay.load(record.day, store: self).stats
        let scoreBefore: Int? = (statsBefore?.focusedSeconds ?? 0) > 0 ? statsBefore?.score.total : nil
        let freezesBefore = freezes
        EventLog.shared.add(Shutdown.kind, detail: record.json)
        Log.write("shutdown filed for \(record.day.formatted(date: .abbreviated, time: .shortened)) · rating \(record.rating.map(String.init) ?? "-") · \(record.tomorrow.count) planned")
        // tomorrow's first item becomes the queue (§5a Q4.5); a cleared queue stays cleared only until the next filing
        if let first = record.tomorrow.first {
            if let oid = first.objectiveId, let o = objective(oid) { prepareSession(objective: o, minutes: first.minutes ?? 0, source: "shutdown") }
            else { prepareSession(goal: first.goal, minutes: first.minutes, strictness: settings.defaultStrictness, source: "shutdown") }
        }
        openShutdown = nil
        reloadLog()
        recomputeShutdownOffer()
        if !quiet { ClosingCard.shared.show(summary: closingSummary(for: record, scoreBefore: scoreBefore, freezesBefore: freezesBefore)) }
        show("day shut down")
    }

    /// G4: the closing card's figures after the filing and the reload — the streak and its row, the landed score, the day's main course moved
    /// from the day's start (its XP without the day's sessions) to now.
    func closingSummary(for record: Shutdown, scoreBefore: Int?, freezesBefore: Int) -> ClosingSummary {
        let dayIsToday = StudyDay.isToday(record.day)
        let bundle = dayIsToday ? nil : HistoryDay.load(record.day, store: self)
        let stats = dayIsToday ? statsToday : bundle?.stats
        let f = (dayIsToday ? today : bundle?.model)?.figures
        let daySessions = (stats?.sessions ?? []).filter { !$0.isTest }
        let bySubject = Dictionary(grouping: daySessions.compactMap { s in objective(s.objectiveId).map { ($0.subjectId, s) } }) { $0.0 }
        let course: CourseMove? = bySubject.max { $0.value.reduce(0) { $0 + $1.1.focusedSeconds } < $1.value.reduce(0) { $0 + $1.1.focusedSeconds } }
            .flatMap { sid, pairs in subject(sid).map { c in
                let gain = pairs.reduce(0) { $0 + XP.earned($1.1) }
                let now = courseXP(c)
                return courseMove(c, before: now - gain, after: now)
            } }
        let o = overall
        return ClosingSummary(dayLabel: record.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)).lowercased(), stars: record.stars,
                              streak: o.streak, cells: dayIsToday ? o.weekCells : Array(repeating: .future, count: 7), today: o.todayIndex,
                              freezeEarned: freezes > freezesBefore, freezes: freezes,
                              scoreBefore: scoreBefore, scoreAfter: stats?.score.total ?? 0, word: stats?.score.word ?? "", unplanned: stats?.unplanned ?? false,
                              focused: f?.focused ?? 0, sessions: (f?.sessionsDone ?? 0) + (f?.sessionsLive ?? 0), course: course,
                              losses: stats.map(Tally.day) ?? [])
    }

    /// §3.7: with no queue, no session and a plan for today, the plan's first item is queued (`source: "plan"`). Run at init.
    func prefillQueueFromPlan() {
        guard session == nil, queued == nil, let first = plan(for: Date()).first else { return }
        if let oid = first.objectiveId, let o = objective(oid) { prepareSession(objective: o, minutes: first.minutes ?? 0, source: "plan") }
        else if !first.goal.isEmpty { prepareSession(goal: first.goal, minutes: first.minutes, strictness: settings.defaultStrictness, source: "plan") }
    }

    // MARK: K3 (§3.5) — the offer and the reminder

    /// `offerShutdown` = no session live ∧ the clock is past `shutdownOfferHour` within the study day ∧ no shutdown for today ∧
    /// the last session ended ≥ 45 min ago or just now. Recomputed once a minute in `tick()`, at every session end and filing.
    func recomputeShutdownOffer(now: Date = Date()) {
        offerShutdown = ShutdownRule.offered(now: now, session: session != nil, offerHour: settings.shutdownOfferHour, startHour: StudyDay.startHour,
                                             shutDown: shutdown(for: now) != nil, lastEnded: lastSessionEnd(now: now))
    }
    /// When today's last session ended (the live one does not count); nil with none today.
    func lastSessionEnd(now: Date = Date()) -> Date? {
        EventLog.shared.events(kind: "session.end", from: StudyDay.start(of: now), to: now).last?.ts
    }

    /// The one reminder (§3.5): at `settings.shutdownReminder` ("HH:mm"; "off" = never), once per study day, when no shutdown is filed —
    /// a 6-s toast and a `ui.reminder` row. Never a card, never a sound. Called once a minute from `tick()`.
    func shutdownReminderTick(now: Date = Date(), reminder: String? = nil) {
        let t = reminder ?? settings.shutdownReminder   // `reminder`: the check's own value, so prefs.json is never written
        guard t != "off", session == nil else { return }
        let p = t.split(separator: ":").compactMap { Int($0) }; guard p.count == 2 else { return }
        let cal = Calendar.current
        let h = cal.component(.hour, from: now), m = cal.component(.minute, from: now)
        guard h == p[0], m == p[1] else { return }
        let day = StudyDay.start(of: now)
        guard shutdownRemindedFor != day, shutdown(for: now) == nil else { return }
        shutdownRemindedFor = day
        EventLog.shared.ui("reminder", "shutdown")
        toast = Toast(text: "shut down the day? ⌘⇧D"); let shown = toast
        Task { try? await Task.sleep(for: .seconds(6)); if toast == shown { toast = nil } }
    }

    /// `endSession`'s hook (§3.5): the summary E's card shows, then the offer.
    func noteSessionEnded(_ s: Session, reason: String) {
        recomputeShutdownOffer()
        let rec = statsToday?.sessions.last { abs($0.start.timeIntervalSince(s.started)) < 2 }
        let secs = rec?.focusedSeconds ?? Int(Date().timeIntervalSince(s.started))
        let clean: Double? = rec.map { r in r.focusedSeconds > 0 ? max(0, min(1, Double(r.focusedSeconds - r.detourSeconds - r.pausedSeconds) / Double(r.focusedSeconds))) : 0 }
        lastSessionSummary = SessionSummary(sessionId: s.id, title: sessionObjectiveTitle(s), objectiveId: s.objectiveId, started: s.started, ended: Date(), seconds: secs,
                                            plannedMinutes: s.ends.map { Int($0.timeIntervalSince(s.started) / 60) }, caught: rec?.caught ?? 0, blocked: rec?.blocked ?? 0,
                                            clean: clean, score: rec?.score ?? .empty, reason: reason, offerShutdown: offerShutdown,
                                            xp: lastSessionXP)
    }
    private func sessionObjectiveTitle(_ s: Session) -> String { objective(s.objectiveId)?.title ?? (s.goal.isEmpty ? "Focus session" : s.goal) }

    // MARK: the quiet check (`--shutdown-check`, K2 §4)

    /// Runs on a scratch log (DBOT_LOG_PATH) and a scratch queue (DBOT_QUEUE_PATH): files a shutdown as if at 00:30 the next morning,
    /// reads it back as that day's, files a second one (latest wins), prints the plan and the queue. Nothing is shown; no real file is touched.
    func shutdownCheck() -> [String] {
        var out: [String] = []
        let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
        let nextMorning = StudyDay.end(of: Date()).addingTimeInterval(-(Double(StudyDay.startHour) * 3600) + 30 * 60)   // 00:30 after today's midnight
        let day = StudyDay.start(of: nextMorning)
        out.append("now \(f.string(from: Date())) · a shutdown at \(f.string(from: nextMorning)) closes the study day \(f.string(from: day)) (today's: \(StudyDay.isToday(day)))")
        let first = catalog.objectives.first { !$0.archived }
        let s1 = Shutdown(day: nextMorning, rating: 4, note: "check one", objectives: first.map { [Shutdown.ObjectiveMark(objectiveId: $0.id, mark: "moved", note: "half the set")] } ?? [],
                          tomorrow: [Shutdown.PlannedItem(objectiveId: first?.id, goal: first?.title ?? "read chapter 4", minutes: 90)], startAt: StudyDay.shift(day, by: 1).addingTimeInterval(15.5 * 3600))
        fileShutdown(s1, quiet: true)
        let back = EventLog.shared.shutdown(for: day)
        out.append("read back: \(back.map { "day \(f.string(from: $0.day)) · rating \($0.rating ?? 0) · note \($0.note) · marks \($0.objectives.map(\.mark)) · tomorrow \($0.tomorrow.map { "\($0.goal) \($0.minutes ?? 0) min" }) · start \($0.startAt.map { f.string(from: $0) } ?? "-")" } ?? "NONE")")
        out.append("filed as the study day: \(back.map { StudyDay.start(of: $0.day) == day } ?? false) · stamped session: \(EventLog.shared.events(kind: Shutdown.kind, from: .distantPast, to: .distantFuture).last?.sessionId ?? "NULL")")
        out.append("queue after filing: \(queued.map { "\($0.goal) · \($0.minutes.map(String.init) ?? "open") min · from \($0.source)" } ?? "none") · file \(FileManager.default.fileExists(atPath: QueuedSession.url.path) ? "written" : "MISSING") at \(QueuedSession.url.path)")
        out.append("plan(for: tomorrow): \(plan(for: StudyDay.shift(day, by: 1)).map { "\($0.goal) \($0.minutes ?? 0) min" }) · plan(for: today): \(plan(for: day).count) items")
        let s2 = Shutdown(day: nextMorning, rating: 2, note: "check two", tomorrow: [])
        fileShutdown(s2, quiet: true)
        let again = EventLog.shared.shutdown(for: day)
        out.append("second filing read back: rating \(again?.rating ?? 0) · note \(again?.note ?? "-") (latest wins: \(again?.note == "check two")) · rows kept: \(EventLog.shared.shutdowns(from: .distantPast, to: .distantFuture).count)")
        out.append("offerShutdown now: \(offerShutdown) (false after a filing: \(!offerShutdown))")
        // the rule with its own clock (K3's judged cases)
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int = 0) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: Date())! }
        out.append("rule · 21:30 no session no record no end → \(ShutdownRule.offered(now: at(21, 30), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: nil)) (expect true)")
        out.append("rule · 20:00 → \(ShutdownRule.offered(now: at(20), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: nil)) (expect false)")
        out.append("rule · 21:30 after a filing → \(ShutdownRule.offered(now: at(21, 30), session: false, offerHour: 21, startHour: 4, shutDown: true, lastEnded: nil)) (expect false)")
        out.append("rule · 21:30 session live → \(ShutdownRule.offered(now: at(21, 30), session: true, offerHour: 21, startHour: 4, shutDown: false, lastEnded: nil)) (expect false)")
        out.append("rule · 22:00 ended 10 min ago → \(ShutdownRule.offered(now: at(22), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: at(21, 50))) (expect false) · ended just now → \(ShutdownRule.offered(now: at(22), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: at(22).addingTimeInterval(-30))) (expect true) · ended 50 min ago → \(ShutdownRule.offered(now: at(22), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: at(21, 10))) (expect true)")
        out.append("rule · 01:00 (inside the study day) → \(ShutdownRule.offered(now: at(1), session: false, offerHour: 21, startHour: 4, shutDown: false, lastEnded: nil)) (expect true)")
        // the reminder: two ticks across 23:30 on a day with no record → one ui.reminder row (the second filing above is for `day`, so use a past day's clock)
        let before = EventLog.shared.count("ui.reminder", since: .distantPast)
        shutdownRemindedFor = nil
        let yesterday2330 = cal.date(bySettingHour: 23, minute: 30, second: 0, of: StudyDay.shift(Date(), by: -3))!   // a day with no record
        for t in [0.0, 20, 60] { shutdownReminderTick(now: yesterday2330.addingTimeInterval(t), reminder: "23:30") }
        out.append("reminder rows written across two ticks at 23:30 (+ one at 23:31): \(EventLog.shared.count("ui.reminder", since: .distantPast) - before) (expect 1)")
        clearQueued()
        return out
    }
}
