import SwiftUI

/// M1 (PLAN_STRUCTURE §3.2): the occasional look's settings, as two sections of the Judge page — `look` (interval · scope · vision model ·
/// the last look) and `privateList` — not a tab of its own. The struct keeps its file and name so the catcher plan's additive rows survive.
struct ScreenWatchView: View {
    @Environment(Store.self) private var store
    @State private var busy = false
    static let privateList = Rules.privateApps
    /// Which of the two sections this instance draws, and its number on the page.
    enum Part { case look, privateList }
    var part: Part = .look
    var number = 2

    var body: some View {
        switch part {
        case .look: look
        case .privateList: privateSection
        }
    }

    private var look: some View {
        @Bindable var look = store.screenLook
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(number, "The look", note: "a 1280-px capture of the front window, described in memory, never kept", count: look.looks == 0 ? nil : "\(look.looks) this session") {
                PillButton(text: "looks ↗", kind: .accent) { store.go(.log, filter: "look") }   // M1: the look rows live on the Log's `looks` pill
            }
            VStack(alignment: .leading, spacing: Space.loose) {
                labelled("every") { PillMenu(options: [(2, "2 min"), (3, "3 min"), (5, "5 min"), (10, "10 min")], selection: $look.intervalMinutes, leadingSymbol: "timer") }
                labelled("at") { PillMenu(options: [("front", "front window only"), ("display", "the whole display")], selection: $look.scope, leadingSymbol: "macwindow") }
                labelled("with") { PillMenu(options: (store.ollamaModels.filter { $0.contains("vl") || $0.contains("vision") || $0 == look.model }.isEmpty ? [look.model] : store.ollamaModels.filter { $0.contains("vl") || $0.contains("vision") || $0 == look.model }).map { ($0, $0) }, selection: $look.model, leadingSymbol: "eye") }
                MonoLabel("skipped when the title or url settled it within the interval · never on the private list")
                HStack(spacing: Space.stack) {
                    ActionButton(title: busy ? "Looking…" : "Look now", symbol: "eye", accent: true) {
                        Task { busy = true; let d = await store.screenLook.look(reason: "button"); busy = false; if d == nil { store.fail("Nothing captured — see the log") } }
                    }.disabled(busy || store.session == nil).opacity(store.session == nil ? 0.5 : 1)
                    if store.session == nil { MonoLabel("start a session on home to look", color: Theme.muted2) }
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                if let d = look.lastDescription, let at = look.lastAt {
                    MonoLabel("last look · \(look.lastApp) · \(clock(at)) · \(look.lastTiming)")
                    Text(d).font(Type.body).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                } else {
                    MonoLabel("no look yet · the description is judged and shown here, never the image", color: Theme.muted2)
                }
            }
            .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
            .card(watermark: "display")
        }
    }

    private var privateSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(number, "Private list", note: "never captured or read", count: "\(Self.privateList.count)")
            WrapRow { ForEach(Self.privateList, id: \.self) { Pill($0, kind: .neutral, dot: true, accent: Theme.danger) } }
                .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                .card(watermark: "eye.slash")
        }
    }

    private func labelled<V: View>(_ l: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(spacing: Space.stack) { MonoLabel(l).frame(width: 44, alignment: .leading); v() }
    }
}
