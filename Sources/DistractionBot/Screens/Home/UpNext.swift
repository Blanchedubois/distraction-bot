import SwiftUI

// PLAN_PLANNING §3.2 (P1, R9 · R10; IMPACT_ANALYSIS §3 "Up next"): one mono line under Home's greeting sentence naming what is
// next — the next calendar event today, the nearest due objective within seven days, K's planned item for today — two items
// at most, ` · ` joined; nothing → the view is empty and the line is absent. Click on an event → Calendar; on an objective → queue it.

struct UpNext: View {
    @Environment(Store.self) private var store
    var now: Date = Date()

    struct Item: Identifiable, Equatable {
        enum Kind: Equatable { case event, objective(String) }
        let kind: Kind
        let text: String
        var id: String { text }
    }

    /// `CS 150 lecture · 19:30 · in 40 min` — the first feed instance today that has not ended; `now` while it runs.
    @MainActor static func nextEvent(store: Store, now: Date) -> Item? {
        let end = StudyDay.end(of: now)
        guard let i = store.feed.instances(from: now.addingTimeInterval(-4 * 3600), to: end).filter({ !$0.allDay && $0.end > now }).min(by: { $0.start < $1.start }) else { return nil }
        let until = i.start.timeIntervalSince(now)
        let when = until <= 0 ? "now" : until < 3600 ? "in \(Int(until / 60)) min" : "in \(Int(until / 3600)) h \(String(format: "%02d", Int(until / 60) % 60))"
        return Item(kind: .event, text: "\(i.title) · \(clock(i.start)) · \(when)")
    }
    /// `Homework #8 due Fri` — the nearest open objective due within seven days (or overdue), in danger-free words; the chip carries the colour.
    @MainActor static func nextDue(store: Store, now: Date) -> Item? {
        guard let o = store.nextDue(now: now, within: JumpBackInOrder.dueWindowDays), let l = store.dueState(o, now: now).label(due: o.due) else { return nil }
        return Item(kind: .objective(o.id), text: "\(o.title) \(l)")
    }
    @MainActor static func items(store: Store, now: Date) -> [Item] {
        // K's planned item for today (`Store.plan(for:)`) joins here when it lands; until then the two sources above
        [nextEvent(store: store, now: now), nextDue(store: store, now: now)].compactMap { $0 }.prefix(2).map { $0 }
    }

    var body: some View {
        let items = Self.items(store: store, now: now)
        if !items.isEmpty {
            HStack(spacing: Space.tight) {
                MonoLabel("up next", color: Theme.muted2)
                ForEach(Array(items.enumerated()), id: \.element.id) { n, it in
                    if n > 0 { MonoLabel("·", color: Theme.muted2) }
                    Button { open(it) } label: { MonoLabel(it.text, color: Theme.ink).lineLimit(1) }.buttonStyle(.plain).help(help(it))
                }
            }
        }
    }
    private func help(_ it: Item) -> String { switch it.kind { case .event: return "Open the calendar"; case .objective: return store.session == nil ? "Queue it" : "Open the objective" } }
    private func open(_ it: Item) {
        switch it.kind {
        case .event: store.go(.calendar)
        case .objective(let id):
            guard let o = store.objective(id) else { return }
            if store.session != nil { store.open(objective: id) } else { store.prepareSession(objective: o, source: "up-next") }
        }
    }
}
