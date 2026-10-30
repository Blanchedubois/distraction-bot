import SwiftUI

/// Jeff's week grid (PLAN_WEEK_CALENDAR §3.2), read-only: a 24-hour canvas at 96 pt per hour scrolling under a pinned
/// day head, beside a 56 pt hour gutter; the now line in today's column. W1 draws the frame; W2 adds the blocks.
/// Every measure comes from `WeekGeometry`. The host sizes it (the card fills the window) and draws the bar.
struct WeekGrid: View {
    let model: WeekModel
    var now: Date = Date()
    /// Bumped by the host's "today" button: scroll to the landing position again even when the week has not changed.
    var landingRequest: Int = 0
    @Environment(\.snapshot) private var snapshot
    @Environment(\.colorScheme) private var scheme
    @Environment(\.narrow) private var narrow
    @State private var position = ScrollPosition(edge: .top)
    @State private var hx: CGFloat = 0                 // W5: the columns' horizontal offset when narrow, mirrored onto the pinned head

    /// Seven columns at the page's full width; below the 900 pt breakpoint Jeff's `colLayout` — whole columns that scroll sideways (§5a Q3).
    private func layout(width: CGFloat) -> (n: Int, colW: CGFloat) {
        let avail = width - G.gutterW
        if !narrow { return (7, (avail / 7).rounded(.down)) }
        return G.columns(available: avail)
    }

    private typealias G = WeekGeometry
    private var dark: Bool { scheme == .dark }
    private var showRail: Bool { model.allDay.contains { !$0.isEmpty } }     // §5a Q6: hidden when nothing is all-day
    private var pinnedH: CGFloat { G.headH + (showRail ? G.railH : 0) }
    private var landing: CGFloat { G.landing(dayStarts: model.dayStarts, holdsToday: model.holdsToday, now: now) }

