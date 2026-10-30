import Foundation

/// HUD1 (PLAN_SESSION_HUD §3.1, §5a Q1–Q7): a session played as a rhythm game. Pure — the session's own spans (`SessionSpans`, M0)
/// and hits (from its rows) in, figures out — so the live HUD, the results screen, the Sessions rows and `scripts/game-check.swift`
/// all run the same arithmetic.
///
/// - **Accuracy** (the session's figure): `100 × (1 − lost ÷ possible)`. Possible = focus + detour seconds + penalties; lost = detour
///   seconds + penalties. Away, paused and short time are neither. It starts at 100, falls on a detour or a penalty, and creeps back as
///   clean seconds add to possible.
/// - **Combo**: clean seconds in a row. ×1 below 10 min, ×2 from 10, ×3 from 30. A detour freezes it (neither grows nor drops while the
///   judge decides); a **slip** drops one level (at ×3 it lands at 10 min, at ×2 at 0); a **miss** resets it to 0; away and paused time
///   freeze it.
/// - **XP**: each clean second pays at the multiplier it was earned at; `XP.session` turns it into minutes × the dial (+ 30 finished).
///   Nothing here ever takes XP back.
enum SessionGame {
    // MARK: the rules (§5a)

    static let slipPenalty = 60             // Q2: a warning answered `back` / `snooze`, a confident verdict closed (extreme)
    static let missPenalty = 180            //     a card ignored, still in front at the follow-up, a session block, a blocked app launched
    /// A miss within this many seconds of the previous one is the same episode (ignored → still in front → the site blocked, one act).
    static let missEpisode = 60
    /// Q4: combo seconds at which each multiplier starts.
    static let tiers: [(from: Int, multiplier: Int)] = [(0, 1), (600, 2), (1800, 3)]
    static func multiplier(combo: Int) -> Int { tiers.last { combo >= $0.from }?.multiplier ?? 1 }
    /// Seconds still to reach the next tier; nil at the top.
    static func toNextTier(combo: Int) -> Int? { tiers.first { $0.from > combo }.map { $0.from - combo } }

    /// Q3: the rank for an accuracy.
    enum Rank: String, CaseIterable { case SS, S, A, B, C, D }
    static func rank(_ accuracy: Double) -> Rank {
        switch accuracy { case 98...: return .SS; case 95..<98: return .S; case 90..<95: return .A; case 80..<90: return .B; case 70..<80: return .C; default: return .D }
    }

    // MARK: hits

    struct Hit: Equatable {
        enum Kind: String, Equatable { case slip, miss }
        var kind: Kind
        var at: Int            // seconds from the start
        var what: String       // the site, app or item, for the loss row
    }

    /// The session's hits from its rows. Answers after a follow-up or a close are the same episode as the act that raised them and are
    /// not counted again; `work`, `told` and `cleared` are not hits (the judge was wrong, or the card went away by itself).
    static func hits(rows: [Event], start: Date, end: Date) -> [Hit] {
        var out: [Hit] = []
        var lastMiss: Int?
        func add(_ k: Hit.Kind, _ e: Event, _ what: String) {
            let at = max(0, Int(e.ts.timeIntervalSince(start)))
            if k == .miss {
                if let m = lastMiss, at - m < missEpisode { return }
                lastMiss = at
            }
            out.append(Hit(kind: k, at: at, what: what))
        }
        for e in rows.sorted(by: { $0.ts < $1.ts }) where e.ts >= start && e.ts <= end {
            let ps = e.detail.components(separatedBy: " · ")
            switch e.kind {
            case "judge.answer":
                guard !e.detail.contains("after follow-up"), !e.detail.contains("after close"), ps.count > 1 else { break }
                let item = TallyFact.site(ps[1])
                switch ps[0] { case "back", "snooze": add(.slip, e, item); case "ignored": add(.miss, e, item); default: break }
            case "judge.followup" where e.detail.hasPrefix("still in front"):
                add(.miss, e, TallyFact.site(ps.dropFirst().first { !$0.hasSuffix("for the session") } ?? ""))
            case "web.block":
                add(.miss, e, TallyFact.site(ps.first ?? e.app))
            case "block.close", "block.shield":
                if Int(e.ts.timeIntervalSince(start)) >= Tally.sweepSeconds { add(.miss, e, e.app) }   // F3: the start-up sweep is not a launch
            case "judge.close":
                add(.slip, e, e.app.isEmpty ? TallyFact.site(ps.first ?? "") : e.app)
            default: break
            }
        }
        return out
    }

