import Foundation

/// HUD4 (PLAN_SESSION_HUD §3.4, §5a Q10): what a session sets out to do, ticked off as it goes. Pure, so `scripts/game-check.swift`
/// judges the same pay rule the HUD and the records use.
struct SessionTask: Codable, Equatable, Identifiable, Hashable {
    var id = UUID().uuidString
    var title: String
    var doneAt: Date? = nil
    var done: Bool { doneAt != nil }
    init(id: String = UUID().uuidString, title: String, doneAt: Date? = nil) { self.id = id; self.title = title; self.doneAt = doneAt }
}

enum SessionTasks {
    /// §5a Q10: +10 XP a tick, not multiplied by the combo or the dial, at most 5 paid per session, at least 3 min apart.
    static let xpEach = 10, maxPaid = 5, minGap = 180, maxTasks = 8

    /// Which ticks were paid, replayed from the session's rows in order (`task.done · <title>`, `task.undo · <title>`):
    /// a tick pays while fewer than 5 are paid and 3 min have passed since the last paid one; an untick takes its 10 back
    /// (from this session only — a level already reached is never taken). Returns the paid titles.
    static func paidTitles(rows: [Event], start: Date) -> Set<String> {
        var paid: [String: Int] = [:]
        var lastPaidAt: Int?
        for e in rows.sorted(by: { $0.ts < $1.ts }) where e.kind == "task.done" || e.kind == "task.undo" {
            let at = Int(e.ts.timeIntervalSince(start)), title = e.detail
            if e.kind == "task.done" {
                guard paid[title] == nil, paid.count < maxPaid, lastPaidAt.map({ at - $0 >= minGap }) ?? true else { continue }
                paid[title] = at; lastPaidAt = at
            } else { paid[title] = nil }
        }
        return Set(paid.keys)
    }
    static func paid(rows: [Event], start: Date) -> Int { paidTitles(rows: rows, start: start).count }

    /// The tasks left open, in order, to carry to the objective at End (§3.4).
    static func open(_ tasks: [SessionTask]) -> [String] { tasks.filter { !$0.done }.map(\.title) }
    /// The first unticked task: what the pill's title says the session is on now.
    static func current(_ tasks: [SessionTask]) -> String? { tasks.first { !$0.done }?.title }
    /// A title as typed: trimmed, one line, at most 80 characters; nil when empty.
    static func clean(_ title: String) -> String? {
        let t = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(80))
    }
}
