import Foundation

/// One fact the tally names (PLAN_GAME_FEEL F0): a detour's site and seconds, an ignored follow-up's site, a launch's app and how many
/// seconds after the session's start it came. Filled by `Stats.compute` from the session's own rows.
struct TallyFact: Equatable {
    var site: String
    var seconds: Int
    /// A row's site in a few words: the part before ` — ` (`Spotify — KIDS SEE GHOSTS` → `Spotify`), a search as `a search`.
    static func site(_ raw: String) -> String {
        let head = raw.components(separatedBy: " — ").first?.trimmingCharacters(in: .whitespaces) ?? ""
        if head.lowercased().hasPrefix("google:") || head.lowercased().hasPrefix("search:") { return "a search" }
        return head.count > 24 ? String(head.prefix(23)) + "…" : head
    }
}

/// The tally (PLAN_GAME_FEEL §3.1–3.2): every score is 100 minus what was taken off. Pure — `SessionRecord`s and `Stats` in, rows out —
/// so `scripts/scoring-check.swift` judges the same code the end card, the session rows and the day's line draw. The rows of a part sum
/// exactly to what that part lost (50 − time, 20 − calm, 20 − kept, 10 − self-control; for a day 50 − plan, …, 10 − closed), so a
/// tally always sums to `100 − score` to the point.
enum Tally {
    enum Part: Hashable { case time, calm, kept, control, plan, closed }
    struct Loss: Equatable {
        var name: String        // ended early · short · away · paused · detour · detours · caught · restless · warning ignored · no warnings · launched · under plan · open
        var detail: String      // `52 of 60 min` · `YouTube · 3 min` · `Steam` …
        var points: Int
        var part: Part
        var at: [Int] = []      // M2 (PLAN_MINUTE_STRIP §3.5): the strip's spans (and, past `spans.count`, marks) this row was taken for — `Tally.point`
    }
    /// An app the close list closes this soon after the start is the sweep of what was already open, not a launch: free, and not a row (§5a Q3).
    static let sweepSeconds = 10

    // MARK: a session

    static func session(_ r: SessionRecord) -> [Loss] {
        let sc = r.score
        var out: [Loss] = []

        // time: what the session fell short of its yardstick, split between stopping early, being away and pausing (F3: pauses are out of focused)
        let yard = Double(max(60, r.yardstickMinutes * 60))
        let elapsed = r.focusedSeconds + r.awaySeconds + r.pauseOnlySeconds
        let shortExact = max(0, 50 - 50 * Double(elapsed) / yard)
        let idleExact = max(0, max(0, 50 - 50 * Double(r.focusedSeconds) / yard) - shortExact)
        let idle = Double(max(1, r.awaySeconds + r.pauseOnlySeconds))
        let awayExact = idleExact * Double(r.awaySeconds) / idle, pausedExact = idleExact * Double(r.pauseOnlySeconds) / idle
        let m = elapsed / 60
        let shortDetail = r.plannedMinutes.map { "\(m) of \($0) min" } ?? r.avgMinutes.map { "\(m) of \(String($0).hasPrefix("8") || $0 == 11 || $0 == 18 ? "an" : "a") \($0)-min average" } ?? "\(m) of 25 min"
        out += split(50 - sc.time, [
            (Loss(name: r.plannedMinutes == nil ? "short" : "ended early", detail: shortDetail, points: 0, part: .time), shortExact),
            (Loss(name: "away", detail: duration(r.awaySeconds), points: 0, part: .time), awayExact),
            (Loss(name: "paused", detail: duration(r.pauseOnlySeconds), points: 0, part: .time), pausedExact),
        ])

        // calm: the detour share (each detour its share of it, or the catch rate before detours had durations) and the switch rate
        let halves = r.calmHalves
        var calm: [(Loss, Double)] = []
        if r.focusedSeconds < 60 {
            calm.append((Loss(name: "too short", detail: "under a minute focused", points: 0, part: .calm), 20))
        } else {
            let shareLoss = 10 - halves.share
            if r.hasDetourData, !r.detours.isEmpty {
                let total = Double(max(1, r.detours.reduce(0) { $0 + $1.seconds }))
                calm += r.detours.map { d in (Loss(name: "detour", detail: (d.site.isEmpty ? "" : "\(d.site) · ") + duration(d.seconds), points: 0, part: .calm), shareLoss * Double(d.seconds) / total) }
            } else if r.hasDetourData {
                calm.append((Loss(name: "detours", detail: duration(r.detourSeconds), points: 0, part: .calm), shareLoss))
            } else {
                calm.append((Loss(name: "caught", detail: "\(times(r.caught)) in \(r.focusedSeconds / 60) min", points: 0, part: .calm), shareLoss))
            }
            calm.append((Loss(name: "restless", detail: r.switchRate.map { "\($0) switches in 10 min" } ?? "", points: 0, part: .calm), 10 - halves.switches))
        }
        out += split(20 - sc.calm, calm)

        // kept: each warning not followed through (none raised keeps all 20, §5a Q2)
        if r.followUps > 0 {
            let each = 20 / Double(r.followUps)
            let rows = r.ignored.isEmpty && r.followedThrough < r.followUps
                ? [(Loss(name: "warning ignored", detail: "", points: 0, part: .kept), each * Double(r.followUps - r.followedThrough))]
                : r.ignored.map { (Loss(name: "warning ignored", detail: $0.site, points: 0, part: .kept), each) }
            out += split(20 - sc.kept, rows)
        }

        // self-control: 3 a launch until the 10 are gone; the close list's sweep at the start is free and not a row (§5a Q3)
        var left = 10.0
        out += split(10 - sc.selfControl, r.launchList.filter { $0.seconds >= sweepSeconds }.map { l in
            let p = min(3, left); left -= p
            return (Loss(name: "launched", detail: l.site, points: 0, part: .control), p)
        })
        return out
    }

