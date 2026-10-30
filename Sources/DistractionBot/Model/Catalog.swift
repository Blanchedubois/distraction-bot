import Foundation
import SwiftUI

/// Subjects and objectives (PLAN_OBJECTIVES_MODEL §3.1): what you study and what you are working on under it.
/// One file, `subjects.json`, saved like the rules. The types are nested because `Store` already has an
/// `enum Subject { app, site }` for warnings; `Catalog.Subject` keeps the two apart.
struct Catalog: Codable {
    struct Subject: Codable, Identifiable, Hashable {
        let id: String
        var name: String            // "BIO 210 - Cell Biology" → code "BIO 210", shortName "Cell Biology"
        var bio: String
        var icon: String            // an SF Symbol name; an emoji is accepted too (§5a Q1, drawn in U4)
        var accent: String          // family name or "#rrggbb"
        var sort: Int
        var createdAt: Date
        /// PLAN_PLANNING §3.1 (P0, R9): the week's yardstick for the ring and the card; nil = no target.
        var weeklyTargetMinutes: Int?

        /// Transcriber's split on " - "; ": " is accepted too so "BIO 210: Cell Biology" works (§3.1).
        private var parts: [String] {
            for sep in [" - ", ": "] where name.contains(sep) {
                let p = name.components(separatedBy: sep)
                if p.count > 1 { return [p[0]] + [p.dropFirst().joined(separator: sep)] }
            }
            return [name]
        }
        init(id: String = UUID().uuidString, name: String, bio: String = "", icon: String = "book", accent: String = "sage", sort: Int = 0, createdAt: Date = Date(), weeklyTargetMinutes: Int? = nil) {
            self.id = id; self.name = name; self.bio = bio; self.icon = icon; self.accent = accent; self.sort = sort; self.createdAt = createdAt; self.weeklyTargetMinutes = weeklyTargetMinutes
        }
        /// Missing keys keep their defaults (a later phase may add fields).
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
            bio = try c.decodeIfPresent(String.self, forKey: .bio) ?? ""
            icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "book"
            accent = try c.decodeIfPresent(String.self, forKey: .accent) ?? "sage"
            sort = try c.decodeIfPresent(Int.self, forKey: .sort) ?? 0
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            weeklyTargetMinutes = try c.decodeIfPresent(Int.self, forKey: .weeklyTargetMinutes)   // P0
        }
        var code: String? { parts.count > 1 ? parts[0] : nil }
        var shortName: String { parts.count > 1 ? parts[1] : name }
    }

    struct Objective: Codable, Identifiable, Hashable {
        let id: String
        var subjectId: String
        var title: String
        var bio: String             // what it entails — the judge reads it (§3.4)
        var icon: String
        var sort: Int
        var createdAt: Date
        /// PLAN_OBJECTIVE_LIFECYCLE §3.1: nil = open; set = completed on that day. Reversible by clearing it. Replaces `archived` (§5a Q1).
        var completedAt: Date?
        var lastMinutes: Int?       // length the objective was last started with (§5a Q7)
        var severity: Strictness    // the focus dial (§3.10); behaviour arrives in O4
        var kind: SessionKind       // the sub-category (§3.9)
        /// PLAN_PLANNING §3.1 (P0, R9): a deadline — a day, stored at 23:59 local of that day (§5 Q1) — and the effort budget in minutes (§5 Q2: hours in halves).
        var due: Date?
        var estimateMinutes: Int?
        /// HUD4 (PLAN_SESSION_HUD §3.4): tasks left unticked at a session's end, offered again with the objective's next queue.
        var openTasks: [String] = []

        var isDone: Bool { completedAt != nil }
        /// The old name, kept so every reader still compiles: "hidden" now means "completed". Setting it completes or reopens.
        var archived: Bool { get { completedAt != nil } set { completedAt = newValue ? (completedAt ?? Date()) : nil } }

        init(id: String = UUID().uuidString, subjectId: String, title: String, bio: String = "", icon: String, sort: Int = 0, createdAt: Date = Date(),
             completedAt: Date? = nil, lastMinutes: Int? = nil, severity: Strictness = .normal, kind: SessionKind = .other, due: Date? = nil, estimateMinutes: Int? = nil) {
            self.id = id; self.subjectId = subjectId; self.title = title; self.bio = bio; self.icon = icon; self.sort = sort; self.createdAt = createdAt
            self.completedAt = completedAt; self.lastMinutes = lastMinutes; self.severity = severity; self.kind = kind; self.due = due; self.estimateMinutes = estimateMinutes
        }
        enum CodingKeys: String, CodingKey { case id, subjectId, title, bio, icon, sort, createdAt, completedAt, archived, lastMinutes, severity, kind, due, estimateMinutes, openTasks }
        /// Missing keys keep their defaults, so a file from O0 survives later fields. An old `archived: true` with no date loads as completed now (§5a Q1).
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id); subjectId = try c.decode(String.self, forKey: .subjectId)
            title = try c.decode(String.self, forKey: .title)
            bio = try c.decodeIfPresent(String.self, forKey: .bio) ?? ""
            icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "target"
            sort = try c.decodeIfPresent(Int.self, forKey: .sort) ?? 0
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            let wasArchived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
            completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt) ?? (wasArchived ? Date() : nil)
            lastMinutes = try c.decodeIfPresent(Int.self, forKey: .lastMinutes)
            severity = (try? c.decodeIfPresent(Strictness.self, forKey: .severity)) ?? .normal
            kind = (try? c.decodeIfPresent(SessionKind.self, forKey: .kind)) ?? .other
            due = try c.decodeIfPresent(Date.self, forKey: .due)                        // P0
            estimateMinutes = try c.decodeIfPresent(Int.self, forKey: .estimateMinutes)
            openTasks = (try? c.decodeIfPresent([String].self, forKey: .openTasks)) ?? []   // HUD4
        }
        func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id); try c.encode(subjectId, forKey: .subjectId); try c.encode(title, forKey: .title); try c.encode(bio, forKey: .bio)
            try c.encode(icon, forKey: .icon); try c.encode(sort, forKey: .sort); try c.encode(createdAt, forKey: .createdAt)
            try c.encodeIfPresent(completedAt, forKey: .completedAt); try c.encodeIfPresent(lastMinutes, forKey: .lastMinutes)
            try c.encode(severity, forKey: .severity); try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(due, forKey: .due); try c.encodeIfPresent(estimateMinutes, forKey: .estimateMinutes)   // P0
            if !openTasks.isEmpty { try c.encode(openTasks, forKey: .openTasks) }   // HUD4: written only when there are some
        }
    }

    var subjects: [Subject] = []
    var objectives: [Objective] = []

    /// `DBOT_CATALOG_PATH` points renders and checks at a scratch copy so the real catalogue is never touched (a lesson: it was deleted once).
    static let url = ProcessInfo.processInfo.environment["DBOT_CATALOG_PATH"].map { URL(fileURLWithPath: $0) } ?? Store.supportDir.appendingPathComponent("subjects.json")
    static func load() -> Catalog {
        if let d = try? Data(contentsOf: url), let c = try? decoder.decode(Catalog.self, from: d) { return c }
        if ProcessInfo.processInfo.environment["DBOT_SEED_CATALOG"] != nil { let c = seed; c.save(); return c }
        return Catalog()
    }
    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601
        try? e.encode(self).write(to: Self.url, options: .atomic)
    }
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    /// Two subjects and three objectives for renders and checks (O0). Written only when the file is missing and DBOT_SEED_CATALOG is set.
    static var seed: Catalog {
        let phys = Subject(id: "seed-phys320", name: "BIO 210 - Bio physics", bio: "Physics of living matter: random walks, diffusion, membranes, molecular motors. The semester project is a simulation plus a LaTeX write-up.", icon: "atom", accent: "sage", sort: 0, createdAt: Date())
        let arts = Subject(id: "seed-arts201", name: "ARTS 201 - Drawing II", bio: "Studio drawing: figure, perspective, weekly problem sets reviewed in class.", icon: "pencil.and.outline", accent: "peach", sort: 1, createdAt: Date())
        return Catalog(subjects: [phys, arts], objectives: [
            Objective(id: "seed-proposal", subjectId: phys.id, title: "research proposal draft", bio: "A two-page proposal for the BIO 210 project: motivation, method, timeline, in LaTeX on Overleaf.", icon: "doc.text", sort: 0, kind: .writeUp),
            Objective(id: "seed-sim", subjectId: phys.id, title: "random-walk simulation", bio: "Python simulation of a 2-D random walk and the MSD plot; results go into part A.", icon: "function", sort: 1, kind: .coding),
            Objective(id: "seed-pset", subjectId: arts.id, title: "problem set 3", bio: "Perspective exercises 1–6 for Thursday's review.", icon: "pencil.and.outline", sort: 0, kind: .problemSet),
        ])
    }

    /// `--catalog`: the file as a table.
    var table: String {
        var out = ["subjects \(subjects.count) · objectives \(objectives.count) · \(Self.url.path)"]
        for s in subjects.sorted(by: { $0.sort < $1.sort }) {
            out.append("\(s.code ?? "—")\t\(s.shortName)\t\(s.icon)\t\(s.accent)\t\(s.bio.prefix(60))")
            for o in objectives.filter({ $0.subjectId == s.id }).sorted(by: { $0.sort < $1.sort }) {
                out.append("    \(o.title)\t\(o.kind.rawValue)\t\(o.severity.rawValue)\t\(o.icon)\(o.completedAt.map { "\t✓ \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "")\t\(o.bio.prefix(60))")
            }
        }
        return out.joined(separator: "\n")
    }
}

