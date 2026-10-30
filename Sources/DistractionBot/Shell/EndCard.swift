import AppKit
import SwiftUI

/// The session-end card (PLAN_OVERLAY §3.3, E2; IMPACT_ANALYSIS R13): the Shield's recipe — one non-activating glass
/// panel, 620 × 420, centred on the pointer's screen, no veil — shown by `Store.endSession` in the toast's place.
/// PLAN_GAME_FEEL F1 (§3.1): it tells the tally — full marks, each loss taken off in turn, the session's figure settling with its word —
/// then where it landed: today's score counting up from `was`, the XP filling the course bar, today's flame lighting. Then the
/// `what got done?` field (Return files `session.note`; it takes the keyboard only when clicked) · `next · <queued> ▸` · `shut down the day`
/// (K's offer) · `done`. 8 s from the settle, or Escape / a click outside; a click on the tally skips to the end. Hard mode: shown after the
/// phrase, same content. Reduce Motion and every render: the last frame at once.
@MainActor
@Observable
final class EndCard {
    static let shared = EndCard()
    /// What the card shows; built by `Store.endSummary`.
    struct Summary {
        var title: String
        var reason: String                  // finished · ended · ended by phrase
        var seconds: Int
        var score: Score
        var losses: [Tally.Loss] = []       // F1: the session's tally (`Tally.session`), grouped to five when drawn
        var strip: SessionSpans.Strip?      // M2 (PLAN_MINUTE_STRIP §3.4): the session drawn as it happened, under the header
        var scored = true                   // F1: false when the log holds no record of the session (the card says so, no tally)
        var strictness = ""                 // the dial's word, on the kicker
        var cleanMinutes: Int?              // F1: what XP was paid on, said under the course line
        var finished = false
        var xp: Int?                        // Z2's `xp` row, when present (shown as `+N XP · no course` without a course)
        var course: CourseMove?             // G3 (PLAN_GAME_LOOP §3.5): what the session moved on its course
        var dayBefore: Int?                 // today's score when the session started; nil when it was the day's first
        var dayAfter: Int?                  // today's score now
        var cells: [WeekCell] = Array(repeating: .future, count: 7)   // F1: the streak's week row after this session
        var today = 0
        var streak = 0
        var lit = false                     // this session made today a session day: today's flame lights on the card
        var best: String?                   // F4: `longest CS 150 session yet`, said under the figure once it settles
        var next: String?                   // the queued session's goal
        var offerShutdown = false           // K's `offerShutdown`
        var hard = false
        var rows: [Tally.Loss] { Tally.grouped(losses) }
        // HUD6 (PLAN_SESSION_HUD §3.6): the results screen — the session as a game
        var game: SessionGame.State?        // nil: an older session without one; the card falls back to F1's tally
        var gameLosses: [SessionGame.Loss] = []
        var gameRows: [SessionGame.Loss] { SessionGame.grouped(gameLosses) }
        var comboXP: Int?                   // the minutes' XP with the combo and the dial (before finished, tasks and the objective)
        var taskXP = 0
        var tasksDone = 0, tasksTotal = 0
        var openTasks: [String] = []        // carried to the objective unless the card's toggle says otherwise
        var objectiveId: String?
        var objectiveDone = false           // completed at this End (`completeOnEnd`): +60 on its course
        /// The tally's beats, whichever tally is told: the game's rows, else F1's.
        var beats: Int { game != nil ? gameRows.count : rows.count }
        var beatAt: [[Int]] { game != nil ? gameRows.map(\.at) : rows.map(\.at) }
    }
    var carry = true                        // HUD6: the tasks left open go to the objective (HUD4 already put them there)
    func setCarry(_ on: Bool) {
        carry = on
        if let oid = summary.objectiveId, !summary.openTasks.isEmpty { Store.current?.setCarry(objectiveId: oid, tasks: summary.openTasks, on: on) }
    }
    var summary = Summary(title: "", reason: "ended", seconds: 0, score: .empty)
    var skipped = false                     // F1: a click on the tally jumps to the last frame
    var frame: Int? = nil                   // F1: `DBOT_SNAPSHOT_FRAME` — a render draws that frame of the sequence
    var note = ""
    var shownAt = Date()
    var onShutdown: () -> Void = {}
    var onNext: () -> Void = {}
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private(set) var isShowing = false
    static let size = NSSize(width: 620, height: 496)   // M2 (PLAN_MINUTE_STRIP §3.4): 420 + the strip; HUD6: + the tasks line
    static let stay: TimeInterval = 8

