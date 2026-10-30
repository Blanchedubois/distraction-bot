// PLAN_CATCHER X1–X4's check: drives the Classifier, the rolling budget window, the return grace, the re-judge expiry, the switch
// rate and the Idle/away maths with synthetic polls — no app, no Ollama, no log. Every line prints ✓ or ✗; the exit code is the count of ✗.
//   swiftc -o /tmp/catcher-check Sources/DistractionBot/Model/AppClass.swift Sources/DistractionBot/Watch/CatcherMaths.swift scripts/catcher-check.swift
//   /tmp/catcher-check
import Foundation

@main struct Check {
  static func main() {

    var failures = 0
    func check(_ ok: Bool, _ what: String) { print((ok ? "✓ " : "✗ ") + what); if !ok { failures += 1 } }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    // ── X1 classes: the 20 apps and hosts of the real log (IMPACT_ANALYSIS A0.8), as the analysis classed them
    print("X1 classes")
    let apps: [(String, String, AppClass)] = [
        ("com.spotify.client", "Spotify", .utility), ("com.apple.Music", "Music", .utility), ("com.sunsama.app", "Sunsama", .utility), ("com.apple.finder", "Finder", .utility),
        ("com.hnc.Discord", "Discord", .communication), ("com.apple.MobileSMS", "Messages", .communication), ("ru.keepcoder.Telegram", "Telegram", .communication),
        ("net.whatsapp.WhatsApp", "WhatsApp", .communication), ("com.valvesoftware.steam", "Steam", .entertainment), ("com.valvesoftware.steam.helper", "Steam Helper", .entertainment),
        ("com.microsoft.VSCode", "Code", .tool), ("com.apple.Terminal", "Terminal", .tool), ("com.apple.iWork.Keynote", "Keynote", .tool), ("com.figma.Desktop", "Figma", .tool),
        ("com.anthropic.claudefordesktop", "Claude", .tool), ("com.apple.Preview", "Preview", .tool), ("some.unknown.app", "Jeff", .unknown),
    ]
    for (b, n, want) in apps { check(Classifier.classOf(app: b, name: n) == want, "\(n) → \(want)") }
    let hosts: [(String, AppClass)] = [
        ("www.youtube.com", .entertainment), ("reddit.com", .entertainment), ("store.steampowered.com", .entertainment), ("linkedin.com", .communication), ("mail.google.com", .communication),
        ("app.slack.com", .communication), ("github.com", .tool), ("www.overleaf.com", .tool), ("canvas.instructure.com", .tool), ("physics.stackexchange.com", .tool), ("en.wikipedia.org", .tool),
        ("claude.ai", .tool), ("www.google.com", .utility), ("calendar.google.com", .utility), ("app.sunsama.com", .utility), ("kisleylab.science", .unknown), ("blanchedubois.github.io", .unknown),
        ("docs.google.com", .tool), ("gradescope.com", .tool), ("fallingfigures.io", .entertainment),
    ]
    for (h, want) in hosts { check(Classifier.classOf(host: h) == want, "\(h) → \(want)") }
    check(Classifier.classOf(host: "mail.google.com") == .communication && Classifier.classOf(host: "google.com") == .utility, "the longest suffix wins (mail.google.com over google.com)")
    Classifier.learned = ["kisleylab.science": .tool, "some.unknown.app": .entertainment]
    check(Classifier.classOf(host: "www.kisleylab.science") == .tool, "a learned host class wins")
    check(Classifier.classOf(app: "some.unknown.app", name: "Jeff") == .entertainment, "a learned app class wins")
    Classifier.learned = [:]
    check(!Classifier.judgedOnDwell(.utility) && !Classifier.judgedOnDwell(.communication) && Classifier.judgedOnDwell(.tool) && Classifier.judgedOnDwell(.unknown), "utility and communication are budgeted only")

    // ── X1 return grace: Spotify 8 s then back to Dia
    print("X1 return grace")
    var hist = FrontHistory()
    hist.front("dia", name: "Dia", title: "Jeff — StudyRAG", at: at(0))
    hist.front("spotify", name: "Spotify", at: at(100))
    hist.front("dia", name: "Dia", at: at(108))
    check(hist.returned(from: "spotify"), "Spotify 8 s then back to Dia → returned (the verdict is dropped, logged judge.returned)")
    check(!hist.returned(from: "dia"), "Dia itself is not a return")
    check(hist.previous?.id == "spotify" && hist.current?.id == "dia", "history: previous Spotify · current Dia")
    var hist2 = FrontHistory()
    hist2.front("dia", name: "Dia", at: at(0)); hist2.front("spotify", name: "Spotify", at: at(100)); hist2.front("dia", name: "Dia", at: at(190))
    check(!hist2.returned(from: "spotify"), "Spotify 90 s then back → not a return (grace is 60 s)")
    var hist3 = FrontHistory()
    hist3.front("dia", name: "Dia", at: at(0)); hist3.front("spotify", name: "Spotify", at: at(100)); hist3.front("code", name: "Code", at: at(108))
    check(!hist3.returned(from: "spotify"), "Spotify 8 s then on to Code → not a return (not where they came from)")
    check(CatcherWords.previous(name: "Overleaf", title: "project.tex", verdict: "work", left: 125) == "Overleaf — project.tex · work · 2 min ago", "PREVIOUS line: " + CatcherWords.previous(name: "Overleaf", title: "project.tex", verdict: "work", left: 125))

    // ── X1 budgets: Discord 6 min of 10 on normal (communication 5 min) → one budget request, a second only after 10 more minutes
    print("X1 budgets")
    var win = FrontWindow()
    var budgetAt: [String: Date] = [:]
    var requests: [Date] = []
    let commBudget = 5.0 * 60
    for s in 0..<(20 * 60) {   // 20 minutes: Discord in front from minute 2 to 8, then Code, then Discord again from minute 12 to 20
        let now = at(Double(s))
        let front = (s >= 120 && s < 480) || s >= 720 ? "discord" : "code"
        win.tick(front, at: now)
        let secs10 = win.seconds("discord", minutes: 10, now: now)
        if Double(secs10) >= commBudget, budgetAt["discord"].map({ now.timeIntervalSince($0) >= 600 }) ?? true { budgetAt["discord"] = now; requests.append(now) }
    }
    check(requests.count == 2, "Discord: \(requests.count) budget requests in 20 min (want 2)")
    check(requests.first.map { $0.timeIntervalSince(t0) } == 419, "the first at 6 min 59 s (5 min of Discord in the window): \(requests.first.map { Int($0.timeIntervalSince(t0)) } ?? -1) s")
    check(requests.count == 2 && requests[1].timeIntervalSince(requests[0]) >= 600, "the second 10 min or more later: \(requests.count == 2 ? Int(requests[1].timeIntervalSince(requests[0])) : -1) s")
    check(win.seconds("discord", minutes: 10, now: at(1199)) == 480, "window: Discord 480 s of the last 10 min at 20:00 (\(win.seconds("discord", minutes: 10, now: at(1199))))")
    check(win.seconds("code", minutes: 10, now: at(1199)) == 121, "window: Code 121 s of the last 10 min (599–719 s inclusive): \(win.seconds("code", minutes: 10, now: at(1199)))")
    var spot = FrontWindow()
    for s in 0..<8 { spot.tick("spotify", at: at(Double(s))) }
    check(Double(spot.seconds("spotify", minutes: 10, now: at(8))) < 2 * 60, "Spotify 8 s: under the 2-min utility budget → no verdict")
    var deep = FrontWindow(); for s in 0..<(25 * 60) { deep.tick("x", at: at(Double(s))) }
    check(deep.stamps["x"]!.count <= 20 * 60 + 1, "the window is 20 min deep (\(deep.stamps["x"]!.count) stamps)")

    // ── X2 re-judge on dwell: a key in front 25 min on normal → requests at 10 and 20 min after the first verdict; nothing before 10 min
    print("X2 re-judge")
    var jk = JudgedKeys()
    let key = "dia|Jeff — StudyRAG"
    var verdicts: [Int] = []
    var dwellLines: [String] = []
    for s in 0..<(25 * 60) {
        let now = at(Double(s))
        if s == 0 { jk.visited(key, at: now) }
        if s == 5 { jk.judged(key, at: now, inFrontSince: at(0)); verdicts.append(s); dwellLines.append(CatcherWords.dwell(inFront: 5, visits: jk.visits(key), lastDistraction: nil)) }
        else if s > 5, jk.due(key, now: now, rejudgeMinutes: 10) {
            jk.judged(key, at: now, inFrontSince: at(0)); verdicts.append(s)
            dwellLines.append(CatcherWords.dwell(inFront: Double(s), visits: jk.visits(key), lastDistraction: nil))
        }
    }
    check(verdicts == [5, 605, 1205], "requests at 5 s, 10 min 05 s and 20 min 05 s: \(verdicts)")
    check(dwellLines[1] == "in front 10 min this session · 1st visit", "DWELL at 10 min: \(dwellLines[1])")
    check(dwellLines[2].hasPrefix("in front 20 min"), "DWELL at 20 min: \(dwellLines[2])")
    check(JudgedKeys.nextAfter(count: 3, base: 10) == 20 && JudgedKeys.nextAfter(count: 4, base: 10) == 40, "then 40 and 80 min (doubling)")
    var jk2 = JudgedKeys()
    jk2.judged(key, at: at(5), inFrontSince: at(0))
    jk2.visited(key, at: at(300))                                         // left at some point, back at 5 min
    check(!jk2.due(key, now: at(605), rejudgeMinutes: 10), "left and re-entered at 5 min: not due at 10 min (the wait restarts)")
    check(jk2.due(key, now: at(900), rejudgeMinutes: 10), "due 10 min after the return")
    check(jk2.visits(key) == 2 && CatcherWords.dwell(inFront: 600, visits: 2, lastDistraction: 840) == "in front 10 min this session · 2nd visit · last distraction 14 min ago",
          "2nd visit: " + CatcherWords.dwell(inFront: 600, visits: 2, lastDistraction: 840))
    check(CatcherWords.ordinal(3) == "3rd" && CatcherWords.ordinal(11) == "11th" && CatcherWords.ordinal(22) == "22nd", "ordinals")
    var jkStrict = JudgedKeys(); jkStrict.judged(key, at: at(0), inFrontSince: at(0))
    check(!jkStrict.due(key, now: at(419), rejudgeMinutes: 7) && jkStrict.due(key, now: at(420), rejudgeMinutes: 7), "strict: 7 min")

    // ── X3 switch rate: 15 synthetic switches in 10 min → rate 15, one nudge, none for the next 10 min; the words at 4/9/15
    print("X3 switch rate")
    var sw = SwitchLog()
    var nudges: [Int] = []
    for s in 0..<(20 * 60) {
        let now = at(Double(s))
        if s < 600, s % 40 == 0 { sw.note(at: now) }                       // 15 switches in the first 10 min
        if let n = sw.nudgeDue(threshold: 12, now: now) { nudges.append(s); check(n == 13 || n == 15, "the nudge carries the rate (\(n))") }
    }
    check(sw.rate(minutes: 10, now: at(599)) == 15, "switchRate 15 at 10 min (\(sw.rate(minutes: 10, now: at(599))))")
    check(nudges.count == 1, "one judge.nudge in 20 min (\(nudges.count), at \(nudges))")
    check(sw.max10 == 15 && sw.total == 15, "the switches row at End: \(sw.total) · max10 \(sw.max10)")
    check(sw.rate(minutes: 10, now: at(1199)) == 0, "rate back to 0 ten minutes later")
    check(SwitchLog.word(rate: 4, nudge: 12) == "calm" && SwitchLog.word(rate: 9, nudge: 12) == "busy" && SwitchLog.word(rate: 15, nudge: 12) == "restless", "switchWord: calm 4 · busy 9 · restless 15")
    check(SwitchLog.word(rate: 9, nudge: 8) == "restless", "extreme (nudge 8): 9 is restless")
    var sw2 = SwitchLog(); for s in stride(from: 0, to: 1200, by: 30) { sw2.note(at: at(Double(s))) }
    var n2 = 0; for s in 0..<1200 where sw2.nudgeDue(threshold: 12, now: at(Double(s))) != nil { n2 += 1 }
    check(sw2.rate(minutes: 10, now: at(1199)) == 20 && n2 >= 1, "a steady 20/10 min stays above the threshold; nudged \(n2)× (once per 10 min)")

    // ── X4 idle and away: 5 min idle opens session.away, input closes it with the seconds; 15 min pauses and extends
    print("X4 idle and away")
    var away = AwayTracker()
    var log: [AwayTracker.Event] = []
    for s in 0..<(30 * 60) {
        let now = at(Double(s))
        let idle: Double = s < 60 ? 0 : (s < 25 * 60 ? Double(s - 60) : 0)      // typing for a minute, away 24 min, back at 25:00
        log += away.tick(idle: idle, now: now, awayAfter: 300, autoPauseAfter: 900)
    }
    let opened = log.compactMap { e -> Date? in if case .opened(let d) = e { return d }; return nil }
    check(opened.count == 1 && opened[0] == at(60), "session.away opens once, dated when input stopped (1:00): \(opened.map { Int($0.timeIntervalSince(t0)) })")
    check(log.contains(.pause), "15 min idle → the auto-pause")
    let extends = log.filter { $0 == .extend }.count
    check(extends == 8, "the pause is extended each minute while still idle: \(extends) extends (at 16…23 min; the pause itself at 15)")
    let closed = log.compactMap { e -> Int? in if case .closed(let n) = e { return n }; return nil }
    check(closed == [24 * 60], "input back at 25:00 closes it with the seconds: \(closed)")
    check(log.contains(.resumed(seconds: 24 * 60)), "and the line with resume · end is asked for")
    check(!away.isAway, "not away afterwards")
    var short = AwayTracker(); var l2: [AwayTracker.Event] = []
    for s in 0..<(8 * 60) { l2 += short.tick(idle: s < 7 * 60 ? Double(s) : 0, now: at(Double(s)), awayAfter: 300, autoPauseAfter: 900) }
    check(l2 == [.opened(at(0)), .closed(seconds: 420)], "7 min idle: an away span of 420 s, no pause: \(l2)")
    var none = AwayTracker(); var l3: [AwayTracker.Event] = []
    for s in 0..<600 { l3 += none.tick(idle: Double(s % 200), now: at(Double(s)), awayAfter: 300, autoPauseAfter: 900) }
    check(l3.isEmpty, "input every 200 s: never away")
    var off = AwayTracker(); var l4: [AwayTracker.Event] = []
    for s in 0..<(20 * 60) { l4 += off.tick(idle: Double(s), now: at(Double(s)), awayAfter: 300, autoPauseAfter: nil) }
    check(l4 == [.opened(at(0))] , "auto-pause off: away opens, never pauses")
    var lock = AwayTracker(); var l5: [AwayTracker.Event] = []
    l5 += lock.force(at: at(10))                                           // the lock screen: away at once
    l5 += lock.tick(idle: 0.5, now: at(11), awayAfter: 300, autoPauseAfter: 900)   // the unlock keystrokes do not close it while locked
    lock.unforce()
    l5 += lock.tick(idle: 0.5, now: at(130), awayAfter: 300, autoPauseAfter: 900)
    check(l5 == [.opened(at(10)), .closed(seconds: 120)], "lock → away at once; unlock + input → closed with 120 s: \(l5)")
    // the figures: a 60-min session with a 24-min away span → focused 36 min
    let focused = 60 * 60 - closed.reduce(0, +)
    check(focused == 36 * 60, "a 60-min session minus the away span → \(focused / 60) min focused (Stats.awaySeconds, DayModel.Figures.away)")

    print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
    exit(Int32(failures))

  }
}
