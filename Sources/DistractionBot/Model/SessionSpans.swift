import Foundation

/// PLAN_MINUTE_STRIP M0 (§3.1): a session as spans of its own seconds — focus, a detour, away, paused, the planned minutes it fell short of —
/// and the launches as marks. Pure, from the session's rows, so `scripts/scoring-check.swift` judges what the strip draws against the
/// score: the focus spans sum to `SessionRecord.netFocusSeconds`.
struct StripSpan: Equatable {
    enum Kind: Equatable { case focus, detour, away, paused, short }
    var kind: Kind
    var from: Int           // seconds from the start
    var to: Int
    var site = ""           // a detour's site
    var heeded = true       // a detour that ended without being blocked (§5a Q2)
    var seconds: Int { to - from }
}
struct StripMark: Equatable { var at: Int; var site: String }

enum SessionSpans {
    struct Strip: Equatable {
        var spans: [StripSpan] = []
        var marks: [StripMark] = []
        var length = 0              // the strip's full width in seconds: the plan, or the session when it ran longer
        var unplacedPaused = 0      // paused seconds the summary counts but no pause row places (sessions before pause rows)
        func total(_ k: StripSpan.Kind) -> Int { spans.filter { $0.kind == k }.reduce(0) { $0 + $1.seconds } }
    }

    /// `planned`: the planned seconds (nil for an open session). `pausedTotal`: the summary's paused seconds, which cap the paused spans
    /// as they cap `Stats.pauseOutsideAway` (nil while live). Overlaps resolve away > paused > detour > focus (§3.1).
    static func build(rows: [Event], start: Date, end: Date, planned: Int?, pausedTotal: Int?) -> Strip {
        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        func off(_ d: Date) -> Int { min(elapsed, max(0, Int(d.timeIntervalSince(start).rounded()))) }
        var aways: [(start: Date, end: Date)] = [], pauses: [(Date, String)] = [], resumes: [Date] = []
        var detours: [(from: Int, to: Int, site: String, heeded: Bool)] = [], marks: [StripMark] = []
        for e in rows.sorted(by: { $0.ts < $1.ts }) where e.ts >= start && e.ts <= end {
            switch e.kind {
            case "session.away": if let secs = Int(e.detail) { aways.append((e.ts.addingTimeInterval(-Double(secs)), e.ts)) }
            case "session.pause": pauses.append((e.ts, e.detail))
            case "session.resume": resumes.append(e.ts)
            case "judge.detour":
                let ps = e.detail.components(separatedBy: " · ")   // `<seconds> · <how> · <site>`
                let secs = Int(ps.first ?? "") ?? 0
                guard secs > 0 else { break }
                detours.append((off(e.ts.addingTimeInterval(-Double(secs))), off(e.ts), TallyFact.site(ps.count > 2 ? ps[2] : ""), !(ps.count > 1 && ps[1].hasPrefix("blocked"))))
            case "block.close", "block.shield":
                let at = Int(e.ts.timeIntervalSince(start))
                if at >= Tally.sweepSeconds { marks.append(StripMark(at: at, site: e.app)) }
            default: break
            }
        }

        // Paused: each pause's span (Stats' rule), capped at the summary's total from the latest back; no rows → nothing to place.
        var paused = Stats.pauseIntervals(pauses: pauses, resumes: resumes, aways: aways, end: end).map { (off($0.0), off($0.1)) }
        var unplaced = 0
        if let cap = pausedTotal {
            let outside = Stats.pauseOutsideAway(pauses: pauses, resumes: resumes, aways: aways, end: end, pausedTotal: cap)
            if pauses.isEmpty { unplaced = outside }
            else {
                let awayOff = aways.map { (off($0.start), off($0.end)) }
                func outsideAway(_ p: [(Int, Int)]) -> Int { p.reduce(0) { acc, s in acc + (s.0..<s.1).count - awayOff.reduce(0) { $0 + max(0, min(s.1, $1.1) - max(s.0, $1.0)) } } }
                while outsideAway(paused) > outside, let last = paused.indices.last {
                    paused[last].1 -= min(outsideAway(paused) - outside, paused[last].1 - paused[last].0)
                    if paused[last].1 <= paused[last].0 { paused.removeLast() }
                }
            }
        }

        // Paint: every boundary, then each piece takes the highest kind covering it.
        typealias Layer = (from: Int, to: Int, rank: Int, detour: Int?)
        var layers: [Layer] = aways.map { (off($0.start), off($0.end), 3, nil) }
        layers += paused.map { ($0.0, $0.1, 2, nil) }
        layers += detours.enumerated().map { ($0.element.from, $0.element.to, 1, $0.offset) }
        let cuts = Set([0, elapsed] + layers.flatMap { [$0.from, $0.to] }).filter { $0 >= 0 && $0 <= elapsed }.sorted()
        var spans: [StripSpan] = [], ids: [Int?] = []   // ids: which detour a detour span is, so two side by side stay two
        for (a, b) in zip(cuts, cuts.dropFirst()) where b > a {
            let top = layers.filter { $0.from <= a && $0.to >= b }.max { $0.rank < $1.rank || ($0.rank == $1.rank && ($0.detour ?? 0) > ($1.detour ?? 0)) }
            var s: StripSpan
            switch top?.rank {
            case 3?: s = StripSpan(kind: .away, from: a, to: b)
            case 2?: s = StripSpan(kind: .paused, from: a, to: b)
            case 1?: let d = detours[top!.detour!]; s = StripSpan(kind: .detour, from: a, to: b, site: d.site, heeded: d.heeded)
            default: s = StripSpan(kind: .focus, from: a, to: b)
            }
            let id = top?.rank == 1 ? top?.detour : nil
            if var last = spans.last, last.kind == s.kind, last.to == a, ids.last == id {
                last.to = b; spans[spans.count - 1] = last
            } else { spans.append(s); ids.append(id) }
        }
        if let p = planned, p > elapsed { spans.append(StripSpan(kind: .short, from: elapsed, to: p)) }
        return Strip(spans: spans, marks: marks, length: max(elapsed, planned ?? 0), unplacedPaused: unplaced)
    }