    func show(summary: Summary, onNext: @escaping () -> Void = {}, onShutdown: @escaping () -> Void = {}) {
        self.summary = summary; self.onNext = onNext; self.onShutdown = onShutdown; note = ""; shownAt = Date(); skipped = false; carry = true
        let p = panel ?? makePanel()
        panel = p
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            p.setFrame(NSRect(origin: NSPoint(x: v.midX - Self.size.width / 2, y: v.midY - Self.size.height / 2 + 40), size: Self.size), display: true)
        }
        if !isShowing { isShowing = true; p.alphaValue = 0; p.orderFrontRegardless(); NSAnimationContext.runAnimationGroup { c in c.duration = 0.2; p.animator().alphaValue = 1 } }
        MiniPanel.shared.suspend("end-card")   // C3 (the session is over, so the panel is gone anyway; the rule is kept)
        EventLog.shared.ui("overlay", "end card shown")
        arm()
    }

    /// 8 s, Escape (when the card has the keyboard) or a click anywhere outside it.
    private func arm() {
        hideTask?.cancel()
        // §5a Q14: the 8 s begin once the tally has settled and the flame has lit
        let tell = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : TallyTiming(rows: summary.beats).done
        hideTask = Task { try? await Task.sleep(for: .seconds(Self.stay + tell)); if !Task.isCancelled, self.isShowing, !self.typing { self.hide(how: "timed out") } }
        disarm()
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in Task { @MainActor in self?.hide(how: "click outside") } } { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            guard let self, let p = self.panel else { return e }
            if e.type == .keyDown { if e.keyCode == 53, p.isKeyWindow { Task { @MainActor in self.hide(how: "escape") }; return nil }; return e }
            if e.window !== p { Task { @MainActor in self.hide(how: "click outside") } }
            return e
        } { monitors.append(m) }
    }
    private func disarm() { monitors.forEach { NSEvent.removeMonitor($0) }; monitors = [] }
    /// The field has the keyboard: the 8 s do not run out under a sentence being typed.
    private var typing: Bool { (panel?.isKeyWindow ?? false) && !note.isEmpty }

    func fileNote() {
        let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
        note = ""
        guard !t.isEmpty else { hide(how: "done"); return }
        EventLog.shared.add("session.note", detail: t)
        Store.current?.reloadLog()
        hide(how: "note filed")
    }

    func hide(how: String = "done") {
        hideTask?.cancel(); disarm()
        guard isShowing, let p = panel else { return }
        isShowing = false
        Log.write("end card hide · \(how)")
        if p.isKeyWindow { p.resignKey() }
        MiniPanel.shared.resume("end-card")   // C3
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.2; p.animator().alphaValue = 0 }, completionHandler: { Task { @MainActor in if !self.isShowing { p.orderOut(nil) } } })
    }

    private func makePanel() -> NSPanel {
        let p = BannerPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true      // the field takes the keyboard only when clicked
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: EndCardView(card: self))
        return p
    }
}

