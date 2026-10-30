import Foundation
import CoreGraphics

/// The strip's geometry — Jeff's `geometry.ts` with days swapped for hours (PLAN_TODAY_TIMELINE §3.3).
/// One number, `pxPerHour`, decides everything: every x is `x(date)`, the level of detail follows the scale,
/// and no view does date arithmetic of its own (Jeff's L1).
struct TodayGeometry {
    enum Detail { case hours3, hours, quarters, minutes }
    struct Tick { let at: Date; let x: CGFloat; let major: Bool; let label: String }
    struct Band { let from: Date; let to: Date; let x0: CGFloat; let x1: CGFloat; let label: String }

    // Jeff's rows, in points (semester-strip.css)
    static let headH: CGFloat = 26, rowGap: CGFloat = 8, rulerH: CGFloat = 18, trackH: CGFloat = 36, tickH: CGFloat = 14
    static let laneH: CGFloat = 24, laneGap: CGFloat = 6, bottom: CGFloat = 12, lanes = 2
    static let planH: CGFloat = 20                                      // PLAN_TODAY_SCHEDULE D2 (§3.4): the plan line and its 4 pt bar
    static let trackTop = rulerH, trackBottom = rulerH + trackH, lanesTop = rulerH + trackH + tickH + 4
    static var canvasH: CGFloat { rulerH + trackH + tickH + CGFloat(lanes) * (laneH + laneGap) + bottom }
    static var bodyH: CGFloat { headH + rowGap + planH + canvasH }                                     // 194 (174 before D2)
    /// G4 (PLAN_DESIGN_CLEANUP §5a Q10): below the page's narrow breakpoint the head takes two rows (chips and zoom under the figure).
    static func headH(twoRows: Bool) -> CGFloat { twoRows ? headH * 2 + rowGap : headH }
    static func bodyH(twoRows: Bool) -> CGFloat { headH(twoRows: twoRows) + rowGap + planH + canvasH }

    let start: Date
    let end: Date
    let width: CGFloat
    let pxPerHour: CGFloat
    var scrollX: CGFloat = 0

    init(start: Date, end: Date, width: CGFloat, pxPerHour: CGFloat? = nil) {
        self.start = start; self.end = end; self.width = width
        let hours = max(1, end.timeIntervalSince(start) / 3600)
        self.pxPerHour = pxPerHour ?? width / CGFloat(hours)
    }

