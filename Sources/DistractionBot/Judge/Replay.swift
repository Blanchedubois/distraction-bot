import Foundation

/// X0 (PLAN_CATCHER §3.1): the replay harness. For every `judge.verdict` in a range, the prompt's facts are rebuilt — exactly from the
/// `judge.facts` row written just before it, or (rows from before X0) from the verdict's own `what` and the session's start row — and the
/// judge is run again with today's prompt and classes, without touching the live `Judge` (its own instance, `persist = false`).
/// `--replay <yyyy-mm-dd> [<yyyy-mm-dd>] [--model m] [--level normal] [--dry]`: quiet, reads the log at `DBOT_LOG_PATH` (a copy) or the live one.
@MainActor
enum Replay {
    struct Item {
        let verdict: Event
        let facts: Judge.Facts
        let exact: Bool                 // rebuilt from a judge.facts row
        let was: Bool                   // the logged verdict: distracted?
        let what: String
        let answer: String?             // the user's answer to this verdict's card, if any (work · back · ignored · snooze)
        let followedThrough: Int?       // seconds of a detour that ended "followed through"
        var date: Date { verdict.ts }
    }

    /// A `judge.facts` detail back into its parts. nil when the FRONT line does not parse.
    struct Parsed { var front: String; var kind: String; var title: String; var url: String?; var cls: String?; var dwell: String?; var previous: String?; var usage: String? }
    static func parse(facts detail: String) -> Parsed? {
        var p = Parsed(front: "", kind: "app", title: "", url: nil)
        var seenFront = false
        for line in detail.components(separatedBy: " ¦ ") {
            if line.hasPrefix("FRONT: ") {
                var rest = String(line.dropFirst(7))
                if let r = rest.range(of: " — url: ", options: .backwards) { p.url = String(rest[r.upperBound...]); rest = String(rest[..<r.lowerBound]) }
                guard let q = rest.range(of: " — \"") , rest.hasSuffix("\"") else { return nil }
                p.title = String(rest[q.upperBound...].dropLast())
                let head = String(rest[..<q.lowerBound])          // App (kind)
                guard let o = head.range(of: " (", options: .backwards), head.hasSuffix(")") else { return nil }
                p.front = String(head[..<o.lowerBound]); p.kind = String(head[o.upperBound...].dropLast())
                seenFront = true
            }
            else if line.hasPrefix("CLASS: ") { p.cls = String(line.dropFirst(7)) }
            else if line.hasPrefix("DWELL: ") { p.dwell = String(line.dropFirst(7)) }
            else if line.hasPrefix("PREVIOUS: ") { p.previous = String(line.dropFirst(10)) }
            else if line.hasPrefix("USAGE: ") { p.usage = String(line.dropFirst(7)) }
        }
        return seenFront ? p : nil
    }

    /// An answer row's (answer, what): "back · what [· after follow-up | · after close | · scope s]".
    static func parse(answer detail: String) -> (String, String) {
        var parts = detail.components(separatedBy: " · ")
        let a = parts.isEmpty ? "" : parts.removeFirst()
        while let l = parts.last, l == "after follow-up" || l == "after close" || l.hasPrefix("scope ") { parts.removeLast() }
        return (a, parts.joined(separator: " · "))
    }

    /// Facts for one verdict, from the rows of its session (ascending; the verdict among them). `exact` when a facts row was found.
    static func facts(for v: Event, in rows: [Event], rules: Rules, level: Strictness? = nil) -> (Judge.Facts, exact: Bool) {
        let start = rows.last { $0.kind == "session.start" && $0.ts <= v.ts }
        let parts = start?.detail.components(separatedBy: " · ") ?? []
        let goal = parts.first ?? ""
        let strictness = level ?? parts.dropFirst(2).first.flatMap { Strictness(rawValue: $0) } ?? .normal
        let minutesIn = start.map { Int(v.ts.timeIntervalSince($0.ts) / 60) } ?? 0
        let what = Stats.what(ofVerdict: v.detail)
        // RECENT as the live prompt builds it: this session's answers before the verdict, newest first, ≤ 6
        let recent: [String] = rows.filter { $0.kind == "judge.answer" && $0.ts < v.ts && $0.ts >= (start?.ts ?? .distantPast) }.reversed().prefix(6).compactMap { e in
            let (a, w) = parse(answer: e.detail)
            switch a { case "work": return "\(w) → you said: work"; case "back", "ignored": return "\(w) → you said: distraction"; default: return nil }
        }
        let allowed = rules.pinnedNames + rules.allowedSites
        var f = Judge.Facts(goal: goal, minutesIn: minutesIn, strictness: strictness.rawValue, allowed: allowed, frontApp: v.app, frontKind: "app", title: "", url: nil,
                            screen: nil, behind: [], recent: recent, usage: nil, leniency: strictness.profile.judgeLine)
        if let fr = rows.last(where: { $0.kind == "judge.facts" && $0.app == v.app && $0.ts <= v.ts && v.ts.timeIntervalSince($0.ts) < 120 }), let p = parse(facts: fr.detail) {
            f.frontApp = p.front; f.frontKind = p.kind; f.title = p.title; f.url = p.url; f.usage = p.usage; f.appClass = p.cls; f.dwell = p.dwell; f.previous = p.previous
            return (f, true)
        }
        // before X0: the verdict's `what` is "App — title", "App", the page title, or "engine: query" (the judge saw "search: query")
        f.frontKind = Stats.browsers.contains(v.app) ? "web browser" : "app"
        var title = what.replacingOccurrences(of: " (private window)", with: "")
        if title.hasPrefix(v.app + " — ") { title = String(title.dropFirst(v.app.count + 3)) }
        else if title == v.app { title = "" }
        else if let c = title.range(of: ": "), Stats.engines.contains(String(title[..<c.lowerBound]).lowercased()) { title = "search: " + title[c.upperBound...] }
        f.title = title
        // the class from today's table (the bundle id is lost, the name is enough for the apps of the log); a page's host is lost with its url
        f.appClass = f.frontKind == "app" ? Classifier.classOf(app: "", name: v.app).rawValue : nil
        return (f, false)
    }

