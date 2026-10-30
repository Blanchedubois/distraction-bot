import SwiftUI

// PLAN_OBJECTIVE_OVERVIEW V1: the Log screen's row and its kind → label / pill maps, shared with the objective's study log.

extension Event {
    /// The short word the Log shows for a kind (`closed`, `verdict`, `warned`, …).
    var label: String {
        switch kind {
        case "block.close": return "closed"; case "block.shield": return "shielded"; case "block.warn": return "warned"
        case "look": return "look"; case "look.skip": return "withheld"; case "judge.verdict": return "verdict"; case "judge.answer": return "answer"; case "judge.followup": return "follow-up"
        case "judge.close": return "closed on verdict"
        case "objective.complete": return "completed"; case "objective.reopen": return "reopened"; case "objective.delete": return "deleted"
        case "web.search": return "search"; case "web.visit": return "page"; case "web.warn": return "warned"; case "web.block": return "blocked"; case "web.answer": return "answer"
        case "session.summary": return "summary"; case "usage": return "in front"; case "judge.detour": return "detour"
        case "session.start": return "started"; case "session.end": return "ended"; case "session.pause": return "paused"; case "session.scheduled": return "scheduled"; case "session.break": return "break"; case "skip": return "5 min"
        case "game": return "game"; case "task.add": return "task"; case "task.done": return "ticked"; case "task.undo": return "unticked"; case "task.remove": return "task removed"; case "task.carry": return "carried"; case "task.uncarry": return "not carried"; case "session.note": return "note"; case "session.resume": return "resumed"; case "ui.overlay": return "overlay"   // E1, E2
        // K0 (PLAN_STUDY_DAY §3.8): the UI usage rows; K2: the day's shutdown record
        case "ui.tab": return "tab"; case "ui.open": return "opened"; case "ui.door": return "door"; case "ui.reminder": return "reminder"   // ui.overlay is E's line above
        case "day.shutdown": return "shut down"
        default: return kind
        }
    }
    /// The pill colour the Log gives a kind.
    var pillKind: PillKind {
        switch kind {
        case "judge.verdict": return .accent; case "judge.answer": return .ok; case "judge.close": return .danger
        case "session.note": return .accent   // E2
        case "objective.complete": return .ok; case "objective.delete": return .danger
        case "web.warn": return .warn; case "web.block": return .danger; case "web.answer": return .ok
        case "block.close": return .danger; case "block.shield": return .accent; case "block.warn": return .warn; case "skip": return .warn
        default: return .neutral
        }
    }
}

/// One event as the Log draws it: `clock · kind pill · app or detail · detail · latency`.
struct EventRow: View {
    let event: Event
    var body: some View {
        let e = event
        HStack(spacing: Space.stack) {
            Text(clock(e.ts)).font(Type.data).foregroundStyle(Theme.muted2).frame(width: 64, alignment: .leading)
            Pill(e.label, kind: e.pillKind)
            Text(e.app.isEmpty ? e.detail : e.app).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
            if !e.app.isEmpty, !e.detail.isEmpty { Text(e.detail).font(Type.data).foregroundStyle(Theme.muted).lineLimit(1) }
            Spacer()
            if let ms = e.latencyMs { Text("\(ms) ms").font(Type.data).foregroundStyle(ms < 300 ? Theme.ok : Theme.warn) }
        }
        .rowPadding()
    }
}

/// The Log's filter choices, reused by the study log's expanded session.
enum EventFilter {
    static let options: [(String, String)] = [("all", "everything"), ("block", "app blocks"), ("web", "web"), ("judge", "judge"), ("look", "looks"), ("session", "sessions"), ("skip", "5-minute skips"), ("ui", "ui use"), ("day", "shutdowns")]   // K0: ui · K2: day
    /// R2 (PLAN_REWORK §3.3, D6): `everything` is the user's log — the `ui.` usage rows show only under their own pill.
    static func matches(_ e: Event, _ filter: String) -> Bool { filter == "all" ? !e.kind.hasPrefix("ui.") : e.kind.hasPrefix(filter) }
}
