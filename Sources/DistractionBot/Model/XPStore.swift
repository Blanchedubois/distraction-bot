import Foundation

// PLAN_SCORING.md: the Store surface for Z1–Z3 — what the siblings read (`courseXP(_:)`, `courseLevel(_:)`, `freezes`, `lastSessionXP`) and what End, reloadLog and reloadStats call. The rules themselves live in `XP` and `Stats`.
// PLAN_GAME_LOOP G0: the tokens, the bonus roll and the stake are gone from here (their log rows stay readable).

extension Store {
    // MARK: Z1 — the plan and shutdown readers

    /// The `plan` and `shutdown` closures for `Stats.compute`, from the `day.shutdown` rows in `from…to` (two days before, so yesterday's
    /// plan for the first day is seen). K's `EventLog.shutdown(for:)` reads the same rows; this needs no type of K's.
    /// The calendar fallback (P's planned blocks) goes here when `plannedBlocks(day:)` lands: `?? calendarPlan(day)` on the first closure.
    func planClosures(from: Date, to: Date) -> (plan: (Date) -> DayPlan?, shutdown: (Date) -> Bool) {
        let rows = EventLog.shared.events(from: from == .distantPast ? .distantPast : from - 2 * 86400, to: to + 86400).filter { $0.kind == "day.shutdown" }
        return ({ Stats.shutdownPlan(in: rows, for: $0) }, { Stats.hasShutdown(in: rows, for: $0) })
    }

    // MARK: Z2 / G1 — XP and the course's level

    /// X4: away seconds per session once `SessionRecord.awaySeconds` exists; 0 until then.
    private func away(_ s: SessionRecord) -> Int { 0 }
    /// A course's real sessions as Progress scores them (the all-time aggregate, tests out, the live one included): every session filed under one of its objectives.
    func sessionRecords(in s: Catalog.Subject) -> [SessionRecord] {
        let ids = Set(catalog.objectives.filter { $0.subjectId == s.id }.map(\.id))
        return (statsAll?.sessions ?? []).filter { $0.objectiveId.map(ids.contains) ?? false && !$0.isTest }
    }
    /// PLAN_GAME_LOOP §3.1: the course's XP (its sessions + 60 per completed objective), its level and the shared label `L2 · 1 340 XP · 460 to L3`.
    func courseXP(_ s: Catalog.Subject) -> Int {
        XP.course(sessionRecords(in: s), completedObjectives: catalog.objectives.filter { $0.subjectId == s.id && $0.isDone }.count, awaySeconds: away)
    }
    func courseLevel(_ s: Catalog.Subject) -> (level: Int, into: Double) { XP.level(courseXP(s)) }
    func courseLabel(_ s: Catalog.Subject) -> String { XP.label(courseXP(s)) }
    /// PLAN_SUBJECT_PROGRESS S0: the course page's figures — level, this week's XP and its parts, the course's streak, its week score, its latest sessions.
    func courseProgress(_ s: Catalog.Subject, now: Date = Date()) -> CourseProgress {
        CourseProgress.build(sessions: sessionRecords(in: s), completedAt: catalog.objectives.filter { $0.subjectId == s.id }.compactMap(\.completedAt), now: now)
    }

    /// Called by `endSession` between the summary row and `session.end`, so the row it writes stays inside the span (Z2). G3: the course's
    /// move for the end card — its XP without this session (the live record left out), then with the row just written.
    func noteSessionEnd(_ s: Session, reason: String, paused: Int, detour: Int) {
        let finished = reason == "finished"
        // HUD1 (PLAN_SESSION_HUD §3.1): the session replayed as a game from its own rows — the same arithmetic its record will read —
        // so the end card's course bar moves by the combo-paid XP. (F3's rule stands inside it: away and pauses are not focus.)
        let game = SessionGame.replay(rows: EventLog.shared.events(session: s.id), start: s.started, end: Date(),
                                      planned: s.ends.map { Int($0.timeIntervalSince(s.started)) }, pausedTotal: paused)
        let xp = Int((game.comboMinutes * XP.multiplier(s.strictness.rawValue)).rounded()) + (finished ? 30 : 0)
            + SessionTasks.xpEach * SessionTasks.paid(rows: EventLog.shared.events(session: s.id), start: s.started)   // HUD4
        EventLog.shared.add("xp", detail: "\(xp) · ×\(XP.multiplier(s.strictness.rawValue)) · \(finished ? "finished" : "ended")")
        // HUD1: the figures as a cache row (the replay stays the truth; `v1` names the rule)
        EventLog.shared.add("game", detail: "\(String(format: "%.1f", SessionGame.shown(game))) · \(game.rank.rawValue) · maxcombo \(game.bestCombo) · combo \(Int(game.comboMinutes.rounded())) · slips \(game.slips) · misses \(game.misses) · v1")
        lastSessionXP = xp
        lastCourseMove = subject(s.subjectId).map { c in
            let before = XP.course(sessionRecords(in: c).filter { !$0.live }, completedObjectives: catalog.objectives.filter { $0.subjectId == c.id && $0.isDone }.count, awaySeconds: away)
            return courseMove(c, before: before, after: before + xp)
        }
    }
    /// A `CourseMove` for the end card and the closing card (G4): the course between two XP totals.
    func courseMove(_ c: Catalog.Subject, before: Int, after: Int) -> CourseMove {
        let b = XP.level(before), a = XP.level(after)
        return CourseMove(code: c.code ?? c.shortName, icon: c.icon, accent: c.accent, levelBefore: b.level, before: b.into, level: a.level, after: a.into, gainedXP: after - before, toNext: XP.toNext(after))
    }

