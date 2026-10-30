import SwiftUI

// Ledger's hand-drawn diagrams (ledger-mac/Design/Diagrams.swift), ported for the Progress tab with local data types:
// a squarified treemap, a month heatmap and a 52-week strip. Values are plain doubles with a caller-supplied formatter,
// so the same views show minutes, counts or anything else.

// MARK: - Data

struct StatTile: Identifiable, Hashable {
    let id: String
    let name: String
    let group: String            // the legend word: app · site · search
    let color: Color
    let value: Double
    let note: String             // the small third line ("11× · site")
    let help: String
}

struct HeatDay: Identifiable, Hashable {
    var id: String { date }
    let date: String             // yyyy-MM-dd
    let day: Int?                // day of month, nil for a padding cell
    let value: Double
    let n: Int
}

struct HeatCalendar {
    let month: String            // yyyy-MM
    let firstWeekday: Int        // 0 = Sunday
    let days: [HeatDay]
    let maxValue: Double
    let year: [HeatDay]          // 364 days ending today, oldest first
    let yearMaxValue: Double

    /// Build from a per-day map (seconds, counts…) for the month containing `now` and the 52 weeks before it.
    static func build(values: [Date: Double], counts: [Date: Int] = [:], now: Date = Date()) -> HeatCalendar {
        let cal = Calendar.current
        let today = StudyDay.start(of: now)   // K1: the cells are study days (keyed by their starts, as Stats.days are)
        let comps = cal.dateComponents([.year, .month], from: today)
        let first = StudyDay.dayStarting(on: cal.date(from: comps)!)   // K1: the 1st's study-day start, so the keys match Stats.days
        let nDays = cal.range(of: .day, in: .month, for: first)!.count
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let days: [HeatDay] = (0..<nDays).map { i in
            let d = cal.date(byAdding: .day, value: i, to: first)!
            return HeatDay(date: f.string(from: d), day: i + 1, value: values[d] ?? 0, n: counts[d] ?? 0)
        }
        let yearStart = cal.date(byAdding: .day, value: -363, to: today)!
        let year: [HeatDay] = (0..<364).map { i in
            let d = cal.date(byAdding: .day, value: i, to: yearStart)!
            return HeatDay(date: f.string(from: d), day: cal.component(.day, from: d), value: values[d] ?? 0, n: counts[d] ?? 0)
        }
        return HeatCalendar(month: String(f.string(from: first).prefix(7)), firstWeekday: cal.component(.weekday, from: first) - 1,
                            days: days, maxValue: days.map(\.value).max() ?? 0, year: year, yearMaxValue: year.map(\.value).max() ?? 0)
    }
}

func monthShort(_ ym: String) -> String {
    let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    let parts = ym.split(separator: "-")
    guard parts.count >= 2, let m = Int(parts[1]), (1...12).contains(m) else { return ym }
    return names[m - 1]
}

// MARK: - Treemap (squarified)

struct TreemapView: View {
    let tiles: [StatTile]
    var format: (Double) -> String = { "\(Int($0))" }
    var onTap: ((StatTile) -> Void)? = nil
    @State private var hover: String?

    private func layout(_ items: [(StatTile, Double)], in rect: CGRect) -> [(StatTile, CGRect)] {
        guard !items.isEmpty else { return [] }
        let total = items.reduce(0) { $0 + $1.1 }
        var rects: [(StatTile, CGRect)] = []
        var remaining = items, r = rect, rem = total
        while !remaining.isEmpty {
            let horizontal = r.width >= r.height
            let side = horizontal ? r.height : r.width
            var row: [(StatTile, Double)] = [], rowSum = 0.0
            func worst(_ row: [(StatTile, Double)], _ sum: Double) -> Double {
                let len = side * (sum / rem)
                guard len > 0, let mx = row.map(\.1).max(), let mn = row.map(\.1).min() else { return .infinity }
                let area = (horizontal ? r.width : r.height) * side
                let scale = area / rem
                let maxW = mx * scale / len, minW = mn * scale / len
                return max(len / minW, maxW / len)
            }
            for it in remaining {
                let candidate = row + [it]
                if row.isEmpty || worst(candidate, rowSum + it.1) <= worst(row, rowSum) { row = candidate; rowSum += it.1 } else { break }
            }
            let frac = rowSum / rem
            let len = (horizontal ? r.width : r.height) * frac
            var off: CGFloat = 0
            for (t, v) in row {
                let share = v / rowSum
                let rr = horizontal
                    ? CGRect(x: r.minX, y: r.minY + off, width: len, height: side * share)
                    : CGRect(x: r.minX + off, y: r.minY, width: side * share, height: len)
                rects.append((t, rr)); off += side * share
            }
            if horizontal { r = CGRect(x: r.minX + len, y: r.minY, width: r.width - len, height: r.height) }
            else { r = CGRect(x: r.minX, y: r.minY + len, width: r.width, height: r.height - len) }
            remaining.removeFirst(row.count); rem -= rowSum
            if rem <= 0 { break }
        }
        return rects
    }

