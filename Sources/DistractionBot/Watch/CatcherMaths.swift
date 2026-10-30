import Foundation

/// X1–X4 (PLAN_CATCHER §3.2–3.5): the catcher's arithmetic, with no AppKit and no Store, so `scripts/catcher-check.swift` drives it
/// with synthetic polls. `AppWatcher` owns one of each and feeds them from its 1-s poll.

/// X1: seconds in front per app over a rolling window — one stamp per polled second, kept `depth` deep.
struct FrontWindow {
    var depth: TimeInterval = 20 * 60
    private(set) var stamps: [String: [Date]] = [:]
    mutating func tick(_ id: String, at now: Date) {
        stamps[id, default: []].append(now)
        prune(id, now: now)
    }
    private mutating func prune(_ id: String, now: Date) {
        let cutoff = now - depth
        while let f = stamps[id]?.first, f < cutoff { stamps[id]!.removeFirst() }
    }
    /// Seconds `id` was in front during the last `minutes`.
    func seconds(_ id: String, minutes: Int, now: Date) -> Int {
        let cutoff = now - Double(minutes) * 60
        return (stamps[id] ?? []).reversed().prefix { $0 >= cutoff }.count
    }
    mutating func reset() { stamps = [:] }
}

/// X1: the front apps in order, for the return grace and the PREVIOUS line.
struct FrontHistory {
    struct Span { var id: String; var name: String; var title: String = ""; var since: Date; var until: Date? }
    private(set) var spans: [Span] = []
    var depth = 12
    var current: Span? { spans.last }
    /// The app before the current one.
    var previous: Span? { spans.count >= 2 ? spans[spans.count - 2] : nil }
    mutating func front(_ id: String, name: String, title: String = "", at now: Date) {
        guard spans.last?.id != id else { if !title.isEmpty { spans[spans.count - 1].title = title }; return }
        if !spans.isEmpty { spans[spans.count - 1].until = now }
        spans.append(Span(id: id, name: name, title: title, since: now, until: nil))
        if spans.count > depth { spans.removeFirst(spans.count - depth) }
    }
    /// The return grace: A was in front for less than `grace` seconds and the front is now the app that was in front before A.
    func returned(from id: String, grace: TimeInterval = 60) -> Bool {
        guard let cur = spans.last, cur.id != id, let i = spans.lastIndex(where: { $0.id == id }), i >= 1, let until = spans[i].until else { return false }
        return spans[i - 1].id == cur.id && until.timeIntervalSince(spans[i].since) < grace
    }
    mutating func reset() { spans = [] }
}

/// X2: judged keys with an expiry — re-judged after `rejudgeMinutes` continuously in front since the last verdict, then at each doubling.
struct JudgedKeys {
    struct Entry { var at: Date; var count: Int; var visits: Int; var inFrontSince: Date }
    private(set) var entries: [String: Entry] = [:]
    func contains(_ key: String) -> Bool { entries[key] != nil }
    /// Called when `key` has just been judged.
    mutating func judged(_ key: String, at now: Date, inFrontSince: Date) {
        if var e = entries[key] { e.at = now; e.count += 1; e.inFrontSince = inFrontSince; entries[key] = e }
        else { entries[key] = Entry(at: now, count: 1, visits: 1, inFrontSince: inFrontSince) }
    }
    /// Called when `key` comes to front again after being away: the visit count grows.
    mutating func visited(_ key: String, at now: Date) {
        guard var e = entries[key] else { return }
        e.visits += 1; e.inFrontSince = now; entries[key] = e
    }
    /// Minutes to wait after the n-th verdict: base after the 1st and 2nd, then doubling — re-judges land at base, 2×, 4× … after the first verdict.
    static func nextAfter(count: Int, base: Int) -> Int { count <= 2 ? base : base * (1 << (count - 2)) }
    /// Whether `key` is due a re-judge: continuously in front for the wait since its last verdict (or since it came back to front, if later).
    func due(_ key: String, now: Date, rejudgeMinutes: Int) -> Bool {
        guard let e = entries[key] else { return false }
        let wait = Double(Self.nextAfter(count: e.count, base: rejudgeMinutes)) * 60
        return now.timeIntervalSince(max(e.at, e.inFrontSince)) >= wait
    }
    func visits(_ key: String) -> Int { entries[key]?.visits ?? 0 }
    mutating func reset() { entries = [:] }
}

