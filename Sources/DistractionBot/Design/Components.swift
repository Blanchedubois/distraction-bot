import SwiftUI

// MARK: - Graph-paper wash (the card signature)

struct GraphWash: View {
    var spacing: CGFloat = 34
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = spacing
            while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
            var y: CGFloat = spacing
            while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
            ctx.stroke(path, with: .color(Theme.line.opacity(0.45)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Watermark

struct Watermark: View {
    let symbol: String
    var size: CGFloat = 150
    var color: Color = Theme.muted2
    var opacity: Double = 0.07
    var body: some View {
        Group {
            if symbol.isEmojiIcon { Text(symbol).font(.system(size: size)).opacity(opacity) }   // lint-ok: a watermark glyph is sized by its card (U4: an emoji at the same size, tilt and opacity)
            else { Image(systemName: symbol).font(.system(size: size, weight: .regular)).foregroundStyle(color.opacity(opacity)) }   // lint-ok: same
        }
        .rotationEffect(.degrees(-13))
        .allowsHitTesting(false)
    }
}

// MARK: - Card

struct CardStyle: ViewModifier {
    var accent: Color? = nil
    var wash: Bool = false
    var radius: CGFloat = Theme.radius
    var watermark: String? = nil
    var watermarkSize: CGFloat = 150
    var shadow: Bool = true
    var gradient: Bool = false
    var watermarkOpacity: Double? = nil    // nil = Tint.watermark for the appearance
    @Environment(\.printing) private var printing
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .frame(maxHeight: .infinity, alignment: .top)
            .background(alignment: .bottomTrailing) {
                if let watermark {
                    Watermark(symbol: watermark, size: watermarkSize, color: accent ?? Theme.muted2, opacity: watermarkOpacity ?? Tint.watermark(dark: scheme == .dark))
                        .offset(x: 16, y: 26)
                }
            }
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.paper)
                    if gradient, !printing, let accent {
                        let (a, b) = Tint.cardGradient(dark: scheme == .dark)
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(LinearGradient(colors: [accent.opacity(a), accent.opacity(b), accent.opacity(0.0)], startPoint: .leading, endPoint: .trailing))
                    }
                    if wash { GraphWash() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(accent.map { $0.opacity(Tint.border(dark: scheme == .dark)) } ?? Theme.line, lineWidth: 1)
            )
            .shadow(color: .black.opacity(shadow ? 0.04 : 0), radius: 1, y: 1)
            .shadow(color: .black.opacity(shadow ? 0.06 : 0), radius: 12, y: 6)
    }
}

extension View {
    func card(accent: Color? = nil, wash: Bool = false, radius: CGFloat = Theme.radius, watermark: String? = nil, watermarkSize: CGFloat = 150, shadow: Bool = true, gradient: Bool = false, watermarkOpacity: Double? = nil) -> some View {
        modifier(CardStyle(accent: accent, wash: wash, radius: radius, watermark: watermark, watermarkSize: watermarkSize, shadow: shadow, gradient: gradient, watermarkOpacity: watermarkOpacity))
    }
}

// MARK: - Mono label

/// Small caps at the one label size (Type.label, 9 pt, muted). The `size:` argument is accepted and ignored so the
/// screens compile until G1–G5 remove it (PLAN_DESIGN_CLEANUP §4 G0).
struct MonoLabel: View {
    let text: String
    var color: Color = Theme.muted
    var lines = 1                       // P3: a figures line that may wrap to two
    init(_ text: String, size: CGFloat? = nil, color: Color = Theme.muted, lines: Int = 1) { self.text = text; self.color = color; self.lines = lines }
    var body: some View {
        Text(text.uppercased())
            .font(Type.label)
            .tracking(Type.labelTracking)
            .foregroundStyle(color)
            .lineLimit(lines)
    }
}

// MARK: - Pill

enum PillKind { case neutral, accent, ok, warn, danger, on }

struct Pill: View {
    let text: String
    var kind: PillKind = .neutral
    var dot: Bool = false
    var accent: Color = Theme.accent
    init(_ text: String, kind: PillKind = .neutral, dot: Bool = false, accent: Color = Theme.accent) {
        self.text = text; self.kind = kind; self.dot = dot; self.accent = accent
    }
    private var fg: Color {
        switch kind {
        case .neutral: return Theme.muted
        case .accent: return accent
        case .ok: return Theme.ok
        case .warn: return Theme.warn
        case .danger: return Theme.danger
        case .on: return accent == Theme.ink ? Theme.paper : .white   // an ink capsule is cream in dark mode: white on it vanished (Calendar's `week` pill)
        }
    }
    private var border: Color {
        switch kind {
        case .neutral: return Theme.line2
        case .on: return .clear
        default: return fg.opacity(0.6)
        }
    }
    var body: some View {
        HStack(spacing: Space.pillGap) {
            if dot { Circle().fill(kind == .neutral ? accent : fg).frame(width: 5, height: 5) }
            Text(text.uppercased()).font(Type.pill).tracking(Type.pillTracking)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, Space.pillH).padding(.vertical, Space.pillV)
        .background(Capsule().fill(kind == .on ? accent : .clear))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .lineLimit(1)
        .fixedSize()
    }
}

struct PillButton: View {
    let text: String
    var kind: PillKind = .neutral
    var accent: Color = Theme.accent
    var log: String? = nil             // K0 (PLAN_STUDY_DAY §3.8): a `↗` door writes `ui.door <log>` when pressed, e.g. "progress from home"
    let action: () -> Void
    var body: some View {
        Button(action: { if let log { Task { @MainActor in EventLog.shared.ui("door", log) } }; action() }) { Pill(text, kind: kind, accent: accent) }
            .buttonStyle(.plain)
            .contentShape(Capsule())
    }
}

// MARK: - Section header: faded numeral · title · mono note · rule

struct SectionHeader<Trailing: View>: View {
    let num: Int
    let title: String
    var note: String? = nil
    var count: String? = nil
    @ViewBuilder var trailing: Trailing

