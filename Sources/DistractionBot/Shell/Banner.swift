import AppKit
import SwiftUI

/// The warning (§5a Q21): a large non-activating glass card in the middle of the screen the pointer is on, over a
/// click-through veil that dims that one display, with three answers. Ignored after 20 s.
/// E0 (PLAN_OVERLAY §3.1): the card takes key focus for its 20 s so `B · W · S · ?` answer it (the document's app stays
/// active, it loses typing — §5 Q1); `W` opens the scoped row `this once · this session · always`, `S` the snooze menu
/// `5 · 10 · 25 min`, `?` the why disclosure (the prompt's FRONT · CLASS · DWELL · USAGE · RECENT lines), ⌘T the
/// tell-the-judge field. Escape and ⌘. do nothing: the card stays until answered (§5a Q24).
@MainActor
@Observable
final class Banner {
    static let shared = Banner()
    var title = ""
    var text = ""
    var reason = ""
    var shownAt = Date()
    private var panel: NSPanel?
    private var veil: NSWindow?                       // E0: one veil, the pointer's screen only
    private var hideTask: Task<Void, Never>?
    private var keyMonitor: Any?                      // E0: the keys, while the card is key
    private var onAnswer: (String) -> Void = { _ in }
    static let size = NSSize(width: 760, height: 300)   // R5 (PLAN_REWORK §3.6): the empty band between the facts line and the buttons is gone

    var timeout: TimeInterval? = 20
    /// Hard mode (B6): no snooze.
    var hard = false

    // E0: the card's sub-states
    /// The scope of a "This is work" answer (X's `AnswerScope` takes over the meaning; nested here so the names never collide).
    enum Scope: String, CaseIterable { case once = "this once", session = "this session", always = "always" }
    enum Mode { case answers, scope, snooze, tell }
    var mode: Mode = .answers
    var why = false
    var told = ""
    /// Set by the last `work` / `snooze` answer; `Store.warn`'s callback reads them (the shim until X's `answer(_:scope:)`).
    var lastScope: Scope?
    var snoozeMinutes = 10
    /// What the `judge.answer` row carries after `<answer> · <what>` (X's row format: `· scope <s>`).
    var answerSuffix: String {
        if let s = lastScope { return " · scope \(String(describing: s))" }
        if snoozeMinutes != 10 { return " · \(snoozeMinutes) min" }
        return ""
    }
    /// A pill from `why?` → `wrong → teach`: the scope row also files a told line.
    var teachFromWhy = false
    static let snoozeChoices = [5, 10, 25]

    /// `timeout` nil: the card stays until a button is pressed. Otherwise, with no answer in time, "ignored" is reported
    /// and the card stays up (§5a Q24: the caller then blocks and rewrites the card).
    // HUD0 B5/B6 (PLAN_SESSION_HUD §2.3): cards wait their turn. A card for the subject on screen replaces it in place (the
    // follow-up rewrites its own card); a card for another subject waits and is shown when the current one is answered, so no
    // callback is dropped and no detour is left open. `key` is the subject (`site:host`, `app:id`, `ladder`); nil = the item text.
    struct Card { let title: String; let text: String; let reason: String; let timeout: TimeInterval?; let onAnswer: (String) -> Void }
    private var queue = HUDRules.CardQueue<Card>()
    /// B9: who had the keyboard when the card took it, for the log line at hide (the user's window test reads it).
    private var frontBefore = ""

    func show(title: String, text: String, reason: String, timeout: TimeInterval? = 20, key: String? = nil, onAnswer: @escaping (String) -> Void) {
        let k = key ?? text
        let card = Card(title: title, text: text, reason: reason, timeout: timeout, onAnswer: onAnswer)
        switch queue.offer(k, card) {
        case .shown, .replaced: present(card)
        case .queued, .requeued: Log.write("banner queued · \(k) · behind \(queue.current?.key ?? "?")")
        }
    }

    /// Removes the card for `key` only (the ladder's own 5 minutes); the next waiting card, if any, comes up.
    func hide(key: String) {
        if queue.remove(key) { dismiss(); presentNext() } else { Log.write("banner hide · \(key) was waiting, removed") }
    }
    /// End and pause: every card goes, current and waiting, without answers (as before HUD0).
    func clear() {
        let dropped = queue.drop()
        if !dropped.isEmpty { Log.write("banner clear · \(dropped.map(\.key).joined(separator: ", "))") }
        onAnswer = { _ in }
        dismiss()
    }
    private func presentNext() {
        if let next = queue.current ?? queue.advance() { present(next.card) }
    }