/// F1 (PLAN_GAME_FEEL §3.1): when each beat of the tally happens, in seconds from the card's fade-in.
struct TallyTiming {
    let rows: Int
    static let first = 0.5, gap = 0.45, tick = 0.25
    func rowAt(_ i: Int) -> Double { Self.first + Self.gap * Double(i) }
    /// The figure has stopped and the word lands.
    var settle: Double { rows == 0 ? 0.9 : rowAt(rows - 1) + Self.tick + 0.2 }
    /// Today counts from `was` over 0.8 s and the course bar fills over 1 s, from here.
    var day: Double { settle + 0.3 }
    /// Today's flame lights (0.4 s), once today and the bar have landed.
    var flame: Double { settle + 1.4 }
    var done: Double { flame + 0.4 }
    /// What a render's `DBOT_SNAPSHOT_FRAME` stands for: 0 full marks · 1…4 one row each · 5 settled and landed · 6 the flame.
    func time(frame: Int) -> Double {
        switch frame {
        case ...0: return 0.3
        case 1...4: return rows == 0 ? 0.7 : rowAt(min(frame, rows) - 1) + 0.3
        case 5: return day + 1.0
        default: return .infinity
        }
    }
}

struct EndCardView: View {
    @Bindable var card: EndCard
    @Environment(\.snapshot) private var snapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private var s: EndCard.Summary { card.summary }
    private var timing: TallyTiming { TallyTiming(rows: s.beats) }   // HUD6: the game's rows when there is a game
    /// The last frame at once: Reduce Motion, a render without a frame asked for, or a click on the tally.
    private var still: Bool { reduceMotion || (snapshot && card.frame == nil) || card.skipped }
    private var scoreColor: Color { s.score.total >= 75 ? Theme.sage : s.score.total >= 50 ? Theme.warn : Theme.danger }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.card) {
            HStack(spacing: Space.loose) {
                Icon("flag.checkered", .card, color: Theme.accent)
                MonoLabel("session \(s.reason) · \(s.title.isEmpty ? "focus session" : s.title)", color: Theme.muted)
                Spacer()
                MonoLabel(([minutes(TimeInterval(s.seconds))] + (s.strictness.isEmpty ? [] : [s.strictness]) + (s.hard ? ["hard mode"] : [])).joined(separator: " · "), color: Theme.muted)
            }
            Group {
                if still { content(.infinity) }
                else if let f = card.frame { content(timing.time(frame: f)) }
                else { TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { ctx in content(ctx.date.timeIntervalSince(card.shownAt)) } }
            }
            Spacer(minLength: 0)
            noteField
            HStack(spacing: Space.stack) {
                if let n = s.next { GhostPill("next · \(n) ▸") { card.onNext(); card.hide(how: "next") } }
                if s.offerShutdown { GhostPill("shut down the day") { card.onShutdown(); card.hide(how: "shutdown") } }
                Spacer()
                OverlayButton("Done", "checkmark", accent: true) { card.hide(how: "done") }
            }
        }
        .padding(Space.sheet)
        .frame(width: EndCard.size.width, height: EndCard.size.height, alignment: .topLeading)
        .modifier(GlassBack(watermark: "flag.checkered", accent: Theme.accent))
    }

    /// The card's middle at `t` seconds into the sequence (`.infinity` = the last frame).
    private func content(_ t: Double) -> some View {
        VStack(alignment: .leading, spacing: Space.card) {
            if let st = s.strip { strip(st, t) }
            columns(t)
            if s.tasksTotal > 0, t >= timing.settle || still { tasksLine }   // HUD6
        }
    }

    /// M2 (PLAN_MINUTE_STRIP §3.4–3.5): the session as it happened; while a tally row ticks, the spans it was taken for thicken.
    private func strip(_ st: SessionSpans.Strip, _ t: Double) -> some View {
        let at = s.beatAt   // HUD6: the game's rows point at the strip as F1's did
        let pointing = t < timing.settle ? at.indices.last { t >= timing.rowAt($0) && t < timing.rowAt($0) + TallyTiming.tick + 0.2 } : nil
        return MinuteStrip(spans: st.spans, marks: st.marks, length: max(1, st.length), tint: s.course.map { Theme.accent($0.accent) } ?? Theme.accent,
                           highlight: pointing.map { Set(at[$0]) } ?? [])
    }

    private func columns(_ t: Double) -> some View {
        HStack(alignment: .top, spacing: Space.sheet) {
            Group { if let g = s.game { gameTally(g, t) } else { tally(t) } }.frame(width: 264, alignment: .topLeading)   // HUD6
                .contentShape(Rectangle()).onTapGesture { card.skipped = true }
            Rectangle().fill(Theme.line).frame(width: 1)
            landing(t).frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    // MARK: the tally — full marks, each loss in turn, the figure settling

    private func tally(_ t: Double) -> some View {
        let rows = s.rows
        let shown = rows.indices.filter { t >= timing.rowAt($0) }.count
        let taken = rows.prefix(shown).enumerated().reduce(0.0) { acc, e in acc + Double(e.element.points) * Self.clamp((t - timing.rowAt(e.offset)) / TallyTiming.tick) }
        let settled = t >= timing.settle
        let figure = settled ? s.score.total : 100 - Int(taken.rounded())
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("the tally", color: Theme.muted)
            if !s.scored {
                Text("not scored").font(Type.headline).foregroundStyle(Theme.muted)
                Text("too short, or not in the log").font(Type.body).foregroundStyle(Theme.muted)
            } else {
            row("full marks", "", "100", ink: shown == 0 && !settled)
            ForEach(Array(rows.prefix(shown).enumerated()), id: \.offset) { i, l in
                let a = Self.clamp((t - timing.rowAt(i)) / 0.2)
                row(l.name, l.detail, "−\(l.points)", ink: i == shown - 1 && !settled).opacity(a).offset(x: (1 - a) * Space.tight)
            }
            if rows.isEmpty, t >= TallyTiming.first { Text("nothing taken off").font(Type.strong).foregroundStyle(Theme.sage) }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: Space.loose) {
                Text("\(figure)").font(Type.figure).monospacedDigit().foregroundStyle(Theme.ink)
                Text(settled ? s.score.word : (shown == 0 && !rows.isEmpty ? "to lose" : "…"))
                    .font(Type.headline).foregroundStyle(settled ? scoreColor : Theme.muted)
            }
            if settled, let b = s.best { MonoLabel(b, color: Theme.sage) }   // F4 (§3.4): the personal best, once
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("score \(s.score.total), \(s.score.word). \(Tally.line(s.losses, total: s.score.total))")
    }

    // MARK: HUD6 — the game's tally: full accuracy, each loss in turn, the rank landing

    private func gameTally(_ g: SessionGame.State, _ t: Double) -> some View {
        let rows = s.gameRows
        let shown = rows.indices.filter { t >= timing.rowAt($0) }.count
        let taken = rows.prefix(shown).enumerated().reduce(0.0) { acc, e in acc + e.element.points * Self.clamp((t - timing.rowAt(e.offset)) / TallyTiming.tick) }
        let settled = t >= timing.settle
        let acc = SessionGame.shown(g)
        let figure = settled ? acc : max(acc, 100 - taken)
        let colour = MiniPanelView.accuracyColor(acc)
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("accuracy", color: Theme.muted)
            row("full", "", "100.0", ink: shown == 0 && !settled)
            ForEach(Array(rows.prefix(shown).enumerated()), id: \.offset) { i, l in
                let a = Self.clamp((t - timing.rowAt(i)) / 0.2)
                row(l.name, l.detail, "−" + String(format: "%.1f", l.points), ink: i == shown - 1 && !settled).opacity(a).offset(x: (1 - a) * Space.tight)
            }
            if rows.isEmpty, t >= TallyTiming.first { Text("nothing taken off").font(Type.strong).foregroundStyle(Theme.sage) }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(alignment: .firstTextBaseline, spacing: Space.loose) {
                Text(settled ? g.rank.rawValue : "…").font(Type.figure).foregroundStyle(settled ? colour : Theme.muted)
                Text(String(format: "%.1f", figure) + " %").font(Type.headline).monospacedDigit().foregroundStyle(settled ? colour : Theme.ink)
            }
            if settled {
                MonoLabel("max combo \(g.bestCombo / 60) min" + ((g.secondsAt[3] ?? 0) >= 60 ? " · ×3 for \((g.secondsAt[3] ?? 0) / 60) min" : (g.secondsAt[2] ?? 0) >= 60 ? " · ×2 for \((g.secondsAt[2] ?? 0) / 60) min" : ""), color: Theme.muted)
                if let b = s.best { MonoLabel(b, color: Theme.sage) }   // F4 (§3.4): the personal best, once
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("accuracy \(String(format: "%.1f", acc)) per cent, rank \(g.rank.rawValue). " + rows.map { "\($0.name) \($0.detail) minus \(String(format: "%.1f", $0.points))" }.joined(separator: ", "))
    }

    /// `76 clean min → 171 with the combo · +30 finished · +30 tasks · +60 objective ✓` — where the session's XP came from.
    private var xpLine: String? {
        guard let c = s.comboXP else { return nil }
        var parts = ["\(s.cleanMinutes ?? 0) clean min → \(c) with the combo"]   // the dial is on the kicker; the line must fit two rows with every source
        if s.finished { parts.append("+30 finished") }
        if s.taskXP > 0 { parts.append("+\(s.taskXP) tasks") }
        if s.objectiveDone { parts.append("+60 objective ✓") }
        return parts.joined(separator: " · ")
    }

    /// `tasks 3 of 4 · ☐ problem 4` and the carry choice (on by default; HUD4 already carried them).
    private var tasksLine: some View {
        HStack(spacing: Space.stack) {
            MonoLabel("tasks \(s.tasksDone) of \(s.tasksTotal)", color: s.tasksDone == s.tasksTotal ? Theme.sage : Theme.muted)
            if !s.openTasks.isEmpty {
                Text("☐ " + s.openTasks.joined(separator: " · ☐ ")).font(Type.data).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Space.stack)
                if s.objectiveId != nil { GhostPill(card.carry ? "✓ carry to next time" : "carry to next time") { card.setCarry(!card.carry) } }
            } else { Spacer(minLength: 0) }
        }
    }

    private func row(_ name: String, _ detail: String, _ points: String, ink: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
            Text(name).font(Type.strong).foregroundStyle(ink ? Theme.ink : Theme.muted).lineLimit(1).layoutPriority(1)
            Text(detail).font(Type.data).foregroundStyle(Theme.muted2).lineLimit(1)
            Spacer(minLength: Space.stack)
            Text(points).font(Type.strong).monospacedDigit().foregroundStyle(ink ? Theme.ink : Theme.muted)
        }
    }

    // MARK: where it landed — today, the course, the streak

    private func landing(_ t: Double) -> some View {
        let dayP = Self.clamp((t - timing.day) / 0.8), barP = Self.clamp((t - timing.day) / 1.0)
        return VStack(alignment: .leading, spacing: Space.card) {
            if let after = s.dayAfter { today(after, dayP) }
            if let c = s.course { course(c, barP) }
            else if let xp = s.xp, barP >= 1 { MonoLabel("+\(xp) XP · no course", color: Theme.muted) }
            streak(t)
        }
    }

    /// `74 · was 62 · +12`, counting from `was`; `first session today` when nothing was scored before it.
    private func today(_ after: Int, _ p: Double) -> some View {
        let before = s.dayBefore
        let value = before.map { $0 + Int((Double(after - $0) * p).rounded()) } ?? after
        let label = p < 1 ? (before == nil ? "first session today" : "before this session")
            : before.map { $0 == after ? "unchanged" : "was \($0) · \(after > $0 ? "+" : "−")\(abs(after - $0))" } ?? "first session today"
        return VStack(alignment: .leading, spacing: Space.hair) {
            MonoLabel("today", color: Theme.muted)
            HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
                Text(before == nil && p == 0 ? "—" : "\(value)").font(Type.figureCard).monospacedDigit().foregroundStyle(p > 0 ? Theme.ink : Theme.muted)
                MonoLabel(label, color: Theme.muted)
            }
        }
    }

    /// The course line: the bar filling from before to after (through the band's end on a level-up), then the gain drawn over the old fill.
    private func course(_ c: CourseMove, _ p: Double) -> some View {
        let tint = Theme.accent(c.accent)
        // the header carries the gain only, so a long code never truncates; what is left to the next level goes under the bar
        let toNext = p >= 1 ? c.toNext.map { "\($0) to L\(c.level + 1)" } : (c.leveledUp ? nil : c.toNext.map { "\($0 + c.gainedXP) to L\(c.level + 1)" })
        let paid = xpLine ?? s.cleanMinutes.map { "\($0) clean min with the combo × \(s.strictness) \(String(format: XP.multiplier(s.strictness) == XP.multiplier(s.strictness).rounded() ? "%.1f" : "%g", XP.multiplier(s.strictness)))" + (s.finished ? " · +30 finished" : "") }   // HUD6: XP by source
        let under = ([toNext] + (p >= 1 ? [paid] : [])).compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: Space.tight) {
            if c.leveledUp, p >= 1 {
                HStack(spacing: Space.stack) {
                    Icon("arrow.up.circle.fill", .row, color: tint)
                    Text("Level \(c.level)").font(Type.headline).foregroundStyle(tint)
                }
            }
            HStack(spacing: Space.stack) {
                Icon(c.icon, .small, color: tint)
                MonoLabel("\(c.code) · L\(p >= 1 ? c.level : c.levelBefore)", color: tint).lineLimit(1)
                Spacer(minLength: Space.stack)
                if p >= 1 { MonoLabel("+\(c.gainedXP) XP", color: Theme.ink) }
            }
            if p >= 1 {
                LevelBar(level: c.level, into: c.after, tint: tint, before: c.leveledUp ? 0 : c.before, animate: false)
            } else if c.leveledUp, p >= 0.5 {
                LevelBar(level: c.level, into: c.after * (p - 0.5) / 0.5, tint: tint)
            } else if c.leveledUp {
                LevelBar(level: c.levelBefore, into: c.before + (1 - c.before) * p / 0.5, tint: tint)
            } else {
                LevelBar(level: c.level, into: c.before + (c.after - c.before) * p, tint: tint)
            }
            if !under.isEmpty { MonoLabel(under, color: Theme.muted2, lines: 2) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(c.code) \(c.label)")
    }

    /// The week row; when this session made today a session day, today's flame lights with a small pulse.
    private func streak(_ t: Double) -> some View {
        let lit = !s.lit || t >= timing.flame
        var cells = s.cells
        if !lit, cells.indices.contains(s.today) { cells[s.today] = .future }
        let n = lit ? s.streak : max(0, s.streak - 1)
        let q = Self.clamp((t - timing.flame) / 0.4)
        return VStack(alignment: .leading, spacing: Space.tight) {
            MonoLabel(n == 0 ? "streak · start one today" : "\(n) \(n == 1 ? "day" : "days") in a row", color: s.lit && lit ? Theme.sage : Theme.muted)
            WeekRow(cells: cells, today: s.today, size: 24)
                .scaleEffect(s.lit && t.isFinite ? 1 + 0.06 * sin(.pi * q) : 1, anchor: .leading)
        }
    }

    private var noteField: some View {
        Group {
            if snapshot {   // ImageRenderer paints a TextField as a yellow box; the render shows the empty well
                Text("what got done?").font(Type.body).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.07)))
            } else {
                TextField("what got done? · optional, return files it", text: $card.note)
                    .textFieldStyle(.plain).font(Type.body)
                    .rowPadding()
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.07)))
                    .focused($focused)
                    .onSubmit { card.fileNote() }
            }
        }
    }
}
