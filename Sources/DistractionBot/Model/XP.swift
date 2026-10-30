import Foundation

/// XP and levels — per session (PLAN_SCORING §3.3, Z2) summed per course (PLAN_GAME_LOOP §3.1, G1; G0 took the tokens, the roll and the stake out). Pure: `SessionRecord`s in, numbers out,
/// so `scripts/scoring-check.swift` judges the same code the app runs. The Store surface (`store.xp(of:)` …) is `Model/XPStore.swift`.
enum XP {
    /// §5a Q7.9: the focus dial is worth something — a stricter session earns more per clean minute. Keyed by `Strictness.rawValue`.
    static let multiplier: [String: Double] = ["laxed": 0.8, "gentle": 0.9, "normal": 1.0, "strict": 1.1, "hard": 1.2, "extreme": 1.25]
    static func multiplier(_ strictness: String) -> Double { multiplier[strictness] ?? 1.0 }

    /// Clean focused minutes: the session's seconds minus pauses, detours and away time (X4), floor 0.
    /// (The plan's "session minutes − detours − away"; a pause is taken out too — paused time is not focus.)
    static func clean(seconds: Int, pausedSeconds: Int = 0, detourSeconds: Int, awaySeconds: Int) -> Int {
        max(0, (seconds - pausedSeconds - detourSeconds - awaySeconds) / 60)
    }
    /// One session's XP: clean minutes × the dial's multiplier, + 30 when it ran to its planned end.
    static func session(seconds: Int, pausedSeconds: Int = 0, detourSeconds: Int, awaySeconds: Int, strictness: String, finished: Bool) -> Int {
        Int((Double(clean(seconds: seconds, pausedSeconds: pausedSeconds, detourSeconds: detourSeconds, awaySeconds: awaySeconds)) * multiplier(strictness)).rounded()) + (finished ? 30 : 0)
    }
    /// The same from a record. F3: `focusedSeconds` already leaves out away and paused time, so neither is taken out again.
    /// HUD1 (PLAN_SESSION_HUD §3.1, §5a Q4–Q7): when the session's game is known (every session read from the log), each clean minute
    /// pays at the combo multiplier it was earned at (×1 · ×2 from 10 min in a row · ×3 from 30), then × the dial, + 30 finished.
    static func session(_ s: SessionRecord, awaySeconds: Int = 0) -> Int {
        if let g = s.game { return Int((g.comboMinutes * multiplier(s.strictness)).rounded()) + (s.finished ? 30 : 0) + SessionTasks.xpEach * s.tasksPaid }   // HUD4: + 10 per paid task
        return session(seconds: s.focusedSeconds, pausedSeconds: 0, detourSeconds: s.detourSeconds, awaySeconds: awaySeconds, strictness: s.strictness, finished: s.finished)
    }
    /// What a session earned. F3 (PLAN_GAME_FEEL §5a Q5, Q7): a session that ended (its summary read) is paid by the rule above from its own
    /// rows, so every session is paid on one "focused" — the `xp` row is read only for a session with no summary (an older one). A live session
    /// earns as it goes. (G0: the `xp.bonus` rows of the removed roll are not read.)
    static func earned(_ s: SessionRecord, awaySeconds: Int = 0) -> Int { s.endedBy.isEmpty ? (s.xpRow ?? session(s, awaySeconds: awaySeconds)) : session(s, awaySeconds: awaySeconds) }
    /// A course's XP (PLAN_GAME_LOOP §3.1, G1): Σ its real sessions' XP over every objective filed under it, + 60 per completed objective.
    static func course(_ sessions: [SessionRecord], completedObjectives: Int, awaySeconds: (SessionRecord) -> Int = { _ in 0 }) -> Int {
        sessions.filter { !$0.isTest }.reduce(0) { $0 + earned($1, awaySeconds: awaySeconds($1)) } + 60 * max(0, completedObjectives)
    }

    /// Streak freezes (PLAN_GAME_LOOP §3.3, G2; §5a Q2): one is earned per `freezeEvery` shutdowns filed, counted over all time, and at most
    /// `freezeCap` are kept in hand — the nth is written only once fewer than the cap are held, so a banked one arrives after a use.
    static let freezeEvery = 5
    static let freezeCap = 2
    static func freezesEarned(shutdowns: Int) -> Int { max(0, shutdowns) / freezeEvery }
    static let freezeRule = "a freeze is earned per 5 shutdowns · at most 2 in hand · it bridges the first missed day, once"

    /// The rule in one hover line, shared by the subject card, the page and Progress' Levels.
    static let rule = "a course's XP = Σ its sessions' clean minutes × the combo (×2 from 10 min in a row, ×3 from 30) × the focus dial (laxed 0.8 … extreme 1.25) + 30 per session finished to its planned end + 60 per completed objective · L1 300 · L2 1 080 · L3 2 520 · L4 5 400 · L5 10 800"
    /// A course's L1…L5 at these totals. HUD1 (PLAN_SESSION_HUD §5a Q7): the combo pays ≈ 2× per clean minute on the real log (ratio 2.01),
    /// so the bands moved with it — set by measurement so no course changed level the day the combo landed (`scripts/game-check.swift`).
    /// No single factor did that (one course at 214 → 318 XP needed L1 ≤ 318, another at 477 → 956 needed L2 > 956), so L1 is 300 and the
    /// rest are doubled: still ≈ 3 · 9 · 21 · 45 · 90 clean hours at a typical combo. L0 below 300. (Was 180 · 540 · 1 260 · 2 700 · 5 400.)
    static let bands = [300, 1080, 2520, 5400, 10800]
    /// The level 0…5 and the fraction of the way to the next band (1 at L5).
    static func level(_ xp: Int, bands: [Int] = bands) -> (level: Int, into: Double) {
        let l = bands.filter { xp >= $0 }.count
        guard l < bands.count else { return (l, 1) }
        let floor = l == 0 ? 0 : bands[l - 1]
        return (l, Double(xp - floor) / Double(bands[l] - floor))
    }
    /// XP still to earn for the next band; nil at L5.
    static func toNext(_ xp: Int, bands: [Int] = bands) -> Int? { bands.first { $0 > xp }.map { $0 - xp } }
    /// `L2 · 137 XP · 43 to L3` (`L5 · 1 912 XP` at the top).
    static func label(_ xp: Int, bands: [Int] = bands) -> String {
        let l = level(xp, bands: bands).level
        return "L\(l) · \(xp) XP" + (toNext(xp, bands: bands).map { " · \($0) to L\(l + 1)" } ?? "")
    }
}