typealias Objective = Catalog.Objective

/// The session's sub-category (§3.9). A fixed list so Stats can group on it; `other` catches the rest.
enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case writeUp = "write-up", homework, reading, review, problemSet = "problem set", research, coding, presentation, revision, other
    var id: String { rawValue }
    /// The one-line KIND hint for the judge (§3.9): what the kind implies counts as work.
    var hint: String {
        switch self {
        case .writeUp: return "writing and editing a document; editors, LaTeX, reference lookups and citation sites are work"
        case .homework: return "working through set exercises; the course page, a calculator, documentation and worked examples are work"
        case .reading: return "reading assigned material; PDFs, the library, dictionaries and note-taking are work"
        case .review: return "revising for a test; notes, flashcards, past papers and short explainer videos on the topic are work"
        case .problemSet: return "solving a problem set; notes, a calculator, documentation and a scratch file are work"
        case .research: return "finding and reading sources; search engines, journals, Zotero and skimming many tabs are work"
        case .coding: return "programming; the editor, terminal, docs, Stack Overflow, GitHub and package sites are work"
        case .presentation: return "building slides or a talk; slide tools, image search for figures and rehearsal notes are work"
        case .revision: return "reworking an existing draft; the editor, feedback files and reference lookups are work"
        case .other: return "general study on the goal"
        }
    }
}