    var body: some View {
        GeometryReader { g in
            let items = tiles.filter { $0.value > 0 }.map { ($0, $0.value) }
            let rects = layout(items, in: CGRect(origin: .zero, size: g.size))
            ZStack(alignment: .topLeading) {
                ForEach(rects, id: \.0.id) { t, r in
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 6).fill(t.color.opacity(hover == nil || hover == t.id ? 0.32 : 0.14))
                        RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.bg, lineWidth: 2)
                        if r.width > 64 && r.height > 32 {
                            VStack(alignment: .leading, spacing: Space.hair) {
                                Text(t.name).font(Type.caption).foregroundStyle(Theme.ink).lineLimit(1)
                                MonoLabel(format(t.value))
                                if r.height > 54 { MonoLabel(t.note, color: Theme.muted2).lineLimit(1) }
                            }
                            .padding(Space.stack)
                        }
                    }
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                    .help(t.help)
                    .contentShape(Rectangle()).onTapGesture { onTap?(t) }
                    .onHover { hover = $0 ? t.id : nil }
                }
            }
        }
    }
}

// MARK: - Calendar heatmap

struct MonthHeatmap: View {
    let cal: HeatCalendar
    var format: (Double) -> String = { "\(Int($0))" }
    var help: (HeatDay) -> String = { "\($0.date)" }
    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: Space.tight), count: 7)
        VStack(spacing: Space.tight) {
            HStack { ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, d in MonoLabel(d, color: Theme.muted2).frame(maxWidth: .infinity) } }
            LazyVGrid(columns: cols, spacing: Space.tight) {
                ForEach(0..<cal.firstWeekday, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [3, 3])).frame(height: 44)
                }
                ForEach(cal.days) { d in
                    let level = cal.maxValue > 0 ? d.value / cal.maxValue : 0
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 6).fill(d.value == 0 ? Theme.ghost.opacity(0.55) : Theme.accent.opacity(0.15 + 0.85 * level))
                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text("\(d.day ?? 0)").font(Type.label).foregroundStyle(level > 0.55 ? .white : (d.value == 0 ? Theme.muted2 : Theme.muted))
                            if d.value > 0 { Text(format(d.value)).font(Type.caption).foregroundStyle(level > 0.55 ? .white : Theme.ink).lineLimit(1).minimumScaleFactor(0.7) }
                        }.padding(Space.tight)
                    }
                    .frame(height: 44)
                    .help(help(d))
                }
            }
        }
    }
}

struct YearStrip: View {
    let cal: HeatCalendar
    var help: (HeatDay) -> String = { "\($0.date)" }
    var body: some View {
        let weeks = stride(from: 0, to: cal.year.count, by: 7).map { Array(cal.year[$0..<min($0 + 7, cal.year.count)]) }
        VStack(alignment: .leading, spacing: Space.tight) {
            GeometryReader { g in
                let gap: CGFloat = 3
                let cell = min(14, max(6, (g.size.width - gap * CGFloat(max(0, weeks.count - 1))) / CGFloat(max(1, weeks.count))))
                HStack(alignment: .top, spacing: gap) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { _, w in
                        VStack(spacing: gap) {
                            ForEach(w) { d in
                                let level = cal.yearMaxValue > 0 ? d.value / cal.yearMaxValue : 0
                                RoundedRectangle(cornerRadius: 2).fill(d.value == 0 ? Theme.ghost : Theme.accent.opacity(0.18 + 0.82 * min(1, level * 1.6)))
                                    .frame(width: cell, height: cell)
                                    .help(help(d))
                            }
                        }
                    }
                }
            }
            .frame(height: 7 * 14 + 6 * 3)
            GeometryReader { g in
                let gap: CGFloat = 3
                let cell = min(14, max(6, (g.size.width - gap * CGFloat(max(0, weeks.count - 1))) / CGFloat(max(1, weeks.count))))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { i, w in
                        if let first = w.first, i > 0, let prev = weeks[i - 1].first, first.date.prefix(7) != prev.date.prefix(7) {
                            MonoLabel(monthShort(String(first.date.prefix(7))), color: Theme.muted2).offset(x: CGFloat(i) * (cell + gap))
                        }
                    }
                }
            }
            .frame(height: 12)
            HStack {
                MonoLabel(monthShort(String(cal.year.first?.date.prefix(7) ?? "")), color: Theme.muted2)
                Spacer()
                HStack(spacing: Space.hair) {
                    MonoLabel("less", color: Theme.muted2)
                    ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { l in RoundedRectangle(cornerRadius: 2).fill(l == 0 ? Theme.ghost : Theme.accent.opacity(0.18 + 0.82 * l)).frame(width: 11, height: 11) }
                    MonoLabel("more", color: Theme.muted2)
                }
                Spacer()
                MonoLabel(monthShort(cal.month), color: Theme.muted2)
            }
        }
    }
}