    /// Every verdict in the range with its rebuilt facts, the user's answer and any followed-through detour.
    static func items(from: Date, to: Date, rules: Rules, level: Strictness? = nil) -> [Item] {
        // the hour before, so a session that began earlier still has its start row
        let rows = EventLog.shared.events(from: from - 6 * 3600, to: to)
        var out: [Item] = []
        for (i, v) in rows.enumerated() where v.kind == "judge.verdict" && v.ts >= from {
            let (f, exact) = facts(for: v, in: Array(rows[...i]), rules: rules, level: level)
            let what = Stats.what(ofVerdict: v.detail)
            let later = rows[(i + 1)...].prefix { $0.ts.timeIntervalSince(v.ts) < 900 && $0.kind != "session.start" }
            let answer = later.first { $0.kind == "judge.answer" && parse(answer: $0.detail).1 == what }.map { parse(answer: $0.detail).0 }
            let through: Int? = later.compactMap { e -> Int? in
                guard e.kind == "judge.detour" else { return nil }
                let p = e.detail.components(separatedBy: " · "); guard p.count >= 3, p[1] == "followed through", p[2...].joined(separator: " · ") == what else { return nil }
                return Int(p[0])
            }.first ?? (later.contains { $0.kind == "judge.followup" && $0.detail == "followed through · \(what)" } ? 30 : nil)
            out.append(Item(verdict: v, facts: f, exact: exact, was: v.detail.hasPrefix("distracted"), what: what, answer: answer, followedThrough: through))
        }
        return out
    }

    /// The command: parses the arguments, prints, exits. Live replays need Ollama; `--dry` prints the rebuilt prompts only.
    static func run(_ args: [String]) {
        guard let i = args.firstIndex(of: "--replay") else { return }
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current
        var dates: [Date] = []; var model: String?; var level: Strictness?; var dry = false
        var k = i + 1
        while k < args.count {
            let a = args[k]
            if a == "--dry" { dry = true }
            else if a == "--model", k + 1 < args.count { model = args[k + 1]; k += 1 }
            else if a == "--level", k + 1 < args.count { level = Strictness(rawValue: args[k + 1]); k += 1 }
            else if let d = df.date(from: a) { dates.append(d) }
            else if a.hasPrefix("--") { break }
            k += 1
        }
        guard let first = dates.first else { print("usage: --replay <yyyy-mm-dd> [<yyyy-mm-dd>] [--model m] [--level normal] [--dry]"); exit(2) }
        let from = Calendar.current.startOfDay(for: first)
        let to = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: dates.count > 1 ? dates[1] : first))! - 1
        let items = items(from: from, to: to, rules: Rules.load(), level: level)
        let tf = DateFormatter(); tf.dateFormat = "MM-dd HH:mm"
        if dry {
            for it in items {
                print("── \(tf.string(from: it.date)) · \(it.facts.frontApp) · \(it.exact ? "exact" : "rebuilt") · was \(it.was ? "distracted" : "work") · user said \(it.answer ?? "—")" + (it.followedThrough.map { " · followed through \($0) s" } ?? ""))
                print(Judge.prompt(it.facts))
            }
            print("REPLAY --dry \(items.count) prompts rebuilt · \(items.filter(\.exact).count) exact · \(items.filter { $0.answer != nil }.count) with an answer · \(items.filter { $0.facts.appClass != nil }.count) with CLASS")
            exit(0)
        }
        let judge = Judge(); judge.persist = false; judge.budget = 60
        if let model { judge.model = model }
        Task { @MainActor in
            await judge.warm()
            var same = 0, unknown = 0, agreeUser = 0, withUser = 0, falseRemoved = 0, missesAdded = 0
            for it in items {
                guard let v = await judge.judge(it.facts) else { unknown += 1; print("\(tf.string(from: it.date)) · \(it.facts.frontApp) · \(it.what.prefix(50)) · was \(it.was ? "distracted" : "work") · now unknown"); continue }
                let now = v.distracted
                if now == it.was { same += 1 }
                if let a = it.answer, a == "work" || a == "back" || a == "ignored" { withUser += 1; if (a == "work") == !now { agreeUser += 1 } }
                let userSaysWork = it.answer == "work" || (it.followedThrough.map { $0 < 40 } ?? false)
                if it.was && !now && userSaysWork { falseRemoved += 1 }
                if !it.was && now { missesAdded += 1 }
                print("\(tf.string(from: it.date)) · \(it.facts.frontApp) · \(it.what.prefix(50)) · was \(it.was ? "distracted" : "work") · now \(now ? "distracted" : "work") \(Int(v.confidence * 100))% · user said \(it.answer ?? "—") · \(now == it.was ? "same" : "changed") · \(v.reason)")
            }
            print("REPLAY model=\(judge.model) verdicts=\(items.count) exact=\(items.filter(\.exact).count) agree-with-log=\(same)/\(items.count - unknown) agree-with-user=\(agreeUser)/\(withUser) false-alarms-removed=\(falseRemoved) misses-added=\(missesAdded) unknown=\(unknown) p50=\(String(format: "%.2f", judge.p50))s")
            exit(0)
        }
        RunLoop.main.run()
    }
}