    init(_ num: Int, _ title: String, note: String? = nil, count: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.num = num; self.title = title; self.note = note; self.count = count; self.trailing = trailing()
    }
    @Environment(\.narrow) private var narrow
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
            Text(title).font(Type.title).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
            if let note, !narrow { MonoLabel(note).lineLimit(1).layoutPriority(-1) }
            if let count { MonoLabel(count, color: Theme.muted2).lineLimit(1) }
            Rectangle().fill(Theme.line).frame(height: 1).frame(minWidth: Space.loose, maxWidth: .infinity).alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + Space.tight }
            trailing
        }
        .help(narrow ? (note ?? "") : "")
        .padding(.horizontal, Space.hair)
        .padding(.bottom, Space.stack)
    }
}

// MARK: - KPI tile

struct KpiTile: View {
    let label: String
    var cents: Int? = nil
    var value: String? = nil
    var sub: String? = nil
    let symbol: String
    var delta: Int? = nil
    var deltaLabel: String? = nil
    var accent: Bool = false
    var invert: Bool = false
    var spark: [Double]? = nil
    var tint: Color? = nil             // explicit colour for the figure (signed money: green when positive, red when negative)
    var small: Bool = false            // compact tile for a 2×2 under a card
    var warning: String? = nil         // one line in red under the figure

    private var good: Bool? {
        guard let delta, delta != 0 else { return nil }
        return (delta > 0) != invert
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack {
                MonoLabel(label)
                Spacer(minLength: Space.tight)
                if let delta {
                    let g = good
                    let col: Color = g == nil ? Theme.muted2 : (g! ? Theme.accent : Theme.danger)
                    HStack(spacing: Space.tight) {
                        Text(delta == 0 ? "—" : delta > 0 ? "↑" : "▾").font(Type.caption)
                        Text("\(abs(delta))%").font(Type.label)
                        if let deltaLabel, !small { Text(deltaLabel.uppercased()).font(Type.label).foregroundStyle(Theme.muted) }
                    }
                    .foregroundStyle(col)
                    .padding(.horizontal, Space.stack).padding(.vertical, Space.hair)
                    .background(Capsule().fill(col.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(col.opacity(0.35), lineWidth: 1))
                }
            }
            let figure = small ? Type.figureSmall : Type.figureCard
            Group {
                if let value {
                    Text(value).font(figure)
                } else if let cents {
                    let dollars = abs(cents) / 100, c = abs(cents) % 100
                    (Text((cents < 0 ? "−$" : "$") + "\(dollars.formatted())").font(figure)
                     + Text(String(format: ".%02d", c)).font(Type.data).foregroundStyle(Theme.muted))
                } else {
                    Text("—").font(figure)
                }
            }
            .foregroundStyle(tint ?? (accent ? Theme.accent : Theme.ink))
            .monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
            if let warning {
                HStack(spacing: Space.tight) { Icon("exclamationmark.triangle.fill", .small, color: Theme.danger); MonoLabel(warning, color: Theme.danger).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                    .foregroundStyle(Theme.danger)
            } else if let sub { MonoLabel(sub).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
        }
        .cardPadding()
        .frame(maxWidth: .infinity, minHeight: small ? 84 : 112, alignment: .leading)
        .background(alignment: .bottom) {
            if let spark, spark.count > 1 {
                Sparkline(values: spark, color: accent ? Theme.accent : Theme.muted2)
                    .frame(height: 34).padding(.horizontal, Space.card).padding(.bottom, Space.stack).opacity(0.5)
            }
        }
        .card(radius: Theme.radiusCell, watermark: spark == nil ? symbol : nil, watermarkSize: 72)
    }
}

/// A faint filled line; values are cumulative, so it always rises.
struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { g in
            let maxV = max(values.max() ?? 1, 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: g.size.width * CGFloat(i) / CGFloat(max(1, values.count - 1)), y: g.size.height * (1 - CGFloat(v / maxV)))
            }
            Path { p in
                guard let f = pts.first else { return }
                p.move(to: CGPoint(x: f.x, y: g.size.height)); p.addLine(to: f)
                for pt in pts.dropFirst() { p.addLine(to: pt) }
                p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height)); p.closeSubpath()
            }
            .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            Path { p in
                guard let f = pts.first else { return }
                p.move(to: f); for pt in pts.dropFirst() { p.addLine(to: pt) }
            }
            .stroke(color, lineWidth: 1.5)
        }
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: Space.stack) {
            Icon(symbol, .empty, color: Theme.muted2)
            Text(text).font(Type.body).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, Space.section).padding(.horizontal, Space.sheet)
    }
}

