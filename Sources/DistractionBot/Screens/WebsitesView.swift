import SwiftUI

/// M1 (PLAN_STRUCTURE §3.2): sections 2 Sites · 3 Searches · 4 Allowed of the Rules page (the struct keeps its file and name so the
/// catcher plan's additive rows survive). The old §4 "What I searched" is the Log's `web` filter, behind the `what I searched ↗` door.
struct WebsitesView: View {
    @Environment(Store.self) private var store
    var filter = ""
    @State private var newSite = ""
    @State private var newStrength: Strength = .warn
    @State private var newTerm = ""
    @State private var newAllowed = ""

    private var siteRows: [(String, Strength)] { store.rules.sites.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }.filter { filter.isEmpty || $0.0.localizedCaseInsensitiveContains(filter) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(2, "Sites", note: "safari · dia · judge · warn · block · allowed", count: "\(siteRows.count)") {
                PillButton(text: "what I searched ↗", kind: .accent) { store.go(.log, filter: "web") }   // M1: pages and searches read during sessions, with the verdicts
            }
            VStack(spacing: Space.hair) {
                if siteRows.isEmpty { EmptyState(symbol: "globe", text: filter.isEmpty ? "No site rules yet." : "No site matches “\(filter)”.") }
                ForEach(siteRows, id: \.0) { host, s in
                    HStack {
                        Text(host).font(Type.strong).foregroundStyle(Theme.ink)
                        Spacer()
                        PillMenu(options: [(Strength.judge, "judge"), (.warn, "warn"), (.close, "block"), (.allowed, "allowed")], selection: Binding(get: { s }, set: { store.rules.sites[host] = $0 }), kind: s == .warn ? .warn : (s == .close ? .danger : (s == .judge ? .accent : .neutral)), width: 92)
                        Button { store.rules.sites.removeValue(forKey: host) } label: { Image(systemName: "trash").foregroundStyle(Theme.muted2) }.buttonStyle(.plain)
                    }
                    .rowPadding()
                }
                Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, Space.loose).padding(.vertical, Space.tight)
                HStack(spacing: Space.stack) {
                    PillField(placeholder: "add a site, e.g. youtube.com", text: $newSite, width: 220)
                    PillMenu(options: [(Strength.judge, "judge"), (.warn, "warn"), (.close, "block")], selection: $newStrength)
                    PillButton(text: "add", kind: .accent) { add() }
                }
                .rowPadding()
            }
            .padding(Space.stack)
            .card(watermark: "globe")
        }
        Pair {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(3, "Searches", note: "google · youtube · duckduckgo · bing · reddit · amazon", count: "\(store.rules.searchTerms.count)")
                VStack(alignment: .leading, spacing: Space.stack) {
                    MonoLabel("a search containing one of these is blocked")
                    if store.rules.searchTerms.isEmpty { EmptyState(symbol: "magnifyingglass", text: "No search-term rules yet.") }
                    else { WrapRow { ForEach(store.rules.searchTerms, id: \.self) { t in removable(t, kind: .danger) { store.rules.searchTerms.removeAll { $0 == t } } } } }
                    HStack(spacing: Space.stack) {
                        PillField(placeholder: "add a term", text: $newTerm, width: 180)
                        PillButton(text: "add", kind: .accent) { let t = newTerm.trimmingCharacters(in: .whitespaces).lowercased(); if !t.isEmpty, !store.rules.searchTerms.contains(t) { store.rules.searchTerms.append(t) }; newTerm = "" }
                    }
                }
                .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                .card(watermark: "magnifyingglass")
            }
        } second: {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(4, "Allowed", note: "never judged · \"this is work\" adds here", count: "\(store.rules.allowedSites.count)")
                VStack(alignment: .leading, spacing: Space.stack) {
                    if store.rules.allowedSites.isEmpty { EmptyState(symbol: "checkmark.seal", text: "Nothing allowed explicitly yet.") }
                    else { WrapRow { ForEach(store.rules.allowedSites, id: \.self) { h in removable(h, kind: .ok) { store.forgetTaught(h) } } } }
                    // X6a (PLAN_CATCHER §3.7): what "this is work · always" taught, with the date; forget = judged again
                    let taught = store.rules.taught.filter { store.rules.allowedSites.contains($0.key) }.sorted { $0.value > $1.value }
                    if !taught.isEmpty {
                        WrapRow { ForEach(taught, id: \.key) { k, d in
                            HStack(spacing: Space.tight) { MonoLabel("\(k) · taught \(d.formatted(.dateTime.day().month(.abbreviated)))", color: Theme.muted); PillButton(text: "forget") { store.forgetTaught(k) } }
                        } }
                    }
                    HStack(spacing: Space.stack) {
                        PillField(placeholder: "add a site", text: $newAllowed, width: 180)
                        PillButton(text: "add", kind: .accent) { let h = clean(newAllowed); if !h.isEmpty, !store.rules.allowedSites.contains(h) { store.rules.allowedSites.append(h) }; newAllowed = "" }
                    }
                }
                .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                .card(watermark: "checkmark.seal")
            }
        }
    }

    private func add() {
        let h = clean(newSite)
        guard !h.isEmpty else { return }
        store.rules.sites[h] = newStrength; newSite = ""
    }
    private func clean(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespaces).lowercased()
        if let u = URL(string: h), let host = u.host { h = host }
        return h.replacingOccurrences(of: "www.", with: "")
    }
    private func removable(_ t: String, kind: PillKind, remove: @escaping () -> Void) -> some View {
        HStack(spacing: Space.tight) { Pill(t, kind: kind); Button(action: remove) { Icon("xmark.circle.fill", .small, color: Theme.muted2) }.buttonStyle(.plain) }
    }
}
