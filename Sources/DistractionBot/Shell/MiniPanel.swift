import AppKit
import SwiftUI

/// The mini panel (PLAN_CURRENT_SESSION §3.7, C3): a small non-activating glass pill in a corner of the screen the
/// pointer is on, while a session runs and the app's window is not in front. Glyph · title · progress · time left · the
/// score · the verdict dot. E1 (PLAN_OVERLAY §3.2, R26): the drawer is the session's remote — Now · the verdict and `wrong` ·
/// pause 5 · 10 · 25 / break / end / + note · Next · shut down the day. ✕ hides it for the session. The pill's top 14 pt is a
/// drag handle; the corner comes from Settings and the dragged offset is remembered per display.
///
/// R0 (PLAN_REWORK §3.1, the hover glitch): **a click opens the drawer; hover only brightens the ✕.** The panel is framed
/// **once per state**, before the drawer's transition, from a height computed from the rows it will have — never measured
/// from the animating view, never from inside `onHover`. A frame the panel set itself is remembered (`lastProgrammaticFrame`)
/// so `windowMoved` counts only a real drag. Never in snapshot mode.
@MainActor
@Observable
final class MiniPanel {
    static let shared = MiniPanel()
    weak var store: Store?

    static let width: CGFloat = HUDRules.width, collapsed: CGFloat = HUDRules.collapsed   // HUD0: the rules live in Model/HUDRules.swift
    static let inset = NSPoint(x: HUDRules.inset.x, y: HUDRules.inset.y)
    static let handle: CGFloat = 14                   // E1: the drag band at the top of the pill
    /// R0: the drawer's rows have fixed heights, so the frame is known before the drawer exists.
    static let lineRow: CGFloat = 16, pillRow: CGFloat = 26, fieldRow: CGFloat = 30, taskRow: CGFloat = HUDRules.taskRow
    static let drawerPadding: CGFloat = Space.loose, rowGap: CGFloat = Space.stack

    /// The id of the session the user hid the panel for (§5a Q8): hidden for the rest of it, back for the next.
    private(set) var hiddenForSession: String?
    /// The drawer is open. Set through `setExpanded(_:animated:)`, which frames the panel first.
    private(set) var expanded = false { didSet { if expanded != oldValue, !expanded { teachOpen = false; noteOpen = false; addingTask = false } } }
    var teachOpen = false { didSet { if teachOpen != oldValue, expanded { reframe() } } }
    var noteOpen = false { didSet { if noteOpen != oldValue { if expanded { reframe() }; if noteOpen { takeKey() } else if !addingTask { releaseKey() } } } }   // HUD0 B4
    var note = ""
    /// HUD4: the `add a task` field is open (it takes the keyboard as the note does).
    var addingTask = false { didSet { if addingTask != oldValue { if expanded { reframe() }; if addingTask { takeKey() } else if !noteOpen { releaseKey() } } } }
    var taskDraft = ""
    /// HUD4: the task list changed (added, removed): the open drawer is framed for its new rows now, not at the next tick.
    func refreshFrame() { if expanded { reframe() } }
    /// HUD4: ⌃⌥T — open the drawer on the `add a task` field.
    func startAddingTask() { if isHidden { showAgain() }; if !expanded { setExpanded(true, animated: true) }; addingTask = true }
    func submitTask() {
        let t = taskDraft; taskDraft = ""
        store?.addTask(t)
        if SessionTasks.clean(t) == nil || (store?.session?.tasks.count ?? 0) >= SessionTasks.maxTasks { addingTask = false }   // empty Return closes; full list closes
    }
    private var suspenders: Set<String> = []          // the warning card, the shield, the escape card (§3.9)
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var attached = false
    private var isShowing = false
    private var screenOrigin: NSPoint?                // where it last went; HUD0 B2: it moves only when its own display's anchor changes (unplugged, resized)
    private var saveTask: Task<Void, Never>?
    /// R0: the last frame this class gave the panel; `windowMoved` ignores a notification that matches it.
    private var lastProgrammaticFrame: NSRect?

