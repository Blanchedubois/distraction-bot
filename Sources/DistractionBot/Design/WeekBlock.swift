import SwiftUI

/// Jeff's `.wkb` — "the one genuinely new object: a chip that knows its own height" (PLAN_WEEK_CALENDAR §3.2–3.4).
/// Radius 9, fill = tint 22 % over paper, edge = tint 56 %, the label sheds a line at a time as the block shrinks, the
/// type glyph as a 46 pt watermark bleeding off the bottom-right, the subject code bottom-left. A session wears its
/// subject's accent; a feed block (W4) the feed's colour in a quieter register.
struct WeekBlock: View {
    let block: WeekModel.Block
    let packed: WeekGeometry.Packed
    let colW: CGFloat
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hot = false

    private typealias G = WeekGeometry
    private var dark: Bool { scheme == .dark }
    private var tint: Color { block.tint == "muted" ? Theme.muted2 : Theme.accent(block.tint) }
    private var feed: Bool { if case .feed = block.source { return true }; return false }
    private var placement: (top: CGFloat, height: CGFloat) { G.placement(start: packed.start, end: packed.end) }
    private var ladder: G.Ladder { G.ladder(for: placement.height) }
    private var narrow: Bool { packed.cols > 1 }

    var body: some View {
        let p = placement, fx = G.frameX(packed, colW: colW)
        let shape = RoundedRectangle(cornerRadius: G.blockRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            // fill: the tint over paper, for sessions and calendar events alike (2026-10-29: "a proper outline … and colored in")
            shape.fill(Theme.paper)
            shape.fill(tint.opacity(G.Skin.fill(dark: dark) * (feed && dark ? 1.7 : 1)))   // a pale feed colour at the session strength reads grey on dark paper
            pauses
            watermark
            label
            if ladder == .full, !narrow, !feed { kindWord }   // a feed block's kind word is the calendar's name, the same on every event: dropped
        }
        .frame(width: fx.width, height: p.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(tint.opacity(G.Skin.edge(dark: dark)), lineWidth: 1)   // one solid edge for every block
        }
        .brightness(hot ? (dark ? 0.12 : -0.035) : 0)                                   // Jeff's hover: brightness .965 / 1.12
        .modifier(Breathe(on: block.live && !snapshot && !reduceMotion, color: tint))  // the live session breathes, as Jeff's final does
        .offset(x: fx.x, y: p.top)
        .onHover { hot = $0 }
        .animation(.easeOut(duration: 0.12), value: hot)
        .help([block.title, block.meta, block.third].compactMap { $0 }.joined(separator: " · "))
        .contentShape(shape)
        .onTapGesture { open() }
        .accessibilityLabel(block.title + ", " + block.meta)
    }

    /// Title display 11 / 600 ink · time mono 8.5 / 600 (tint 58 % over muted) · the third line; `.med` drops the third,
    /// `.short` keeps the title alone, centred. A feed block's title is weight 500 in ink 82 % over muted (Jeff's `.free`).
    private var label: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            if ladder == .short { Spacer(minLength: 0) }
            Text(block.title).font(Type.caption)
                .foregroundStyle(Theme.ink).lineLimit(1)
            if ladder != .short {
                Mixed(block.meta, size: 8.5, tint: tint, over: Theme.muted, strength: G.Skin.inkMeta)
                if ladder == .full, let t = block.third { Mixed(t, size: 8.5, tint: tint, over: Theme.muted, strength: G.Skin.inkMeta) }
            }
            if ladder == .short { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Space.stack).padding(.vertical, ladder == .short ? Space.hair : Space.tight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The type in words, bottom-left: mono 8 / 600 `.06em` uppercase, tint 70 % over muted. Click → the subject's page.
    private var kindWord: some View {
        Mixed(block.kindWord.uppercased(), size: 8, tint: tint, over: Theme.muted, strength: G.Skin.inkType, tracking: 0.48)
            .padding(.leading, Space.stack).padding(.bottom, Space.tight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(block.subjectId != nil)
            .onTapGesture { if let s = block.subjectId { store.open(subject: s) } }
    }

    /// The objective's glyph at 46 pt, rotated −10°, `right −20 %, bottom −28 %`, tint at .16 (dark .26); the same size on every block.
    private var watermark: some View {
        Glyph(icon: block.symbol, size: G.watermark, color: tint)
            .opacity(G.Skin.watermark(dark: dark) * (feed ? 0.7 : 1))
            .rotationEffect(.degrees(-10))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: G.watermark * 0.20, y: G.watermark * 0.28)
            .allowsHitTesting(false)
    }

    /// A pause inside the block (§5a Q8): the Today strip's hatch — 135° ink lines at .12 every 5 pt — only in `.full` blocks.
    @ViewBuilder private var pauses: some View {
        if ladder == .full, !block.pauses.isEmpty {
            let top = placement.top
            ForEach(Array(block.pauses.enumerated()), id: \.offset) { _, r in
                let y0 = G.y(G.minute(of: r.lowerBound)) - top, y1 = G.y(G.minute(of: r.upperBound)) - top
                Canvas { ctx, size in
                    var path = Path()
                    var d: CGFloat = -size.height
                    while d < size.width { path.move(to: CGPoint(x: d, y: size.height)); path.addLine(to: CGPoint(x: d + size.height, y: 0)); d += 5 }
                    ctx.stroke(path, with: .color(Theme.ink.opacity(0.12)), lineWidth: 1)
                }
                .frame(height: max(3, y1 - y0)).offset(y: y0)
                .allowsHitTesting(false)
            }
        }
    }

    /// A session block opens the Log filtered to the session's span (S1's filter); a feed block only has its tooltip (§5a Q14).
    private func open() {
        guard case .session = block.source else { return }
        store.go(.log, query: "", from: block.start, to: block.end, title: block.title)
    }
}

/// Jeff's `color-mix(in oklab, tint S%, base)` as two layered texts: the base colour under the tint at S opacity — exact in
/// sRGB terms, and theme-safe (both colours stay dynamic). Mono, semibold, one line.
private struct Mixed: View {
    let text: String; let size: CGFloat; let tint: Color; let over: Color; let strength: Double; var tracking: CGFloat = 0
    init(_ text: String, size: CGFloat, tint: Color, over: Color, strength: Double, tracking: CGFloat = 0) {
        self.text = text; self.size = size; self.tint = tint; self.over = over; self.strength = strength; self.tracking = tracking
    }
    var body: some View {
        let font = size <= 8 ? Type.label : Type.data   // G4: the kind word is a label, the time lines are data; `size` is kept for the callers
        Text(text).font(font).tracking(tracking).foregroundStyle(over).lineLimit(1)
            .overlay { Text(text).font(font).tracking(tracking).foregroundStyle(tint.opacity(strength)).lineLimit(1) }
    }
}

/// The live block's halo: Jeff's `wkbBreathe` — a 3.6 s box-shadow in the tint from 5 px/10 % to 16 px/42 % (dark 6/16 → 20/60).
private struct Breathe: ViewModifier {
    let on: Bool
    let color: Color
    @Environment(\.colorScheme) private var scheme
    @State private var phase = false
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .shadow(color: on ? color.opacity(phase ? (dark ? 0.6 : 0.42) : (dark ? 0.16 : 0.10)) : .clear, radius: on ? (phase ? (dark ? 10 : 8) : 2.5) : 0)
            .onAppear { if on { withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { phase = true } } }
    }
}
