// T3's headless check: cursor-anchored zoom keeps the point under the cursor still through 10 steps in and out,
// reaching fit snaps back to the day, and a 37-second period grows from 3 pt to a legible span at the hour scale.
//   swiftc -o /tmp/zoom-check Sources/DistractionBot/Design/TodayGeometry.swift scripts/zoom-check.swift && /tmp/zoom-check
import Foundation
import CoreGraphics
@main struct ZoomCheck {
    static func main() {
        let cal = Calendar.current, day = cal.startOfDay(for: Date())
        let start = cal.date(bySettingHour: 7, minute: 0, second: 0, of: day)!, end = cal.date(byAdding: .day, value: 1, to: day)!
        let width: CGFloat = 952, hours: CGFloat = 17
        let fit = TodayGeometry.fitScale(start: start, end: end, width: width), maxS = TodayGeometry.maxScale(width: width)
        var z = TodayGeometry.Zoom(); let cx: CGFloat = 300
        func hourUnder(_ z: TodayGeometry.Zoom) -> CGFloat { let s = z.scale ?? fit; return (TodayGeometry.clampScroll(z.scrollX, total: hours * s, width: width) + cx) / s }
        let h0 = hourUnder(z); var worst: CGFloat = 0; var fails = 0
        for i in 1...10 {
            z = TodayGeometry.zoom(z, to: (z.scale ?? fit) * 1.25, at: cx, fit: fit, maxScale: maxS, hours: hours, width: width)
            let drift = abs(hourUnder(z) - h0) * (z.scale ?? fit)          // in points at the new scale
            worst = max(worst, drift); if drift > 1 { fails += 1 }
            let g = TodayGeometry(start: start, end: end, width: width, pxPerHour: z.scale ?? fit)
            print(String(format: "in  %2d  %6.1f px/h  drift %.3f pt  detail %@", i, Double(z.scale ?? fit), Double(drift), g.detailWord))
        }
        for i in 1...10 {
            z = TodayGeometry.zoom(z, to: (z.scale ?? fit) / 1.25, at: cx, fit: fit, maxScale: maxS, hours: hours, width: width)
            let drift = abs(hourUnder(z) - h0) * (z.scale ?? fit)
            worst = max(worst, drift); if drift > 1 { fails += 1 }
            print(String(format: "out %2d  %6.1f px/h  drift %.3f pt  scale %@", i, Double(z.scale ?? fit), Double(drift), z.scale == nil ? "FIT (day)" : "zoomed"))
        }
        let atMax = TodayGeometry.zoom(TodayGeometry.Zoom(), to: 1e9, at: cx, fit: fit, maxScale: maxS, hours: hours, width: width)
        let gMax = TodayGeometry(start: start, end: end, width: width, pxPerHour: atMax.scale!)
        let span37 = CGFloat(37.0 / 3600) * (atMax.scale!), span37fit = CGFloat(37.0 / 3600) * fit
        print("\nfit \(fit) px/h · max \(atMax.scale!) px/h (\(gMax.detailWord)) · a 37-s period: \(String(format: "%.1f", Double(span37fit))) pt at fit (drawn at the 3 pt minimum) → \(String(format: "%.1f", Double(span37))) pt at max")
        print("worst drift \(String(format: "%.3f", Double(worst))) pt over 20 steps · \(fails) steps over 1 pt · back at fit: \(z.scale == nil && z.scrollX == 0 ? "yes" : "NO")")
        let panned = TodayGeometry.pan(TodayGeometry.Zoom(scale: maxS, scrollX: 0), by: 1e6, fit: fit, hours: hours, width: width)
        // the worked-window fit (Home's ask, 2026-10-27): 19:00–23:40 worked at 984 pt opens 18:00–00:00 (clamped), start at the left edge
        let a = cal.date(bySettingHour: 19, minute: 0, second: 0, of: day)!, b = cal.date(bySettingHour: 23, minute: 40, second: 0, of: day)!
        let w984: CGFloat = 984, f984 = TodayGeometry.fitScale(start: start, end: end, width: w984)
        let win = max(start, a.addingTimeInterval(-3600))...min(end, b.addingTimeInterval(3600))
        let zw = TodayGeometry.fit(win, start: start, end: end, width: w984)
        var gw = TodayGeometry(start: start, end: end, width: w984, pxPerHour: zw.scale ?? f984); gw.scrollX = zw.scrollX
        print(String(format: "\nworked fit  %.1f px/h (%@) · left edge at %.1f pt (0 wanted) · right edge of the window at %.1f pt (%.0f wanted) · %.1fx the day fit",
            Double(zw.scale ?? f984), gw.detailWord, Double(gw.x(win.lowerBound)), Double(gw.x(win.upperBound)), Double(w984), Double((zw.scale ?? f984) / f984)))
        let whole = TodayGeometry.fit(start...end, start: start, end: end, width: w984)
        print("a window of the whole day snaps to fit: \(whole.scale == nil ? "yes" : "NO")")
        print("pan clamps at the end: scrollX \(panned.scrollX) == total − width \(hours * maxS - width) → \(panned.scrollX == hours * maxS - width ? "yes" : "NO")")
    }
}
