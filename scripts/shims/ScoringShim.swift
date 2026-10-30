// Stand-ins so `scripts/scoring-check.swift` compiles Model/Stats.swift, Model/XP.swift and Model/OverallFigures.swift without
// SwiftUI, SQLite-backed EventLog or the Store (PLAN_SCORING §3.7). Keep the shapes equal to Model/EventLog.swift's Event,
// Model/Session.swift's Strictness/Session/clock/minutes and Design/Theme.swift's ISO8601DateFormatter.ymd.
import Foundation

struct Event: Identifiable, Equatable {
    let id: Int64
    let ts: Date
    let kind: String
    let app: String
    let detail: String
    let latencyMs: Int?
    var sessionId: String? = nil
    var objectiveId: String? = nil
    var sessionKind: String? = nil
    init(id: Int64, ts: Date, kind: String, app: String, detail: String, latencyMs: Int?, sessionId: String? = nil, objectiveId: String? = nil, sessionKind: String? = nil) {
        self.id = id; self.ts = ts; self.kind = kind; self.app = app; self.detail = detail; self.latencyMs = latencyMs
        self.sessionId = sessionId; self.objectiveId = objectiveId; self.sessionKind = sessionKind
    }
}

enum Strictness: String, CaseIterable { case laxed, gentle, normal, strict, hard, extreme }

struct Session { var goal: String; var started: Date; var ends: Date?; var strictness: Strictness }

func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
func minutes(_ t: TimeInterval) -> String {
    let m = Int(t / 60), s = Int(t) % 60
    return m >= 60 ? "\(m / 60) h \(m % 60) min" : (m > 0 ? "\(m) min" : "\(s) s")
}

extension ISO8601DateFormatter {
    static let ymd: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; f.timeZone = .current; return f }()
}

/// Only what `Stats.checkRun` touches; the script never calls it.
@MainActor final class EventLog {
    static let shared = EventLog()
    func events(from: Date, to: Date) -> [Event] { [] }
}