/// X3: every front-app change, `depth` deep; the rate over the last N minutes and the word for it.
struct SwitchLog {
    var depth: TimeInterval = 20 * 60
    private(set) var stamps: [Date] = []
    private(set) var total = 0
    private(set) var max10 = 0
    mutating func note(at now: Date) {
        stamps.append(now); total += 1
        let cutoff = now - depth
        while let f = stamps.first, f < cutoff { stamps.removeFirst() }
        max10 = max(max10, rate(minutes: 10, now: now))
    }
    func rate(minutes: Int, now: Date) -> Int {
        let cutoff = now - Double(minutes) * 60
        return stamps.reversed().prefix { $0 >= cutoff }.count
    }
    /// calm ≤ 6 · busy ≤ the level's nudge threshold · restless above it
    static func word(rate: Int, nudge: Int) -> String { rate <= 6 ? "calm" : rate <= nudge ? "busy" : "restless" }
    /// The quiet nudge: the 10-min rate when it is above `threshold` and no nudge went out in the last 10 min; nil otherwise.
    private var lastNudge: Date?
    mutating func nudgeDue(threshold: Int, now: Date) -> Int? {
        let r = rate(minutes: 10, now: now)
        guard r > threshold, lastNudge.map({ now.timeIntervalSince($0) >= 600 }) ?? true else { return nil }
        lastNudge = now; return r
    }
    mutating func reset() { stamps = []; total = 0; max10 = 0; lastNudge = nil }
}

/// X4: idle seconds → away spans and the auto-pause, as events for the watcher to log and act on.
struct AwayTracker {
    enum Event: Equatable { case opened(Date), closed(seconds: Int), pause, extend, resumed(seconds: Int) }
    private(set) var awaySince: Date?
    private(set) var pausedByIdle = false
    private var lastExtend: Date?
    private var forced = false
    var isAway: Bool { awaySince != nil }

    /// One poll: `idle` seconds since the last input, the level's `awayAfter`, the auto-pause threshold (nil = off).
    mutating func tick(idle: TimeInterval, now: Date, awayAfter: TimeInterval, autoPauseAfter: TimeInterval?) -> [Event] {
        var out: [Event] = []
        if awaySince == nil {
            if idle >= awayAfter { awaySince = now - idle; out.append(.opened(awaySince!)) }
            return out
        }
        // away: input returned (idle fell under 2 s, or the lock lifted) → close
        if idle < 2 && !forced {
            let secs = Int(now.timeIntervalSince(awaySince!))
            out.append(.closed(seconds: secs))
            if pausedByIdle { out.append(.resumed(seconds: secs)) }
            awaySince = nil; pausedByIdle = false; lastExtend = nil
            return out
        }
        if let a = autoPauseAfter, now.timeIntervalSince(awaySince!) >= a {
            if !pausedByIdle { pausedByIdle = true; lastExtend = now; out.append(.pause) }
            else if let l = lastExtend, now.timeIntervalSince(l) >= 60 { lastExtend = now; out.append(.extend) }
        }
        return out
    }
    /// The lock screen or sleep: away at once, until `unforce` (unlock, wake) lets input close it.
    mutating func force(at now: Date) -> [Event] {
        forced = true
        guard awaySince == nil else { return [] }
        awaySince = now; return [.opened(now)]
    }
    mutating func unforce() { forced = false }
    mutating func reset() { awaySince = nil; pausedByIdle = false; lastExtend = nil; forced = false }
}

/// X3 · X5: the words the watcher puts in the DWELL and PREVIOUS lines.
enum CatcherWords {
    static func ordinal(_ n: Int) -> String {
        let s = n % 100
        let suffix = (s >= 11 && s <= 13) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }
    static func ago(_ seconds: TimeInterval) -> String {
        let m = Int(seconds / 60)
        return m < 1 ? "just now" : m < 60 ? "\(m) min ago" : "\(m / 60) h \(m % 60) min ago"
    }
    /// "in front 11 min this session · 3rd visit · last distraction 14 min ago"
    static func dwell(inFront: TimeInterval, visits: Int, lastDistraction: TimeInterval?) -> String {
        var parts = ["in front \(inFront < 60 ? "\(Int(inFront)) s" : "\(Int(inFront / 60)) min") this session"]
        if visits > 1 { parts.append("\(ordinal(visits)) visit") } else { parts.append("1st visit") }
        if let d = lastDistraction { parts.append("last distraction \(ago(d))") }
        return parts.joined(separator: " · ")
    }
    /// "Overleaf — project.tex · work · 2 min ago"
    static func previous(name: String, title: String, verdict: String?, left: TimeInterval) -> String {
        [title.isEmpty ? name : "\(name) — \(String(title.prefix(50)))", verdict ?? "not judged", ago(left)].joined(separator: " · ")
    }
}
