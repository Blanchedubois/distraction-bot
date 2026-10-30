import Foundation
import CoreGraphics

// HUD0 (PLAN_SESSION_HUD §2.3, §4): the overlay's rules as pure code, so `scripts/hud-check.swift` can judge them without
// starting the app. No AppKit, no SwiftUI, no Store: geometry, the click-or-drag rule, the display choice, the alert line,
// the card queue, the results-card floor and the once-a-minute cache.

enum HUDRules {
    // MARK: geometry (R0's, moved here from `MiniPanel` so the check needs no window)

    static let width: CGFloat = 340, collapsed: CGFloat = 64   // HUD2: 340 for accuracy · rank · combo · XP (was 320)
    static let inset = CGPoint(x: 16, y: 12)
    static let lineRow: CGFloat = 16, pillRow: CGFloat = 26, fieldRow: CGFloat = 30
    static let taskRow: CGFloat = 22   // HUD4: one checklist line
    static let drawerPadding: CGFloat = 12, rowGap: CGFloat = 8

    static func drawerHeight(rows: [CGFloat]) -> CGFloat { drawerPadding * 2 + rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * rowGap }
    /// The pill's own rectangle inside a frame: the top 64 pt for a top corner, the bottom 64 pt for a bottom one.
    static func pillRect(in frame: CGRect, bottom: Bool) -> CGRect {
        CGRect(x: frame.minX, y: bottom ? frame.minY : frame.maxY - collapsed, width: width, height: collapsed)
    }
    /// The frame for a state, anchored on the pill: a top corner grows down, a bottom corner grows up.
    static func frame(expanded: Bool, drawerHeight: CGFloat, pill: CGRect, bottom: Bool) -> CGRect {
        let h = expanded ? collapsed + drawerHeight : collapsed
        return CGRect(x: pill.minX, y: bottom ? pill.minY : pill.maxY - h, width: width, height: h)
    }
    /// True when the window's frame is the one the panel set itself (so a move notification is not a drag).
    static func isProgrammatic(_ frame: CGRect, last: CGRect?) -> Bool {
        guard let last else { return false }
        return abs(frame.minX - last.minX) < 0.5 && abs(frame.minY - last.minY) < 0.5 && abs(frame.width - last.width) < 0.5 && abs(frame.height - last.height) < 0.5
    }
    /// The corner's anchor for a collapsed pill in a visible frame.
    static func anchor(in v: CGRect, right: Bool, bottom: Bool) -> CGPoint {
        CGPoint(x: right ? v.maxX - width - inset.x : v.minX + inset.x, y: bottom ? v.minY + inset.y : v.maxY - collapsed - inset.y)
    }

    // MARK: B1 — a click is a click

    /// A mouse-down that travels this far before the mouse-up is a drag; anything shorter is a click.
    static let dragThreshold: CGFloat = 4
    static func isDrag(from a: CGPoint, to b: CGPoint) -> Bool { hypot(b.x - a.x, b.y - a.y) >= dragThreshold }
    /// The ✕'s hit rectangle in the pill's own coordinates (origin top-left, y down): the gesture surface leaves it alone.
    static let closeRect = CGRect(x: width - 34, y: 6, width: 28, height: 28)

    // MARK: B2 — the HUD stays on its display

    /// The display the HUD lives on: the one it was put on when still attached, else the main one. The pointer plays no part.
    static func display(saved: String?, attached: [String], main: String) -> String {
        if let saved, attached.contains(saved) { return saved }
        return attached.contains(main) ? main : (attached.first ?? main)
    }

    // MARK: B3 — an alert borrows a line; it never opens the drawer

    /// One deadline, no timers racing: the line is shown while `now < until`.
    struct AlertLine: Equatable {
        private(set) var text: String?
        private(set) var until: Date = .distantPast
        mutating func show(_ t: String, now: Date, seconds: Double) { text = t; until = now.addingTimeInterval(seconds) }
        func current(now: Date) -> String? { now < until ? text : nil }
    }