    // MARK: a day (or any period Stats scores)

    static func day(_ s: Stats) -> [Loss] {
        let sc = s.score
        guard s.focusedSeconds > 0 else { return [] }
        var out: [Loss] = []
        if s.planSeconds > 0 {
            out += split(50 - sc.plan, [(Loss(name: "under plan", detail: "\(hm(s.focusedSeconds)) of \(hm(s.planSeconds))", points: 0, part: .plan), 50 - Double(sc.plan))])
        }
        // calm and kept are the sessions' parts weighted by focused seconds (Stats.compute); split the same way
        let focused = Double(max(1, s.sessions.reduce(0) { $0 + $1.focusedSeconds }))
        func weighted(_ f: (SessionRecord) -> Double) -> Double { s.sessions.reduce(0.0) { $0 + f($1) * Double($1.focusedSeconds) } / focused }
        let caught = s.sessions.reduce(0) { $0 + $1.caught }
        out += split(20 - sc.calm, [
            (Loss(name: "detours", detail: s.hasDetourData ? duration(s.detourSeconds) : "\(caught) caught", points: 0, part: .calm), weighted { 10 - $0.calmHalves.share }),
            (Loss(name: "restless", detail: "", points: 0, part: .calm), weighted { 10 - $0.calmHalves.switches }),
        ])
        let fu = s.sessions.reduce(0) { $0 + $1.followUps }, kept = s.sessions.reduce(0) { $0 + $1.followedThrough }
        out += split(20 - sc.kept, [(Loss(name: "warnings ignored", detail: "\(fu - kept) of \(fu)", points: 0, part: .kept), weighted { 20 - Double($0.score.kept) })])
        out += split(10 - sc.closed, [(Loss(name: "open", detail: "+10 at the shutdown", points: 0, part: .closed), 10 - Double(sc.closed))])
        return out
    }

    // MARK: several sessions as one score (F2: the course page's week)