    private func present(_ card: Card) {
        let (title, text, reason, timeout, onAnswer) = (card.title, card.text, card.reason, card.timeout, card.onAnswer)
        self.title = title; self.text = text; self.reason = reason; self.onAnswer = onAnswer; self.timeout = timeout; shownAt = Date()
        if panel?.isVisible != true { frontBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }   // B9
        mode = .answers; why = false; told = ""; lastScope = nil; snoozeMinutes = 10; teachFromWhy = false   // E0
        let p = panel ?? makePanel()
        panel = p
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            p.setFrame(NSRect(origin: NSPoint(x: v.midX - Self.size.width / 2, y: v.midY - Self.size.height / 2 + 30), size: Self.size), display: true)
        }
        // E0: the veil dims only the display the card is on (§8.2: the second screen with the slides keeps 0 %)
        if veil == nil {
            let w = NSWindow(contentRect: screen?.frame ?? .zero, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            w.level = .statusBar; w.isOpaque = false; w.backgroundColor = NSColor.black.withAlphaComponent(0.3); w.hasShadow = false
            w.ignoresMouseEvents = true; w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.isReleasedWhenClosed = false
            veil = w
        }
        if let w = veil, let sc = screen { w.setFrame(sc.frame, display: true); w.alphaValue = 0; w.orderFrontRegardless(); NSAnimationContext.runAnimationGroup { c in c.duration = 0.25; w.animator().alphaValue = 1 } }
        p.alphaValue = 0; p.orderFrontRegardless(); NSAnimationContext.runAnimationGroup { c in c.duration = 0.25; p.animator().alphaValue = 1 }
        // E0 (§5 Q1): key focus without activating the app — the panel is non-activating, so the document keeps its app in front
        p.becomesKeyOnlyIfNeeded = false
        p.makeKey()
        installKeys()
        MiniPanel.shared.suspend("banner")   // C3
        hideTask?.cancel()
        if let timeout {
            hideTask = Task { try? await Task.sleep(for: .seconds(timeout)); if !Task.isCancelled { let f = self.onAnswer; self.onAnswer = { _ in }; f("ignored") } }
        }
    }

    /// HUD0: the answer runs **before** the next card is shown (the callback reads `lastScope`/`snoozeMinutes`, which a new card
    /// resets), and the callback may itself rewrite this subject's card (`escalate`), which then shows at once.
    func answer(_ a: String) {
        let f = onAnswer; onAnswer = { _ in }
        if let k = queue.current?.key { _ = queue.remove(k) }
        dismiss()
        f(a)
        if queue.current == nil { presentNext() }
    }

    // E0: the scoped and timed answers (the shim: every scope sends today's "work" until X's `answer(_:scope:)` lands)
    func answer(work scope: Scope) {
        lastScope = scope
        if teachFromWhy, !text.isEmpty { Store.current?.told("\(text) — not a distraction") }
        answer("work")
    }
    func answer(snooze minutes: Int) { snoozeMinutes = minutes; answer("snooze") }
    /// The told line: filed, then the one verdict is re-run; the card updates in place or clears on `work`.
    func tell() {
        let t = told.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { mode = .answers; return }
        told = ""; mode = .answers
        Store.current?.told(t)
        reason = "told the judge · asking again…"
        Store.current?.rejudgeLast()
    }
    func toggle(_ m: Mode) { mode = mode == m ? .answers : m }

    /// The card on screen goes (the caller has handled its answer); the next waiting one comes up.
    func hide() {
        if let k = queue.current?.key { _ = queue.remove(k) }
        dismiss()
        presentNext()
    }