    // MARK: the state

    struct State: Equatable {
        var possible = 0          // seconds
        var lost = 0
        var combo = 0
        var bestCombo = 0
        var cleanSeconds = 0
        var detourSeconds = 0
        var xpSeconds = 0         // Σ clean seconds × the multiplier they were earned at
        var secondsAt: [Int: Int] = [1: 0, 2: 0, 3: 0]
        var slips = 0
        var misses = 0
        var accuracy: Double { possible == 0 ? 100 : 100 * (1 - Double(lost) / Double(possible)) }
        var rank: Rank { SessionGame.rank(accuracy) }
        var multiplier: Int { SessionGame.multiplier(combo: combo) }
        /// The XP the combo earned, in clean minutes at ×1 (before the dial and the finish bonus).
        var comboMinutes: Double { Double(xpSeconds) / 60 }

        /// `seconds` of focus: the combo grows, crossing tiers mid-span when it does.
        mutating func clean(_ seconds: Int) {
            var left = max(0, seconds)
            while left > 0 {
                let m = SessionGame.multiplier(combo: combo)
                let step = min(left, SessionGame.toNextTier(combo: combo) ?? left)
                xpSeconds += m * step; secondsAt[m, default: 0] += step
                combo += step; cleanSeconds += step; possible += step; left -= step
            }
            bestCombo = max(bestCombo, combo)
        }
        /// `seconds` of a detour: lost, and the combo is frozen.
        mutating func detour(_ seconds: Int) { let s = max(0, seconds); possible += s; lost += s; detourSeconds += s }
        mutating func hit(_ k: Hit.Kind) {
            switch k {
            case .slip:
                slips += 1; possible += SessionGame.slipPenalty; lost += SessionGame.slipPenalty
                let m = SessionGame.multiplier(combo: combo)
                combo = m > 1 ? (SessionGame.tiers.first { $0.multiplier == m - 1 }?.from ?? 0) : 0
            case .miss:
                misses += 1; possible += SessionGame.missPenalty; lost += SessionGame.missPenalty
                combo = 0
            }
        }
    }

    /// Plays a session's spans with its hits in time order; a hit inside a span cuts it there. `short` spans (planned time not run)
    /// are not played; away and paused spans freeze everything.
    static func play(spans: [StripSpan], hits: [Hit], until: Int? = nil) -> State {
        var st = State()
        var hs = hits.sorted { $0.at < $1.at }[...]
        for sp in spans where sp.kind != .short {
            var from = sp.from
            let to = min(sp.to, until ?? sp.to)
            guard to > from else { continue }
            while let h = hs.first, h.at < to {
                if h.at > from { feed(&st, sp.kind, h.at - from); from = h.at }
                st.hit(h.kind); hs = hs.dropFirst()
            }
            feed(&st, sp.kind, to - from)
        }
        for h in hs where until.map({ h.at <= $0 }) ?? true { st.hit(h.kind) }   // hits after the last span (at the very end)
        return st
    }
    private static func feed(_ st: inout State, _ k: StripSpan.Kind, _ s: Int) {
        switch k { case .focus: st.clean(s); case .detour: st.detour(s); case .away, .paused, .short: break }
    }

    /// A whole session from its rows: the spans M0 draws, the hits above.
    static func replay(rows: [Event], start: Date, end: Date, planned: Int?, pausedTotal: Int?) -> State {
        let strip = SessionSpans.build(rows: rows, start: start, end: end, planned: planned, pausedTotal: pausedTotal)
        return play(spans: strip.spans, hits: hits(rows: rows, start: start, end: end))
    }

    // MARK: the losses, in accuracy points (HUD6 draws them; F's "100 minus what was taken off", per cent)

