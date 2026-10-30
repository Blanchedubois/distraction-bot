import Foundation

/// The daily shutdown's record (PLAN_STUDY_DAY §3.3, K2; IMPACT_ANALYSIS R8): one `day.shutdown` row, app "", detail = this struct as
/// one line of JSON (ISO-8601 dates, so `Stats.shutdownDay` and the scoring check read it without this type), stamped with NO session
/// (it is filed after End), `ts` = when filed. `day` is the study day it closes — a 00:30 shutdown closes yesterday's study day.
/// A second shutdown on the same day replaces the first in every reader (latest wins, §5a Q1); the log keeps both.
struct Shutdown: Codable, Equatable {
    var day: Date                      // StudyDay.start
    var rating: Int?                   // 1–5
    var note: String = ""              // one line
    var objectives: [ObjectiveMark] = []   // every objective worked that day, plus planned-but-skipped ones
    var tomorrow: [PlannedItem] = []       // the plan for the next study day
    var startAt: Date?                 // tomorrow's intended first session
    struct ObjectiveMark: Codable, Equatable { var objectiveId: String; var mark: String; var note: String = "" }   // mark: stuck · moved · done · skipped
    struct PlannedItem: Codable, Equatable, Identifiable {
        var objectiveId: String?; var goal: String; var minutes: Int?
        var id: String { objectiveId ?? "goal:\(goal)" }
    }

    static let kind = "day.shutdown"
    static let marks = ["stuck", "moved", "done"]

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    var json: String { String(data: (try? Self.encoder.encode(self)) ?? Data(), encoding: .utf8) ?? "{}" }
    static func parse(_ detail: String) -> Shutdown? { detail.data(using: .utf8).flatMap { try? decoder.decode(Shutdown.self, from: $0) } }
    init(day: Date, rating: Int? = nil, note: String = "", objectives: [ObjectiveMark] = [], tomorrow: [PlannedItem] = [], startAt: Date? = nil) {
        self.day = day; self.rating = rating; self.note = note; self.objectives = objectives; self.tomorrow = tomorrow; self.startAt = startAt
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        day = try c.decode(Date.self, forKey: .day)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        objectives = try c.decodeIfPresent([ObjectiveMark].self, forKey: .objectives) ?? []
        tomorrow = try c.decodeIfPresent([PlannedItem].self, forKey: .tomorrow) ?? []
        startAt = try c.decodeIfPresent(Date.self, forKey: .startAt)
    }
    /// `★★★★☆`-style stars for the closing card and the History card.
    var stars: String { rating.map { String(repeating: "★", count: $0) + String(repeating: "☆", count: 5 - $0) } ?? "" }
}

/// The offer rule (§3.5), pure, so `scripts/shutdown-check.swift` judges the code the app runs.
enum ShutdownRule {
    /// The rule alone, pure, so a check can drive it with its own clock.
    static func offered(now: Date, session: Bool, offerHour: Int, startHour: Int, shutDown: Bool, lastEnded: Date?) -> Bool {
        guard !session, !shutDown else { return false }
        let h = Calendar.current.component(.hour, from: now)
        let pastOffer = h >= offerHour || h < startHour            // 01:00 is still inside the study day that began yesterday
        guard pastOffer else { return false }
        guard let last = lastEnded else { return true }
        let since = now.timeIntervalSince(last)
        return since >= 45 * 60 || since < 120
    }
}