    private func dismiss() {
        hideTask?.cancel()
        removeKeys()
        panel?.becomesKeyOnlyIfNeeded = true
        if panel?.isKeyWindow == true { panel?.resignKey() }
        panel?.orderOut(nil)
        veil?.orderOut(nil)
        mode = .answers; why = false; teachFromWhy = false
        MiniPanel.shared.resume("banner")   // C3
        // HUD0 B9 (suspected: the document may not get the keyboard back): what had it before, what has it now
        Log.write("banner hide · front before \(frontBefore) · front now \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") · this app key window \(NSApp.keyWindow.map { $0.title.isEmpty ? String(describing: type(of: $0)) : $0.title } ?? "none")")
    }

    /// The card's facts, from the judge's last call (X fills `appClass` and `dwell`; nil before X5).
    var facts: Judge.Facts? { Store.current?.judge.lastFacts }
    /// HUD5 (PLAN_SESSION_HUD §3.5, §5a Q15): what the answer costs, said honestly — a slip drops one level, a miss resets.
    /// Only with a combo worth keeping (×2 or more); nil otherwise.
    var stake: String? {
        guard let st = Store.current, let s = st.session else { return nil }
        let g = st.liveGame(s)
        guard g.multiplier >= 2 else { return nil }
        return "×\(g.multiplier) · \(g.combo / 60) min combo — back to work keeps ×\(g.multiplier - 1) · no answer drops to ×1"
    }
    /// The strict ladder's break card is about the goal, not an item: no facts line, no why.
    var showsFacts: Bool { facts != nil && !title.hasPrefix("Three detours") }
    /// `Dia · entertainment · 4 min in front · 3rd visit` (§3.1); before X: `Dia · 4 min in front` from the watcher's seconds.
    var factsLine: String {
        guard let f = facts else { return "" }
        var parts = [f.frontApp]
        if let c = f.appClass { parts.append(c) }
        if let d = f.dwell { parts.append(d) }
        else if let w = Store.current?.watcher, w.frontName == f.frontApp, let s = w.frontSeconds[w.frontBundle], s > 0 { parts.append("\(minutes(TimeInterval(s))) in front") }
        return parts.joined(separator: " · ")
    }
    /// The prompt's lines for `why?` — never SCREEN, never page text (`Judge.factsLine` keeps that rule), plus RECENT.
    var whyLines: [String] {
        guard let f = facts else { return [] }
        var lines = Judge.factsLine(f).components(separatedBy: " ¦ ").filter { !$0.isEmpty }
        if !f.recent.isEmpty { lines.append("RECENT: " + f.recent.joined(separator: " · ")) }
        return Array(lines.prefix(5))
    }
    /// §3.1: no sound for a budget card (X's utility and communication classes), judged within the last 15 s.
    static func isBudgetCard(_ f: Judge.Facts?, judgedAt: Date?) -> Bool {
        guard let f, let c = f.appClass, let t = judgedAt, Date().timeIntervalSince(t) < 15 else { return false }
        return c == "utility" || c == "communication"
    }

    // MARK: keys (E0)

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let p = self.panel, p.isKeyWindow else { return e }
            return self.handle(e) ? nil : e
        }
    }
    private func removeKeys() { if let m = keyMonitor { NSEvent.removeMonitor(m) }; keyMonitor = nil }

    /// True when the key was taken. Escape and ⌘. close a sub-row and otherwise do nothing; the card never dismisses on a key.
    private func handle(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let ch = (e.charactersIgnoringModifiers ?? "").lowercased()
        if e.keyCode == 53 || (cmd && ch == ".") { if mode != .answers { mode = .answers; told = "" }; return true }
        if cmd && ch == "t" { toggle(.tell); return true }
        if mode == .tell { return false }                      // the field has the keys; Return submits it
        if cmd { return false }
        switch (mode, ch) {
        case (.scope, "1"): answer(work: .once); return true
        case (.scope, "2"), (.scope, "\r"): answer(work: .session); return true
        case (.scope, "3"): answer(work: .always); return true
        case (.snooze, "1"): answer(snooze: 5); return true
        case (.snooze, "2"), (.snooze, "\r"): answer(snooze: 10); return true
        case (.snooze, "3"): answer(snooze: 25); return true
        case (_, "b"): answer("back"); return true
        case (_, "w"): toggle(.scope); return true
        case (_, "s"): if !hard { toggle(.snooze) }; return true
        case (_, "?"), (_, "/"): if showsFacts { why.toggle() }; return true
        default: return false
        }
    }

    private func makePanel() -> NSPanel {
        let p = BannerPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: BannerView(banner: self))
        return p
    }
}

