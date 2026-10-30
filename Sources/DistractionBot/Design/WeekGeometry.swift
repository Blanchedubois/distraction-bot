import Foundation

/// The week grid's one geometry module (PLAN_WEEK_CALENDAR §3.2): Jeff's `pure.ts` constants and functions, verbatim.
/// Every x and y the grid draws comes from here — never inline arithmetic — so a check can assert exact columns.
/// The axis is CONSTANT (24 h × 96 pt); only the week changes, never the scale.
enum WeekGeometry {
    static let hourH: CGFloat = 96                      // HOUR_H
    static let canvasH: CGFloat = 24 * hourH            // CANVAS_H 2304, every week, always
    static let ppm: CGFloat = hourH / 60                // PPM 1.6 pt per minute
    static let gutterW: CGFloat = 56                    // GUT_W
    static let headH: CGFloat = 38                      // HEAD_H
    static let railH: CGFloat = 28                      // RAIL_H
    static let colMin: CGFloat = 140                    // COL_MIN
    static let minBlockH: CGFloat = 26                  // MIN_H: "a 15-minute event is still readable"
    static let wideDay: CGFloat = 132                   // "Wednesday" + a two-digit date needs ~132 pt of column
    static let railCapWide: CGFloat = 200               // the rail shows 2 chips at ≥ 200 pt columns, else 1
    static let blockInsetX: CGFloat = 2, blockGapX: CGFloat = 5    // left: col% + 2 · width: 1/cols% − 5
    static let watermark: CGFloat = 46                  // the type glyph, the same size on every block
    static let blockRadius: CGFloat = 9                 // "a block is a span; the capsule is for instants"

    /// `colLayout`: whole columns only — n = clamp(floor(avail / 140), 1, 7), colW = floor(avail / n).
    static func columns(available: CGFloat) -> (n: Int, colW: CGFloat) {
        let n = max(1, min(7, Int((available / colMin).rounded(.down))))
        return (n, (available / CGFloat(n)).rounded(.down))
    }

    static func y(_ minute: Int) -> CGFloat { CGFloat(minute) * ppm }
    static func minute(of date: Date, calendar: Calendar = .current) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// `placement`: top = start × 1.6, height = max(26, duration × 1.6).
    static func placement(start: Int, end: Int) -> (top: CGFloat, height: CGFloat) {
        (y(start), max(minBlockH, CGFloat(end - start) * ppm))
    }

    /// The label ladder by block height: three lines ≥ 60 · two ≥ 38 · else the title only, centred.
    enum Ladder { case full, med, short }
    static func ladder(for height: CGFloat) -> Ladder { height >= 60 ? .full : height >= 38 ? .med : .short }

    /// `landingScrollTop`: the week holding today opens at now − 60 min; another week at its earliest block − 30 min; an empty week at 07:00.
    static func landing(dayStarts: [Int], holdsToday: Bool, now: Date) -> CGFloat {
        if holdsToday { return max(0, CGFloat(minute(of: now) - 60) * ppm) }
        if let first = dayStarts.min() { return max(0, CGFloat(first - 30) * ppm) }
        return 7 * hourH
    }

    // MARK: packDay — R9 §5 verbatim

    /// A span in minutes from midnight, identified so the packer's answer can be looked up.
    struct Span: Equatable { let id: String; let start: Int; let end: Int; let title: String }
    struct Packed: Equatable { let id: String; let col: Int; let cols: Int; let start: Int; let end: Int }

    /// `spanOf`: a zero or negative span is still a span — 30 minutes.
    static func normalised(_ s: Span) -> Span { s.end <= s.start ? Span(id: s.id, start: s.start, end: s.start + 30, title: s.title) : s }

    /// The sort is a TOTAL order — start ↑, duration ↓, title — so two runs of the same data produce an identical picture.
    /// Sweep into clusters of mutually overlapping spans; first free column within a cluster; every member is 1/cols wide.
    static func pack(_ spans: [Span]) -> [Packed] {
        let evs = spans.map(normalised).sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            let da = a.end - a.start, db = b.end - b.start
            if da != db { return da > db }
            return a.title.localizedCompare(b.title) == .orderedAscending
        }
        var out: [Packed] = []
        var cluster: [(Span, Int)] = []        // the span and its column
        var colEnd: [Int] = []
        var maxEnd = -1
        func flush() {
            let n = colEnd.count
            for (s, col) in cluster { out.append(Packed(id: s.id, col: col, cols: n, start: s.start, end: s.end)) }
            cluster = []; colEnd = []
        }
        for s in evs {
            if !cluster.isEmpty, s.start >= maxEnd { flush() }   // a new cluster begins
            var col = 0
            while col < colEnd.count, colEnd[col] > s.start { col += 1 }
            if col == colEnd.count { colEnd.append(s.end) } else { colEnd[col] = s.end }
            cluster.append((s, col))
            maxEnd = max(maxEnd, s.end)
        }
        if !cluster.isEmpty { flush() }
        return out
    }

    /// A packed span's horizontal frame inside a column: left = col/cols × colW + 2, width = colW/cols − 5.
    static func frameX(_ p: Packed, colW: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let w = colW / CGFloat(p.cols)
        return (CGFloat(p.col) * w + blockInsetX, w - blockGapX)
    }

    // MARK: Time text — Jeff's `fmtT` / `timeRange`

    /// `9am` · `9:50am` · `12pm`.
    static func time(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: d)
        let h = c.hour ?? 0, m = c.minute ?? 0
        var h12 = h % 12; if h12 == 0 { h12 = 12 }
        return "\(h12)" + (m > 0 ? String(format: ":%02d", m) : "") + (h < 12 ? "am" : "pm")
    }
    /// One meridiem when both ends share it: `10–10:50am`, not `10am–10:50am`.
    static func range(_ a: Date, _ b: Date, allDay: Bool = false) -> String {
        if allDay { return "all day" }
        var s = time(a); let e = time(b)
        if s.suffix(2) == e.suffix(2) { s = String(s.dropLast(2)) }
        return s + "–" + e
    }

    /// Skin strengths (event-skin.css): light / dark.
    enum Skin {   // values live in Tint (PLAN_DESIGN_CLEANUP §3.5, G0); the API is kept for WeekGrid / WeekBlock
        static func fill(dark: Bool) -> Double { Tint.weekFill(dark: dark) }
        static func edge(dark: Bool) -> Double { Tint.weekEdge(dark: dark) }
        static func outline(dark: Bool) -> Double { Tint.weekOutline(dark: dark) }
        static func watermark(dark: Bool) -> Double { Tint.weekWatermark(dark: dark) }
        static let inkType = 0.70, inkMeta = 0.58
    }
}