    var total: CGFloat { CGFloat(end.timeIntervalSince(start) / 3600) * pxPerHour }
    func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / 3600) * pxPerHour - scrollX }
    func clampedX(_ d: Date) -> CGFloat { max(0, min(width, x(d))) }

    /// Jeff's `detailFor`: months → weeks → days → hours becomes 3 h → 1 h → 15 min → 5 min.
    var detail: Detail { pxPerHour < 40 ? .hours3 : pxPerHour < 170 ? .hours : pxPerHour < 480 ? .quarters : .minutes }   // P2: quarter labels collided below 170 px/h (rendered 2026-10-29)

    /// The ruler's bands (Jeff's month bands): the first starts AT the axis start (Jeff labels the first month at the
    /// axis, not the 1st), the rest on 3-h boundaries — hourly once past 80 px/h.
    func bands() -> [Band] {
        let cal = Calendar.current
        let step = pxPerHour < 80 ? 3 : 1
        var out: [Band] = []
        var d = start
        while d < end {
            let h = cal.component(.hour, from: d)
            let nextH = (h / step + 1) * step
            let n = min(end, nextH >= 24 ? cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d))! : cal.date(bySettingHour: nextH, minute: 0, second: 0, of: d)!)
            out.append(Band(from: d, to: n, x0: x(d), x1: x(n), label: String(format: "%02d:00", h)))
            d = n
        }
        return out
    }

    /// Ticks under the track: minor every hour at 3-h scale, every 15 min at 1-h scale, every 5 min at quarters, every minute deeper.
    func ticks() -> [Tick] {
        let cal = Calendar.current
        let (minorSec, majorSec): (TimeInterval, TimeInterval) = {
            switch detail { case .hours3: return (3600, 3 * 3600); case .hours: return (900, 3600); case .quarters: return (300, 900); case .minutes: return (60, 300) }
        }()
        var out: [Tick] = []
        var t = cal.startOfDay(for: start)
        while t < start { t += minorSec }
        let f = DateFormatter(); f.dateFormat = detail == .hours3 || detail == .hours ? "HH:mm" : "HH:mm"
        while t <= end {
            let major = t.timeIntervalSince(cal.startOfDay(for: start)).truncatingRemainder(dividingBy: majorSec) == 0
            out.append(Tick(at: t, x: x(t), major: major, label: major && (detail == .quarters || detail == .minutes) ? f.string(from: t) : ""))
            t += minorSec
        }
        return out
    }

    // MARK: Zoom (Jeff's useStripView: one number, px per hour, from fit-to-width to one hour filling the width)

    struct Zoom: Equatable { var scale: CGFloat? = nil; var scrollX: CGFloat = 0 }          // nil scale = fit (the whole day)

    static func fitScale(start: Date, end: Date, width: CGFloat) -> CGFloat { width / CGFloat(max(1, end.timeIntervalSince(start) / 3600)) }
    static func maxScale(width: CGFloat) -> CGFloat { max(1, width) }
    static func clampScroll(_ x: CGFloat, total: CGFloat, width: CGFloat) -> CGFloat { max(0, min(x, max(0, total - width))) }

    /// Zoom to `next` px/hour keeping the axis point under viewport x `cx` still; reaching fit snaps to the whole day.
    static func zoom(_ z: Zoom, to next: CGFloat, at cx: CGFloat, fit: CGFloat, maxScale: CGFloat, hours: CGFloat, width: CGFloat) -> Zoom {
        let cur = z.scale ?? fit
        let s = max(fit, min(maxScale, next))
        let hourUnder = (clampScroll(z.scrollX, total: hours * cur, width: width) + cx) / cur
        if s <= fit + 1e-6 { return Zoom() }
        return Zoom(scale: s, scrollX: clampScroll(hourUnder * s - cx, total: hours * s, width: width))
    }
    /// Zoom that fits an interval of the day into the width, its start at the left edge: the worked window on
    /// appear and on "now". A window the whole day already fits snaps to the day.
    static func fit(_ r: ClosedRange<Date>, start: Date, end: Date, width: CGFloat) -> Zoom {
        let hours = CGFloat(max(1, end.timeIntervalSince(start) / 3600))
        let f = fitScale(start: start, end: end, width: width)
        let span = CGFloat(max(1.0 / 60, r.upperBound.timeIntervalSince(r.lowerBound) / 3600))
        let s = max(f, min(maxScale(width: width), width / span))
        if s <= f + 1e-6 { return Zoom() }
        return Zoom(scale: s, scrollX: clampScroll(CGFloat(r.lowerBound.timeIntervalSince(start) / 3600) * s, total: hours * s, width: width))
    }
    static func pan(_ z: Zoom, by dx: CGFloat, fit: CGFloat, hours: CGFloat, width: CGFloat) -> Zoom {
        guard let s = z.scale else { return z }
        return Zoom(scale: s, scrollX: clampScroll(z.scrollX + dx, total: hours * s, width: width))
    }
    /// Centre an instant (its x at the current scale, un-scrolled).
    static func centre(_ z: Zoom, onX x: CGFloat, hours: CGFloat, width: CGFloat, fit: CGFloat) -> Zoom {
        let s = z.scale ?? fit
        return Zoom(scale: z.scale, scrollX: clampScroll(x - width / 2, total: hours * s, width: width))
    }
    var detailWord: String { switch detail { case .hours3: return "3 h"; case .hours: return "hour"; case .quarters: return "15 min"; case .minutes: return "5 min" } }

    // MARK: Lanes and clusters (Jeff's packLanes / clusterBy)

    struct Placed<T> { let item: T; let x: CGFloat; let lane: Int }
    struct Group<T> { var x: CGFloat; var items: [T] }

    /// Marks closer than `px` collapse into one group (greedy, left to right, the group's x the mean).
    static func cluster<T>(_ items: [(item: T, x: CGFloat)], within px: CGFloat) -> [Group<T>] {
        var out: [Group<T>] = []
        for p in items.sorted(by: { $0.x < $1.x }) {
            if var last = out.last, p.x - last.x < px {
                last.items.append(p.item); last.x = (last.x * CGFloat(last.items.count - 1) + p.x) / CGFloat(last.items.count); out[out.count - 1] = last
            } else { out.append(Group(x: p.x, items: [p.item])) }
        }
        return out
    }

    /// Greedy lane packing: each item takes the first lane whose last item ends `gap` before it; the rest overflow.
    static func packLanes<T>(_ items: [(item: T, x: CGFloat, w: CGFloat)], lanes: Int, gap: CGFloat) -> (placed: [Placed<T>], overflow: [(item: T, x: CGFloat)]) {
        var ends = Array(repeating: -CGFloat.infinity, count: lanes)
        var placed: [Placed<T>] = []; var overflow: [(item: T, x: CGFloat)] = []
        for p in items.sorted(by: { $0.x < $1.x }) {
            if let l = ends.indices.first(where: { ends[$0] + gap <= p.x - p.w / 2 }) { ends[l] = p.x + p.w / 2; placed.append(Placed(item: p.item, x: p.x, lane: l)) }
            else { overflow.append((p.item, p.x)) }
        }
        return (placed, overflow)
    }
}