// MARK: - Primary button

struct ActionButton: View {
    let title: String
    var symbol: String? = nil
    var accent: Bool = false
    var ghost: Bool = false
    var tint: Color? = nil             // the accent fill when `accent` (Home's objective colour, H5); Theme.accent by default
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.stack) {
                if let symbol { Image(systemName: symbol).font(.system(size: Icon.Size.row.rawValue, weight: .semibold)) }   // lint-ok: Icon's row size, inheriting the label colour
                Text(title.uppercased()).font(Type.button).tracking(Type.pillTracking).lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(ghost ? Theme.ink : (accent ? Color.white : Theme.paper))
            .padding(.horizontal, Space.buttonH).padding(.vertical, Space.buttonV)
            .background(Capsule().fill(ghost ? Color.clear : (accent ? (tint ?? Theme.accent) : Theme.ink)))
            .overlay(Capsule().strokeBorder(ghost ? Theme.line2 : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Progress bar

struct Bar: View {
    let fraction: Double
    var color: Color = Theme.accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.14))
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }
        .frame(height: 7)
    }
}


/// KPI tiles that reflow: 4 across when wide, 2 when narrow.
struct KpiGrid<Content: View>: View {
    var columns: Int? = nil            // force a column count (e.g. 2 for a 2×2 of four tiles)
    @ViewBuilder let content: Content
    @Environment(\.narrow) private var narrow
    var body: some View {
        let cols: [GridItem] = columns.map { Array(repeating: GridItem(.flexible(), spacing: Space.card), count: $0) }
            ?? (narrow ? Array(repeating: GridItem(.flexible(), spacing: Space.card), count: 2) : [GridItem(.adaptive(minimum: 150, maximum: 400), spacing: Space.card)])
        LazyVGrid(columns: cols, spacing: Space.card) { content }
    }
}

/// Pills that wrap onto new lines instead of overflowing.
struct WrapRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        FlowLayout(spacing: Space.stack) { content }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = Space.stack
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > bounds.width { x = 0; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}



/// Two columns when they fit, stacked when narrow (Ledger).
struct Pair<A: View, B: View>: View {
    var firstWidth: CGFloat? = nil
    var secondWidth: CGFloat? = nil     // a fixed right column (Home's Overall widget, H0)
    var minWidth: CGFloat = Breakpoint.narrow
    @ViewBuilder let first: A
    @ViewBuilder let second: B
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.sheet) {
                if let w = firstWidth { first.frame(width: w).frame(maxHeight: .infinity, alignment: .top) } else { first.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
                if let w = secondWidth { second.frame(width: w).frame(maxHeight: .infinity, alignment: .top) } else { second.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: minWidth)
            VStack(alignment: .leading, spacing: Space.section) { first; second }
        }
    }
}


/// A switch that draws as a pill when rendering offscreen (ImageRenderer cannot draw Toggle).
struct SwitchRow: View {
    @Binding var isOn: Bool
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        if snapshot { Pill(isOn ? "on" : "off", kind: isOn ? .on : .neutral) }
        else { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch) }
    }
}