    /// The week's losses: each row family's points weighted by focused time as `CourseProgress.score` weights the parts, then split so
    /// each part's rows sum to what the weighted score lost (`100 − 1 short − 1 detours = 98`).
    static func weighted(_ sessions: [SessionRecord], score: Score) -> [Loss] {
        let w = Double(max(1, sessions.reduce(0) { $0 + max(1, $1.focusedSeconds) }))
        var exact: [String: (Loss, Double)] = [:], order: [String] = []
        for r in sessions {
            for l in session(r) {
                let key = family(l.name)
                if exact[key] == nil { order.append(key); exact[key] = (Loss(name: key, detail: "", points: 0, part: l.part), 0) }
                exact[key]!.1 += Double(l.points) * Double(max(1, r.focusedSeconds)) / w
            }
        }
        let target: [Part: Int] = [.time: 50 - score.time, .calm: 20 - score.calm, .kept: 20 - score.kept, .control: 10 - score.selfControl]
        return [Part.time, .calm, .kept, .control].flatMap { p in split(target[p] ?? 0, order.compactMap { exact[$0] }.filter { $0.0.part == p }) }
    }
    /// One name per kind of loss, for sums over sessions.
    static func family(_ name: String) -> String {
        switch name {
        case "ended early": return "short"
        case "detour", "caught", "too short": return "detours"
        case "warning ignored": return "warnings ignored"
        default: return name
        }
    }

    // MARK: drawing helpers

    /// At most `max` rows (§5a Q13): the `max − 1` largest in their order, the rest summed into one `N more` row.
    static func grouped(_ losses: [Loss], max: Int = 5) -> [Loss] {
        guard losses.count > max else { return losses }
        let keep = Set(losses.indices.sorted { losses[$0].points > losses[$1].points || (losses[$0].points == losses[$1].points && $0 < $1) }.prefix(max - 1))
        let rest = losses.indices.filter { !keep.contains($0) }.map { losses[$0] }
        var names: [String] = []
        for l in rest where !names.contains(l.name) { names.append(l.name) }
        return losses.indices.filter(keep.contains).map { losses[$0] }
            + [Loss(name: "\(rest.count) more", detail: names.joined(separator: " · "), points: rest.reduce(0) { $0 + $1.points }, part: rest[0].part,
                    at: Array(Set(rest.flatMap(\.at))).sorted())]
    }

    /// `100 − 7 ended early · 52 of 60 min − 2 detour · YouTube · 3 min = 91`; `100 · nothing taken off`.
    static func line(_ losses: [Loss], total: Int) -> String {
        guard !losses.isEmpty else { return "100 · nothing taken off" }
        return "100 " + losses.map { "− \($0.points) \($0.name)" + ($0.detail.isEmpty ? "" : " · \($0.detail)") }.joined(separator: " ") + " = \(total)"
    }

    /// The names only, for a row too narrow for the line: `−10 short · −10 caught · −3 launched`; `nothing taken off`.
    static func brief(_ losses: [Loss]) -> String {
        losses.isEmpty ? "nothing taken off" : losses.map { "−\($0.points) \($0.name)" }.joined(separator: " · ")
    }

    /// Integer points for rows whose exact losses are `items`, summing to `target`: floors first, then a point at a time to the row
    /// furthest below its exact value (or from the one furthest above). Rows left at 0 are dropped.
    static func split(_ target: Int, _ items: [(Loss, Double)]) -> [Loss] {
        guard target > 0, !items.isEmpty else { return [] }
        var pts = items.map { Int(max(0, $0.1).rounded(.down)) }
        var guardN = 0
        while pts.reduce(0, +) != target, guardN < 200 {
            guardN += 1
            if pts.reduce(0, +) < target {
                let i = pts.indices.max { items[$0].1 - Double(pts[$0]) < items[$1].1 - Double(pts[$1]) }!
                pts[i] += 1
            } else {
                guard let i = pts.indices.filter({ pts[$0] > 0 }).max(by: { Double(pts[$0]) - items[$0].1 < Double(pts[$1]) - items[$1].1 }) else { break }
                pts[i] -= 1
            }
        }
        return items.indices.compactMap { i -> Loss? in
            guard pts[i] > 0 else { return nil }
            var l = items[i].0; l.points = pts[i]; return l
        }
    }

    static func duration(_ seconds: Int) -> String { seconds >= 60 ? "\(seconds / 60) min" : "\(seconds) s" }
    static func hm(_ seconds: Int) -> String { seconds >= 3600 ? "\(seconds / 3600) h \(String(format: "%02d", seconds % 3600 / 60))" : "\(seconds / 60) min" }
    static func times(_ n: Int) -> String { n == 1 ? "once" : n == 2 ? "twice" : "\(n) times" }
}
