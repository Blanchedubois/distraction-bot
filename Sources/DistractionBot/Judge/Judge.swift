import AppKit
import Foundation

/// The judge (§3.5, §5a Q19): facts the app computed → qwen3:14b on localhost → distracted or not, with a reason.
/// Rules settle what they can first; the judge only warns, never closes.
@MainActor
@Observable
final class Judge {
    struct Facts {
        var goal: String
        var minutesIn: Int
        var strictness: String
        var allowed: [String]
        var frontApp: String
        var frontKind: String          // "app" or "web browser"
        var title: String
        var url: String?
        var screen: String?            // the vision description (B4)
        var behind: [String]
        var recent: [String]           // "youtube: keyboards → you said: distraction"
        var usage: String?             // "Music in front 14 min this session, switched to 7 times (budget 10 min / 6 switches)"
            var subject: String? = nil     // PLAN_OBJECTIVES_MODEL O3: "BIO 210 Cell Biology — <bio>" when the session is for an objective
        var kind: String? = nil        // O4 §3.9: "write-up — writing and editing a document; …" (sent when `sendKind`)
        var leniency: String? = nil    // O4 §3.10: the level's line for the judge, nil for normal
        // X0 (PLAN_CATCHER §3.6): the window's history — logged in `judge.facts` from X0, sent to the judge only when the X5 flags are on
        var dwell: String? = nil       // "in front 11 min this session · 3rd visit · last distraction 14 min ago"
        var appClass: String? = nil    // "utility" · "communication" · "entertainment" · "tool" · "unknown"
        var previous: String? = nil    // "Overleaf — project.tex · work · 2 min ago"
    }
    struct Verdict: Equatable { var distracted: Bool; var confidence: Double; var reason: String; var seconds: Double; var model: String }

    var model: String = UserDefaults.standard.string(forKey: "dbot.judgeModel") ?? Ollama.judgeModel { didSet { if persist { UserDefaults.standard.set(model, forKey: "dbot.judgeModel") } } }
    var persist = true
    /// O3: whether a session from an objective adds a SUBJECT line. Off until it measures ≥ 37/40 (§6 O3: 36 on one run).
    static let sendSubject = false
    /// O4: whether the KIND hint line is sent. Off until the fixture measures it no worse than the control (§6 O4).
    /// HUD4 (PLAN_SESSION_HUD §5a Q11): the current task on the GOAL line (`Homework #8 — now: problem 3`). Off until the fixture
    /// measures it no worse than the control (X5's ship rule: control ≥ 37/40); `DBOT_SEND_TASK=1` turns it on for that run.
    static let sendTask = ProcessInfo.processInfo.environment["DBOT_SEND_TASK"] == "1"
    static let sendKind = ProcessInfo.processInfo.environment["DBOT_SEND_KIND"] == "1"   // the fixture flips it on; off in the app until measured
    /// X5 (PLAN_CATCHER §3.6): the CLASS · DWELL · PREVIOUS lines and the utility sentence — off until the fixture measures them (control ≥ 37/40, the 10 new ≥ 9/10).
    /// `DBOT_SEND_CATCHER=1` flips all three on (the fixture run); `DBOT_SEND_CLASS/DWELL/PREVIOUS=1` one at a time.
    static let sendClass = ["DBOT_SEND_CATCHER", "DBOT_SEND_CLASS"].contains { ProcessInfo.processInfo.environment[$0] == "1" }
    static let sendDwell = ["DBOT_SEND_CATCHER", "DBOT_SEND_DWELL"].contains { ProcessInfo.processInfo.environment[$0] == "1" }
    static let sendPrevious = ["DBOT_SEND_CATCHER", "DBOT_SEND_PREVIOUS"].contains { ProcessInfo.processInfo.environment[$0] == "1" }
    var threshold = 0.7
    var budget: TimeInterval = 6
    var online = true
    var lastVerdict: Verdict?
    var lastFacts: Facts?
    var calls = 0
    var latencies: [Double] = []
    var p50: Double { pct(0.5) }
    var p95: Double { pct(0.95) }
    private func pct(_ q: Double) -> Double { let s = latencies.sorted(); guard !s.isEmpty else { return 0 }; return s[min(s.count - 1, Int(Double(s.count - 1) * q))] }
    let client = OllamaClient()
    private var inFlight = false

    static let system = """
    You judge whether a person at their Mac is distracted from their work right now. They told you their GOAL for this session.
    Judge only the item IN FRONT. BEHIND windows are context, never evidence. Anything named in ALLOWED is never a distraction.
    Educational or reference material related to the goal is work, even on YouTube or Reddit; entertainment, shopping, games and social feeds unrelated to the goal are distractions.
    Brief use of a utility (controlling music, a quick message, a settings pane) is not a distraction unless USAGE says it is long or frequent.
    \(sendClass || sendDwell ? "A utility or communication app used briefly on the way back to work is not a distraction; judge it by USAGE.\n" : "")RECENT lines are the person's own earlier answers; follow them for similar items.
    Answer with JSON only: {"distracted": true or false, "confidence": 0 to 1, "reason": "at most 12 words"}.
    """

