import SwiftUI

/// The Today card's body (PLAN_TODAY_TIMELINE §3): Jeff's semester strip drawn for one day — a ruler of hours, the
/// sessions as blocks on a 36 pt track, distraction periods as chips on branch pins with their span hatched into the
/// block, blocks as ticks under the track, a now rule. Interior-only: the host draws the header and the card.
/// T1 draws the rest state at fit scale; hover (T2) and zoom (T3) come later into this same view.
struct TodayTimeline: View {
    let model: DayModel
    var now: Date?
    var accent: Color = Theme.accent
    /// R3 (PLAN_REWORK §3.5, D13): the head's `show ▾` and zoom controls; the objective pane's per-day strips pass `false`.
    var controls: Bool = true

    enum Family: String, CaseIterable, Identifiable { case detours, falseAlarms = "false alarms", blocks, looks; var id: String { rawValue } }
    @State private var on: Set<Family> = [.detours, .blocks]
    /// Jeff's hover with HYSTERESIS: the hover moves the geometry (the dot grows into the pill), so a plain hover could
    /// flip off as the view slides under the cursor. Enter sets `hot` at once; leave clears it after a 140 ms grace.
    @State private var hot: String?
    @State private var leaving: Task<Void, Never>?
    @State private var fanned: String?                       // a cluster opened by click (hover opens it too)
    @FocusState private var focused: String?
    /// T3 — one number, px per hour (nil = fit, the whole day), and one offset (Jeff's useStripView).
    @State private var zoom = TodayGeometry.Zoom()
    /// True once the user has zoomed or panned by hand; the strip then never re-fits on its own ("now" or a new day reset it).
    @State private var byHand = false
    @State private var width: CGFloat = 0
    @State private var canvasFrame: CGRect = .zero
    @State private var wheelMonitor: Any?
    @State private var dragFrom: CGFloat?
    @Environment(\.narrow) private var narrow
    @Environment(\.snapshot) private var snapshot
    @Environment(\.colorScheme) private var scheme
    @Environment(Store.self) private var store
    /// PLAN_TODAY_SCHEDULE D1 (§3.2): a legend entry tapped dims the other subjects' blocks (not a filter; tap again clears).
    @State private var heldSubject: String?

    private typealias G = TodayGeometry

    var body: some View {
        VStack(alignment: .leading, spacing: G.rowGap) {
            head.frame(height: G.headH(twoRows: narrow))
            planRow.frame(height: G.planH)
            if now != nil, !snapshot {
                TimelineView(.periodic(from: .now, by: model.blocks.contains { $0.live } ? 1 : 60)) { ctx in
                    GeometryReader { g in canvas(width: g.size.width, at: ctx.date) }
                }
                .frame(height: G.canvasH)
            } else {
                GeometryReader { g in canvas(width: g.size.width, at: now) }
                    .frame(height: G.canvasH)
            }
        }
        .frame(height: G.bodyH(twoRows: narrow))
    }

    // MARK: Head — standing · chips  (Jeff's `.ss-head`)