    // MARK: B5/B6 — cards wait their turn

    /// The warning card's queue. A card for the subject already shown replaces it in place (the follow-up rewrites its own card);
    /// a card for another subject waits, once per subject, and is shown when the current one is answered. Nothing is dropped
    /// without its owner hearing about it: `drop` hands back the dropped entries so their callbacks can be told.
    struct CardQueue<Card> {
        private(set) var current: (key: String, card: Card)?
        private(set) var waiting: [(key: String, card: Card)] = []
        enum Placement: Equatable { case shown, replaced, queued, requeued }
        /// Returns where the card went; `.replaced`/`.requeued` mean an earlier card with that key was superseded.
        mutating func offer(_ key: String, _ card: Card) -> Placement {
            if current == nil { current = (key, card); return .shown }
            if current?.key == key { current = (key, card); return .replaced }
            if let i = waiting.firstIndex(where: { $0.key == key }) { waiting[i] = (key, card); return .requeued }
            waiting.append((key, card)); return .queued
        }
        /// The current card is done: the next waiting one (if any) becomes current and is returned.
        mutating func advance() -> (key: String, card: Card)? {
            current = waiting.isEmpty ? nil : waiting.removeFirst()
            return current
        }
        /// Remove one card by key, wherever it is; true when it was the current one.
        mutating func remove(_ key: String) -> Bool {
            if current?.key == key { current = nil; return true }
            waiting.removeAll { $0.key == key }; return false
        }
        /// Everything goes (End, a pause): the dropped cards, current first.
        mutating func drop() -> [(key: String, card: Card)] {
            let all = (current.map { [$0] } ?? []) + waiting
            current = nil; waiting = []
            return all
        }
        var isEmpty: Bool { current == nil && waiting.isEmpty }
    }

    // MARK: B8 — no results for a false start

    static let resultsFloorSeconds: Double = 60
    static func showsResults(elapsed: Double) -> Bool { elapsed >= resultsFloorSeconds }

    // MARK: HUD3 — breaks (PLAN_SESSION_HUD §3.3, §5a Q8–Q9)

    static let breakChoices = [5, 10, 15]
    /// Hard and extreme: breaks only from an earned bank — 5 min per 25 clean min, at most 20 in hand.
    static let bankEvery = 25 * 60, bankStep = 5, bankCap = 20
    static func breakBank(cleanSeconds: Int, usedMinutes: Int) -> Int {
        let earned = max(0, cleanSeconds) / bankEvery * bankStep
        return max(0, min(bankCap, earned - max(0, usedMinutes)))
    }
    /// Below hard any break is free; hard and extreme may take one only from the bank.
    static func mayBreak(minutes: Int, hard: Bool, bank: Int) -> Bool { minutes > 0 && (!hard || minutes <= bank) }
    /// Seconds of work since the last rest: summed back from now until a break, a pause or an away stretch of 2 min or more.
    static let restSeconds = 120
    static func workSinceRest(_ pieces: [(off: Bool, seconds: Int)]) -> Int {
        var total = 0
        for p in pieces.reversed() { if p.off { if p.seconds >= restSeconds { break } } else { total += p.seconds } }
        return total
    }
    /// `a break is due` once per stretch of work, after `every` minutes (0 = never).
    static func breakDue(workSeconds: Int, everyMinutes: Int, alreadySaid: Bool) -> Bool { everyMinutes > 0 && !alreadySaid && workSeconds >= everyMinutes * 60 }
    /// The strict ladder (three detours in 15 min) is five minutes on the goal, drawn by the HUD (HUD0 B5's card is gone).
    static let lockSeconds: Double = 300
    /// `7:42`
    static func clock(_ seconds: Double) -> String { let s = max(0, Int(seconds.rounded(.up))); return "\(s / 60):" + String(format: "%02d", s % 60) }

    // MARK: HUD5 — alerts while you work (PLAN_SESSION_HUD §3.5, §5a Q12–Q13)