    private var snapshot: Bool { ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] != nil }

    enum Corner: String, CaseIterable { case topRight, topLeft, bottomRight, bottomLeft
        var label: String { switch self { case .topRight: return "top right"; case .topLeft: return "top left"; case .bottomRight: return "bottom right"; case .bottomLeft: return "bottom left" } }
        var bottom: Bool { self == .bottomRight || self == .bottomLeft }
    }
    /// The corner: Settings, or `DBOT_SNAPSHOT_CORNER` for a render (prefs untouched).
    var corner: Corner {
        if let c = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_CORNER"].flatMap(Corner.init(rawValue:)) { return c }
        return Corner(rawValue: store?.settings.miniPanelCorner ?? "") ?? .topRight
    }

    /// Called once by the Store: the activation notifications and the window's open/close drive `refresh()`.
    func attach(store: Store) {
        self.store = store
        guard !attached, !snapshot else { return }
        attached = true
        Hotkeys.apply(enabled: store.settings.hotkeys)   // HUD2: the session keys (Settings → Behaviour)
        let nc = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    /// Hidden by the user for the running session (the menu items read it).
    var isHidden: Bool { guard let s = store?.session else { return false }; return hiddenForSession == s.id }

    /// The app's own window is in front: the app is active and a main window is on screen and not miniaturised.
    private var appInFront: Bool {
        guard NSApp.isActive else { return false }
        return NSApp.windows.contains { $0.title == "Distraction Bot" && $0.isVisible && !$0.isMiniaturized }
    }

    private var shouldShow: Bool {
        guard !snapshot, let store, let s = store.session, store.settings.miniPanel, suspenders.isEmpty, hiddenForSession != s.id else { return false }
        return !appInFront
    }

    /// Re-evaluates and shows or hides; called on activation changes, each second from `Store.tick()`, and after every setting.
    func refresh() {
        if shouldShow {
            let p = panel ?? makePanel()
            panel = p
            let origin = targetOrigin(height: p.frame.height)
            if !isShowing {
                move(p, to: origin); screenOrigin = origin
                isShowing = true
                p.alphaValue = 0; p.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; p.animator().alphaValue = 1 }
                Log.write("mini panel show")
            } else if let last = screenOrigin, abs(last.x - origin.x) > 1 || abs(last.y - origin.y) > 1, !expanded {
                // HUD0 B2: its display changed under it (unplugged, a resolution change, a new corner or offset) — never because the pointer moved
                move(p, to: origin); screenOrigin = origin
            }
        } else if isShowing, let p = panel {
            isShowing = false
            if expanded { setExpanded(false, animated: false) }
            NSAnimationContext.runAnimationGroup({ c in c.duration = 0.15; p.animator().alphaValue = 0 },
                                                 completionHandler: { Task { @MainActor in if !self.isShowing { p.orderOut(nil) } } })
            Log.write("mini panel hide")
        }
    }

    /// Once a second from the Store (the pointer's screen, a session ending, a setting flipped elsewhere). R0: an open drawer whose
    /// rows changed under it (the queue, the calendar, the shutdown offer) is re-framed here — one frame per state, not per tick.
    func tick() {
        guard attached else { return }
        refresh()
        watchGame()   // HUD2: the moments (a tier reached, the combo lost)
        if expanded, let p = panel, abs(p.frame.height - (Self.collapsed + drawerHeight)) > 0.5 { reframe() }
    }

    // MARK: HUD2 — the moments (PLAN_SESSION_HUD §3.2): on events only, never on a timer

    /// The badge reads `×3!` and springs once until this time.
    private(set) var tierUpUntil: Date = .distantPast
    @ObservationIgnored private var watched: (session: String, multiplier: Int, combo: Int, hits: Int)?
    /// Compares the live game with the last second's: a higher multiplier is a tier reached; a new hit that cost a level or a combo of
    /// a minute or more is `combo lost · <what>` on the pill's second line for 4 s. A new or relaunched session starts silent.
    func watchGame() {
        guard let store, let s = store.session else { watched = nil; crossing = HUDRules.Crossing(); timeLeftSaid = false; lastCheckIn = 0; return }
        let g = store.liveGame(s)
        let hits = g.slips + g.misses
        defer { watched = (s.id, g.multiplier, g.combo, hits) }
        guard let w = watched, w.session == s.id else { crossing = HUDRules.Crossing(); timeLeftSaid = false; lastCheckIn = s.elapsed; return }
        // HUD5: the combo tier — the badge's moment is the HUD's way of saying it; a notification only when chosen
        let comboRoute = HUDRules.route(.combo, settings: store.settings.alerts)
        if g.multiplier > w.multiplier {
            if comboRoute != .off { tierUpUntil = Date().addingTimeInterval(2) }
            if comboRoute == .notify { Alerts.shared.fire(.combo, "×\(g.multiplier) · \(g.combo / 60) min of focus in a row") }
            EventLog.shared.ui("overlay", "combo ×\(g.multiplier)")
        }
        if hits > w.hits, let h = store.liveHits.last, w.multiplier > 1 || w.combo >= 60 {
            attention("combo lost · \(h.what.isEmpty ? h.kind.rawValue : h.what)", seconds: 4)
        }
        // HUD5: accuracy below your line, once per crossing (silent for the first 5 judged minutes)
        if crossing.check(accuracy: SessionGame.shown(g), line: Double(store.settings.accuracyLine), possibleSeconds: g.possible) {
            Alerts.shared.fire(.accuracy, "accuracy \(String(format: "%.1f", SessionGame.shown(g))) % — below \(store.settings.accuracyLine)")
        }
        // HUD5: 5 minutes before a planned end, once
        if HUDRules.timeLeftDue(remaining: s.remaining, said: timeLeftSaid) { timeLeftSaid = true; Alerts.shared.fire(.timeLeft, "5 min left · \(s.goal.isEmpty ? "the session" : s.goal)") }
        // HUD5: the check-in, every N minutes of the session (off by default)
        if !s.paused, HUDRules.checkInDue(elapsed: s.elapsed, last: lastCheckIn, everyMinutes: store.settings.checkInMinutes) {
            lastCheckIn = s.elapsed
            Alerts.shared.fire(.checkIn, "still on \(SessionTasks.current(s.tasks) ?? (s.goal.isEmpty ? "it" : s.goal))? · ⌃⌥Space to tick it", seconds: 8)
        }
        // HUD3: `50 min in · a break is due`, once per stretch of work (a break, a pause or 2 min away starts a new one)
        guard !s.paused else { dueSaid = false; return }
        let pieces = store.liveSpans(s, now: Date()).filter { $0.kind != .short }.map { (off: $0.kind == .away || $0.kind == .paused, seconds: $0.seconds) }
        let work = HUDRules.workSinceRest(pieces)
        if work < HUDRules.restSeconds { dueSaid = false }
        if HUDRules.breakDue(workSeconds: work, everyMinutes: store.settings.breakDueMinutes, alreadySaid: dueSaid) {
            dueSaid = true
            Alerts.shared.fire(.breakDue, "\(work / 60) min in · a break is due", seconds: 8)   // HUD5: routed
        }
    }
    @ObservationIgnored private var dueSaid = false
    @ObservationIgnored private var crossing = HUDRules.Crossing()   // HUD5
    @ObservationIgnored private var timeLeftSaid = false
    @ObservationIgnored private var lastCheckIn: Double = 0

    // MARK: the drawer's open and close (R0)

    /// Opens or closes the drawer. Opening frames the panel for the full drawer **before** the transition; closing frames it
    /// collapsed **after** the transition has run. The pill's edge never moves.
    func setExpanded(_ open: Bool, animated: Bool) {
        guard open != expanded else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let spring = Animation.spring(duration: 0.3, bounce: 0.1)
        if open {
            reframe(expanded: true)
            if animated, !reduceMotion { withAnimation(spring) { expanded = true } } else { expanded = true }
        } else {
            if animated, !reduceMotion { withAnimation(spring) { expanded = false } completion: { self.reframe(expanded: false) } }
            else { expanded = false; reframe(expanded: false) }
        }
        if open { EventLog.shared.ui("overlay", "minipanel drawer") }
    }
    func toggleDrawer() { setExpanded(!expanded, animated: true) }

    /// The rows the drawer has in the current state, as heights (§3.1: Now · verdict · [teach] · actions · [note] · [next] · [shut down]).
    var drawerRows: [CGFloat] {
        var rows: [CGFloat] = [Self.lineRow, Self.lineRow, Self.lineRow, Self.pillRow]   // HUD2: combo · best/today/streak/left · Now · verdict
        // HUD4: one line per task, then `add a task` (a field while typing), unless the list is full
        let tasks = store?.session?.tasks.count ?? 0
        rows += Array(repeating: Self.taskRow, count: tasks)
        if tasks < SessionTasks.maxTasks { rows.append(addingTask ? Self.fieldRow : Self.taskRow) }
        if teachOpen { rows.append(Self.pillRow) }
        rows.append(Self.pillRow)
        if noteOpen { rows.append(Self.fieldRow) }
        if nextLine != nil { rows.append(Self.lineRow) }
        return rows
    }
    var drawerHeight: CGFloat { Self.drawerHeight(rows: drawerRows) }
    static func drawerHeight(rows: [CGFloat]) -> CGFloat { HUDRules.drawerHeight(rows: rows) }   // HUD0

    /// The pill's own rectangle inside a frame: the top 64 pt for a top corner, the bottom 64 pt for a bottom one.
    static func pillRect(in frame: NSRect, corner: Corner) -> NSRect { HUDRules.pillRect(in: frame, bottom: corner.bottom) }   // HUD0
    /// The frame for a state, anchored on the pill: a top corner grows down from the pill's top edge, a bottom corner grows up from its bottom edge.
    static func frame(expanded: Bool, drawerHeight: CGFloat, pill: NSRect, corner: Corner) -> NSRect { HUDRules.frame(expanded: expanded, drawerHeight: drawerHeight, pill: pill, bottom: corner.bottom) }   // HUD0
    /// True when the window's frame is the one this class set (so `didMove` is not a drag).
    static func isProgrammatic(_ frame: NSRect, last: NSRect?) -> Bool { HUDRules.isProgrammatic(frame, last: last) }   // HUD0

    private func reframe() { reframe(expanded: expanded) }
    private func reframe(expanded open: Bool) {
        guard let p = panel else { return }
        let pill = Self.pillRect(in: p.frame, corner: corner)
        let f = Self.frame(expanded: open, drawerHeight: drawerHeight, pill: pill, corner: corner)
        guard !Self.isProgrammatic(p.frame, last: f) else { return }
        lastProgrammaticFrame = f
        p.setFrame(f, display: true, animate: false)
    }

    // HUD7: R0's `frameCheck` moved to `scripts/hud-check.swift` (pure, over `HUDRules`), with the HUD2–HUD4 rows added.

    // MARK: hide, suspend, doors

    /// ✕: gone for the rest of this session (R0: no question asked; the reason, when a caller has one, goes on the row).
    func hideForSession(reason: String?) {
        guard let s = store?.session else { return }
        hiddenForSession = s.id
        EventLog.shared.add("session.minipanel", detail: "hidden")
        EventLog.shared.ui("overlay", "minipanel hidden · \(reason ?? "✕")")
        refresh()
    }
    func hideForSession() { hideForSession(reason: nil) }
    /// "Show Mini Panel" from the menu bar or the Session menu.
    func showAgain() { hiddenForSession = nil; EventLog.shared.add("session.minipanel", detail: "shown"); refresh() }
    func toggleHidden() { if isHidden { showAgain() } else { hideForSession() } }

    /// The warning card, the shield and the escape card take the screen; the panel stays out of their way (§3.9).
    func suspend(_ who: String) { suspenders.insert(who); refresh() }
    func resume(_ who: String) { suspenders.remove(who); refresh() }

    /// Brings the app's window back (the end card's `next` uses it).
    func openApp() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title == "Distraction Bot" }) { w.makeKeyAndOrderFront(nil) }
        else { NSApp.sendAction(#selector(NSResponder.newWindowForTab(_:)), to: nil, from: nil) }
        refresh()
    }

    /// E1: `+ note` — Return files `session.note · <text>` (shown on the end card and the shutdown).
    func fileNote() {
        let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
        note = ""; noteOpen = false
        guard !t.isEmpty else { return }
        EventLog.shared.add("session.note", detail: t)
        store?.reloadLog()
    }
    /// E1: `wrong` on the last verdict — the judge is told, in the scope's words (X's scoped answer takes over the meaning).
    func teach(_ scope: Banner.Scope) {
        teachOpen = false
        guard let v = store?.judge.lastVerdict, let f = store?.judge.lastFacts else { return }
        let item = f.title.isEmpty ? f.frontApp : "\(f.frontApp): \(f.title.prefix(60))"
        store?.told(v.distracted ? "\(item) — not a distraction (\(scope.rawValue))" : "\(item) — a distraction (\(scope.rawValue))")
    }

    // MARK: the drawer's lines (read by the view; `nextLine` also decides a row's presence)

    /// R2 (PLAN_REWORK §3.3, D16): a line that takes the Now line's place for 6 s — X3's nudge (`restless · 15 switches in 10 min`) or X4's
    /// away return (`away 22 min — paused · resume below`). The panel must be on screen; otherwise the Store keeps its window toast.
    /// HUD0 B3: one deadline (`HUDRules.AlertLine`), no tasks racing, and **never the drawer**: the line takes the pill's time text
    /// (and the drawer's Now line when it is open) until it runs out; the 1-s TimelineView redraws it away.
    private(set) var alert = HUDRules.AlertLine()
    var attentionLine: String? { alert.current(now: Date()) }
    var visible: Bool { isShowing }
    func attention(_ text: String, seconds: Double = 6) { alert.show(text, now: Date(), seconds: seconds) }

    /// `Dia · overleaf.com · 11 min · busy` — X3's `switchWord` joins when the session is not calm (R0).
    var nowLine: String {
        if let a = attentionLine { return a }
        guard let store else { return "watching" }
        let w = store.watcher
        guard !w.frontName.isEmpty else { return "watching" }
        var parts = [w.frontName]
        if let h = store.webWatcher.current?.host, !h.isEmpty, BrowserReader.browsers.contains(w.frontBundle) { parts.append(h) }
        if let secs = w.frontSeconds[w.frontBundle], secs >= 60 { parts.append(minutes(TimeInterval(secs))) }
        let word = store.switchWord
        if word != "calm" { parts.append(word) }
        return parts.joined(separator: " · ")
    }
    /// Next: the queued session, else the next calendar event today.
    /// HUD0 B7: computed once a minute (or when the queue changes), not on every render and tick — the feed expands 745 events.
    var nextLine: String? {
        guard let store else { return nil }
        if let q = store.queued { return "next · \(q.goal)" }
        let now = Date()
        return nextCache.get(HUDRules.MinuteCache<String?>.minuteKey(now, extra: store.settings.icsURL.isEmpty ? "" : "feed")) {
            let end = Calendar.current.date(byAdding: .hour, value: 12, to: now)!
            return store.feed.instances(from: now, to: end).first(where: { !$0.allDay && $0.end > now }).map { "next · \($0.title) · \(clock($0.start))" }
        }
    }
    @ObservationIgnored private var nextCache = HUDRules.MinuteCache<String?>()

    // MARK: the window

    /// The corner's anchor for a collapsed pill on the pointer's screen, plus the remembered offset, clamped to the visible frame (E1).
    private func targetOrigin(height: CGFloat) -> NSPoint {
        let screen = homeScreen   // HUD0 B2: was the pointer's screen, so the pill jumped between the two displays
        let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let c = corner
        var o = NSPoint(x: c == .topRight || c == .bottomRight ? v.maxX - Self.width - Self.inset.x : v.minX + Self.inset.x,
                        y: c.bottom ? v.minY + Self.inset.y : v.maxY - Self.collapsed - Self.inset.y)
        if let off = store?.settings.miniPanelOffset[screen?.localizedName ?? "screen"], off.count == 2 { o.x += off[0]; o.y += off[1] }
        o.x = min(max(o.x, v.minX), v.maxX - Self.width)
        o.y = min(max(o.y, v.minY), v.maxY - Self.collapsed)
        if !c.bottom { o.y -= (height - Self.collapsed) }   // a top corner grows the frame downward from the pill's top edge
        return o
    }
    /// HUD0 B2: the display the HUD lives on (`settings.miniPanelScreen`, set by a drag), else the primary display.
    private var homeScreen: NSScreen? {
        let name = HUDRules.display(saved: store?.settings.miniPanelScreen, attached: NSScreen.screens.map(\.localizedName), main: NSScreen.screens.first?.localizedName ?? "")
        return NSScreen.screens.first { $0.localizedName == name } ?? NSScreen.screens.first
    }
    /// HUD0 B4: the note field needs the keyboard; the panel takes it without activating the app, and gives it back after.
    private func takeKey() {
        guard let p = panel, !snapshot else { return }
        p.becomesKeyOnlyIfNeeded = false
        p.makeKey()
    }
    private func releaseKey() {
        guard let p = panel else { return }
        p.becomesKeyOnlyIfNeeded = true
        if p.isKeyWindow { p.resignKey(); Log.write("mini panel: key released · front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")") }
    }
    private func move(_ p: NSPanel, to origin: NSPoint) {
        let f = NSRect(origin: origin, size: p.frame.size)
        lastProgrammaticFrame = f
        p.setFrameOrigin(origin)
    }

    /// E1: after a real drag, the pill's offset from its corner anchor is saved for this display (debounced: a drag moves the window
    /// many times). R0: a frame this class set is not a drag, whatever thread the notification arrived on.
    private func windowMoved() {
        guard let p = panel, isShowing, !Self.isProgrammatic(p.frame, last: lastProgrammaticFrame) else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled, let store = self.store, let p = self.panel, !Self.isProgrammatic(p.frame, last: self.lastProgrammaticFrame) else { return }
            let screen = NSScreen.screens.first { $0.frame.intersects(p.frame) } ?? NSScreen.main
            let v = screen?.visibleFrame ?? .zero
            let c = self.corner
            let anchor = NSPoint(x: c == .topRight || c == .bottomRight ? v.maxX - Self.width - Self.inset.x : v.minX + Self.inset.x,
                                 y: c.bottom ? v.minY + Self.inset.y : v.maxY - Self.collapsed - Self.inset.y)
            let pillY = Self.pillRect(in: p.frame, corner: c).minY
            let off = [Double((p.frame.minX - anchor.x).rounded()), Double((pillY - anchor.y).rounded())]
            let key = screen?.localizedName ?? "screen"
            if store.settings.miniPanelOffset[key] != off || store.settings.miniPanelScreen != key {   // HUD0 B2: a drag also says which display it lives on
                store.settings.miniPanelOffset[key] = off; store.settings.miniPanelScreen = key; EventLog.shared.ui("overlay", "minipanel dragged")
            }
            self.lastProgrammaticFrame = p.frame   // the dragged place is the new baseline
            self.screenOrigin = p.frame.origin
        }
    }

    private func makePanel() -> NSPanel {
        let p = BannerPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: Self.collapsed)),
                            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = false
        let host = NSHostingView(rootView: MiniPanelView(panel: self).environment(store!))
        host.sizingOptions = []
        p.contentView = host
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windowMoved() }
        })
        // R0: Escape closes the drawer while the panel is key (the note field makes it key)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let p = self.panel, p.isKeyWindow, e.keyCode == 53, self.expanded else { return e }
                if self.addingTask { self.addingTask = false; self.taskDraft = "" } else if self.noteOpen { self.noteOpen = false } else { self.setExpanded(false, animated: true) }   // HUD0 B4 · HUD4
                return nil
            }
        }
        return p
    }
}