    var body: some View {
        GeometryReader { g in
            let lay = layout(width: g.size.width), colW = lay.colW
            ZStack(alignment: .top) {
                if snapshot {
                    // ImageRenderer cannot draw a scroll view: the canvas is drawn at the landing offset and clipped
                    // clamped to the canvas end as a real scroll view clamps: the last screen is full, not half empty
                    let y = min(landing, max(0, G.canvasH + pinnedH - g.size.height))
                    content(colW: colW).padding(.top, pinnedH).offset(y: -y).frame(height: g.size.height, alignment: .top).clipped()
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        content(colW: colW).padding(.top, pinnedH)
                    }
                    .scrollPosition($position)
                    .onAppear { land() }
                    .onChange(of: model.weekStart) { _, _ in land() }
                    .onChange(of: landingRequest) { _, _ in land(animated: true) }
                }
                pinned(colW: colW, visible: CGFloat(lay.n) * colW)
            }
            .background(Theme.paper)
            .onChange(of: narrow) { _, _ in hx = 0 }
        }
    }

    private func land(animated: Bool = false) {
        let y = landing
        Task { @MainActor in
            if animated { withAnimation(.easeInOut(duration: 0.35)) { position.scrollTo(y: y) } } else { position.scrollTo(y: y) }
        }
    }

    // MARK: The pinned band — the day head (and, when needed, the rail) over the corner and the gutter's top

    private func pinned(colW: CGFloat, visible: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: G.gutterW, height: G.headH)
                    .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                HStack(spacing: 0) { ForEach(Array(model.days.enumerated()), id: \.offset) { i, day in dayHead(day, colW: colW) } }
                    .offset(x: -hx).frame(width: visible, alignment: .leading).clipped()
                Spacer(minLength: 0)
            }
            .frame(height: G.headH)
            .background(pinnedBackground(0.94))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            if showRail {
                HStack(spacing: 0) {
                    MonoLabel("all day", color: Theme.muted2).frame(width: G.gutterW - 8, alignment: .trailing).frame(width: G.gutterW)
                        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                    HStack(spacing: 0) { ForEach(0..<7, id: \.self) { i in
                        // W4: the all-day capsules — Jeff's rail chips, `.free` register: 18 pt, outline in the feed's tint, title 10.5 / 500
                        let items = model.allDay[i], cap = colW >= G.railCapWide ? 2 : 1
                        HStack(spacing: Space.hair) {
                            ForEach(items.prefix(cap)) { b in railCapsule(b) }
                            if items.count > cap { MonoLabel("+\(items.count - cap)").padding(.leading, Space.hair) }
                        }
                        .padding(.horizontal, Space.tight).frame(width: colW, height: G.railH, alignment: .leading)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.line.opacity(0.45)).frame(width: 1) }
                        .clipped()
                    } }
                    .offset(x: -hx).frame(width: visible, alignment: .leading).clipped()
                    Spacer(minLength: 0)
                }
                .frame(height: G.railH)
                .background(pinnedBackground(0.92))
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
            }
        }
    }

    private func railCapsule(_ b: WeekModel.Block) -> some View {
        let tint: Color = b.tint == "muted" ? Theme.muted2 : Theme.accent(b.tint)
        let edge: Color = tint.opacity(G.Skin.outline(dark: dark))
        let help: String = b.title + " · all day" + (b.third.map { " · " + $0 } ?? "")   // split out: CI's compiler timed out on the one chain (PLAN_PUBLIC_RELEASE P5)
        return Text(b.title).font(Type.caption).foregroundStyle(Theme.ink.opacity(0.82)).lineLimit(1)
            .padding(.horizontal, Space.stack).frame(height: 18)
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
            .help(help)
            .layoutPriority(-1)
    }

    /// Jeff: `paper 94 %` with a 5 px backdrop blur; the material is the blur (not under the offscreen renderer).
    @ViewBuilder private func pinnedBackground(_ alpha: Double) -> some View {
        if snapshot { Theme.paper } else { Theme.paper.opacity(alpha).background(.ultraThinMaterial) }
    }

    private func dayHead(_ day: Date, colW: CGFloat) -> some View {
        let cal = Calendar.current
        let wd = cal.component(.weekday, from: day)
        let weekend = wd == 1 || wd == 7
        let today = cal.isDateInToday(day)
        let f = DateFormatter(); f.dateFormat = colW >= G.wideDay ? "EEEE" : "EEE"
        return HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
            MonoLabel(f.string(from: day), color: weekend ? Theme.muted2 : Theme.muted)
            Text("\(cal.component(.day, from: day))")
                .font(Type.figureSmall)
                .foregroundStyle(today ? Theme.paper : Theme.ink)
                // today's pill is decoration drawn behind the number: it takes no space, so no head cell moves
                .background {
                    if today {
                        GeometryReader { t in
                            Capsule().fill(Theme.accent)
                                .frame(width: max(25, t.size.width + 15), height: 25)
                                .position(x: t.size.width / 2, y: t.size.height / 2)
                        }
                    }
                }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.pillH)
        .frame(width: colW, height: G.headH)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line.opacity(0.45)).frame(width: 1) }
        .clipped()
    }

    // MARK: The canvas — the gutter beside seven columns, 2304 pt tall

    private func content(colW: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 0) {
            gutter
            if narrow, !snapshot {
                ScrollView(.horizontal, showsIndicators: false) {
                    columns(colW: colW).scrollTargetLayout()
                }
                .scrollTargetBehavior(.viewAligned)       // whole columns always: the settle lands on a day edge
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in hx = max(0, x) }
            } else {
                columns(colW: colW)
            }
            Spacer(minLength: 0)
        }
        .frame(height: G.canvasH)
    }

    private func columns(colW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            rules(width: colW * 7)
            HStack(spacing: 0) {
                ForEach(Array(model.days.enumerated()), id: \.offset) { i, day in column(i, day: day, colW: colW) }
            }
        }
    }

    /// 01 … 23 — midnight's line is the canvas edge and needs no label. Mono 12 / 500 muted, 8 pt from the right edge, centred on the hour.
    private var gutter: some View {
        ZStack(alignment: .topTrailing) {
            Theme.paper
            ForEach(1..<24, id: \.self) { h in
                Text(String(format: "%02d", h)).font(Type.data).foregroundStyle(Theme.muted)
                    .frame(height: 16).offset(y: CGFloat(h) * G.hourH - 8).padding(.trailing, Space.stack)
            }
        }
        .frame(width: G.gutterW, height: G.canvasH)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    /// The hour rules (`line 60 %`) and half-hour rules (`line 22 %`), one Canvas under the columns.
    private func rules(width: CGFloat) -> some View {
        Canvas { ctx, size in
            var hours = Path(), halves = Path()
            for h in 0..<24 {
                let y = CGFloat(h) * G.hourH + 0.5
                hours.move(to: CGPoint(x: 0, y: y)); hours.addLine(to: CGPoint(x: size.width, y: y))
                let hy = y + G.hourH / 2
                halves.move(to: CGPoint(x: 0, y: hy)); halves.addLine(to: CGPoint(x: size.width, y: hy))
            }
            ctx.stroke(hours, with: .color(Theme.line.opacity(0.6)), lineWidth: 1)
            ctx.stroke(halves, with: .color(Theme.line.opacity(0.22)), lineWidth: 1)
        }
        .frame(width: width, height: G.canvasH)
        .allowsHitTesting(false)
    }

    private func column(_ i: Int, day: Date, colW: CGFloat) -> some View {
        let today = Calendar.current.isDateInToday(day)
        let packed = G.pack(model.blocks[i].map(\.span))
        return ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.blocks[i]) { b in
                if let p = packed.first(where: { $0.id == b.id }) { WeekBlock(block: b, packed: p, colW: colW) }
            }
            if today {
                if snapshot { nowLine(at: now, colW: colW) }
                else { TimelineView(.periodic(from: .now, by: 60)) { ctx in nowLine(at: ctx.date, colW: colW) } }
            }
        }
        .frame(width: colW, height: G.canvasH)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line.opacity(0.45)).frame(width: 1) }
    }

    /// Today's column only: a 1.5 pt accent rule across the column with a 7 pt dot at its left end (`left −3, top −4.5`).
    private func nowLine(at date: Date, colW: CGFloat) -> some View {
        let y = G.y(G.minute(of: date))
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.accent).frame(width: colW, height: 1.5).offset(y: y)
            Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: -3, y: y - 4.5 + 0.75)
        }
        .allowsHitTesting(false)
    }
}