    enum AlertRoute: String, CaseIterable { case off, hud, notify
        var label: String { switch self { case .off: return "off"; case .hud: return "in the HUD"; case .notify: return "notification" } }
    }
    enum AlertKind: String, CaseIterable {
        case drifting, restless, accuracy, checkIn, breakDue, breakOver, timeLeft, combo
        var label: String {
            switch self {
            case .drifting: return "Drifting"; case .restless: return "Restless"; case .accuracy: return "Accuracy dropped"; case .checkIn: return "Check-in"
            case .breakDue: return "Break due"; case .breakOver: return "Break over"; case .timeLeft: return "Time left"; case .combo: return "Combo tier"
            }
        }
        var help: String {
            switch self {
            case .drifting: return "the judge leans towards a detour but is not sure enough for the card"
            case .restless: return "many app switches in ten minutes"
            case .accuracy: return "the session's accuracy falls below your line"
            case .checkIn: return "every few minutes: still on the current task?"
            case .breakDue: return "a long stretch without a break"
            case .breakOver: return "a break ran out"
            case .timeLeft: return "5 minutes before a planned end"
            case .combo: return "×2 and ×3 reached"
            }
        }
        /// §3.5's table.
        var defaultRoute: AlertRoute { switch self { case .checkIn: return .off; case .breakOver: return .notify; default: return .hud } }
        /// Seconds before the same kind (and key) may fire again.
        var throttle: Double { switch self { case .drifting: return 300; case .restless: return 600; default: return 0 } }
    }
    static func route(_ k: AlertKind, settings: [String: String]) -> AlertRoute { settings[k.rawValue].flatMap(AlertRoute.init(rawValue:)) ?? k.defaultRoute }

    /// When each kind (and key) last fired; `allow` says whether it may fire now and records it if so.
    struct AlertThrottle {
        private(set) var last: [String: Date] = [:]
        mutating func allow(_ k: AlertKind, key: String = "", now: Date) -> Bool {
            let id = k.rawValue + "|" + key
            if let t = last[id], now.timeIntervalSince(t) < k.throttle { return false }
            last[id] = now; return true
        }
    }
    /// Q13: a verdict that leans towards a detour without reaching the card's threshold.
    static let driftFloor = 0.5
    static func isDrifting(distracted: Bool, confidence: Double, threshold: Double) -> Bool { distracted && confidence >= driftFloor && confidence < threshold }
    /// Fires once when accuracy crosses below `line`, re-armed once it is back at or above it. Silent for the first 5 min of judged time.
    struct Crossing {
        private(set) var armed = true
        mutating func check(accuracy: Double, line: Double, possibleSeconds: Int) -> Bool {
            if accuracy >= line { armed = true; return false }
            guard armed, possibleSeconds >= 300 else { return false }
            armed = false; return true
        }
    }
    /// The check-in: due every `everyMinutes` of the session's clock (0 = never) since the last one.
    static func checkInDue(elapsed: Double, last: Double, everyMinutes: Int) -> Bool { everyMinutes > 0 && elapsed - last >= Double(everyMinutes * 60) }
    /// Time left: once, in the 5 minutes before a planned end.
    static func timeLeftDue(remaining: Double?, said: Bool) -> Bool { guard let r = remaining, !said else { return false }; return r > 0 && r <= 300 }

    // MARK: B7 — computed once a minute

    /// A value recomputed only when its key (the minute, plus whatever else it depends on) changes.
    struct MinuteCache<Value> {
        private var key: String?
        private var value: Value?
        private(set) var computations = 0
        mutating func get(_ key: String, _ make: () -> Value) -> Value {
            if key == self.key, let v = value { return v }
            let v = make(); self.key = key; value = v; computations += 1; return v
        }
        static func minuteKey(_ d: Date, extra: String = "") -> String { "\(Int(d.timeIntervalSince1970 / 60))|\(extra)" }
    }
}