// MARK: - Sankey (Ledger's SankeyView over plain nodes and links)

struct SankeyNode: Identifiable, Hashable { let id: String; let label: String; let value: Int; let color: Color; let column: Int }
struct SankeyLink: Hashable { let from: String; let to: String; let value: Int; let color: Color }

struct SankeyView: View {
    let nodes: [SankeyNode]
    let links: [SankeyLink]
    var columns: Int = 3
    @State private var hover: String?

    private struct Layout {
        var ys: [String: (CGFloat, CGFloat)] = [:]
        var ribbons: [(Path, Color, String, String)] = []
        var colX: [CGFloat] = []
        var nodeW: CGFloat = 10
    }

    private func layout(_ size: CGSize) -> Layout {
        let W = size.width, H = size.height
        var L = Layout()
        let nodeW: CGFloat = 10, gap: CGFloat = 8
        var seen = Set<String>()
        let ns = nodes.filter { $0.value > 0 && seen.insert($0.id).inserted }
        let cols = (0..<columns).map { c in ns.filter { $0.column == c } }
        L.colX = (0..<columns).map { c in columns == 1 ? 0 : (W - nodeW) * CGFloat(c) / CGFloat(columns - 1) }
        let totals = cols.map { max(1, $0.reduce(0) { $0 + $1.value }) }
        let maxTotal = CGFloat(totals.max() ?? 1)
        let maxCount = cols.map(\.count).max() ?? 1
        let minH: CGFloat = 11
        let scale = max(0.0001, (H - gap * CGFloat(max(maxCount, 1) - 1) - minH * CGFloat(maxCount)) / maxTotal)
        for col in cols {
            let hs = col.map { max(minH, CGFloat($0.value) * scale) }
            let colH = hs.reduce(0, +) + gap * CGFloat(max(0, col.count - 1))
            var y = max(0, (H - colH) / 2)
            for (n, h) in zip(col, hs) { L.ys[n.id] = (y, h); y += h + gap }
        }
        var outOff: [String: CGFloat] = [:], inOff: [String: CGFloat] = [:]
        let byId = Dictionary(ns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for l in links where l.value > 0 {
            guard let (fy, fh) = L.ys[l.from], let (ty, th) = L.ys[l.to], let fromNode = byId[l.from], let toNode = byId[l.to] else { continue }
            let fScale = fh / CGFloat(max(1, fromNode.value)), tScale = th / CGFloat(max(1, toNode.value))
            let h1 = CGFloat(l.value) * fScale, h2 = CGFloat(l.value) * tScale
            let y1 = fy + (outOff[l.from] ?? 0), y2 = ty + (inOff[l.to] ?? 0)
            outOff[l.from, default: 0] += h1; inOff[l.to, default: 0] += h2
            let x1 = L.colX[fromNode.column] + nodeW, x2 = L.colX[toNode.column]
            let cx = (x1 + x2) / 2
            var p = Path()
            p.move(to: CGPoint(x: x1, y: y1))
            p.addCurve(to: CGPoint(x: x2, y: y2), control1: CGPoint(x: cx, y: y1), control2: CGPoint(x: cx, y: y2))
            p.addLine(to: CGPoint(x: x2, y: y2 + h2))
            p.addCurve(to: CGPoint(x: x1, y: y1 + h1), control1: CGPoint(x: cx, y: y2 + h2), control2: CGPoint(x: cx, y: y1 + h1))
            p.closeSubpath()
            L.ribbons.append((p, l.color, l.from, l.to))
        }
        return L
    }

    var body: some View {
        GeometryReader { g in
            let L = layout(g.size)
            let ns = nodes.filter { $0.value > 0 }
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for (p, color, from, to) in L.ribbons {
                        let dim = hover != nil && hover != from && hover != to
                        ctx.fill(p, with: .color(color.opacity(dim ? 0.08 : 0.28)))
                    }
                    for n in ns {
                        guard let (y, h) = L.ys[n.id] else { continue }
                        let r = CGRect(x: L.colX[n.column], y: y, width: L.nodeW, height: h)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(n.color.opacity(hover == nil || hover == n.id ? 1 : 0.35)))
                    }
                }
                ForEach(ns) { n in
                    if let (y, h) = L.ys[n.id] {
                        let last = n.column == columns - 1
                        HStack(spacing: Space.tight) {
                            Text(n.label).font(Type.caption).foregroundStyle(Theme.ink).lineLimit(1)
                            Text("\(n.value)").font(Type.label).foregroundStyle(Theme.muted)
                        }
                        .fixedSize()
                        .frame(width: 150, alignment: last ? .trailing : .leading)
                        .position(x: last ? L.colX[n.column] - 80 : L.colX[n.column] + L.nodeW + 80, y: y + h / 2)
                        .onHover { hover = $0 ? n.id : nil }
                    }
                }
            }
        }
    }
}
