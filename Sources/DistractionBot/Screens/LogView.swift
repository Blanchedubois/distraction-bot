import SwiftUI

struct LogView: View {
    @Environment(Store.self) private var store
    @State private var filter = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_FILTER"] ?? "all"   // M1: a render lands on that pill (onAppear never runs offscreen)

    private var shown: [Event] {
        // a query from Progress (an app, a host, a search) reads the whole range, not the last 300 rows
        let base: [Event] = store.logQuery.map { q in
            EventLog.shared.events(from: q.from, to: q.to ?? Date()).reversed().filter { e in
                q.text.isEmpty || e.app.localizedCaseInsensitiveContains(q.text) || e.detail.localizedCaseInsensitiveContains(q.text)
            }
        } ?? store.events
        return base.filter { EventFilter.matches($0, filter) }
    }

    var body: some View {
        Page(kicker: store.logQuery.map { q in q.title ?? "matching “\(q.text)” since \(q.from.formatted(date: .abbreviated, time: .shortened))" } ?? "every event, on this mac", title: "Log", trailing: AnyView(
            HStack(spacing: Space.stack) {
            if let q = store.logQuery { PillButton(text: "\(q.text.isEmpty ? (q.title ?? "session") : q.text) ×", kind: .accent) { store.logQuery = nil } }
            PillMenu(options: EventFilter.options, selection: $filter, leadingSymbol: "line.3.horizontal.decrease")
            }
        )) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(1, "Recent", note: "newest first", count: "\(shown.count)")
                VStack(spacing: Space.hair) {
                    if shown.isEmpty { EmptyState(symbol: "list.bullet.rectangle", text: "Nothing logged yet. Start a session on Home.") }
                    ForEach(shown) { e in EventRow(event: e) }   // the row and its kind maps live in Design/EventRow.swift (shared with the objective's study log, V1)
                }
                .padding(Space.stack)
                .card(watermark: "list.bullet.rectangle")
            }
        }
        .task { store.reloadLog() }
        .onAppear { if let f = store.logFilter { filter = f; store.logFilter = nil } }   // M1: a `go(.log, filter:)` door lands on that pill
    }
}