    /// Narrow (§5a Q10, G4): the figure and the standing on one row, the chips and the zoom on a second — the head is `G.headH(twoRows:)` tall.
    @ViewBuilder private var head: some View {
        let f = model.figures
        if narrow {
            VStack(alignment: .leading, spacing: Space.stack) {
                HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
                    if f.sessions == 0 { Text(StudyDay.isToday(model.day) ? "Nothing yet today" : "Nothing that day").font(Type.figureSmall).foregroundStyle(Theme.muted2) }
                    else { Text(short(f.focused)).font(Type.figureSmall).foregroundStyle(Theme.ink).monospacedDigit().fixedSize(); standing(f, saidWork: false, last: false, minutes: false) }
                    Spacer(minLength: 0)
                }
                if controls { HStack(spacing: Space.stack) { tail } }
            }
        } else { wideHead(f) }
    }

    private func wideHead(_ f: DayModel.Figures) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
            if f.sessions == 0 {
                Text(StudyDay.isToday(model.day) ? "Nothing yet today" : "Nothing that day").font(Type.figureSmall).foregroundStyle(Theme.muted2)
                Spacer(minLength: Space.stack)
                tail
            } else {
                Text(short(f.focused)).font(Type.figureSmall).foregroundStyle(Theme.ink).monospacedDigit().fixedSize()
                // Jeff's standing: what does not fit is dropped from the right, never truncated mid-word
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.stack) { standing(f, saidWork: true, last: true); Spacer(minLength: Space.stack); tail }
                    HStack(spacing: Space.stack) { standing(f, saidWork: true, last: false); Spacer(minLength: Space.stack); tail }
                    HStack(spacing: Space.stack) { standing(f, saidWork: false, last: false); Spacer(minLength: Space.stack); tail }
                    HStack(spacing: Space.stack) { standing(f, saidWork: false, last: false, minutes: false); Spacer(minLength: Space.stack); tail }
                }
            }
        }
    }

    private func standing(_ f: DayModel.Figures, saidWork: Bool, last: Bool, minutes: Bool = true) -> some View {
        HStack(spacing: Space.tight) {
            MonoLabel("focused")
            if let c = f.clean { MonoLabel(String(format: "· %.0f %% clean", c * 100), color: Theme.ink) }   // R3 (D17): a figure, not a verdict — one accent on the card
            MonoLabel("· \(f.detours) detour\(f.detours == 1 ? "" : "s")" + (minutes ? " · \(short(f.distracted))" : "") + " · \(f.blocks) block\(f.blocks == 1 ? "" : "s")")
            if saidWork, f.falseAlarms > 0 { MonoLabel("· \(f.falseAlarms) said work", color: Theme.muted2) }
            if last, let l = model.last { MonoLabel("· last \(l.title) \(clock(l.start))", color: Theme.muted2) }
        }
        .fixedSize()
    }

    // MARK: Dress — the objective on a block (PLAN_TODAY_SCHEDULE D1, §3.2)

    /// What a session block wears: its subject's colour, its objective's glyph and title; grey for a one-off, a removed
    /// objective, or a B-phase test. Resolved through the catalogue here, so the model stays pure.
    struct Dress { let tint: Color; let icon: String; let title: String; let subjectId: String?; let code: String? }
    private func dress(_ b: DayModel.Block) -> Dress {
        if b.goal.range(of: #"^B\d+\s"#, options: .regularExpression) != nil { return Dress(tint: Theme.muted2, icon: "wrench", title: b.goal, subjectId: nil, code: nil) }
        guard let oid = b.objectiveId else { return Dress(tint: Theme.muted2, icon: "text.cursor", title: b.goal, subjectId: nil, code: nil) }
        guard let o = store.objective(oid) else { return Dress(tint: Theme.muted2, icon: "questionmark", title: b.goal, subjectId: nil, code: nil) }
        let s = store.subject(o.subjectId)
        return Dress(tint: s.map { Theme.accent($0.accent) } ?? accent, icon: o.icon.isEmpty ? (s?.icon ?? "target") : o.icon,
                     title: o.title.isEmpty ? b.goal : o.title, subjectId: s?.id, code: s?.code ?? s?.shortName)
    }
    /// The wash recipe (fill · edge · elapsed · label opacities): the strip's sage recipe with the tint swapped in. In dark,
    /// a deep tint (relative luminance < 0.2, e.g. #004aa1) is lifted so it still reads as a wash on dark paper — one
    /// place, gone when `Theme.accent` lifts app-wide (§5a Q9).
    private func wash(_ tint: Color) -> (fill: Double, edge: Double, done: Double, label: Double, text: Color) {
        if scheme == .dark, Self.luminance(tint) < 0.2 { return (0.22, 0.50, 0.45, 0.90, Theme.ink2) }     // deep tint: the words in ink, not in the tint
        return (0.12, 0.30, 0.42, 0.70, tint)
    }
    private static func luminance(_ c: Color) -> Double {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return 0.5 }
        func lin(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(n.redComponent) + 0.7152 * lin(n.greenComponent) + 0.0722 * lin(n.blueComponent)
    }
    /// The subjects that appear in the day's blocks, in order of first appearance (one-offs are not subjects).
    private var subjectsToday: [(id: String, code: String, tint: Color)] {
        var seen: Set<String> = []; var out: [(String, String, Color)] = []
        for b in model.blocks { let d = dress(b); if let id = d.subjectId, !seen.contains(id) { seen.insert(id); out.append((id, d.code ?? "", d.tint)) } }
        return out
    }
    /// The legend, only when two or more subjects appear: a 6 pt dot and the subject code in the canvas's bottom strip
    /// (the head's ladder has no room for it at 1080 — rendered 2026-10-27, §6 D1); tapping one dims the others.
    @ViewBuilder private func legend(_ geo: G) -> some View {
        let subs = subjectsToday
        if subs.count >= 2 {
            HStack(spacing: Space.stack) {
                ForEach(subs, id: \.id) { s in
                    HStack(spacing: Space.tight) {
                        Circle().fill(s.tint).frame(width: 6, height: 6)
                        MonoLabel(s.code, color: heldSubject == nil || heldSubject == s.id ? Theme.muted : Theme.muted2)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { heldSubject = heldSubject == s.id ? nil : s.id }
                    .help(heldSubject == s.id ? "Show every subject" : "Dim the other subjects' sessions")
                }
            }
            .fixedSize()
            .offset(x: 6, y: G.canvasH - 11)
        }
    }

    // MARK: Plan — progress through the day (PLAN_TODAY_SCHEDULE D2, §3.4)

    /// "of 4 h planned · 2 sessions done · 1 on", a 4 pt ink bar (focused ÷ target) with a tick where now sits in the
    /// day, and the percentage. Without a target (a 0-minute day) the words alone.
    private var planRow: some View {
        let f = model.figures
        let done = "\(f.sessionsDone) session\(f.sessionsDone == 1 ? "" : "s") done" + (f.sessionsLive > 0 ? " · \(f.sessionsLive) on" : "")
        return HStack(spacing: Space.stack) {
            if let t = f.target { MonoLabel("of \(short(t)) planned · " + done).fixedSize() } else { MonoLabel(done).fixedSize() }
            if let p = f.progress {
                GeometryReader { g in
                    let w = g.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.ghost).frame(height: 4)
                        Capsule().fill(Theme.ink.opacity(0.55)).frame(width: max(4, w * p), height: 4)
                        // the tick: where now sits between the axis's start and end — ahead of it is on pace
                        if let n = now ?? model.now, n > model.axisStart, n < model.axisEnd {
                            let k = n.timeIntervalSince(model.axisStart) / model.axisEnd.timeIntervalSince(model.axisStart)
                            Rectangle().fill(Theme.line2).frame(width: 1, height: 8).offset(x: w * k - 0.5)
                        }
                    }
                    .frame(height: 8)
                    .position(x: w / 2, y: g.size.height / 2)
                }
                MonoLabel(String(format: "%.0f %%", p * 100), color: Theme.muted2).fixedSize()
            } else { Spacer() }
        }
    }

    // MARK: The block as an event — pill and click (D2, §3.3)

    private func blockKey(_ b: DayModel.Block) -> String { "b-\(b.start.timeIntervalSince1970)" }
    /// "18:59–19:59 · 60 min · 1 detour · 1 pause", or for the live block "since 20:04 · 1 h 17 · ends 21:04".
    private func when(_ b: DayModel.Block) -> String {
        var parts: [String]
        if b.live {
            parts = ["since \(clock(b.start))", short(b.duration)]
            if let m = DayModel.minutes(b.length) { parts.append("ends \(clock(b.start.addingTimeInterval(m)))") } else { parts.append("open") }
        } else {
            parts = ["\(clock(b.start))–\(clock(b.end))", short(b.duration)]
            if !b.ended { parts.append("no end recorded") }
        }
        if b.detours > 0 { parts.append("\(b.detours) detour\(b.detours == 1 ? "" : "s")") }
        if !b.pauses.isEmpty { parts.append("\(b.pauses.count) pause\(b.pauses.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
    /// Click (§5a Q5): an objective's block opens its pane; a one-off opens the Log sliced to the session.
    private func open(_ b: DayModel.Block) {
        if let oid = b.objectiveId, store.objective(oid) != nil { store.open(objective: oid) }
        else { store.go(.log, query: "", from: b.start.addingTimeInterval(-2), to: b.end.addingTimeInterval(2), title: "session · \(b.goal)") }
    }
    /// The hot block's pill: rises over the ruler row at the block's start, the hot-chip recipe, growing leftward near
    /// the right edge; z 6, inside the canvas (the card clips, so it cannot reach the head's gap as §3.3 wished).
    private func blockPill(_ b: DayModel.Block, d: Dress, o: (fill: Double, edge: Double, done: Double, label: Double, text: Color), x: CGFloat, geo: G) -> some View {
        let maxW = min(360, geo.width - 12)
        let left: CGFloat = x + maxW <= geo.width - 6 ? x : (x - maxW >= 6 ? x - maxW : max(6, min(geo.width - 6 - maxW, x - maxW / 2)))
        let align: Alignment = left == x ? .leading : (left == x - maxW ? .trailing : .center)
        return HStack(spacing: Space.tight) {
            Icon(d.icon, .row, color: o.text).frame(width: 18)
            Text(d.title).font(Type.caption).lineLimit(1).truncationMode(.tail)
            MonoLabel(when(b), color: o.text.opacity(0.8)).transition(.opacity.animation(.easeOut(duration: 0.12).delay(0.08)))
        }
        .foregroundStyle(o.text)
        .padding(.leading, Space.tight).padding(.trailing, Space.pillH).frame(height: 24)
        .frame(maxWidth: maxW, alignment: .leading)
        .fixedSize(horizontal: true, vertical: true)
        .background(Capsule().fill(d.tint.opacity(0.11)).background(Capsule().fill(Theme.paper)))
        .overlay(Capsule().strokeBorder(d.tint.opacity(0.45), lineWidth: 1))
        .background(Capsule().strokeBorder(Theme.paper, lineWidth: 2).padding(-2))
        .shadow(color: .black.opacity(0.18), radius: 11, y: 8)
        .frame(width: maxW, alignment: align)
        .offset(x: left, y: 0)
        .transition(.opacity.combined(with: .offset(y: 4)))
        .zIndex(6)
    }

    /// R3 (PLAN_REWORK §3.5, §5a Q5): the four family pills are one `show ▾` menu of toggles; the zoom stays `− day + · now`.
    @ViewBuilder private var tail: some View {
        if controls {
            PillToggles(options: Family.allCases.map { ($0, $0.rawValue) }, selection: $on, label: on == [.detours, .blocks] ? "show" : "show · \(on.count)")
            zoomControls
        }
    }

    // MARK: Canvas — ruler · track · ticks · lanes · now

    private func canvas(width: CGFloat, at clock: Date?) -> some View {
        let now = clock
        var geo = G(start: model.axisStart, end: model.axisEnd, width: width, pxPerHour: zoom.scale ?? G.fitScale(start: model.axisStart, end: model.axisEnd, width: width))
        geo.scrollX = G.clampScroll(zoom.scrollX, total: geo.total, width: width)
        let lo: CGFloat = -160, hi = width + 160
        let shownPeriods = model.periods.filter { ($0.falseAlarm && on.contains(.falseAlarms)) || (!$0.falseAlarm && on.contains(.detours)) }
        let chipW: CGFloat = geo.detail == .hours3 ? 22 : geo.detail == .hours ? 120 : 154
        // Jeff: marks within a dot cluster first, then the singles pack; what will not fit clusters too
        let groups = G.cluster(shownPeriods.map { ($0, geo.x($0.start)) }.filter { $0.1 >= lo && $0.1 <= hi }, within: 10)
        let singles = groups.filter { $0.items.count == 1 }.map { (item: $0.items[0], x: $0.x, w: chipW) }
        let multi = groups.filter { $0.items.count > 1 }
        let packed = G.packLanes(singles, lanes: multi.isEmpty ? G.lanes : G.lanes - 1, gap: 6)
        // D3: dot clusters and lane overflow cluster as ONE set at 40 pt (36 pt badges), so two badges never overlap
        let clusters = G.cluster(multi.flatMap { grp in grp.items.map { (item: $0, x: grp.x) } } + packed.overflow.map { (item: $0.item, x: $0.x) }, within: 40)
        let clusterLane = G.lanes - 1

        return ZStack(alignment: .topLeading) {
            ruler(geo)
            track(geo)
            ticks(geo)
            if on.contains(.blocks) { blockTicks(geo) }
            if on.contains(.looks) { lookTicks(geo) }
            ForEach(Array(packed.placed.enumerated()), id: \.offset) { _, p in chip(p.item, x: p.x, lane: p.lane, geo: geo, dot: geo.detail == .hours3) }
            ForEach(Array(clusters.enumerated()), id: \.offset) { _, c in countChip(c, lane: clusterLane, geo: geo) }
            nowRule(geo)
            legend(geo)
            canvasOriginLogger()
        }
        .frame(width: width, height: G.canvasH, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        // DRAG pans when zoomed; a press under 3 pt is still a click on a chip
        .gesture(DragGesture(minimumDistance: 3).onChanged { v in
            guard zoomed else { return }
            if dragFrom == nil { dragFrom = zoom.scrollX; fanned = nil; byHand = true }
            zoom = G.pan(G.Zoom(scale: zoom.scale, scrollX: dragFrom ?? zoom.scrollX), by: -v.translation.width, fit: fit, hours: hours, width: width)
        }.onEnded { _ in dragFrom = nil })
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in
            // ←/→ pan 10 % (shift: an hour), +/− zoom ×1.6 about the centre, Home = the day, N = now
            switch press.key {
            case .leftArrow: panBy(press.modifiers.contains(.shift) ? -pxPerHour : -width * 0.1); return .handled
            case .rightArrow: panBy(press.modifiers.contains(.shift) ? pxPerHour : width * 0.1); return .handled
            case .home: snapDay(); return .handled
            default:
                switch press.characters {
                case "+", "=": zoomAt(pxPerHour * 1.6, cx: width / 2); return .handled
                case "-", "_": zoomAt(pxPerHour / 1.6, cx: width / 2); return .handled
                case "n", "N": snapNow(); return .handled
                default: return .ignored
                }
            }
        }
        .background(GeometryReader { g in Color.clear.onChange(of: g.frame(in: .global), initial: true) { _, f in canvasFrame = f } })
        .onChange(of: width, initial: true) { _, w in self.width = w; if !byHand { fitWorked(width: w) } }
        .onChange(of: model.day) { _, _ in byHand = false; fitWorked(width: width) }             // the day rolled over
        .onChange(of: model.workedWindow(now: now ?? model.now)) { _, _ in if !byHand { fitWorked(width: width) } }
        .onChange(of: zoom) { _, _ in fanned = nil; hot = nil }
        .onAppear { self.width = width; installWheel() }
        .onDisappear { removeWheel() }
        .help(zoomed ? "Drag or scroll sideways to pan · scroll to zoom · Home fits the day · N fits the worked hours" : "Scroll or pinch over the strip to zoom in")
    }

    /// Hour bands with a hairline left edge and a mono label 6 pt in (Jeff's `.ss-month`).
    private func ruler(_ geo: G) -> some View {
        ForEach(Array(geo.bands().filter { $0.x1 >= -160 && $0.x0 <= geo.width + 160 }.enumerated()), id: \.offset) { _, b in
            if b.x0 > 0 { Rectangle().fill(Theme.line).frame(width: 1, height: G.rulerH).offset(x: b.x0) }
            // the label clamps to the viewport's left edge, so the hour you are zoomed into is always named
            let lx = max(b.x0, 0), room = b.x1 - lx
            if room > 26 { MonoLabel(b.label, color: Theme.ink2).offset(x: lx + 6, y: 1) }
        }
    }

    /// The sessions as blocks: radius 6, accent 12 % over paper, 30 % edge, the elapsed part at 42 %; pauses hatched;
    /// distraction spans hatched in their tint; outside any session a dashed hairline at mid-track.
    private func track(_ geo: G) -> some View {
        let y = G.trackTop
        return ZStack(alignment: .topLeading) {
            Path { p in p.move(to: CGPoint(x: 0, y: y + G.trackH / 2)); p.addLine(to: CGPoint(x: geo.width, y: y + G.trackH / 2)) }
                .stroke(Theme.line2.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            ForEach(model.planned) { p in plannedBlock(p, geo: geo, now: now) }   // P2 (PLAN_PLANNING §3.3): under the real blocks
            ForEach(Array(model.blocks.enumerated()), id: \.offset) { _, b in
                let x0 = geo.x(b.start), x1 = geo.x(b.end), w = max(2, x1 - x0)
                let fillTo = b.live ? x1 : (now.map { min(x1, geo.x($0)) } ?? x1)
                // D1: the block wears its objective — the subject's colour as the wash, the glyph and title inside it
                let d = dress(b), o = wash(d.tint)
                let dimmed = heldSubject != nil && heldSubject != d.subjectId
                let bk = blockKey(b)
                let isHot = !snapshot && (hot == bk || focused == bk)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(d.tint.opacity(o.fill))
                    Rectangle().fill(d.tint.opacity(o.done)).frame(width: max(0, fillTo - x0))
                    ForEach(Array(b.pauses.enumerated()), id: \.offset) { _, s in
                        hatch(Theme.ink.opacity(0.12), label: s.label).frame(width: max(3, geo.x(s.end) - geo.x(s.start))).offset(x: geo.x(s.start) - x0)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: max(3, geo.x(s.end) - geo.x(s.start))).offset(x: geo.x(s.start) - x0), alignment: .leading)
                    }
                    ForEach(Array(model.periods.enumerated()), id: \.offset) { _, p in
                        if !p.falseAlarm, p.start >= b.start, p.start <= b.end, on.contains(.detours) {
                            hatch(tint(p).opacity(0.35), label: nil).frame(width: max(3, geo.x(p.end) - geo.x(p.start))).offset(x: geo.x(p.start) - x0)
                        }
                    }
                    // by width (§3.3): ≥ 150 glyph · title · "60 min · normal"; 60–150 glyph · title; 24–60 the glyph; under 24 nothing
                    if w >= 24 {
                        HStack(spacing: Space.tight) {
                            Icon(d.icon, .row, color: o.text).frame(width: 16)
                            if w >= 60 { Text(d.title).font(Type.caption).foregroundStyle(o.text.opacity(0.9)).lineLimit(1).truncationMode(.tail) }
                            if w >= 150 { MonoLabel([b.length, b.strictness].filter { !$0.isEmpty }.joined(separator: " · "), color: o.text.opacity(o.label)) }
                        }
                        .padding(.horizontal, Space.tight).padding(.vertical, Space.hair)
                        // a paper lozenge under the words only where the elapsed fill runs beneath them
                        .background(Capsule().fill(Theme.paper.opacity(fillTo - x0 > 20 ? 0.6 : 0)))
                        .padding(.leading, Space.tight)
                        .frame(maxWidth: w - 6, alignment: .leading)
                    }
                }
                .frame(width: w, height: G.trackH)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(d.tint.opacity(isHot ? 0.6 : o.edge), lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(accent, lineWidth: focused == bk ? 2 : 0).padding(-4))   // the focus ring
                .opacity(dimmed ? 0.5 : 1)
                .animation(.easeOut(duration: 0.15), value: isHot)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onContinuousHover { ph in switch ph { case .active: enter(bk); case .ended: leave(bk) } }
                .onTapGesture { open(b) }
                .focusable().focused($focused, equals: bk).focusEffectDisabled()
                .onKeyPress(.return) { open(b); return .handled }
                .help("\(d.title) · \(when(b))")
                .offset(x: x0, y: y)
                .zIndex(isHot ? 5 : 1)
                // the pill: the same hover, so moving from the block onto it keeps it hot (Jeff's grace covers the gap)
                if isHot {
                    blockPill(b, d: d, o: o, x: x0, geo: geo)
                        .onContinuousHover { ph in switch ph { case .active: enter(bk); case .ended: leave(bk) } }
                        .onTapGesture { open(b) }
                }
            }
        }
    }

    // MARK: Planned blocks (PLAN_PLANNING §3.3, P2, R10)

    /// A planned block from the calendar: a dashed empty block in the subject's hairline (`tint.opacity(0.30)`, dash `[4, 3]`, radius 6,
    /// no fill), the glyph at the left from 24 pt and the title from 60 pt in the tint's label strength. A real session over it is
    /// drawn on top. In the future, with no session on, hover shows a `start ▸` pill and a click queues it (`prepareSession(planned:)`).
    private func plannedBlock(_ p: DayModel.Planned, geo: G, now: Date?) -> some View {
        let s = store.subject(p.subjectId)
        let tint = s.map { Theme.accent($0.accent) } ?? accent
        let icon = p.objectiveId.flatMap { store.objective($0)?.icon } ?? s?.icon ?? "calendar"
        let x0 = geo.x(p.start), w = max(2, geo.x(p.end) - x0)
        let k = "p-\(p.id)"
        let future = (now ?? model.now).map { p.start > $0 } ?? false
        let canStart = future && store.session == nil && !snapshot
        let isHot = !snapshot && hot == k
        let dimmed = heldSubject != nil && heldSubject != p.subjectId
        let label = tint.opacity(wash(tint).label)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(tint.opacity(isHot ? 0.6 : 0.30), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            if w >= 24 {
                HStack(spacing: Space.tight) {
                    Icon(icon, .row, color: label).frame(width: 16)
                    if w >= 60 { Text(p.title).font(Type.caption).foregroundStyle(label).lineLimit(1).truncationMode(.tail) }
                    if w >= 150 { MonoLabel("planned · \(p.minutes) min", color: label) }
                }
                .padding(.horizontal, Space.tight).padding(.leading, Space.tight)
                .frame(maxWidth: w - 6, alignment: .leading)
            }
            if isHot, canStart {
                Pill("start ▸", kind: .accent, accent: Theme.ink).padding(.leading, Space.tight).frame(maxWidth: w, alignment: .trailing).offset(x: -Space.tight)
                    .transition(.opacity)
            }
        }
        .frame(width: w, height: G.trackH)
        .opacity(dimmed ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onContinuousHover { ph in switch ph { case .active: enter(k); case .ended: leave(k) } }
        .onTapGesture { if canStart { store.prepareSession(planned: p) } else if let oid = p.objectiveId { store.open(objective: oid) } else { store.go(.calendar) } }
        .help("planned · \(p.title) · \(clock(p.start))–\(clock(p.end))" + (canStart ? " · click to queue it" : ""))
        .offset(x: x0, y: G.trackTop)
        .zIndex(0)
    }

    /// Jeff's break hatch: 135° lines every 5 pt.
    private func hatch(_ color: Color, label: String?) -> some View {
        Canvas { ctx, size in
            var p = Path()
            var o: CGFloat = -size.height
            while o < size.width { p.move(to: CGPoint(x: o, y: size.height)); p.addLine(to: CGPoint(x: o + size.height, y: 0)); o += 5 }
            ctx.stroke(p, with: .color(color), lineWidth: 2)
        }
        .overlay(alignment: .leading) { if let label { MonoLabel(label).padding(.horizontal, Space.tight).padding(.vertical, Space.hair).background(Capsule().fill(Theme.paper.opacity(0.92))).padding(.leading, Space.tight) } }
        .frame(height: G.trackH)
    }

    /// Minor 1 × 4 at 60 % line, major 1 × 6 in line-2, labels below 3-h scale only.
    private func ticks(_ geo: G) -> some View {
        let y = G.trackBottom
        return ForEach(Array(geo.ticks().filter { $0.x >= -160 && $0.x <= geo.width + 160 }.enumerated()), id: \.offset) { _, t in
            Rectangle().fill(t.major ? Theme.line2 : Theme.line.opacity(0.6)).frame(width: 1, height: t.major ? 6 : 4).offset(x: t.x, y: y)
            if !t.label.isEmpty { MonoLabel(t.label).offset(x: t.x + 3, y: y + 5) }
        }
    }

    /// Blocks (close · shield · redirect): 2 × 5 red ticks rising from the track's underside (Jeff's class ticks).
    private func blockTicks(_ geo: G) -> some View {
        ForEach(Array(model.ticks.filter { let x = geo.x($0.at); return x >= -8 && x <= geo.width + 8 }.enumerated()), id: \.offset) { _, k in
            RoundedRectangle(cornerRadius: 1).fill(Theme.danger.opacity(0.55)).frame(width: 2, height: 5).offset(x: geo.x(k.at) - 1, y: G.trackBottom + 1)
        }
    }

    private static let hoverLog = ProcessInfo.processInfo.environment["DBOT_HOVER_LOG"] != nil     // T2's flicker check: every hot change, to the app log
    private func enter(_ key: String) { leaving?.cancel(); leaving = nil; if hot != key { if Self.hoverLog { Log.write("hot on  \(key)") }; hot = key } }
    private func leave(_ key: String) {
        leaving?.cancel()
        leaving = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            if !Task.isCancelled, hot == key { if Self.hoverLog { Log.write("hot off \(key)") }; hot = nil }
        }
    }
    /// T2's check: positions in CANVAS space, computed from the same numbers that place the views (a GeometryReader
    /// under an `.offset` view reports the un-offset layout frame, which is how the first run aimed at one corner).
    /// The canvas's own settled origin is logged once by `canvasOriginLogger`, so the driver adds the two.
    private func logPos(_ name: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        Color.clear.onAppear { if Self.hoverLog { Log.write("pos \(name) \(x) \(y) \(w) \(h)") } }
    }
    private func canvasOriginLogger() -> some View {
        GeometryReader { g in
            Color.clear.task {
                guard Self.hoverLog else { return }
                try? await Task.sleep(for: .seconds(1.5))                 // after the window is sized and placed
                let f = g.frame(in: .global)
                Log.write("canvas-origin \(f.minX) \(f.minY) \(f.width) \(f.height)")
            }
        }
    }
    private func key(_ p: DayModel.Period) -> String { "\(p.start.timeIntervalSince1970)-\(p.subject)" }
    private func when(_ p: DayModel.Period) -> String {
        let o: String = { switch p.outcome { case .back: return "came back"; case .blocked: return "blocked"; case .work: return "said work"; case .snoozed: return "snoozed"; case .open: return "now" } }()
        return "\(clock(p.start)) · \(short(p.duration)) · \(o)"
    }
    /// A click opens the Log on this period's rows (§5a Q9): the subject, inside the period's span.
    private func open(_ p: DayModel.Period) {
        if Self.hoverLog { Log.write("open log query=\(p.subject) from=\(p.start.timeIntervalSince1970) to=\(p.end.timeIntervalSince1970)") }
        store.go(.log, query: p.subject, from: p.start.addingTimeInterval(-2), to: p.end.addingTimeInterval(2), title: "detour · \(p.title)")
    }

    /// Screen looks: 2 × 5 ticks in muted-2 under the track, a withheld look hollow (§5a Q10).
    private func lookTicks(_ geo: G) -> some View {
        ForEach(Array(model.looks.filter { let x = geo.x($0.at); return x >= -8 && x <= geo.width + 8 }.enumerated()), id: \.offset) { _, k in
            RoundedRectangle(cornerRadius: 1).fill(k.kind == "look" ? Theme.muted2.opacity(0.7) : .clear)
                .overlay(RoundedRectangle(cornerRadius: 1).strokeBorder(Theme.muted2.opacity(0.7), lineWidth: k.kind == "look" ? 0 : 1))
                .frame(width: 2, height: 5).offset(x: geo.x(k.at) - 1, y: G.trackBottom + 7)
                .help(k.kind == "look" ? "looked at \(k.what) · \(clock(k.at))" : "\(k.what) · withheld · \(clock(k.at))")
        }
    }

    /// A period: a branch pin from the track's underside to the chip's centre, and the chip — a 22 pt glyph dot at
    /// fit scale, a titled pill closer in (Jeff's `.ss-ev`). THE DOT IS THE PILL: on hover or focus the same view grows
    /// to 24 pt and widens with the title and time; it grows leftward within 140 pt of the right edge.
    private func chip(_ p: DayModel.Period, x: CGFloat, lane: Int, geo: G, dot: Bool) -> some View {
        let k = key(p)
        let c = tint(p)
        let isHot = !snapshot && (hot == k || focused == k)
        let laneY = G.lanesTop + CGFloat(lane) * (G.laneH + G.laneGap)
        let centerY = laneY + G.laneH / 2
        let asDot = dot && !isHot
        let maxW: CGFloat = isHot ? min(360, geo.width - 12) : (dot ? 22 : 120)
        let h: CGFloat = isHot ? 24 : (dot ? 22 : 20)
        // side: grows right of the pin, or left of it near the right edge, or centred when neither fits (Jeff's pill-r/l/c)
        let left: CGFloat = {
            if asDot { return x - 11 }
            if x - 10 + maxW <= geo.width - 6 { return x - 10 }
            if x + 10 - maxW >= 6 { return x + 10 - maxW }
            return max(6, min(geo.width - 6 - maxW, x - maxW / 2))
        }()
        let align: Alignment = asDot ? .leading : (left == x - 10 ? .leading : (left == x + 10 - maxW ? .trailing : .center))
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(c.opacity(isHot ? 1 : (p.falseAlarm ? 0.2 : 0.38))).frame(width: isHot ? 2 : 1.5, height: centerY - G.trackBottom).offset(x: x - (isHot ? 1 : 0.75), y: G.trackBottom)
            HStack(spacing: asDot ? 0 : 5) {
                Image(systemName: glyph(p)).font(.system(size: Icon.Size.row.rawValue, weight: .semibold))   // lint-ok: Icon.row, colour from the chip.frame(width: asDot ? 20 : 18)
                if !asDot {
                    Text(p.title).font(Type.caption).lineLimit(1).truncationMode(.tail)
                    if isHot { MonoLabel(when(p), color: c.opacity(0.8)).transition(.opacity.animation(.easeOut(duration: 0.12).delay(0.08))) }
                }
            }
            .foregroundStyle(c)
            .padding(.leading, asDot ? 0 : (isHot ? 4 : 3)).padding(.trailing, asDot ? 0 : (isHot ? 11 : 8))
            .frame(width: asDot ? 22 : nil, height: h)
            .frame(maxWidth: maxW, alignment: .leading)
            .fixedSize(horizontal: !asDot, vertical: true)
            .background(Capsule().fill(p.falseAlarm && !isHot ? Theme.paper : c.opacity(isHot ? 0.11 : 0.08)).background(Capsule().fill(Theme.paper)))
            .overlay(Capsule().strokeBorder(c.opacity(isHot ? 0.45 : 0.4), style: StrokeStyle(lineWidth: 1, dash: p.falseAlarm ? [3, 2] : [])))
            .background(Capsule().strokeBorder(Theme.paper, lineWidth: isHot ? 2 : 1.5).padding(isHot ? -2 : -1.5))
            .background(Capsule().strokeBorder(accent, lineWidth: focused == k ? 2 : 0).padding(-4))     // the focus ring
            .shadow(color: .black.opacity(isHot ? 0.18 : 0), radius: 11, y: 8)
            .modifier(Halo(on: p.outcome == .open && !snapshot, color: c))
            .opacity(p.falseAlarm && !isHot ? 0.45 : 1)
            .frame(width: maxW, alignment: align)
            .offset(x: left, y: centerY - h / 2)
            .animation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22), value: isHot)
            .background { if !isHot { logPos("chip " + k, x: left, y: centerY - h / 2, w: asDot ? 22 : maxW, h: h) } }
            .contentShape(Capsule())
            .onContinuousHover { ph in switch ph { case .active: enter(k); case .ended: leave(k) } }
            .onTapGesture { open(p) }
            .focusable().focused($focused, equals: k).focusEffectDisabled()
            .onKeyPress(.return) { open(p); return .handled }
            .help("\(p.title) · \(when(p))" + (p.reason.isEmpty ? "" : " · \(p.reason)"))
        }
        .zIndex(isHot ? 6 : 2)
    }

    /// A cluster: "+n" in the tinted recipe on its pin, in the lane under the packed ones. Hover, click or focus opens
    /// THE FAN — every period as its own pill — as a paper panel over the lanes band (the card clips, so it cannot open
    /// upward past the track as Jeff's does; it fans sideways inside the strip instead).
    private func countChip(_ g: G.Group<DayModel.Period>, lane: Int, geo: G) -> some View {
        let k = "c-\(g.items[0].start.timeIntervalSince1970)"
        let c = tint(g.items[0])
        let isHot = !snapshot && (hot == k || fanned == k || focused == k)
        let centerY = G.lanesTop + CGFloat(lane) * (G.laneH + G.laneGap) + G.laneH / 2
        let badgeLeft = max(2, min(geo.width - 38, g.x - 18))             // D3: the badge stays inside the canvas at either edge
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(c.opacity(isHot ? 1 : 0.3)).frame(width: isHot ? 2 : 1.5, height: centerY - G.trackBottom).offset(x: g.x - 0.75, y: G.trackBottom)
            // D3 (§3.6): the count in ink on paper with a 6 pt dot in the outcome tint — the tinted capsule was part of the "clashing" screenshot
            HStack(spacing: Space.tight) {
                Circle().fill(c).frame(width: 6, height: 6)
                Text("+\(g.items.count)").font(Type.label)
            }
                .foregroundStyle(isHot ? Theme.paper : Theme.ink2)
                .padding(.horizontal, Space.stack).frame(minWidth: 28).frame(height: 20)
                .background(Capsule().fill(isHot ? Theme.ink : Theme.paper))
                .overlay(Capsule().strokeBorder(isHot ? Theme.ink : Theme.line2, lineWidth: 1))
                .background(Capsule().strokeBorder(Theme.paper, lineWidth: 1.5).padding(-1.5))
                .background(Capsule().strokeBorder(accent, lineWidth: focused == k ? 2 : 0).padding(-4))
                .offset(x: badgeLeft, y: centerY - 10)
                .background { logPos("cluster " + k, x: badgeLeft, y: centerY - 10, w: 36, h: 20) }
                .contentShape(Capsule())
                .onContinuousHover { ph in switch ph { case .active: enter(k); case .ended: leave(k) } }
                .onTapGesture { fanned = fanned == k ? nil : k }
                .focusable().focused($focused, equals: k).focusEffectDisabled()
                .onKeyPress(.return) { fanned = fanned == k ? nil : k; return .handled }
                .help("\(g.items.count) detours here")
            if isHot { fan(g, key: k, geo: geo) }
        }
        .zIndex(isHot ? 8 : 2)
    }

    /// The fan: a paper panel (radius 14, hairline, shadow) of fan pills, wrapping, at most three rows plus "+N more";
    /// anchored at the cluster and kept inside the strip; it closes when the pointer leaves it or the view pans (T3).
    private func fan(_ g: G.Group<DayModel.Period>, key k: String, geo: G) -> some View {
        let shown = Array(g.items.prefix(9))
        let panelW = min(geo.width - 12, 420)
        let left = max(6, min(geo.width - 6 - panelW, g.x - 20))
        return VStack(alignment: .leading, spacing: Space.tight) {
            WrapRow {
                ForEach(shown, id: \.start) { p in
                    let c = tint(p)
                    Button { fanned = nil; open(p) } label: {
                        HStack(spacing: Space.tight) {
                            Image(systemName: glyph(p)).font(.system(size: Icon.Size.row.rawValue, weight: .semibold))   // lint-ok: Icon.row, colour from the chip
                            Text(p.title).font(Type.caption).lineLimit(1)
                            MonoLabel(clock(p.start))
                        }
                        .foregroundStyle(c)
                        .padding(.leading, Space.stack).padding(.trailing, Space.stack).frame(height: 24)
                        .background(Capsule().fill(c.opacity(0.08)))
                        .overlay(Capsule().strokeBorder(c.opacity(0.4), lineWidth: 1))
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("\(p.title) · \(when(p))")
                }
                if g.items.count > shown.count { MonoLabel("+\(g.items.count - shown.count) more · zoom in", color: Theme.muted2).frame(height: 24) }
            }
        }
        .padding(Space.tight)
        .frame(width: panelW, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 15, y: 8)
        .offset(x: left, y: G.lanesTop - 6)
        .background { logPos("fan " + k, x: left, y: G.lanesTop - 6, w: panelW, h: 36) }     // the first pill's row: 6 pt padding + 24 pt pill
        .onContinuousHover { ph in switch ph { case .active: enter(k); case .ended: leave(k) } }
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    /// The now rule: 2 pt accent from the ruler's bottom to the canvas bottom, its word at the bottom (Jeff's `.ss-today`).
    @ViewBuilder private func nowRule(_ geo: G) -> some View {
        if let now, now >= geo.start, now <= geo.end {
            let x = geo.x(now)
            let edge = x > geo.width - 48
            Rectangle().fill(accent).frame(width: 2, height: G.canvasH - G.rulerH).offset(x: x - 1, y: G.rulerH)
            MonoLabel("now", color: accent).offset(x: edge ? x - 5 - 24 : x + 5, y: G.canvasH - 10)
        }
    }

    // MARK: Zoom and pan (T3)

    private var hours: CGFloat { CGFloat(max(1, model.axisEnd.timeIntervalSince(model.axisStart) / 3600)) }
    private var fit: CGFloat { width > 0 ? G.fitScale(start: model.axisStart, end: model.axisEnd, width: width) : 1 }
    private var pxPerHour: CGFloat { zoom.scale ?? fit }
    private var zoomed: Bool { zoom.scale != nil }
    private func zoomAt(_ next: CGFloat, cx: CGFloat) {
        guard width > 0 else { return }
        byHand = true
        zoom = G.zoom(zoom, to: next, at: cx, fit: fit, maxScale: G.maxScale(width: width), hours: hours, width: width)
    }
    private func panBy(_ dx: CGFloat) { byHand = true; zoom = G.pan(zoom, by: dx, fit: fit, hours: hours, width: width) }
    private func snapDay() { byHand = true; zoom = G.Zoom() }
    /// "now" / N: back to the worked window (which ends an hour past now while a session is on), and the strip follows again.
    private func snapNow() { byHand = false; fitWorked(width: width) }
    /// The strip opens on the hours that were worked, not the whole day (most of which is sleep): an hour before the
    /// first block or tick to an hour after the last one or now. Nothing yet → the whole day.
    private func fitWorked(width w: CGFloat) {
        guard w > 0 else { return }
        guard let r = model.workedWindow(now: now ?? model.now) else { zoom = G.Zoom(); return }
        zoom = G.fit(r, start: model.axisStart, end: model.axisEnd, width: w)
    }
    /// The wheel: VERTICAL zooms about the cursor (a pinch arrives as ctrl/cmd + wheel or a magnify event, faster),
    /// HORIZONTAL pans when zoomed. A local monitor scoped to the canvas's frame, so the chips keep their clicks and
    /// the page under the strip is not scrolled while the pointer is over it (Jeff's mapping, 2026-08-22).
    private func installWheel() {
        guard wheelMonitor == nil, !snapshot else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { e in
            guard let win = e.window, let cv = win.contentView else { return e }
            let p = e.locationInWindow
            let pt = CGPoint(x: p.x, y: cv.bounds.height - p.y)
            guard canvasFrame.contains(pt) else { return e }
            let cx = pt.x - canvasFrame.minX
            if e.type == .magnify { zoomAt(pxPerHour * (1 + e.magnification), cx: cx); return nil }
            let horizontal = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) && !e.modifierFlags.contains(.control) && !e.modifierFlags.contains(.command)
            if horizontal { if zoomed { panBy(e.scrollingDeltaX) }; return nil }
            let k: CGFloat = e.modifierFlags.contains(.control) || e.modifierFlags.contains(.command) ? 0.01 : 0.004
            zoomAt(pxPerHour * exp(-e.scrollingDeltaY * k), cx: cx)
            return nil
        }
    }
    private func removeWheel() { if let m = wheelMonitor { NSEvent.removeMonitor(m); wheelMonitor = nil } }

    /// `−` `+` as 24 pt circles, "day" and "now" as word pills, the active word solid; the detail word at the end (Jeff's `.ss-zoom`).
    private var zoomControls: some View {
        HStack(spacing: Space.tight) {
            zbtn("minus", enabled: zoomed) { zoomAt(pxPerHour / 1.6, cx: width / 2) }
            Pill("day", kind: zoomed ? .neutral : .accent, accent: Theme.ink).onTapGesture { snapDay() }.help("Fit the whole day (Home)")
            zbtn("plus", enabled: pxPerHour < G.maxScale(width: width) - 1e-6) { zoomAt(pxPerHour * 1.6, cx: width / 2) }
            if now != nil { Pill("now", kind: byHand || !zoomed ? .neutral : .accent, accent: Theme.ink).onTapGesture { snapNow() }.help("Fit the worked hours, following now (N)") }
            MonoLabel(G(start: model.axisStart, end: model.axisEnd, width: max(1, width), pxPerHour: pxPerHour).detailWord, color: Theme.muted2).padding(.leading, Space.tight)
        }
        .fixedSize()
    }
    private func zbtn(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Icon(symbol, .small, color: enabled ? Theme.muted : Theme.muted2.opacity(0.5))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.paper)).overlay(Circle().strokeBorder(Theme.line2, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(!enabled)
    }

    // MARK: Dress

    private func tint(_ p: DayModel.Period) -> Color {
        switch p.outcome { case .back, .open: return Theme.warn; case .blocked: return Theme.danger; case .work: return Theme.ok; case .snoozed: return Theme.muted2 }
    }
    private func glyph(_ p: DayModel.Period) -> String {
        switch p.kind { case .site: return "globe"; case .app: return "app.badge"; case .look: return "eye" }
    }
    /// "2 h 14" · "37 min" · "41 s"
    private func short(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : m > 0 ? "\(m) min" : "\(Int(t)) s"
    }
}

/// Jeff's `ssBreathe`: a 3.6 s halo in the tint, for the one period that is still open (a card is up now).
private struct Halo: ViewModifier {
    let on: Bool
    let color: Color
    @State private var phase = false
    func body(content: Content) -> some View {
        content
            .shadow(color: on ? color.opacity(phase ? 0.6 : 0.2) : .clear, radius: on ? (phase ? 8 : 3) : 0)
            .onAppear { if on { withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { phase = true } } }
    }
}