final class BannerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct BannerView: View {
    @Bindable var banner: Banner
    @Environment(\.snapshot) private var snapshot
    @FocusState private var fieldFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: Space.sheet) {
            HStack(spacing: Space.loose) {
                Icon("exclamationmark.bubble.fill", .card, color: Theme.warn)
                MonoLabel(banner.title == "Still here" ? "you said back to work" : (banner.title == "Blocked" ? "no answer" : "the judge thinks this is a detour"), color: Theme.muted)
                Spacer()
                if let t = banner.timeout { MonoLabel("answer within \(Int(t)) s or it is blocked", color: Theme.muted) }
                else { MonoLabel("stays until you answer", color: Theme.muted) }
            }
            VStack(alignment: .leading, spacing: Space.stack) {
                Text(banner.text).font(Type.headline).foregroundStyle(Theme.ink).lineLimit(2).minimumScaleFactor(0.7)
                if banner.why && banner.showsFacts { whyBlock }                     // E0: the why disclosure replaces the reason line
                else { Text(banner.reason).font(Type.body).foregroundStyle(Theme.muted).lineLimit(2) }
                if banner.showsFacts, let st = banner.stake { Text(st).font(Type.data).foregroundStyle(Theme.muted).lineLimit(1) }   // HUD5: the combo at stake
                HStack(spacing: Space.stack) {                                      // E0: the second mono line — what the judge saw — and the two ghost pills
                    if banner.showsFacts, !banner.factsLine.isEmpty { Text(banner.factsLine).font(Type.data).foregroundStyle(Theme.muted).lineLimit(1) }
                    Spacer(minLength: 0)
                    if banner.showsFacts { GhostPill(banner.why ? "hide why" : "why", key: "?") { banner.why.toggle() } }
                    GhostPill("tell the judge", key: "⌘T") { banner.toggle(.tell) }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.stack) {
                button("Back to work", "arrow.uturn.backward", key: "b", accent: true) { banner.answer("back") }
                button("This is work", "checkmark", key: "w") { banner.toggle(.scope) }
                if !banner.hard { button("Snooze", "moon.zzz", key: "s") { banner.toggle(.snooze) } }
                Spacer()
            }
            if banner.mode != .answers { subRow }   // E0: the scope row, the snooze menu or the field, under the buttons
        }
        .padding(Space.sheet)
        .frame(width: Banner.size.width, height: Banner.size.height, alignment: .topLeading)
        .modifier(GlassBack(watermark: "exclamationmark.bubble", accent: Theme.warn))
        .onChange(of: banner.mode) { _, m in fieldFocused = m == .tell }
    }

    private var whyBlock: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            ForEach(banner.whyLines, id: \.self) { l in Text(l).font(Type.data).foregroundStyle(Theme.muted).lineLimit(1) }
            GhostPill("wrong → teach") { banner.teachFromWhy = true; banner.mode = .scope }.padding(.top, Space.tight)
        }
    }

    @ViewBuilder private var subRow: some View {
        switch banner.mode {
        case .scope:
            HStack(spacing: Space.stack) {
                MonoLabel("this is work —", color: Theme.muted)
                GhostPill("this once", key: "1") { banner.answer(work: .once) }
                GhostPill("this session", key: "2 ↩") { banner.answer(work: .session) }
                GhostPill("always", key: "3") { banner.answer(work: .always) }
                if banner.teachFromWhy { MonoLabel("· the judge is told too", color: Theme.muted) }
            }
            .help("Until the catcher's scoped answers land, every scope allows it as today's “This is work” does; the row is kept on the log.")
        case .snooze:
            HStack(spacing: Space.stack) {
                MonoLabel("snooze —", color: Theme.muted)
                ForEach(Array(Banner.snoozeChoices.enumerated()), id: \.offset) { i, m in
                    GhostPill("\(m) min", key: i == 1 ? "2 ↩" : "\(i + 1)") { banner.answer(snooze: m) }
                }
            }
        case .tell:
            HStack(spacing: Space.stack) {
                MonoLabel("tell the judge —", color: Theme.muted)
                if snapshot {   // ImageRenderer paints a TextField as a yellow box; the render shows the empty well
                    Text(" ").font(Type.body).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.07)))
                } else {
                    TextField("one line, in your words · return re-runs the verdict", text: $banner.told)
                        .textFieldStyle(.plain).font(Type.body)
                        .rowPadding()
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.07)))
                        .focused($fieldFocused)
                        .onSubmit { banner.tell() }
                        .onAppear { fieldFocused = true }
                }
            }
        case .answers: EmptyView()
        }
    }

    private func button(_ t: String, _ sym: String, key: String? = nil, accent: Bool = false, _ action: @escaping () -> Void) -> some View { OverlayButton(t, sym, key: key, accent: accent, action) }
}

