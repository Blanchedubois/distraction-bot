import SwiftUI
import AppKit

/// The block list (§3.2): every installed app with its strength. Pinned apps (Discord by default) sit on top, never blocked, and can be unpinned.
/// M1 (PLAN_STRUCTURE §3.2): section 1 of the Rules page, not a page of its own; the Installed list is collapsed to the apps
/// running now with a `show all N ↗` pill (§5a Q3.3); the filter comes from the page head.
struct AppsView: View {
    @Environment(Store.self) private var store
    var filter = ""
    @State private var apps: [InstalledApp] = []
    @State private var showAll = false
    @Environment(\.narrow) private var narrow

    private var listed: [InstalledApp] { apps.filter { store.rules.apps[$0.bundleID] != nil && !store.rules.isPinned($0.bundleID) } }
    private var pinnedApps: [InstalledApp] { store.rules.pinned.map { id in apps.first { $0.bundleID == id } ?? InstalledApp(name: id.split(separator: ".").last.map(String.init) ?? id, bundleID: id, icon: NSWorkspace.shared.icon(forFile: "/Applications"), running: false) } }
    private var matching: [InstalledApp] { apps.filter { !store.rules.isPinned($0.bundleID) && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)) } }
    /// Running now while collapsed; everything that matches the filter once `show all` is on or a filter is typed.
    private var installed: [InstalledApp] { showAll || !filter.isEmpty ? matching : matching.filter(\.running) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(1, "Apps", note: "close · shield · warn · allowed (never judged) · pinned apps are never blocked", count: "\(listed.count)")
            VStack(spacing: Space.hair) {
                ForEach(pinnedApps) { a in row(a, locked: true) }
                if listed.isEmpty { EmptyState(symbol: "app.badge.checkmark", text: "No apps on the list. Pick close, shield or warn below.") }
                ForEach(listed) { a in row(a, locked: false) }
            }
            .padding(Space.stack)
            .card(accent: Theme.accent, watermark: "xmark.shield")
        }
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(1, showAll || !filter.isEmpty ? "Installed" : "Running now", note: "no rule = the judge decides against your goal", count: "\(installed.count)") {
                if filter.isEmpty { PillButton(text: showAll ? "running now" : "show all \(apps.count) ↗", kind: .neutral) { withAnimation { showAll.toggle() } } }
            }
            .opacity(0.9)
            VStack(spacing: Space.hair) {
                if installed.isEmpty { EmptyState(symbol: "app.badge.checkmark", text: filter.isEmpty ? "Nothing else is running." : "No app matches “\(filter)”.") }
                ForEach(installed) { a in row(a, locked: false) }
            }
            .padding(Space.stack)
            .card(watermark: "app.badge.checkmark")
        }
        .task { apps = InstalledApp.scan() }
    }

    private func row(_ a: InstalledApp, locked: Bool) -> some View {
        HStack(spacing: Space.loose) {
            Image(nsImage: a.icon).resizable().frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(a.name).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                if !narrow { Text(a.bundleID).font(Type.data).foregroundStyle(Theme.muted2).lineLimit(1) }
            }
            Spacer()
            if a.running { Pill("running", kind: .ok, dot: true) }
            // X1 (PLAN_CATCHER §3.2): the class pill — the table's class, or the one you set (utility · communication are budgeted, never judged on dwell)
            // R5 (PLAN_REWORK §3.6): the word in full in a 150-pt column; an unknown class reads `class ▾`, a ghost that opens the menu
            PillMenu(options: AppClass.allCases.map { ($0, $0 == .unknown ? "class" : $0.rawValue) },
                     selection: Binding(get: { Classifier.classOf(app: a.bundleID, name: a.name) }, set: { c in
                         if c == Classifier.classOf(app: a.bundleID, name: "") && store.rules.classes[a.bundleID] == nil { return }
                         store.rules.classes[a.bundleID] = c
                     }),
                     kind: store.rules.classes[a.bundleID] != nil ? .accent : .neutral, width: 150)
            if let d = store.rules.taught[a.bundleID], store.rules.apps[a.bundleID] == .allowed { MonoLabel("taught \(d.formatted(.dateTime.day().month(.abbreviated)))", color: Theme.muted2) }   // X6a
            if locked {
                Pill("pinned", kind: .on, accent: Theme.ink)
                PillButton(text: "unpin", kind: .neutral) { store.rules.pinned.removeAll { $0 == a.bundleID } }
            }
            else {
                PillMenu(options: [(Strength.judge, "judge"), (.allowed, "allowed"), (.warn, "warn"), (.shield, "shield"), (.close, "close")],
                         selection: Binding(get: { store.rules.strength(for: a.bundleID) }, set: { v in
                             if v == .judge { store.rules.apps.removeValue(forKey: a.bundleID) } else { store.rules.apps[a.bundleID] = v }
                         }),
                         kind: kind(store.rules.strength(for: a.bundleID)), width: 96)
            }
        }
        .rowPadding()
    }

    private func kind(_ s: Strength) -> PillKind {
        switch s { case .judge: return .neutral; case .allowed: return .ok; case .warn: return .warn; case .shield: return .accent; case .close: return .danger }
    }
}

struct InstalledApp: Identifiable {
    let name: String
    let bundleID: String
    let icon: NSImage
    var running = false
    var id: String { bundleID }

    /// /Applications and /System/Applications, one level deep, plus whatever regular app is running now.
    static func scan() -> [InstalledApp] {
        let running = Dictionary(NSWorkspace.shared.runningApplications.compactMap { a in a.bundleIdentifier.map { ($0, a) } }, uniquingKeysWith: { a, _ in a })
        var seen: [String: InstalledApp] = [:]
        for dir in ["/Applications", "/System/Applications"].map({ URL(fileURLWithPath: $0) }) {
            for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where u.pathExtension == "app" {
                guard let b = Bundle(url: u), let id = b.bundleIdentifier, !Rules.alwaysAllowed.contains(id) else { continue }
                let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? u.deletingPathExtension().lastPathComponent
                seen[id] = InstalledApp(name: name, bundleID: id, icon: NSWorkspace.shared.icon(forFile: u.path), running: running[id] != nil)
            }
        }
        for (id, a) in running where seen[id] == nil && a.activationPolicy == .regular && !Rules.alwaysAllowed.contains(id) {
            seen[id] = InstalledApp(name: a.localizedName ?? id, bundleID: id, icon: a.icon ?? NSImage(), running: true)
        }
        return seen.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