    struct Loss: Equatable {
        var name: String; var detail: String; var points: Double
        /// HUD6: the strip's spans (and, past `spans.count`, its marks) this loss was taken for — the end card lights them as the row lands (M2's rule).
        var at: [Int] = []
    }

    /// Every loss as a share of the session's possible seconds, rounded to tenths by largest remainder so the rows sum exactly to
    /// `100 − accuracy` at one decimal.
    static func losses(spans: [StripSpan], hits: [Hit], state: State, marks: [StripMark] = []) -> [Loss] {
        guard state.possible > 0 else { return [] }
        var raw: [(Loss, Double)] = []
        for (i, sp) in spans.enumerated() where sp.kind == .detour && sp.seconds > 0 { raw.append((Loss(name: "detour", detail: "\(sp.site.isEmpty ? "—" : sp.site) · \(minutes(Double(sp.seconds)))", points: 0, at: [i]), Double(sp.seconds))) }
        for h in hits {
            // HUD6: a launch points at its mark; any other hit at the span it fell in, or the detour that ended just before it
            let at: [Int] = marks.firstIndex { abs($0.at - h.at) <= 1 }.map { [spans.count + $0] }
                ?? spans.firstIndex { $0.from <= h.at && h.at < $0.to && $0.kind == .detour }.map { [$0] }
                ?? spans.lastIndex { $0.kind == .detour && $0.to <= h.at && h.at - $0.to <= 60 }.map { [$0] } ?? []
            raw.append((Loss(name: h.kind.rawValue, detail: h.what.isEmpty ? "—" : h.what, points: 0, at: at), Double(h.kind == .slip ? slipPenalty : missPenalty)))
        }
        let exact = raw.map { 1000 * $0.1 / Double(state.possible) }                 // tenths of a point
        let target = Int((1000 * Double(state.lost) / Double(state.possible)).rounded())
        var tenths = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { (exact[$0] - Double(tenths[$0])) > (exact[$1] - Double(tenths[$1])) }
        var short = target - tenths.reduce(0, +)
        for i in order where short > 0 { tenths[i] += 1; short -= 1 }
        return zip(raw, tenths).map { var l = $0.0.0; l.points = Double($0.1) / 10; return l }.filter { $0.points > 0 }.sorted { $0.points > $1.points }
    }
    /// HUD6: at most `max` rows for the card — the largest `max − 1` in order, the rest as one `N more` row (their points and spans summed).
    static func grouped(_ ls: [Loss], max: Int = 5) -> [Loss] {
        guard ls.count > max else { return ls }
        let head = Array(ls.prefix(max - 1)), tail = ls.dropFirst(max - 1)
        let sum = tail.reduce(0) { $0 + $1.points }
        return head + [Loss(name: "\(tail.count) more", detail: Set(tail.map(\.name)).sorted().joined(separator: " · "), points: (sum * 10).rounded() / 10, at: tail.flatMap(\.at))]
    }
    /// HUD6: one line for a hover or an opened row — `100 − 1.4 detour · YouTube 3 min − 1.2 slip · Reddit = 97.4 % S`.
    static func line(_ ls: [Loss], _ st: State) -> String {
        let acc = String(format: "%.1f", shown(st))
        guard !ls.isEmpty else { return "100 · nothing taken off = \(acc) % \(st.rank.rawValue)" }
        return "100 " + ls.map { "− \(String(format: "%.1f", $0.points)) \($0.name) · \($0.detail)" }.joined(separator: " ") + " = \(acc) % \(st.rank.rawValue)"
    }
    /// `−1.4 detour · −1.2 slip` (by kind, summed), or `nothing taken off`.
    static func brief(_ ls: [Loss]) -> String {
        guard !ls.isEmpty else { return "nothing taken off" }
        var sums: [(String, Double)] = []
        for l in ls { if let i = sums.firstIndex(where: { $0.0 == l.name }) { sums[i].1 += l.points } else { sums.append((l.name, l.points)) } }
        return sums.map { "−\(String(format: "%.1f", $0.1)) \($0.0)" }.joined(separator: " · ")
    }
    /// The accuracy as shown: one decimal, equal to 100 minus the rounded losses.
    static func shown(_ state: State) -> Double { (state.accuracy * 10).rounded() / 10 }
}