// MARK: - The view

struct MiniPanelView: View {
    @Bindable var panel: MiniPanel
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.snapshot) private var snapshot
    @State private var hovering = false
    @State private var closeRect = HUDRules.closeRect   // HUD0 B1: the ✕'s place, measured
    @FocusState private var noteFocused: Bool
    @FocusState private var taskFocused: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }

    var body: some View {
        if let s = store.session {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let o = store.sessionObjective
                let tint = o.map { store.accent(of: $0) } ?? Theme.accent
                let bottom = panel.corner.bottom
                VStack(alignment: .leading, spacing: 0) {
                    if bottom, panel.expanded { drawer(s).transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)).zIndex(-1) }
                    top(s, objective: o, tint: tint)
                        .contentShape(Rectangle())
                        .coordinateSpace(name: "pill")   // HUD0 B1: the ✕ reports its rectangle in the gesture surface's own space
                        .overlay { if !snapshot { PillGesture(exclude: closeRect, onClick: { panel.toggleDrawer() }, onHover: { hovering = $0 }) } }   // HUD0 B1: click = the drawer, ≥ 4 pt = a drag, the ✕ excluded
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(accessibilityLine(s))
                        .accessibilityHint("Click to open the session drawer")
                        .frame(height: MiniPanel.collapsed)
                    if !bottom, panel.expanded { drawer(s).transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)).zIndex(-1) }
                }
                .frame(width: MiniPanel.width)
                .frame(maxHeight: snapshot ? nil : .infinity, alignment: bottom ? .bottom : .top)   // R0: in the panel the pill keeps its edge while the frame grows the other way; a render sizes to content
                // C5: the score card's watermark on the pill too — the flag in the objective's colour, cut off by the corner
                .background(alignment: .bottomTrailing) {
                    Watermark(symbol: "flag.checkered", size: 84, color: tint, opacity: Tint.watermark(dark: scheme == .dark)).offset(x: 10, y: 16)
                }
                .modifier(MiniGlass(shape: shape))
                .clipShape(shape)
                .onHover { hovering = $0 }                                                    // R0: hover only brightens the ✕
            }
            .frame(width: MiniPanel.width)
        }
    }

    // MARK: the pill

    /// HUD2 (PLAN_SESSION_HUD §3.2): the pill is the game. Line 1: glyph · goal · ✕; line 2: the minute strip · the combo badge.
    /// The right column: the session's accuracy at `figureSmall` in its colour, the rank beside it, the session's XP under it.
    /// (Was: today's score and a verdict dot — the day's figure is in the drawer now.)
    private func top(_ s: Session, objective o: Objective?, tint: Color) -> some View {
        let now = Date()
        let g = store.liveGame(s, now: now)
        let acc = SessionGame.shown(g)
        return HStack(alignment: .center, spacing: Space.loose) {
            Glyph(icon: o?.icon ?? "shield.lefthalf.filled", size: 18, weight: .regular, color: tint)
                .frame(width: 28, height: 28)
                .overlay { breakRing(s) }   // HUD3: a break drains a ring around the glyph
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(spacing: Space.stack) {
                    // HUD4: the current task after the goal — what you said you would do, always in view
                    (Text(s.goal.isEmpty ? "Focus session" : s.goal).foregroundStyle(.primary) + Text(SessionTasks.current(s.tasks).map { " · \($0)" } ?? "").foregroundStyle(.secondary))
                        .font(Type.strong).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    // E1 §5 Q2: ✕ always visible at 0.5, 1 on hover
                    Button { panel.hideForSession() } label: {
                        Image(systemName: "xmark").font(.system(size: Icon.Size.tiny.rawValue, weight: .bold)).foregroundStyle(.secondary).frame(width: 18, height: 18)   // lint-ok: Icon.tiny on the glass pill, system secondary on real glass
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .opacity(hovering || panel.expanded ? 1 : 0.5)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("pill")).insetBy(dx: -5, dy: -5) } action: { closeRect = $0 }   // HUD0 B1: where the gesture surface must not reach
                    .accessibilityLabel("Hide mini panel for this session")
                }
                HStack(spacing: Space.stack) {
                    // M1 (PLAN_MINUTE_STRIP §5a Q6): the live card's strip at 3 pt
                    MinuteStrip(spans: store.liveSpans(s, now: now), marks: store.liveStrip.marks, length: store.liveStripLength(s, now: now), tint: tint, height: 3)
                        .accessibilityHidden(true)
                    badge(s, g, tint: tint, now: now)
                }
            }
            VStack(alignment: .trailing, spacing: Space.hair) {
                HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                    Text(String(format: "%.1f", acc)).font(Type.figureSmall).monospacedDigit().foregroundStyle(Self.accuracyColor(acc)).lineLimit(1)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text(g.rank.rawValue).font(Type.pill).tracking(Type.pillTracking).foregroundStyle(Self.accuracyColor(acc)).lineLimit(1).fixedSize()
                        .contentTransition(reduceMotion ? .identity : .opacity)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Accuracy \(String(format: "%.1f", acc)) per cent, rank \(g.rank.rawValue)")
                Text("+\(store.liveXP(s, g)) XP").font(Type.data).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    .accessibilityLabel("\(store.liveXP(s, g)) XP this session")
            }
            .padding(.trailing, Space.tight)
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, Space.loose)
    }

    /// Sage at 90 and up, amber at 80, red below — the one coloured figure on the pill.
    static func accuracyColor(_ a: Double) -> Color { a >= 90 ? Theme.sage : a >= 80 ? Theme.warn : Theme.danger }

    /// The combo badge: `×2 · 14m` (muted at ×1, ink at ×2, the objective's tint at ×3; `×3!` with one spring when a tier is reached).
    /// An alert (HUD0 B3) or a break takes its place in amber or muted.
    @ViewBuilder private func badge(_ s: Session, _ g: SessionGame.State, tint: Color, now: Date) -> some View {
        if let a = panel.attentionLine {
            Text(a).font(Type.data).foregroundStyle(Theme.warn).lineLimit(1).fixedSize()
        } else if s.paused, let p = s.pausedUntil {
            // HUD3: `break · 7:42 left`; an away pause says so
            Text("\(s.onBreak ? "break" : "paused") · \(HUDRules.clock(p.timeIntervalSinceNow)) left").font(Type.data).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).fixedSize()
        } else if let l = store.lockUntil, l > now {
            // HUD3: the strict ladder — five minutes on the goal, the judge on
            Text("3 detours · 5 min on this · \(HUDRules.clock(l.timeIntervalSince(now)))").font(Type.data).foregroundStyle(Theme.warn).monospacedDigit().lineLimit(1).fixedSize()
        } else {
            let up = now < panel.tierUpUntil
            let colour: AnyShapeStyle = g.multiplier >= 3 ? AnyShapeStyle(tint) : g.multiplier == 2 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
            Text(up ? "×\(g.multiplier)!" : "×\(g.multiplier) · \(g.combo / 60)m").font(Type.data).monospacedDigit().foregroundStyle(colour).lineLimit(1).fixedSize()
                .scaleEffect(up && !reduceMotion ? 1.15 : 1)
                .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.5), value: up)
                .accessibilityLabel("Combo \(g.combo / 60) minutes, times \(g.multiplier)")
        }
    }

    /// HUD3: the break's ring — the share of the break left, drawn around the glyph in the secondary ink; nothing outside a break.
    @ViewBuilder private func breakRing(_ s: Session) -> some View {
        if s.onBreak, let p = s.pausedUntil, let start = store.breakStartedAt {
            let total = max(1, p.timeIntervalSince(start)), left = max(0, p.timeIntervalSinceNow)
            Circle().trim(from: 0, to: left / total).stroke(Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90)).padding(-Space.tight)
        }
    }

    /// The drawer's first row: the combo and how far to the next tier.
    private func comboRow(_ g: SessionGame.State, tint: Color) -> some View {
        let next = SessionGame.toNextTier(combo: g.combo)
        let from = SessionGame.tiers.last { g.combo >= $0.from }?.from ?? 0
        let span = next.map { Double($0 + g.combo - from) } ?? 1
        return HStack(spacing: Space.stack) {
            MonoLabel("combo ×\(g.multiplier) · \(g.combo / 60) min", color: .secondary)
            Bar(fraction: next == nil ? 1 : Double(g.combo - from) / max(1, span), color: g.multiplier >= 3 ? tint : Color.secondary.opacity(0.45)).frame(height: 3)   // quieter than the strip until ×3
            MonoLabel(next.map { "\(Int(ceil(Double($0) / 60))) to ×\(g.multiplier + 1)" } ?? "top tier", color: .secondary)
        }
    }

    /// `best 42 min · today 74 · 4 days · 52 min left` — the course's best combo to chase, the day's score, the day streak, the time.
    private func statsLine(_ s: Session, _ g: SessionGame.State) -> String {
        var parts: [String] = []
        if let b = store.courseBestCombo(s), b >= 60 { parts.append(g.combo > b ? "best combo yet!" : "best \(b / 60) min") }
        if let t = store.statsToday?.score.total, (store.statsToday?.focusedSeconds ?? 0) > 0 { parts.append("today \(t)") }
        if store.overall.streak > 0 { parts.append("\(store.overall.streak) day\(store.overall.streak == 1 ? "" : "s")") }
        parts.append(s.remaining.map { "\(minutes($0)) left" } ?? "\(minutes(s.elapsed)) in")   // the break is the badge's to say, not twice
        return parts.joined(separator: " · ")
    }

    private func timeText(_ s: Session) -> String {
        if s.paused, let p = s.pausedUntil { return "break · \(minutes(p.timeIntervalSinceNow)) left" }
        if let r = s.remaining { return "\(minutes(r)) left" }
        return "\(minutes(s.elapsed)) in"
    }

    private func accessibilityLine(_ s: Session) -> String {
        "Focus session \(s.goal.isEmpty ? "" : s.goal), \(timeText(s))"
    }

    // MARK: the drawer (E1 §3.2: Now · Verdict · Actions · Next · shut down) — every row at its fixed height (R0)

    private func drawer(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: MiniPanel.rowGap) {
            let g = store.liveGame(s)
            comboRow(g, tint: store.sessionObjective.map { store.accent(of: $0) } ?? Theme.accent).frame(height: MiniPanel.lineRow)   // HUD2
            Text(statsLine(s, g)).font(Type.data).foregroundStyle(.secondary).lineLimit(1).frame(height: MiniPanel.lineRow, alignment: .leading)   // HUD2
            ForEach(s.tasks) { t in taskLine(t).frame(height: MiniPanel.taskRow) }   // HUD4: the checklist
            if s.tasks.count < SessionTasks.maxTasks { addTaskLine.frame(height: panel.addingTask ? MiniPanel.fieldRow : MiniPanel.taskRow) }
            Text(panel.nowLine).font(Type.data).foregroundStyle(panel.attentionLine == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.warn)).lineLimit(1).frame(height: MiniPanel.lineRow, alignment: .leading)
            verdictRow.frame(height: MiniPanel.pillRow)
            if panel.teachOpen {
                HStack(spacing: Space.stack) {   // the card's scope row, in the 320 variant: shorter words
                    MonoLabel("teach —", color: .secondary)
                    ForEach(Banner.Scope.allCases, id: \.self) { sc in GhostPill(sc == .once ? "once" : sc == .session ? "session" : "always") { panel.teach(sc) } }
                }
                .frame(height: MiniPanel.pillRow, alignment: .leading)
            }
            actions(s).frame(height: MiniPanel.pillRow)
            if panel.noteOpen { noteField.frame(height: MiniPanel.fieldRow) }
            if let n = panel.nextLine { Text(n).font(Type.data).foregroundStyle(.secondary).lineLimit(1).frame(height: MiniPanel.lineRow, alignment: .leading) }
        }
        .padding(.horizontal, Space.card)
        .padding(.vertical, MiniPanel.drawerPadding)
        .frame(width: MiniPanel.width, alignment: .leading)
    }

    private var verdictRow: some View {
        HStack(spacing: Space.stack) {
            if let v = store.judge.lastVerdict {
                Pill(v.distracted ? "detour" : "work", kind: v.distracted ? .warn : .ok)
                Text(v.reason.isEmpty ? "—" : v.reason).font(Type.data).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                GhostPill(panel.teachOpen ? "wrong ▴" : "wrong") { panel.teachOpen.toggle() }.accessibilityLabel("The verdict is wrong: tell the judge")
            } else {
                Pill("no verdict yet")
                Spacer(minLength: 0)
            }
        }
    }

    private func actions(_ s: Session) -> some View {
        HStack(spacing: Space.tight) {   // six pills in 288 pt: the chip gap, not the stack gap
            if s.paused {
                capsule(s.onBreak ? "end break" : "resume", "play.fill") { store.resumeSession() }.accessibilityLabel(s.onBreak ? "End the break now" : "Resume the session")
            } else {
                // HUD3 (PLAN_SESSION_HUD §3.3): breaks 5 · 10 · 15 — free below hard; hard and extreme spend the earned bank
                let bank = store.breakBank(s)
                let choices = HUDRules.breakChoices.filter { HUDRules.mayBreak(minutes: $0, hard: s.strictness.isHard, bank: bank) }
                if choices.isEmpty { MonoLabel(s.strictness.isHard ? "☕ \(bank) min earned" : "", color: .secondary).help("hard mode: 5 min of break per 25 clean minutes, at most 20") }
                ForEach(choices, id: \.self) { m in
                    capsule("\(m)", m == choices.first ? "cup.and.saucer" : nil) { store.takeBreak(minutes: m); EventLog.shared.ui("overlay", "minipanel break \(m)") }
                        .accessibilityLabel("Take a \(m)-minute break").help("break · \(m) min" + (s.strictness.isHard ? " · \(bank) min earned" : ""))
                }
            }
            capsule(s.strictness.isHard ? "end…" : "end", "stop.fill") { store.requestEnd() }.accessibilityLabel(s.strictness.isHard ? "End session, the escape phrase is asked" : "End session")
            capsule(nil, "square.and.pencil") { panel.noteOpen.toggle() }.accessibilityLabel("Add a note to the session").help("+ note · what got done")
            Spacer(minLength: 0)
        }
    }

    // MARK: HUD4 — the checklist

    /// `☑ problem 2   +10` — a click ticks or unticks it; the ✕ removes it.
    private func taskLine(_ t: SessionTask) -> some View {
        HStack(spacing: Space.stack) {
            Button { store.toggleTask(t.id) } label: {
                HStack(spacing: Space.stack) {
                    Image(systemName: t.done ? "checkmark.square.fill" : "square").font(.system(size: Icon.Size.row.rawValue)).foregroundStyle(t.done ? AnyShapeStyle(Theme.sage) : AnyShapeStyle(.secondary))   // lint-ok: Icon.row on glass
                    Text(t.title).font(Type.body).foregroundStyle(t.done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)).strikethrough(t.done, color: .secondary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(t.title), \(t.done ? "done" : "to do")")
            if store.liveTaskPaid.contains(t.title) { Text("+\(SessionTasks.xpEach)").font(Type.data).foregroundStyle(Theme.sage).monospacedDigit() }
            Button { store.removeTask(t.id) } label: { Image(systemName: "xmark").font(.system(size: Icon.Size.tiny.rawValue, weight: .bold)).foregroundStyle(.secondary) }   // lint-ok: Icon.tiny
                .buttonStyle(.plain).opacity(0.5).accessibilityLabel("Remove \(t.title)")
        }
    }

    /// `+ add a task` — a click (or ⌃⌥T) opens the field; Return adds and keeps it open for the next; an empty Return or Escape closes it.
    @ViewBuilder private var addTaskLine: some View {
        if panel.addingTask {
            if snapshot {
                Text("a task · return adds it").font(Type.body).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            } else {
                TextField("a task · return adds it", text: $panel.taskDraft)
                    .textFieldStyle(.plain).font(Type.body)
                    .rowPadding()
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .focused($taskFocused)
                    .onAppear { taskFocused = true }
                    .onSubmit { panel.submitTask(); taskFocused = panel.addingTask }
            }
        } else {
            Button { panel.addingTask = true } label: {
                HStack(spacing: Space.stack) {
                    Image(systemName: "plus").font(.system(size: Icon.Size.small.rawValue, weight: .semibold)).foregroundStyle(.secondary)   // lint-ok: Icon.small on glass
                    Text("add a task").font(Type.body).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Add a task")
        }
    }

    private var noteField: some View {
        Group {
            if snapshot {
                Text("what got done? · return files it").font(Type.body).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
            } else {
                TextField("what got done? · return files it", text: $panel.note)
                    .textFieldStyle(.plain).font(Type.body)
                    .rowPadding()
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .focused($noteFocused)
                    .onAppear { noteFocused = true }   // HUD0 B4: the panel has made itself key by now
                    .onSubmit { panel.fileNote() }
            }
        }
    }

    private func capsule(_ t: String?, _ sym: String?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.tight) {
                if let sym { Image(systemName: sym).font(.system(size: Icon.Size.tiny.rawValue, weight: .semibold)) }   // lint-ok: Icon.tiny, colour from the pill
                if let t { Text(t.uppercased()).font(Type.pill).tracking(Type.pillTracking).lineLimit(1).fixedSize() }
            }
            .padding(.horizontal, Space.pillH).padding(.vertical, Space.pillV)
            .background(Capsule().fill(Color.primary.opacity(0.10)))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
}

/// HUD0 B1 (PLAN_SESSION_HUD §2.3): the whole pill is one gesture surface. A mouse-down that travels `HUDRules.dragThreshold`
/// (4 pt) is a drag (`performDrag` from the original mouse-down); anything shorter is a click, which opens or closes the drawer.
/// Replaces E1's 14-pt drag band, which turned every click near the top edge into a "drag". The ✕'s rectangle is not hit, so the
/// SwiftUI button under it gets its click. `acceptsFirstMouse`: the panel is never key, and the first click must count.
private struct PillGesture: NSViewRepresentable {
    let exclude: CGRect
    let onClick: () -> Void
    let onHover: (Bool) -> Void
    func makeNSView(context: Context) -> GestureView { let v = GestureView(); update(v); return v }
    func updateNSView(_ v: GestureView, context: Context) { update(v) }
    private func update(_ v: GestureView) { v.exclude = exclude; v.onClick = onClick; v.onHover = onHover }
    final class GestureView: NSView {
        var exclude: CGRect = .zero
        var onClick: () -> Void = {}
        var onHover: (Bool) -> Void = { _ in }
        private var down: NSEvent?
        private var downAt: CGPoint = .zero
        private var dragged = false
        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            return bounds.contains(local) && !exclude.contains(local) ? self : nil
        }
        override func mouseDown(with event: NSEvent) { down = event; downAt = NSEvent.mouseLocation; dragged = false }
        override func mouseDragged(with event: NSEvent) {
            guard !dragged, let d = down, HUDRules.isDrag(from: downAt, to: NSEvent.mouseLocation) else { return }
            dragged = true
            window?.performDrag(with: d)   // runs its own loop to the mouse-up; the move notification decides whether it was a real move
        }
        override func mouseUp(with event: NSEvent) {
            defer { down = nil }
            if !dragged, down != nil { onClick() }
        }
        override func updateTrackingAreas() {
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
            super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
    }
}

/// Regular glass without the card signature (§3.7: no wash, no watermark; subtle was the word).
private struct MiniGlass: ViewModifier {
    let shape: RoundedRectangle
    @Environment(\.snapshot) private var snapshot
    func body(content: Content) -> some View {
        // an offscreen render cannot draw glass: paper with a hairline stands in
        if snapshot { content.background(shape.fill(Theme.paper)).overlay(shape.stroke(Theme.line, lineWidth: 1)) }
        else if #available(macOS 26, *) { content.glassEffect(.regular, in: shape) }
        else { content.background(.regularMaterial, in: shape) }
    }
}
