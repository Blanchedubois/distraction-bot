import AppKit
import SwiftUI

/// The shield (§5a Q20): a Liquid Glass overlay in Jeff 2's style — one non-activating panel, centred on the screen
/// the pointer is on, above everything, on every Space. `.notice` (after a close) fades after 3 s; `.wall` (a shielded
/// app, hidden behind it) stays until answered: Back to work · 5 more minutes after 30 s · End session.
@MainActor
@Observable
final class Shield {
    static let shared = Shield()
    enum Mode { case wall, notice }

    var appName = ""
    var bundleID = ""
    var icon: NSImage?
    var attempts = 0
    var mode: Mode = .wall
    var shownAt = Date()
    weak var store: Store?
    private var panel: NSPanel?
    private var noticeTask: Task<Void, Never>?
    private(set) var isShowing = false

    static let size = NSSize(width: 600, height: 300)   // G5: 600 so three OverlayButtons fit on one row

    private func makePanel() -> NSPanel {
        let p = BannerPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: ShieldView(shield: self).environment(store!))
        return p
    }

    func show(app: NSRunningApplication, name: String, attempts: Int, mode: Mode) {
        appName = name; bundleID = app.bundleIdentifier ?? ""; icon = app.icon; self.attempts = attempts; self.mode = mode; shownAt = Date()
        noticeTask?.cancel()
        Log.write("shield show \(mode) \(name) attempt \(attempts)")
        let p = panel ?? makePanel()
        panel = p
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            p.setFrame(NSRect(origin: NSPoint(x: v.midX - Self.size.width / 2, y: v.midY - Self.size.height / 2 + 40), size: Self.size), display: true)
        }
        if !isShowing { isShowing = true; p.alphaValue = 0; p.orderFrontRegardless(); NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; p.animator().alphaValue = 1 } }
        MiniPanel.shared.suspend("shield")   // C3
        if mode == .notice {
            noticeTask = Task { try? await Task.sleep(for: .seconds(3)); if !Task.isCancelled, self.mode == .notice { hide() } }
        }
    }

    func hide() {
        noticeTask?.cancel()
        guard isShowing, let p = panel else { return }
        isShowing = false
        Log.write("shield hide")
        MiniPanel.shared.resume("shield")   // C3
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { Task { @MainActor in if !self.isShowing { p.orderOut(nil) } } })
    }
}

struct ShieldView: View {
    @Bindable var shield: Shield
    @Environment(Store.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let waited = ctx.date.timeIntervalSince(shield.shownAt)
            let wait: Double = (store.session?.strictness ?? .normal).profile.coolDown   // O4: the level's cool-down (hard and extreme: 120 s, B6)
            let canSkip = waited >= wait
            VStack(spacing: Space.card) {
                HStack(spacing: Space.loose) {
                    if let icon = shield.icon { Image(nsImage: icon).resizable().frame(width: 48, height: 48).opacity(shield.mode == .notice ? 0.7 : 1) }
                    VStack(alignment: .leading, spacing: Space.hair) {
                        MonoLabel(shield.mode == .notice ? "closed" : "blocked", color: Theme.danger)
                        Text(shield.mode == .notice ? "\(shield.appName) was closed" : "\(shield.appName) is blocked")
                            .font(Type.headline).foregroundStyle(Theme.ink)
                        if let s = store.session {
                            MonoLabel([s.ends.map { "until \(clock($0))" } ?? "until you stop", shield.attempts > 1 ? "\(shield.attempts) attempts" : nil].compactMap { $0 }.joined(separator: " · "), color: Theme.muted)
                        }
                    }
                    Spacer()
                }
                if let s = store.session {
                    VStack(alignment: .leading, spacing: Space.tight) {
                        MonoLabel("you said you were working on", color: Theme.muted)
                        Text(s.goal.isEmpty ? "—" : s.goal).font(Type.body).foregroundStyle(Theme.ink).lineLimit(2)
                        if let r = s.remaining { MonoLabel("\(minutes(r)) left", color: Theme.muted) }   // R1: one accent on the card (the kicker's danger)
                        if let sc = store.statsToday?.score, (store.statsToday?.focusedSeconds ?? 0) > 0 {   // E3 §3.4: what the detour costs
                            MonoLabel("today's score \(sc.total) · \(sc.word)", color: Theme.muted)   // R1: a figure, not a verdict
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if shield.mode == .wall {
                    WrapRow {   // R1 (D2): a long label wraps the row, never clips the card
                        button("Back to work", "arrow.uturn.backward", accent: true) { Shield.shared.hide() }
                        // E3 (PLAN_OVERLAY §3.4, §5a Q8.3): extensions are counted per app per session; the third is refused on strict and
                        // above, free below (G0 took the token price out)
                        let taken = store.watcher.extensions[shield.bundleID] ?? 0
                        let strictLevel = store.session?.strictness.isStrict == true
                        let refused = taken >= 2 && strictLevel
                        let label = !canSkip ? "5 more min in \(Int(wait - waited)) s"
                            : refused ? "no more today"
                            : "5 more minutes" + (taken > 0 ? " · \(AppWatcher.ordinal(taken + 1))" : "")
                        button(label, refused ? "hand.raised" : "hourglass") { store.watcher.allow(shield.bundleID, name: shield.appName) }
                        .disabled(!canSkip || refused).opacity(canSkip && !refused ? 1 : 0.5)
                        if store.session?.strictness.isStrict != true { button("End session", "stop.fill") { store.requestEnd() } }
                    }
                }
            }
            .padding(Space.sheet)
            .frame(width: Shield.size.width, height: Shield.size.height, alignment: .top)
            .modifier(GlassBack(watermark: "shield.lefthalf.filled", accent: Theme.danger))
        }
    }

    private func button(_ t: String, _ sym: String, accent: Bool = false, _ action: @escaping () -> Void) -> some View { OverlayButton(t, sym, accent: accent, action) }
}
