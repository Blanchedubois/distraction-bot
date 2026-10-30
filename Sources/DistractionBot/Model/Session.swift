import Foundation

/// The focus dial (PLAN_OBJECTIVES_MODEL O4, §3.10): six levels, each a `FocusProfile` of weights. The name stays `Strictness` so every call site holds.
enum Strictness: String, Codable, CaseIterable, Identifiable {
    case laxed, gentle, normal, strict, hard, extreme
    var id: String { rawValue }
    /// strict's rules (10 s to answer, the ladder) apply to hard and extreme too
    var isStrict: Bool { self == .strict || self == .hard || self == .extreme }
    /// Hard mode (B6): no quitting, no pause, no early end except by the typed phrase; a guard agent relaunches the app. Extreme is hard plus close-on-verdict.
    var isHard: Bool { self == .hard || self == .extreme }

    var profile: FocusProfile {
        var p = base
        switch self {   // X1–X4: utility / communication budgets (min per 10), re-judge wait, switch nudge; awayAfter is 300 s on every level
        case .laxed:   p.utilityMinutes = 4;   p.communicationMinutes = 10; p.rejudgeMinutes = 20; p.switchNudge = 20
        case .gentle:  p.utilityMinutes = 3;   p.communicationMinutes = 7;  p.rejudgeMinutes = 15; p.switchNudge = 16
        case .normal:  p.utilityMinutes = 2;   p.communicationMinutes = 5;  p.rejudgeMinutes = 10; p.switchNudge = 12
        case .strict:  p.utilityMinutes = 1.5; p.communicationMinutes = 4;  p.rejudgeMinutes = 7;  p.switchNudge = 10
        case .hard:    p.utilityMinutes = 1.5; p.communicationMinutes = 4;  p.rejudgeMinutes = 7;  p.switchNudge = 10
        case .extreme: p.utilityMinutes = 1;   p.communicationMinutes = 2;  p.rejudgeMinutes = 5;  p.switchNudge = 8
        }
        return p
    }
    private var base: FocusProfile {
        switch self {
        case .laxed:   return FocusProfile(enforceBlockList: false, threshold: 0.9, dwell: 15, answerSeconds: nil, ignoredBlocks: false, followUp: false, ladder: false, closeOnVerdict: false, coolDown: 30,  usageMinutes: 20, usageSwitches: 10,
                                           judgeLine: "Be lenient: only a clear, sustained distraction counts; brief detours and anything plausibly related to the goal are work.")
        case .gentle:  return FocusProfile(enforceBlockList: false, threshold: 0.8, dwell: 10, answerSeconds: 30,  ignoredBlocks: false, followUp: true,  ladder: false, closeOnVerdict: false, coolDown: 30,  usageMinutes: 15, usageSwitches: 8,
                                           judgeLine: "Lean towards work when in doubt.")
        case .normal:  return FocusProfile(enforceBlockList: true,  threshold: 0.7, dwell: 5,  answerSeconds: 20,  ignoredBlocks: true,  followUp: true,  ladder: false, closeOnVerdict: false, coolDown: 30,  usageMinutes: 10, usageSwitches: 6,  judgeLine: nil)
        case .strict:  return FocusProfile(enforceBlockList: true,  threshold: 0.6, dwell: 5,  answerSeconds: 10,  ignoredBlocks: true,  followUp: true,  ladder: true,  closeOnVerdict: false, coolDown: 30,  usageMinutes: 8,  usageSwitches: 5,
                                           judgeLine: "Be strict: unrelated material is a distraction even if brief.")
        case .hard:    return FocusProfile(enforceBlockList: true,  threshold: 0.6, dwell: 5,  answerSeconds: 10,  ignoredBlocks: true,  followUp: true,  ladder: true,  closeOnVerdict: false, coolDown: 120, usageMinutes: 8,  usageSwitches: 5,
                                           judgeLine: "Be strict: unrelated material is a distraction even if brief.")
        case .extreme: return FocusProfile(enforceBlockList: true,  threshold: 0.5, dwell: 2,  answerSeconds: 5,   ignoredBlocks: true,  followUp: true,  ladder: true,  closeOnVerdict: true,  coolDown: 120, usageMinutes: 5,  usageSwitches: 3,
                                           judgeLine: "Be harsh: anything not clearly part of the goal is a distraction.")
        }
    }

    /// One line per level for the pickers (the objective editor, the overview).
    var blurb: String {
        switch self {
        case .laxed:   return "laxed: the judge warns only when sure (90 %) · no block list · the card just fades · no follow-up"
        case .gentle:  return "gentle: warns only, nothing closed · 30 s to answer · an ignored card just logs"
        case .normal:  return "normal: the block list enforced · the judge warns · 20 s to answer, ignoring blocks for the session"
        case .strict:  return "strict: 10 s to answer · three detours in 15 min → a 5-minute break card"
        case .hard:    return "hard: strict, plus no quit, no pause, no snooze; ends only by the escape phrase"
        case .extreme: return "extreme: hard, plus a confident verdict closes the app or blocks the site at once · 5 s to answer · 2 s dwell"
        }
    }
}