// MARK: - Store surface (§3.2)

extension Store {
    /// Start a focus session from an objective (§3.3): the goal the judge reads is "<title> — <bio>" (§3.4, measured in O3),
    /// the session carries the ids, and the objective remembers the length and severity for next time (§5a Q7).
    func startSession(objective o: Objective, minutes: Int?, strictness: Strictness? = nil, kind: SessionKind? = nil) {
        let goal = o.title   // O3 (§6): the title only — the composed "title — bio" scored 33/40 vs 37; the bio stays on screen via sessionObjective
        let sev = strictness ?? o.severity
        if let i = catalog.objectives.firstIndex(where: { $0.id == o.id }) { catalog.objectives[i].lastMinutes = minutes ?? 0; catalog.objectives[i].severity = sev }
        startSession(goal: goal, minutes: minutes, strictness: sev, objective: o, kind: kind ?? o.kind)
    }
    /// Sessions with no objective (free-text goals and every session from before O1), newest first — the Unsorted inbox (U3).
    var unsortedSessions: [ObjectiveSession] { EventLog.shared.sessions().filter { $0.objectiveId == nil } }

    /// A guess for an unsorted session (O2 §3.7): the objective sharing the most words (4+ letters) with the goal, counting its title,
    /// bio and subject name; the subject's code (e.g. "BIO 210") in the goal counts double. Needs a score of 2 or none is offered.
    func suggestObjective(for goal: String) -> Objective? {
        func words(_ s: String) -> Set<String> { Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 }) }
        let g = words(goal); let gl = goal.lowercased()
        var best: (Objective, Int)? = nil
        for o in catalog.objectives where !o.archived {
            let subj = subject(o.subjectId)
            var score = g.intersection(words(o.title + " " + o.bio + " " + (subj?.name ?? ""))).count
            if let code = subj?.code, gl.contains(code.lowercased()) { score += 2 }
            if score >= 2, score > (best?.1 ?? 0) { best = (o, score) }
        }
        return best?.0
    }

    /// File a past session under an objective (or nil to unfile) and refresh what reads the log.
    func fileSession(_ id: String, under objective: String?) { EventLog.shared.fileSession(id, under: objective); reloadLog() }

    /// The judge's SUBJECT line (O3 §3.4): code, name and the first 200 characters of the bio, for a session started from an objective.
    var subjectLine: String? {
        guard Judge.sendSubject, let sid = session?.subjectId, let s = subject(sid) else { return nil }   // off: 36/40 on one run (§6 O3)
        let bio = s.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        return [s.code, s.shortName].compactMap { $0 }.joined(separator: " ") + (bio.isEmpty ? "" : " — " + String(bio.prefix(200)))
    }

    /// The objective the live session is for, if any.
    var sessionObjective: Objective? { objective(session?.objectiveId) }

    /// Open a subject's page or an objective's pane from anywhere: sets the screen and the open item together, so the
    /// sidebar's own clearing (which runs only through its selection binding) cannot undo it.
    func open(subject id: String) { if openSubject != id || openObjective != nil { EventLog.shared.ui("open", "subject") }; screen = .subjects; openObjective = nil; openSubject = id; openShutdown = nil }   // K0: ui.open, no ids · K2: closes the shutdown screen
    func open(objective id: String) { if openObjective != id { EventLog.shared.ui("open", "objective") }; screen = .subjects; openObjective = id; openShutdown = nil }

    func subject(_ id: String?) -> Catalog.Subject? { catalog.subjects.first { $0.id == id } }
    func objective(_ id: String?) -> Objective? { catalog.objectives.first { $0.id == id } }
    var subjects: [Catalog.Subject] { catalog.subjects.sorted { $0.sort < $1.sort } }
    func objectives(in subject: String, includeArchived: Bool = false) -> [Objective] {
        catalog.objectives.filter { $0.subjectId == subject && (includeArchived || !$0.archived) }.sorted { $0.sort < $1.sort }
    }
    /// An objective wears its subject's colour (Transcriber's rule).
    func accent(of o: Objective) -> Color { Theme.accent(subject(o.subjectId)?.accent) }

    @discardableResult
    func saveSubject(id: String?, name: String, bio: String, icon: String, accent: String, weeklyTargetMinutes: Int?? = nil) -> Catalog.Subject {
        if let id, let i = catalog.subjects.firstIndex(where: { $0.id == id }) {
            catalog.subjects[i].name = name; catalog.subjects[i].bio = bio; catalog.subjects[i].icon = icon; catalog.subjects[i].accent = accent
            if let t = weeklyTargetMinutes { catalog.subjects[i].weeklyTargetMinutes = t }   // P0: nil = untouched, .some(nil) = cleared
            return catalog.subjects[i]
        }
        let s = Catalog.Subject(id: UUID().uuidString, name: name, bio: bio, icon: icon, accent: accent, sort: (catalog.subjects.map(\.sort).max() ?? -1) + 1, createdAt: Date(),
                                weeklyTargetMinutes: weeklyTargetMinutes ?? nil)
        catalog.subjects.append(s)
        return s
    }
    /// Its objectives go too (§5a Q8); the log keeps their ids.
    func deleteSubject(_ id: String) {
        catalog.objectives.removeAll { $0.subjectId == id }
        catalog.subjects.removeAll { $0.id == id }
    }
    @discardableResult
    func saveObjective(id: String?, subject: String, title: String, bio: String, icon: String, kind: SessionKind? = nil, severity: Strictness? = nil,
                       due: Date?? = nil, estimateMinutes: Int?? = nil) -> Objective {
        if let id, let i = catalog.objectives.firstIndex(where: { $0.id == id }) {
            catalog.objectives[i].subjectId = subject; catalog.objectives[i].title = title; catalog.objectives[i].bio = bio; catalog.objectives[i].icon = icon
            if let kind { catalog.objectives[i].kind = kind }
            if let severity { catalog.objectives[i].severity = severity }
            if let d = due { catalog.objectives[i].due = d.map { Planning.dueDate(forDay: $0) } }          // P0: nil = untouched, .some(nil) = cleared
            if let e = estimateMinutes { catalog.objectives[i].estimateMinutes = e }
            return catalog.objectives[i]
        }
        let o = Objective(subjectId: subject, title: title, bio: bio, icon: icon, sort: (objectives(in: subject, includeArchived: true).map(\.sort).max() ?? -1) + 1,
                          severity: severity ?? settings.defaultStrictness, kind: kind ?? .other, due: (due ?? nil).map { Planning.dueDate(forDay: $0) }, estimateMinutes: estimateMinutes ?? nil)
        catalog.objectives.append(o)
        return o
    }
    func archiveObjective(_ id: String, _ on: Bool) { if on { complete(id) } else { reopen(id) } }   // the old name (PLAN_OBJECTIVE_LIFECYCLE §5a Q1)

    // MARK: Lifecycle (PLAN_OBJECTIVE_LIFECYCLE §3.1–3.4)

    /// Complete an objective: the date is set, a queued session on it is dropped (§5a Q3), the toast offers undo (§5a Q8).
    /// During a session on it, the completion waits for the session's end (§5a Q2).
    func complete(_ id: String) {
        guard let i = catalog.objectives.firstIndex(where: { $0.id == id }), catalog.objectives[i].completedAt == nil else { return }
        let o = catalog.objectives[i]
        if session?.objectiveId == id { completeOnEnd = id; show("completes when this session ends"); return }
        catalog.objectives[i].completedAt = Date()
        if queued?.objective?.id == id { queued = nil; show("queue cleared — \(o.title) is complete") }
        else { show("completed · \(o.title)", undo: { [weak self] in self?.reopen(id) }) }
        EventLog.shared.add("objective.complete", detail: "\(o.title) · \(id)")
        reloadLog()
    }
    func reopen(_ id: String) {
        guard let i = catalog.objectives.firstIndex(where: { $0.id == id }) else { return }
        if completeOnEnd == id { completeOnEnd = nil; show("stays open"); return }
        guard catalog.objectives[i].completedAt != nil else { return }
        catalog.objectives[i].completedAt = nil
        show("reopened · \(catalog.objectives[i].title)")
        EventLog.shared.add("objective.reopen", detail: "\(catalog.objectives[i].title) · \(id)")
        reloadLog()
    }
    /// What a delete costs, for the confirmation (§3.4): the sessions that stay in the log and go back to the inbox.
    func deleteCost(_ id: String) -> (sessions: Int, seconds: Int) {
        let ss = EventLog.shared.sessions(objective: id)
        return (ss.count, ss.reduce(0) { $0 + $1.seconds })
    }
    /// Delete the record; its sessions are unfiled, not deleted, so they return to the Unsorted inbox with their goal text (§5a Q6).
    func deleteObjective(_ id: String) {
        let title = objective(id)?.title ?? id
        for s in EventLog.shared.sessions(objective: id) { EventLog.shared.fileSession(s.id, under: nil) }
        catalog.objectives.removeAll { $0.id == id }
        if queued?.objective?.id == id { queued = nil }
        if completeOnEnd == id { completeOnEnd = nil }
        if openObjective == id { openObjective = nil }
        EventLog.shared.add("objective.delete", detail: "\(title) · \(id)")
        reloadLog()
    }
    func reorderSubjects(_ ids: [String]) { for (n, id) in ids.enumerated() { if let i = catalog.subjects.firstIndex(where: { $0.id == id }) { catalog.subjects[i].sort = n } } }
    func reorderObjectives(_ ids: [String]) { for (n, id) in ids.enumerated() { if let i = catalog.objectives.firstIndex(where: { $0.id == id }) { catalog.objectives[i].sort = n } } }
}
