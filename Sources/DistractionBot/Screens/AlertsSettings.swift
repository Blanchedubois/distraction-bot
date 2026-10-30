import SwiftUI

/// HUD5 (PLAN_SESSION_HUD §3.5): Settings → Behaviour → Alerts while you work — each kind off · in the HUD · notification, the
/// accuracy line and the check-in interval. Choosing `notification` for any kind asks macOS for permission then (once).
struct AlertsSettings: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: Space.stack) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text("Alerts while you work").font(Type.strong).foregroundStyle(Theme.ink)
                Text("Where each one goes: off, a line on the mini panel (the menu bar when it is hidden), or a macOS notification. The warning card is not one of these; it stays for a confident detour.")
                    .font(Type.body).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(HUDRules.AlertKind.allCases, id: \.self) { k in
                HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(k.label).font(Type.body).foregroundStyle(Theme.ink)
                        Text(k.help).font(Type.data).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: Space.card)
                    if k == .accuracy {
                        PillMenu(options: [80, 85, 90, 95].map { ($0, "below \($0) %") }, selection: $store.settings.accuracyLine, leadingSymbol: "scope")
                    }
                    if k == .checkIn {
                        PillMenu(options: [(15, "every 15 min"), (25, "every 25 min"), (45, "every 45 min"), (0, "never")], selection: $store.settings.checkInMinutes, leadingSymbol: "clock")
                    }
                    PillMenu(options: HUDRules.AlertRoute.allCases.map { ($0, $0.label) },
                             selection: Binding(get: { HUDRules.route(k, settings: store.settings.alerts) },
                                                set: { r in store.settings.alerts[k.rawValue] = r.rawValue; if r == .notify { Alerts.shared.prepare() } }),
                             leadingSymbol: "bell")
                }
            }
        }
    }
}