/// What a level does (§3.10's table): the constants the watchers, the card and the judge read instead of literals.
struct FocusProfile {
    var enforceBlockList: Bool        // the close/shield list acts (false: everything on it only warns)
    var threshold: Double             // judge confidence needed to warn (normal takes the Judge screen's override)
    var dwell: TimeInterval           // seconds an unruled app sits in front before it is judged
    var answerSeconds: TimeInterval?  // nil = the card never times out into a block (laxed: it fades at 30 s)
    var ignoredBlocks: Bool           // no answer → blocked for the session
    var followUp: Bool                // the 30-s "still here" check after Back to work
    var ladder: Bool                  // three detours in 15 min → the break card
    var closeOnVerdict: Bool          // a confident distracted app is closed (a site blocked) at once, the card after
    var coolDown: TimeInterval        // the shield's "5 more minutes" wait
    var usageMinutes: Int
    var usageSwitches: Int
    var judgeLine: String?            // what the judge is told, after SESSION
    // X1–X4 (PLAN_CATCHER §3.2–3.5): the budgets per class over a rolling 10 min, the re-judge wait, the switch nudge, the away threshold
    var utilityMinutes: Double = 2
    var communicationMinutes: Double = 5
    var rejudgeMinutes: Int = 10
    var switchNudge: Int = 12
    var awayAfter: TimeInterval = 300
}

/// A focus session (§3.2): the goal, when it ends, how strict. Saved so a relaunch resumes it.
struct Session: Codable, Equatable {
    var goal: String
    var started: Date
    var ends: Date?                 // nil: until I stop
    var strictness: Strictness
    var pausedUntil: Date?
    // PLAN_OBJECTIVES_MODEL O1: every session has an id; one started from an objective carries it (§3.3, §3.9)
    var id: String = UUID().uuidString
    var subjectId: String?
    var objectiveId: String?
    var kind: SessionKind?
    /// HUD3 (PLAN_SESSION_HUD §3.3): the pause is a break the user took — the block list holds, the judge rests, nothing is charged.
    /// False for an away auto-pause (X4), which keeps today's behaviour.
    var onBreak = false
    /// HUD4 (PLAN_SESSION_HUD §3.4): what the session set out to do, ticked off in the HUD's drawer.
    var tasks: [SessionTask] = []
    var dayScoreAtStart: Int?       // G3 (PLAN_GAME_LOOP §3.5): today's score when the session began, so the end card can say where the day landed

    init(goal: String, started: Date, ends: Date?, strictness: Strictness, pausedUntil: Date? = nil,
         id: String = UUID().uuidString, subjectId: String? = nil, objectiveId: String? = nil, kind: SessionKind? = nil) {
        self.goal = goal; self.started = started; self.ends = ends; self.strictness = strictness; self.pausedUntil = pausedUntil
        self.id = id; self.subjectId = subjectId; self.objectiveId = objectiveId; self.kind = kind
    }
    /// An older session.json has no id or objective: it keeps running with a fresh id and none.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        goal = try c.decode(String.self, forKey: .goal); started = try c.decode(Date.self, forKey: .started)
        ends = try c.decodeIfPresent(Date.self, forKey: .ends); strictness = try c.decode(Strictness.self, forKey: .strictness)
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        subjectId = try c.decodeIfPresent(String.self, forKey: .subjectId); objectiveId = try c.decodeIfPresent(String.self, forKey: .objectiveId)
        kind = try? c.decodeIfPresent(SessionKind.self, forKey: .kind)
        dayScoreAtStart = try? c.decodeIfPresent(Int.self, forKey: .dayScoreAtStart)   // G3
        onBreak = (try? c.decodeIfPresent(Bool.self, forKey: .onBreak)) ?? false   // HUD3
        tasks = (try? c.decodeIfPresent([SessionTask].self, forKey: .tasks)) ?? []   // HUD4
    }

    var remaining: TimeInterval? { ends.map { max(0, $0.timeIntervalSinceNow) } }
    var elapsed: TimeInterval { Date().timeIntervalSince(started) }
    var paused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    /// `DBOT_SESSION_PATH` points quiet checks and renders at a scratch file, so a live session.json is never read or replaced (PLAN_CURRENT_SESSION C0).
    static let url = ProcessInfo.processInfo.environment["DBOT_SESSION_PATH"].map { URL(fileURLWithPath: $0) } ?? Store.supportDir.appendingPathComponent("session.json")
    static func load() -> Session? {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(Session.self, from: d) else { return nil }
        if let e = s.ends, e < Date() { try? FileManager.default.removeItem(at: url); return nil }
        return s
    }
    func save() { try? JSONEncoder().encode(self).write(to: Session.url, options: .atomic) }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}

func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
func minutes(_ t: TimeInterval) -> String {
    let m = Int(t / 60), s = Int(t) % 60
    return m >= 60 ? "\(m / 60) h \(m % 60) min" : (m > 0 ? "\(m) min" : "\(s) s")
}
