import Foundation

/// A session set up but not started — what the Current Session widget shows in its queued state
/// (PLAN_CURRENT_SESSION §3.4, C0; the click contract of PLAN_JUMP_BACK_IN §3.5, whose names this file keeps).
/// Set by callers (a Jump-back-in card, the Objectives panel, the Session card's own tiles, a one-off goal), read and
/// started by the widget, cleared by every start. Saved to `queued.json` so the app reopens on the queue it was closed on (§5a Q3).
struct QueuedSession: Equatable, Codable {
    var objective: Objective?     // nil = a one-off goal (`goal` holds the text); an objective's `goal` is its title
    var goal: String
    var minutes: Int?             // nil = until I stop; from objective.startMinutes(settings) unless the caller gave one
    var strictness: Strictness    // from objective.severity unless given
    let queuedAt: Date            // changes on every call, so onChange(of: store.queued) fires even for the same objective twice
    let source: String            // "jump-back-in" · "home-tile" · "objectives-panel" · "one-off" · "calendar" · "today" · "new-objective" · "up-next"
    /// PLAN_PLANNING §3.3 (P2): a one-off queued from a subject-only calendar match carries the subject, so the strip and the card can colour it.
    var subjectId: String? = nil
    var subject: String? { subjectId ?? objective?.subjectId }
    /// HUD4 (PLAN_SESSION_HUD §3.4): the tasks set before the start; a queued objective pre-fills its open ones.
    var tasks: [String] = []

    /// `DBOT_QUEUE_PATH` points checks at a scratch file so the real queue is never touched (as `DBOT_CATALOG_PATH` does for the catalogue).
    static let url = ProcessInfo.processInfo.environment["DBOT_QUEUE_PATH"].map { URL(fileURLWithPath: $0) } ?? Store.supportDir.appendingPathComponent("queued.json")

    /// The saved form: the objective by id, so a renamed or recoloured objective is read fresh from the catalogue on load.
    private struct Saved: Codable { var objectiveId: String?; var goal: String; var minutes: Int?; var strictness: Strictness; var queuedAt: Date; var source: String; var subjectId: String?; var tasks: [String]? }   // HUD4: tasks optional, so an older file loads

    func save() {
        let s = Saved(objectiveId: objective?.id, goal: goal, minutes: minutes, strictness: strictness, queuedAt: queuedAt, source: source, subjectId: subjectId, tasks: tasks.isEmpty ? nil : tasks)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(s).write(to: Self.url, options: .atomic)
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
    /// Nil when there is no file, or its objective no longer exists (archived or deleted) — the queue is then dropped with the file.
    static func load(catalog: Catalog) -> QueuedSession? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let s = try? d.decode(Saved.self, from: data) else { return nil }
        if let id = s.objectiveId {
            guard let o = catalog.objectives.first(where: { $0.id == id && !$0.archived }) else { clear(); return nil }
            return QueuedSession(objective: o, goal: o.title, minutes: s.minutes, strictness: s.strictness, queuedAt: s.queuedAt, source: s.source, tasks: s.tasks ?? [])
        }
        return QueuedSession(objective: nil, goal: s.goal, minutes: s.minutes, strictness: s.strictness, queuedAt: s.queuedAt, source: s.source,
                             subjectId: s.subjectId.flatMap { id in catalog.subjects.contains { $0.id == id } ? id : nil }, tasks: s.tasks ?? [])   // P2: a removed subject is forgotten
    }
}

extension Store {
    /// Queue a session under `objective` for the Current Session widget and show Home. Returns false (and does nothing) while a
    /// session is live (§5a Q6: no "next up"). `minutes` nil = the objective's remembered length (`startMinutes`); 0 = until I stop.
    @discardableResult
    func prepareSession(objective: Objective, minutes: Int? = nil, strictness: Strictness? = nil, source: String) -> Bool {
        guard session == nil else { return false }
        let m: Int? = minutes.map { $0 == 0 ? nil : $0 } ?? startMinutes(for: objective)   // P0 (Q4.9): the average real length when nothing is remembered
        queued = QueuedSession(objective: objective, goal: objective.title, minutes: m, strictness: strictness ?? objective.severity, queuedAt: Date(), source: source,
                               tasks: objective.openTasks)   // HUD4: the tasks left open last time come back with the objective
        Log.write("queued \(objective.title) from \(source)")
        if screen != .home || openSubject != nil || openObjective != nil { go(.home) }
        return true
    }
    /// The one-off goal path: the typed text is queued the same way, so the widget has one state for both.
    @discardableResult
    func prepareSession(goal: String, minutes: Int?, strictness: Strictness, source: String = "one-off", subjectId: String? = nil) -> Bool {
        guard session == nil else { return false }
        let g = goal.trimmingCharacters(in: .whitespaces)
        guard !g.isEmpty else { return false }
        queued = QueuedSession(objective: nil, goal: g, minutes: minutes, strictness: strictness, queuedAt: Date(), source: source, subjectId: subjectId)   // P2: subjectId for a calendar one-off
        return true
    }
    /// PLAN_PLANNING §3.3 (P2): queue a planned block — the objective with the event's length, or a one-off titled by the event under its subject (§5 Q3).
    @discardableResult
    func prepareSession(planned p: DayModel.Planned) -> Bool {
        if let oid = p.objectiveId, let o = objective(oid) { return prepareSession(objective: o, minutes: max(5, p.minutes), source: "calendar") }
        return prepareSession(goal: p.title, minutes: max(5, p.minutes), strictness: settings.defaultStrictness, source: "calendar", subjectId: p.subjectId)
    }
    /// The widget's ✕ or Escape, or a second click on the queued card.
    func clearQueued() { queued = nil }
    /// The widget's Start, Return and ⇧⌘S: starts what is queued; `startSession` itself drops the queue.
    func startQueued() {
        guard let q = queued else { return }
        if let o = q.objective { startSession(objective: o, minutes: q.minutes, strictness: q.strictness) }
        else { startSession(goal: q.goal, minutes: q.minutes, strictness: q.strictness) }
    }
    /// The live session's own score (PLAN_CURRENT_SESSION §3.5): `SessionRecord.score`, time against the planned length.
    var liveSessionScore: Score? { session == nil ? nil : statsToday?.sessions.last { $0.live }?.score }
}
