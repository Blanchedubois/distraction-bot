// HUD0's check (PLAN_SESSION_HUD.md §4): the overlay's rules judged as pure code — never starts the app, reads nothing.
//   swiftc -parse-as-library -o /tmp/hud-check Sources/DistractionBot/Model/HUDRules.swift scripts/hud-check.swift && /tmp/hud-check
// Exit code 1 when an expectation fails.
import Foundation
import CoreGraphics

var failures = 0
func expect(_ name: String, _ ok: Bool, _ got: @autoclosure () -> String = "") {
    print((ok ? "PASS  " : "FAIL  ") + name + (got().isEmpty ? "" : " · got \(got())"))
    if !ok { failures += 1 }
}

@main enum HUDCheck {
    static func main() {
        let R = HUDRules.self

        print("— geometry (R0's rule, now outside the app)")
        let v = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for (right, bottom) in [(true, false), (false, false), (true, true), (false, true)] {
            let a = R.anchor(in: v, right: right, bottom: bottom)
            let pill = CGRect(origin: a, size: CGSize(width: R.width, height: R.collapsed))
            // HUD2: combo · best/today/streak/left · Now · verdict · actions, then with teach + note + next
            for rows in [[R.lineRow, R.lineRow, R.lineRow, R.pillRow, R.pillRow], [R.lineRow, R.lineRow, R.lineRow, R.pillRow, R.pillRow, R.pillRow, R.fieldRow, R.lineRow]] {
                let h = R.drawerHeight(rows: rows)
                let open = R.frame(expanded: true, drawerHeight: h, pill: pill, bottom: bottom)
                let closed = R.frame(expanded: false, drawerHeight: h, pill: R.pillRect(in: open, bottom: bottom), bottom: bottom)
                let name = "\(bottom ? "bottom" : "top")\(right ? "Right" : "Left") · \(rows.count) rows"
                expect("\(name): the pill keeps its place when the drawer opens", R.pillRect(in: open, bottom: bottom) == pill)
                expect("\(name): closing returns exactly the pill", closed == pill)
                expect("\(name): the open frame stays on screen", v.contains(open))
            }
        }
        let f = CGRect(x: 100, y: 100, width: R.width, height: R.collapsed)
        expect("a frame the panel set is not a drag", R.isProgrammatic(f, last: f))
        expect("a moved frame is a drag", !R.isProgrammatic(f.offsetBy(dx: 40, dy: -12), last: f))

        expect("HUD2: the pill is 340 wide and the fullest drawer stays under 260 pt", R.width == 340 && R.drawerHeight(rows: [R.lineRow, R.lineRow, R.lineRow, R.pillRow, R.pillRow, R.pillRow, R.fieldRow, R.lineRow]) < 260, "\(R.drawerHeight(rows: [R.lineRow, R.lineRow, R.lineRow, R.pillRow, R.pillRow, R.pillRow, R.fieldRow, R.lineRow]))")
        print("— B1: a click is a click")
        let down = CGPoint(x: 50, y: 30)
        expect("no movement is a click", !R.isDrag(from: down, to: down))
        expect("a 2-pt wobble during a click is still a click", !R.isDrag(from: down, to: CGPoint(x: 51.5, y: 31.2)))
        expect("3.9 pt is a click", !R.isDrag(from: down, to: CGPoint(x: 53.9, y: 30)))
        expect("4 pt is a drag", R.isDrag(from: down, to: CGPoint(x: 54, y: 30)))
        expect("the ✕ sits inside the pill, at its trailing top", R.closeRect.maxX <= R.width && R.closeRect.minY >= 0 && R.closeRect.maxY <= R.collapsed && R.closeRect.minX > R.width / 2)
        expect("the top band left of the ✕ is the gesture surface's (no separate drag band)", !R.closeRect.contains(CGPoint(x: 60, y: 6)))

        print("— B2: the HUD stays on its display")
        let screens = ["Built-in Retina Display", "FlipGo-A"]
        expect("the display it was put on, while attached", R.display(saved: "FlipGo-A", attached: screens, main: "Built-in Retina Display") == "FlipGo-A")
        expect("the main display when that one is unplugged", R.display(saved: "FlipGo-A", attached: ["Built-in Retina Display"], main: "Built-in Retina Display") == "Built-in Retina Display")
        expect("the main display when nothing was saved", R.display(saved: nil, attached: screens, main: "Built-in Retina Display") == "Built-in Retina Display")
        expect("the rule has no pointer input at all (the signature takes none)", true)

        print("— B3: an alert borrows a line, one deadline")
        var line = R.AlertLine()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        line.show("restless · 11 switches in 10 min", now: t0, seconds: 6)
        expect("shown at once", line.current(now: t0) != nil)
        expect("still shown at 5.9 s", line.current(now: t0.addingTimeInterval(5.9)) != nil)
        expect("gone at 6 s, with no timer left to fire", line.current(now: t0.addingTimeInterval(6)) == nil)
        line.show("away 22 min — paused", now: t0.addingTimeInterval(3), seconds: 10)
        expect("a newer alert replaces the older and keeps its own end", line.current(now: t0.addingTimeInterval(12)) == "away 22 min — paused" && line.current(now: t0.addingTimeInterval(13)) == nil)
        expect("the alert line has no drawer state to touch (AlertLine holds text and a date only)", true)

        print("— B5/B6: cards wait their turn")
        var q = R.CardQueue<String>()
        expect("the first card is shown", q.offer("site:youtube.com", "warn youtube") == .shown)
        expect("a card for another subject waits", q.offer("app:com.apple.MobileSMS", "warn messages") == .queued)
        expect("the ladder card waits behind them", q.offer("ladder", "three detours") == .queued)
        expect("the same subject's card replaces it in place (the follow-up)", q.offer("site:youtube.com", "still here youtube") == .replaced && q.current?.card == "still here youtube")
        expect("a waiting card offered again is updated, not doubled", q.offer("app:com.apple.MobileSMS", "warn messages 2") == .requeued && q.waiting.count == 2)
        expect("answering shows the next waiting card", q.advance()?.card == "warn messages 2")
        expect("then the ladder", q.advance()?.key == "ladder")
        expect("the ladder's own timer removes only the ladder", q.remove("ladder") && q.isEmpty)
        _ = q.offer("a", "1"); _ = q.offer("b", "2")
        expect("removing a card that is not shown leaves the shown one", !q.remove("b") && q.current?.key == "a")
        _ = q.offer("c", "3")
        let dropped = q.drop()
        expect("End drops everything and hands each card back to be told", dropped.map(\.key) == ["a", "c"] && q.isEmpty)

        print("— B7: the next line, once a minute")
        var cache = R.MinuteCache<String?>()
        let m0 = Date(timeIntervalSince1970: 60 * 1_000_000 + 5)
        for s in 0..<55 { _ = cache.get(R.MinuteCache<String?>.minuteKey(m0.addingTimeInterval(Double(s))), { "next · lecture 19:30" }) }
        expect("55 ticks in one minute compute once", cache.computations == 1, "\(cache.computations)")
        _ = cache.get(R.MinuteCache<String?>.minuteKey(m0.addingTimeInterval(60)), { nil })
        expect("the next minute computes again", cache.computations == 2)
        _ = cache.get(R.MinuteCache<String?>.minuteKey(m0.addingTimeInterval(61), extra: "queued: BIO 210"), { "next · BIO 210" })
        expect("a new queue recomputes within the minute", cache.computations == 3)

        print("— B8: no results for a false start")
        expect("4 s (today 14:20:40) shows no results card", !R.showsResults(elapsed: 4))
        expect("8 s (today 17:44:45) shows none", !R.showsResults(elapsed: 8))
        expect("59 s shows none", !R.showsResults(elapsed: 59))
        expect("60 s shows the results", R.showsResults(elapsed: 60))

        print("— HUD3: breaks")
        expect("the bank earns 5 min per 25 clean min: 24 min → 0, 25 → 5, 74 → 10", R.breakBank(cleanSeconds: 24 * 60, usedMinutes: 0) == 0 && R.breakBank(cleanSeconds: 25 * 60, usedMinutes: 0) == 5 && R.breakBank(cleanSeconds: 74 * 60, usedMinutes: 0) == 10)
        expect("…holds at most 20 (3 h clean → 20, not 35)", R.breakBank(cleanSeconds: 180 * 60, usedMinutes: 0) == 20)
        expect("…less what was taken (100 min clean, 10 used → 10)", R.breakBank(cleanSeconds: 100 * 60, usedMinutes: 10) == 10)
        expect("below hard any break is allowed, with nothing banked", R.mayBreak(minutes: 15, hard: false, bank: 0))
        expect("hard refuses a manual break with nothing banked", !R.mayBreak(minutes: 5, hard: true, bank: 0))
        expect("hard allows a break inside the bank (10 of 10), refuses one past it (15 of 10)", R.mayBreak(minutes: 10, hard: true, bank: 10) && !R.mayBreak(minutes: 15, hard: true, bank: 10))
        let work = [(off: false, seconds: 1800), (off: true, seconds: 600), (off: false, seconds: 2400), (off: true, seconds: 60), (off: false, seconds: 700)]
        expect("work since rest: a 10-min break resets, a 1-min blip does not (40 + 11.7 min)", R.workSinceRest(work) == 3100, "\(R.workSinceRest(work))")
        expect("a break is due at 50 min of work, once", R.breakDue(workSeconds: 3000, everyMinutes: 50, alreadySaid: false) && !R.breakDue(workSeconds: 3600, everyMinutes: 50, alreadySaid: true) && !R.breakDue(workSeconds: 2999, everyMinutes: 50, alreadySaid: false))
        expect("never, when the reminder is off", !R.breakDue(workSeconds: 99_999, everyMinutes: 0, alreadySaid: false))
        expect("the countdown reads 7:42 and 0:00", R.clock(462) == "7:42" && R.clock(-3) == "0:00")
        expect("the ladder's lock is five minutes", R.lockSeconds == 300)

        print("— HUD5: alerts")
        typealias K = HUDRules.AlertKind
        expect("defaults: check-in off, break over a notification, every other kind in the HUD",
               R.route(.checkIn, settings: [:]) == .off && R.route(.breakOver, settings: [:]) == .notify && [K.drifting, .restless, .accuracy, .breakDue, .timeLeft, .combo].allSatisfy { R.route($0, settings: [:]) == .hud })
        expect("a setting overrides the default, a garbled one falls back", R.route(.drifting, settings: ["drifting": "off"]) == .off && R.route(.drifting, settings: ["drifting": "loud"]) == .hud)
        var th = R.AlertThrottle(); let a0 = Date(timeIntervalSince1970: 2_000_000)
        expect("drifting: once per 5 min for the same item", th.allow(.drifting, key: "youtube", now: a0) && !th.allow(.drifting, key: "youtube", now: a0.addingTimeInterval(299)) && th.allow(.drifting, key: "youtube", now: a0.addingTimeInterval(300)))
        expect("…but another item may come at once", th.allow(.drifting, key: "reddit", now: a0.addingTimeInterval(10)))
        expect("restless: once per 10 min", th.allow(.restless, now: a0) && !th.allow(.restless, now: a0.addingTimeInterval(599)) && th.allow(.restless, now: a0.addingTimeInterval(600)))
        expect("the other kinds have no throttle of their own (each fires once by its own rule)", th.allow(.timeLeft, now: a0) && th.allow(.timeLeft, now: a0))
        expect("drifting is the band 0.5 ≤ c < threshold, for a distracted verdict only",
               R.isDrifting(distracted: true, confidence: 0.55, threshold: 0.7) && !R.isDrifting(distracted: true, confidence: 0.7, threshold: 0.7) && !R.isDrifting(distracted: true, confidence: 0.49, threshold: 0.7) && !R.isDrifting(distracted: false, confidence: 0.6, threshold: 0.7))
        var cr = R.Crossing()
        expect("accuracy below the line in the first 5 judged minutes is silent", !cr.check(accuracy: 80, line: 90, possibleSeconds: 200))
        expect("after that, crossing below fires once", cr.check(accuracy: 88, line: 90, possibleSeconds: 400) && !cr.check(accuracy: 85, line: 90, possibleSeconds: 500))
        expect("back at the line re-arms it; the next crossing fires again", !cr.check(accuracy: 90, line: 90, possibleSeconds: 600) && cr.check(accuracy: 89.9, line: 90, possibleSeconds: 700))
        expect("check-in every 25 min: due at 25, not at 24:59; never when off", R.checkInDue(elapsed: 1500, last: 0, everyMinutes: 25) && !R.checkInDue(elapsed: 1499, last: 0, everyMinutes: 25) && !R.checkInDue(elapsed: 99_999, last: 0, everyMinutes: 0))
        expect("time left: in the last 5 min, once; never for an open session", R.timeLeftDue(remaining: 299, said: false) && !R.timeLeftDue(remaining: 299, said: true) && !R.timeLeftDue(remaining: 301, said: false) && !R.timeLeftDue(remaining: nil, said: false))

        print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
