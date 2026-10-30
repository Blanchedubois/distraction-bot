// T2's pointer check (PLAN_TODAY_TIMELINE §4, second attempt). With the app open as
//   DBOT_DEV_VIEW=today DBOT_HOVER_LOG=1 DBOT_SNAPSHOT_DAY=2026-10-26
// the app log carries "canvas-origin X Y W H" (window-content space, after settling), "devwindow content-origin X Y"
// (the content's screen origin, CG coordinates) and "pos <kind> <key> x y w h" (canvas space, computed). This script:
//   1. parks the pointer on empty paper in the strip for 400 ms (clears any launch-time hover),
//   2. crosses the named chip's LEFT edge N times at 2 pt per 12 ms (expect N "hot on" + N "hot off" for it),
//   3. hovers the named cluster (expect "hot on c-…" and "pos fan c-…"), clicks its first fan pill (expect "open log query"),
//   4. clicks the named chip itself (expect "open log query=<subject>"),
//   5. restores the pointer and sends SIGTERM to the app.
//   swiftc -o /tmp/t2-drive scripts/t2-drive.swift && /tmp/t2-drive <log> <app pid> <chip key substring> <cluster key substring> [N]
import Foundation
import CoreGraphics

let a = CommandLine.arguments
let logPath = a[1], pid = Int32(a[2]) ?? 0, chipSub = a[3], clusterSub = a[4]
let n = a.count > 5 ? Int(a[5]) ?? 20 : 20
func lines() -> [String] { (try? String(contentsOfFile: logPath, encoding: .utf8))?.components(separatedBy: "\n") ?? [] }
func nums(_ l: String, _ k: Int) -> [Double] { l.components(separatedBy: " ").suffix(k).compactMap { Double($0) } }
func last(_ needle: String, after: Int = 0) -> String? { Array(lines().dropFirst(after)).last { $0.contains(needle) } }
func move(_ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
func click(_ p: CGPoint) {
    move(p); usleep(100_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap); usleep(60_000)
    CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func fail(_ s: String) -> Never { print("FAIL \(s)"); if pid > 0 { kill(pid, SIGTERM) }; exit(2) }

let before = CGEvent(source: nil)?.location ?? .zero
guard let co = last("devwindow content-origin").map({ nums($0, 2) }), co.count == 2,
      let cv = last("canvas-origin").map({ nums($0, 4) }), cv.count == 4 else { fail("no origins in log") }
let ox = co[0] + cv[0], oy = co[1] + cv[1]                      // canvas (0,0) on screen, CG coordinates
func screen(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + x, y: oy + y) }
guard let chip = last("pos chip").flatMap({ _ in last("pos chip ") }).flatMap({ _ in lines().last { $0.contains("pos chip ") && $0.contains(chipSub) } }).map({ nums($0, 4) }), chip.count == 4 else { fail("no chip pos for \(chipSub)") }
guard let cl = lines().last(where: { $0.contains("pos cluster ") && $0.contains(clusterSub) }).map({ nums($0, 4) }), cl.count == 4 else { fail("no cluster pos for \(clusterSub)") }
print("canvas at screen (\(ox), \(oy)) size \(cv[2])×\(cv[3]); chip at canvas \(chip); cluster at \(cl)")

// 1 · park on empty paper: the ruler band, far left
move(screen(30, 8)); usleep(400_000)
let n0 = lines().count

// 2 · cross the chip's left edge
let cy = chip[1] + chip[3] / 2, x0 = chip[0] - 14, x1 = chip[0] + 6
for _ in 0..<n {
    for s in stride(from: x0, through: x1, by: 2) { move(screen(s, cy)); usleep(12_000) }
    usleep(250_000)
    for s in stride(from: x1, through: x0, by: -2) { move(screen(s, cy)); usleep(12_000) }
    usleep(250_000)
}
usleep(300_000)
let crossed = Array(lines().dropFirst(n0))
let ons = crossed.filter { $0.contains("hot on") && $0.contains(chipSub) }.count
let offs = crossed.filter { $0.contains("hot off") && $0.contains(chipSub) }.count
print("crossings \(n): hot on \(ons), hot off \(offs)")

// 3 · the cluster and its first fan pill
let n1 = lines().count
move(screen(cl[0] + cl[2] / 2, cl[1] + cl[3] / 2)); usleep(500_000)
if let fan = Array(lines().dropFirst(n1)).last(where: { $0.contains("pos fan ") }).map({ nums($0, 4) }), fan.count == 4 {
    let px = fan[0] + 6 + 24, py = fan[1] + 6 + 12                 // inside the first pill of the first row
    move(screen(px, fan[1] + 2)); usleep(120_000); move(screen(px, py)); usleep(250_000); click(screen(px, py)); usleep(400_000)
    print("fan opened at \(fan); clicked first pill → " + (Array(lines().dropFirst(n1)).last { $0.contains("open log query") } ?? "no open line"))
} else { print("fan did not open (no pos fan line)") }

// 4 · click the chip itself
move(screen(30, 8)); usleep(400_000)
let n2 = lines().count
click(screen(chip[0] + 12, cy)); usleep(400_000)
print("chip click → " + (Array(lines().dropFirst(n2)).last { $0.contains("open log query") } ?? "no open line"))

// 5 · restore and quit the app
move(before)
if pid > 0 { kill(pid, SIGTERM) }
print("done; pointer restored; app told to quit")