    // MARK: Z3 — freezes, from the rows; `reloadScoring()` runs inside `reloadLog()`

    /// Streak freezes (§3.4, G2): one earned per 5 shutdowns filed (`streak.freeze · earned · 5 shutdowns · <n>`; Z3's `earned · <week>` rows
    /// still count), one used per bridged day (`streak.freeze · used · <day>`).
    func reloadScoring() {
        if settings.scoreRulesSince == nil, ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] == nil { settings.scoreRulesSince = Date() }   // Z5: the first launch under the new rules (the Progress line, 7 days); a render never writes prefs.json
        let rows = EventLog.shared.events(from: .distantPast, to: Date())
        earnFreezes(rows)
        applyFreezeIfNeeded(rows)
        let after = EventLog.shared.events(from: .distantPast, to: Date())   // the rows just written count too
        let freezeRows = after.filter { $0.kind == "streak.freeze" }
        freezes = freezeRows.filter { $0.detail.hasPrefix("earned") }.count - freezeRows.filter { $0.detail.hasPrefix("used") }.count
    }
    /// G2 (PLAN_GAME_LOOP §3.3): the nth freeze for every `XP.freezeEvery` shutdown days, written while fewer than `XP.freezeCap` are in hand
    /// (`streak.freeze · earned · 5 shutdowns · <n>`, idempotent on n). Z3's weekly `earned · <Monday>` rows and bought ones keep counting.
    private func earnFreezes(_ rows: [Event]) {
        let shutdownDays = Set(rows.compactMap(Stats.shutdownDay)).count
        let freezeRows = rows.filter { $0.kind == "streak.freeze" }
        let earnedNth = Set(freezeRows.compactMap { e -> Int? in
            let ps = e.detail.components(separatedBy: " · ")
            return ps.count == 3 && ps[0] == "earned" && ps[1] == "\(XP.freezeEvery) shutdowns" ? Int(ps[2]) : nil
        })
        var inHand = freezeRows.filter { $0.detail.hasPrefix("earned") }.count - freezeRows.filter { $0.detail.hasPrefix("used") }.count
        for n in 1...max(1, XP.freezesEarned(shutdowns: shutdownDays)) where n <= XP.freezesEarned(shutdowns: shutdownDays) && !earnedNth.contains(n) && inHand < XP.freezeCap {
            EventLog.shared.add("streak.freeze", detail: "earned · \(XP.freezeEvery) shutdowns · \(n)"); inHand += 1
            Log.write("streak freeze earned · \(n * XP.freezeEvery) shutdowns filed")
        }
    }
    /// Yesterday had no session, the day before did, and a freeze is in hand → yesterday is bridged, once (§3.4: the first breaking day).
    private func applyFreezeIfNeeded(_ rows: [Event]) {
        let now = Date()
        let yesterday = StudyDay.shift(now, by: -1), dayBefore = StudyDay.shift(now, by: -2)
        let freezeRows = rows.filter { $0.kind == "streak.freeze" }
        let have = freezeRows.filter { $0.detail.hasPrefix("earned") }.count - freezeRows.filter { $0.detail.hasPrefix("used") }.count
        guard have > 0 else { return }
        let sessionDays = Set(Stats.sessionSpans(events: rows, live: session, now: now).filter { !$0.isTest }.map { StudyDay.start(of: $0.start) })
        let key = ISO8601DateFormatter.ymd.string(from: yesterday)
        guard !sessionDays.contains(yesterday), sessionDays.contains(dayBefore), !freezeRows.contains(where: { $0.detail == "used · \(key)" }) else { return }
        EventLog.shared.add("streak.freeze", detail: "used · \(key)")
        Log.write("streak freeze used for \(key)")
    }
}