    /// M1 (§3.3): a live session's spans at `now` seconds in, from a strip built at an earlier refresh. The tail since then is paused
    /// while the session is paused, else focus; an away span still open (`awayFrom`, seconds in) is drawn over everything from its start.
    static func live(_ built: [StripSpan], now: Int, paused: Bool, awayFrom: Int?) -> [StripSpan] {
        var spans = built.filter { $0.kind != .short }
        let end = spans.last?.to ?? 0
        if now > end {
            let k: StripSpan.Kind = paused ? .paused : .focus
            if var last = spans.last, last.kind == k, k != .detour { last.to = now; spans[spans.count - 1] = last }
            else { spans.append(StripSpan(kind: k, from: end, to: now)) }
        }
        if let a = awayFrom.map({ max(0, min($0, now)) }), a < now {
            spans = spans.compactMap { s in s.to <= a ? s : s.from >= a ? nil : { var t = s; t.to = a; return t }() }
            if var last = spans.last, last.kind == .away, last.to == a { last.to = now; spans[spans.count - 1] = last }
            else { spans.append(StripSpan(kind: .away, from: a, to: now)) }
        }
        return spans
    }
}

extension Tally {
    /// M2 (§3.5): each loss pointed at what it was taken for on the strip — short at the short span, away and paused at theirs, each detour
    /// at its own span (in order, by site), an ignored warning at the blocked detour of its site, a launch at its mark (index `spans.count + i`).
    /// Restlessness, `too short` and the old `caught` row point at nothing.
    static func point(_ losses: [Loss], _ strip: SessionSpans.Strip) -> [Loss] {
        let idx = Array(strip.spans.indices)
        var usedDetours = Set<Int>(), usedMarks = Set<Int>()
        func kind(_ k: StripSpan.Kind) -> [Int] { idx.filter { strip.spans[$0].kind == k } }
        return losses.map { l in
            var l = l
            let site = l.detail.components(separatedBy: " · ").first ?? ""
            switch l.name {
            case "short", "ended early": l.at = kind(.short)
            case "away": l.at = kind(.away)
            case "paused": l.at = kind(.paused)
            case "detours": l.at = kind(.detour)
            case "detour":
                let free = kind(.detour).filter { !usedDetours.contains($0) }
                if let i = free.first(where: { strip.spans[$0].site == site }) ?? free.first { l.at = [i]; usedDetours.insert(i) }
            case "warning ignored":
                let blocked = kind(.detour).filter { !strip.spans[$0].heeded }
                let bySite = blocked.filter { strip.spans[$0].site == site }   // a follow-up names the host, a detour the page; fall back to every blocked one
                l.at = bySite.isEmpty ? blocked : bySite
            case "launched":
                if let i = strip.marks.indices.first(where: { !usedMarks.contains($0) && strip.marks[$0].site == site }) { l.at = [idx.count + i]; usedMarks.insert(i) }
            default: l.at = []
            }
            return l
        }
    }
}
