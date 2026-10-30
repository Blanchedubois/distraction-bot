import AppKit
import SwiftUI

/// What the closing card shows (PLAN_GAME_LOOP §3.6, G4): the streak with today's flame lighting, the score landing with `closed`,
/// the day's main course moving. Built by `Store.fileShutdown`; the `closing` snapshot draws a fixture.
struct ClosingSummary {
    var dayLabel: String                 // `wed 28 oct`
    var stars: String                    // `★★★★☆`, "" without a rating
    var streak: Int
    var cells: [WeekCell]
    var today: Int
    var freezeEarned = false
    var freezes = 0
    var scoreBefore: Int?                // the day's score before the filing (nil when nothing was focused)
    var scoreAfter: Int
    var word: String
    var unplanned = false
    var focused: TimeInterval = 0
    var sessions = 0
    var course: CourseMove?              // the day's most-focused course, from the day's start to now
    var losses: [Tally.Loss] = []        // PLAN_GAME_FEEL F2: the day's tally once closed (no `open` row)
}

/// The closing card (PLAN_STUDY_DAY §3.6, K2 → PLAN_GAME_LOOP §3.6, G4): a `Shield`-recipe glass card, 620 × 300, centred on the pointer's
/// screen, no veil, no buttons — the streak and its week row, the score counting to its closed value, the course line. Fades after 5 s or on a
/// click. No session is live when it shows, so the mini panel needs no suspending.
@MainActor
@Observable
final class ClosingCard {
    static let shared = ClosingCard()
    var summary = ClosingSummary(dayLabel: "", stars: "", streak: 0, cells: Array(repeating: .future, count: 7), today: 0, scoreAfter: 0, word: "")
    var shownAt = Date()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    static let size = NSSize(width: 620, height: 300)

    func show(summary: ClosingSummary) {
        guard ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] == nil else { return }
        self.summary = summary; shownAt = Date()
        let p = panel ?? makePanel()
        panel = p
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            p.setFrame(NSRect(origin: NSPoint(x: v.midX - Self.size.width / 2, y: v.midY - Self.size.height / 2 + 40), size: Self.size), display: true)
        }
        p.alphaValue = 0; p.orderFrontRegardless(); NSAnimationContext.runAnimationGroup { c in c.duration = 0.25; p.animator().alphaValue = 1 }
        hideTask?.cancel()
        hideTask = Task { try? await Task.sleep(for: .seconds(5)); if !Task.isCancelled { hide() } }
    }

    func hide() {
        hideTask?.cancel()
        guard let p = panel else { return }
        NSAnimationContext.runAnimationGroup({ c in c.duration = 0.4; p.animator().alphaValue = 0 }, completionHandler: { Task { @MainActor in p.orderOut(nil) } })
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
        p.contentView = NSHostingView(rootView: ClosingCardView(card: self))
        return p
    }
}