    static func prompt(_ f: Facts) -> String {
        var lines = ["GOAL: \(f.goal.isEmpty ? "(none given)" : f.goal)",
                     "SESSION: \(f.minutesIn) min in, strictness \(f.strictness)",
                     "ALLOWED (never a distraction): \(f.allowed.joined(separator: ", "))",
                     frontLine(f)]
        if let sub = f.subject { lines.insert("SUBJECT: \(sub)", at: 1) }   // O3 §3.4: right under the goal
        if let k = f.kind, Self.sendKind { lines.insert("KIND: \(k)", at: 1) }   // O4 §3.9: what the kind of work implies
        if let l = f.leniency { lines.insert("LENIENCY: \(l)", at: lines.firstIndex { $0.hasPrefix("SESSION:") }.map { $0 + 1 } ?? 2) }   // O4 §3.10: the level's line
        if let c = f.appClass, Self.sendClass { lines.append("CLASS: \(c)") }        // X5 §3.6: after FRONT
        if let d = f.dwell, Self.sendDwell { lines.append("DWELL: \(d)") }
        if let s = f.screen { lines.append("SCREEN (vision): \"\(s)\"") }
        if !f.behind.isEmpty { lines.append("BEHIND: " + f.behind.joined(separator: " · ")) }
        if let p = f.previous, Self.sendPrevious { lines.append("PREVIOUS: \(p)") }   // X5: after BEHIND
        if let u = f.usage { lines.append("USAGE: " + u) }
        if !f.recent.isEmpty { lines.append("RECENT: " + f.recent.joined(separator: " · ")) }
        return lines.joined(separator: "\n")
    }

    /// X0: the `judge.facts` row — the FRONT line and the X5 lines (CLASS · DWELL · PREVIOUS · USAGE) joined by ` ¦ `; never SCREEN, never page text.
    static func frontLine(_ f: Facts) -> String { "FRONT: \(f.frontApp) (\(f.frontKind)) — \"\(f.title)\"" + (f.url.map { " — url: \($0)" } ?? "") }
    static func factsLine(_ f: Facts) -> String {
        var lines = [frontLine(f)]
        if let c = f.appClass { lines.append("CLASS: \(c)") }
        if let d = f.dwell { lines.append("DWELL: \(d)") }
        if let p = f.previous { lines.append("PREVIOUS: \(p)") }
        if let u = f.usage { lines.append("USAGE: \(u)") }
        return lines.joined(separator: " ¦ ")
    }

    /// nil = unknown (offline, over budget, or a reply that was not JSON). Never shown to the user.
    func judge(_ facts: Facts) async -> Verdict? {
        guard !inFlight else { return nil }
        inFlight = true; defer { inFlight = false }
        lastFacts = facts
        do {
            let (text, st) = try await client.chatJSON(model: model, messages: [.init(role: "system", content: Self.system), .init(role: "user", content: Self.prompt(facts))], budget: budget)
            guard let d = text.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { Log.write("judge: not json: \(text.prefix(120))"); return nil }
            let distracted = (j["distracted"] as? Bool) ?? ((j["distracted"] as? String)?.lowercased() == "true")
            let conf = (j["confidence"] as? Double) ?? Double((j["confidence"] as? String) ?? "") ?? 0.5
            let v = Verdict(distracted: distracted, confidence: conf, reason: (j["reason"] as? String ?? "").trimmingCharacters(in: .whitespaces), seconds: st.totalSeconds, model: model)
            online = true; calls += 1; latencies.append(st.totalSeconds); if latencies.count > 200 { latencies.removeFirst() }
            lastVerdict = v
            Log.write("judge \(String(format: "%.2f", st.totalSeconds)) s → \(distracted ? "DISTRACTED" : "work") \(conf) \"\(v.reason)\" | \(facts.frontApp) \"\(facts.title.prefix(60))\"")
            return v
        } catch OllamaClient.Failure.timeout { Log.write("judge: over budget (\(Int(budget)) s)"); return nil }
        catch { online = false; Log.write("judge: offline (\(error))"); return nil }
    }

    func warm() async { await client.warm(model: model) }

    // MARK: facts helpers

    /// Window titles behind the front app (Screen Recording gives titles); the private list's titles are withheld.
    static func behind(excluding frontPid: pid_t, privateApps: [String]) -> [String] {
        let wins = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var out: [String] = []; var seenOwners: Set<String> = []
        for w in wins where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let owner = w[kCGWindowOwnerName as String] as? String, (w[kCGWindowOwnerPID as String] as? pid_t) != frontPid, owner != "Distraction Bot" else { continue }
            let title = (w[kCGWindowName as String] as? String) ?? ""
            let key = owner + "|" + title
            guard !seenOwners.contains(key) else { continue }; seenOwners.insert(key)
            if privateApps.contains(owner) { out.append("\(owner) — ‹title withheld›") }
            else { out.append(title.isEmpty ? owner : "\(owner) — \(String(title.prefix(60)))") }
            if out.count >= 8 { break }
        }
        return out
    }
}