/// The one button of the three overlays (banner, escape card, shield): `ActionButton`'s type and insets on glass —
/// the accent fill for the primary answer, a 10 % ink fill for the rest. G5 (PLAN_DESIGN_CLEANUP §3.4, §5a Q5).
/// E0: `key` draws the answer's key as a small cap at the trailing end.
struct OverlayButton: View {
    let title: String; let symbol: String; var key: String? = nil; var accent = false; let action: () -> Void
    init(_ title: String, _ symbol: String, key: String? = nil, accent: Bool = false, _ action: @escaping () -> Void) { self.title = title; self.symbol = symbol; self.key = key; self.accent = accent; self.action = action }
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.stack) {
                Image(systemName: symbol).font(.system(size: Icon.Size.row.rawValue, weight: .semibold))   // lint-ok: Icon.row, colour from the button
                Text(title.uppercased()).font(Type.button).tracking(Type.pillTracking).lineLimit(1).fixedSize()
                if let key { KeyCap(key, light: accent) }
            }
            .padding(.horizontal, Space.buttonH).padding(.vertical, Space.buttonV)
            .background(Capsule().fill(accent ? Theme.accent : Theme.ink.opacity(0.10)))
            .foregroundStyle(accent ? .white : Theme.ink)
        }
        .buttonStyle(.plain)
    }
}

/// A key's name in a small square, as a hint on a button or pill (E0).
struct KeyCap: View {
    let key: String; var light = false
    init(_ key: String, light: Bool = false) { self.key = key; self.light = light }
    var body: some View {
        Text(key.uppercased()).font(Type.pill).lineLimit(1).fixedSize()
            .padding(.horizontal, Space.tight).frame(minWidth: 16, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill((light ? Color.white : Theme.ink).opacity(0.14)))
            .opacity(0.8)
    }
}

/// The cards' small pill (the mini panel's capsule recipe, shared from E0): small caps on a 10 % ink fill, an optional key cap.
/// Theme ink rather than `.primary`: the hierarchical styles do not resolve over `GlassBack` in an offscreen render.
struct GhostPill: View {
    let text: String; var key: String? = nil; let action: () -> Void
    init(_ text: String, key: String? = nil, _ action: @escaping () -> Void) { self.text = text; self.key = key; self.action = action }
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.tight) {
                Text(text.uppercased()).font(Type.pill).tracking(Type.pillTracking).lineLimit(1)
                if let key { KeyCap(key) }
            }
            .padding(.horizontal, Space.pillH).padding(.vertical, Space.pillV)
            .background(Capsule().fill(Theme.ink.opacity(0.10)))
            .foregroundStyle(Theme.ink)
        }
        .buttonStyle(.plain)
    }
}

/// Liquid Glass on macOS 26 (the regular material before it), with Ledger's card signature under it:
/// the graph-paper wash and a large tilted watermark cut off at the bottom-right.
struct GlassBack: ViewModifier {
    var watermark: String? = nil
    var accent: Color = Theme.accent
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 28, style: .continuous) }
    func body(content: Content) -> some View {
        let signature = ZStack(alignment: .bottomTrailing) {
            GraphWash(spacing: 30).opacity(0.7)   // lint-ok: the wash grid pitch, not a layout gap
            if let watermark { Watermark(symbol: watermark, size: 220, color: accent, opacity: 0.10).offset(x: 24, y: 36) }
        }
        .clipShape(shape)
        if #available(macOS 26, *) { content.background(signature).glassEffect(.regular, in: shape) }
        else { content.background(signature).background(.regularMaterial, in: shape) }
    }
}