struct ClosingCardView: View {
    @Bindable var card: ClosingCard
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshot) private var snapshot
    @State private var lit = false         // today's flame scales in once the card is up
    private var s: ClosingSummary { card.summary }
    private var scoreColor: Color { s.scoreAfter >= 75 ? Theme.sage : s.scoreAfter >= 50 ? Theme.warn : Theme.danger }
    private var still: Bool { reduceMotion || snapshot }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.card) {
            HStack(spacing: Space.loose) {
                Icon("flag.checkered", .card, color: Theme.accent)
                MonoLabel("day shut down · \(s.dayLabel)", color: Theme.muted)
                Spacer()
                if !s.stars.isEmpty { MonoLabel("rating \(s.stars)", color: Theme.muted) }
            }
            HStack(alignment: .top, spacing: Space.sheet) {
                VStack(alignment: .leading, spacing: Space.stack) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.loose) {
                        Text("\(s.streak)").font(Type.figure).monospacedDigit().foregroundStyle(Theme.ink)
                        Text(s.streak == 1 ? "day · a start" : "days in a row").font(Type.headline).foregroundStyle(s.streak > 0 ? Theme.sage : Theme.muted)
                    }
                    // the week row with today's flame lighting up (scale 0.6 → 1 after 0.4 s); the other cells as Home draws them
                    WeekRow(cells: s.cells, today: s.today, tint: Theme.sage)
                        .mask(alignment: .leading) { todayMask }
                        .overlay(alignment: .leading) { if s.cells.indices.contains(s.today), s.cells[s.today] == .session { litFlame } }
                    MonoLabel(s.freezeEarned ? "a freeze earned · \(s.freezes) in hand" : s.freezes > 0 ? "\(s.freezes) freeze\(s.freezes == 1 ? "" : "s") in hand" : XP.freezeRule, color: s.freezeEarned ? Theme.sage : Theme.muted)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: Space.stack) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
                        if s.unplanned { Text(minutes(s.focused)).font(Type.figure).monospacedDigit().foregroundStyle(Theme.ink) }
                        else {
                            landingFigure
                            Text(s.word).font(Type.headline).foregroundStyle(scoreColor)
                        }
                    }
                    if s.unplanned { MonoLabel("unplanned day · \(s.sessions) session\(s.sessions == 1 ? "" : "s")", color: Theme.muted).lineLimit(1) }
                    else {
                        // F2 (PLAN_GAME_FEEL §3.2): the tally's last row turning over, then the day's line without it
                        if let before = s.scoreBefore, s.scoreAfter > before { MonoLabel("open −\(s.scoreAfter - before) → shut down +\(s.scoreAfter - before)", color: Theme.sage) }
                        Text(Tally.line(s.losses, total: s.scoreAfter)).font(Type.data).foregroundStyle(Theme.muted).lineLimit(2).multilineTextAlignment(.trailing)
                            .frame(maxWidth: 300, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            if let c = s.course {
                if c.leveledUp {   // F4 (PLAN_GAME_FEEL §3.4): the level-up beat, as on the end card
                    HStack(spacing: Space.stack) {
                        Icon("arrow.up.circle.fill", .row, color: Theme.accent(c.accent))
                        Text("Level \(c.level)").font(Type.headline).foregroundStyle(Theme.accent(c.accent))
                    }
                }
                CourseLine(move: c, animate: !still, plain: c.leveledUp)
            } else { MonoLabel("no course worked today", color: Theme.muted2) }
        }
        .padding(Space.sheet)
        .frame(width: ClosingCard.size.width, height: ClosingCard.size.height, alignment: .topLeading)
        .modifier(GlassBack(watermark: "flame", accent: Theme.accent))
        .contentShape(Rectangle())
        .onTapGesture { card.hide() }
        .onAppear { if still { lit = true } else { lit = false; withAnimation(.spring(duration: 0.5, bounce: 0.3).delay(0.4)) { lit = true } } }
    }
    /// The row with today's cell cut out, so the lit flame can be drawn over it on its own.
    private var todayMask: some View {
        HStack(spacing: Space.stack) {
            ForEach(0..<7, id: \.self) { i in Rectangle().fill(i == s.today && s.cells[i] == .session ? Color.clear : Color.black).frame(width: 30) }
        }
    }
    private var litFlame: some View {
        HStack(spacing: Space.stack) {
            ForEach(0..<7, id: \.self) { i in
                ZStack {
                    if i == s.today {
                        Circle().strokeBorder(Theme.sage.opacity(0.5), lineWidth: 1)
                        Icon("flame.fill", .row, color: Theme.sage).scaleEffect(lit ? 1 : 0.6).opacity(lit ? 1 : 0)
                    }
                }
                .frame(width: 30, height: 30)
            }
        }
    }
    /// `97` counting up from the unclosed score over 1 s (text only when still).
    private var landingFigure: some View {
        let before = s.scoreBefore ?? s.scoreAfter, after = s.scoreAfter
        return Group {
            if before != after, !still {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { ctx in
                    let t = min(1, max(0, (ctx.date.timeIntervalSince(card.shownAt) - 0.4) / 1.0))
                    Text("\(before + Int(Double(after - before) * t))").font(Type.figure).monospacedDigit().foregroundStyle(Theme.ink)
                }
            } else { Text("\(after)").font(Type.figure).monospacedDigit().foregroundStyle(Theme.ink) }
        }
    }
}
