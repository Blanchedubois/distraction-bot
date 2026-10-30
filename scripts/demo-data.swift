// PLAN_PUBLIC_RELEASE P1: an invented student's five weeks, for the README's renders. Four courses, their objectives, and a log of sessions,
// catches, shutdowns and freezes — deterministic (one seed) and written relative to today, so the streak and "this week" always look current.
//   swiftc -o /tmp/demo-data scripts/demo-data.swift && /tmp/demo-data <out-dir>
//   → <out-dir>/catalog.json, <out-dir>/log.sqlite (replaced). Render with DBOT_CATALOG_PATH / DBOT_LOG_PATH on them and
//     DBOT_SNAPSHOT_ICS=docs/demo/calendar.ics and DBOT_NAME=Sam. Never point it at ~/Library/Application Support/Distraction Bot.
// Prints each course's XP and level as the app's rule computes them (XP.swift), so the bands can be checked without a render.
import Foundation
import SQLite3

guard CommandLine.arguments.count > 1 else { print("usage: demo-data <out-dir>"); exit(2) }
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
guard !out.path.contains("Application Support/Distraction Bot") else { print("refusing to write into the app's data folder"); exit(2) }
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var seed: UInt64 = 0xD15C0
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
func pick<T>(_ a: [T]) -> T { a[Int(rnd() * Double(a.count)) % a.count] }
var uuidN: UInt64 = 0
func uuid(_ tag: String) -> String { uuidN += 1; return String(format: "DE300000-0000-4000-8000-%012llX", uuidN) }

let cal = Calendar.current
let now = Date()
/// The app's study day starts at 4 am (Model/StudyDay.swift).
func studyDay(_ d: Date) -> Date { let s = cal.startOfDay(for: d.addingTimeInterval(-4 * 3600)); return s.addingTimeInterval(4 * 3600) }
let today = studyDay(now)
func day(_ back: Int) -> Date { cal.date(byAdding: .day, value: -back, to: today)! }
let iso = ISO8601DateFormatter()
let ymd: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; f.timeZone = .current; return f }()

// MARK: - the catalogue

struct Obj { let id: String; let title: String; let bio: String; let icon: String; let kind: String; let severity: String; var done: Int? = nil; var due: Int? = nil; var estimate: Int? = nil }
struct Course { let id: String; let name: String; let bio: String; let icon: String; let accent: String; let weight: Double; var objectives: [Obj] }

var courses: [Course] = [
    Course(id: uuid("cs"), name: "CS 150 - Data Structures", bio: "Lists, trees, heaps, hash maps and graphs, in Python. Weekly labs and a term project.", icon: "curlybraces", accent: "sky", weight: 0.51, objectives: [
        Obj(id: uuid(""), title: "Hash map lab", bio: "Open addressing vs chaining; benchmark both at three load factors.", icon: "number", kind: "coding", severity: "strict", done: 9),
        Obj(id: uuid(""), title: "Problem set 5 — heaps", bio: "Heapify proofs, a d-ary heap, and the k-smallest question.", icon: "list.number", kind: "problem set", severity: "strict", due: 3, estimate: 180),
        Obj(id: uuid(""), title: "Graph search project", bio: "BFS, DFS and Dijkstra on the campus map; a short write-up of the runtimes.", icon: "point.3.connected.trianglepath.dotted", kind: "coding", severity: "hard", due: 12, estimate: 600),
        Obj(id: uuid(""), title: "Midterm review", bio: "Past papers 2023–2025, the big-O table, the tree rotations.", icon: "checklist", kind: "review", severity: "normal", due: 6),
    ]),
    Course(id: uuid("math"), name: "MATH 221 - Linear Algebra", bio: "Vector spaces, linear maps, eigenvalues, orthogonality. Problem sets every Friday.", icon: "function", accent: "lilac", weight: 0.28, objectives: [
        Obj(id: uuid(""), title: "Problem set 7", bio: "Change of basis and similarity; questions 1–9.", icon: "pencil.and.list.clipboard", kind: "homework", severity: "strict", done: 2),
        Obj(id: uuid(""), title: "Eigenvalues notes", bio: "Rewrite lecture 15–17 notes into one page with worked examples.", icon: "note.text", kind: "review", severity: "normal"),
        Obj(id: uuid(""), title: "Quiz 4 prep", bio: "Diagonalisation drills from the textbook, §5.3.", icon: "bolt", kind: "revision", severity: "normal", due: 2, estimate: 90),
    ]),
    Course(id: uuid("bio"), name: "BIO 210 - Cell Biology", bio: "Membranes, organelles, signalling and the cell cycle. A lab every Wednesday.", icon: "leaf", accent: "sage", weight: 0.15, objectives: [
        Obj(id: uuid(""), title: "Lab report 3 — osmosis", bio: "Potato-core osmosis data, the graph, and the discussion section.", icon: "flask", kind: "write-up", severity: "normal", due: 5, estimate: 240),
        Obj(id: uuid(""), title: "Chapter 9 reading", bio: "Cell signalling, with the end-of-chapter questions.", icon: "book", kind: "reading", severity: "laxed", done: 6),
        Obj(id: uuid(""), title: "Membrane transport flashcards", bio: "Channels, carriers, pumps; 40 cards.", icon: "rectangle.stack", kind: "revision", severity: "gentle"),
    ]),
    Course(id: uuid("hist"), name: "HIST 140 - Modern Europe", bio: "Europe from 1789 to 1914: revolutions, nations and industry. One essay per half-term.", icon: "building.columns", accent: "peach", weight: 0.06, objectives: [
        Obj(id: uuid(""), title: "Essay: the revolutions of 1848", bio: "2 000 words on why 1848 failed; outline, draft, sources.", icon: "doc.text", kind: "write-up", severity: "normal", due: 9, estimate: 480),
        Obj(id: uuid(""), title: "Week 8 reading", bio: "Hobsbawm, The Age of Capital, ch. 1–2.", icon: "book", kind: "reading", severity: "laxed"),
    ]),
]

func catalogJSON() -> Data {
    var subjects: [[String: Any]] = [], objectives: [[String: Any]] = []
    let created = iso.string(from: day(40))
    for (i, c) in courses.enumerated() {
        subjects.append(["id": c.id, "name": c.name, "bio": c.bio, "icon": c.icon, "accent": c.accent, "sort": i, "createdAt": created])
        for (j, o) in c.objectives.enumerated() {
            var d: [String: Any] = ["id": o.id, "subjectId": c.id, "title": o.title, "bio": o.bio, "icon": o.icon, "sort": j, "createdAt": created,
                                    "severity": o.severity, "kind": o.kind, "lastMinutes": 0]
            if let b = o.done { d["completedAt"] = iso.string(from: day(b).addingTimeInterval(19 * 3600)) }
            if let b = o.due { d["due"] = iso.string(from: day(-b).addingTimeInterval(19 * 3600)) }
            if let e = o.estimate { d["estimateMinutes"] = e }
            objectives.append(d)
        }
    }
    return try! JSONSerialization.data(withJSONObject: ["subjects": subjects, "objectives": objectives], options: [.prettyPrinted, .sortedKeys])
}

// MARK: - the log

struct Row { let ts: Date; let kind: String; var app = ""; var detail = ""; var ms: Int? = nil; var session: String? = nil; var objective: String? = nil; var tag: String? = nil }
var rows: [Row] = []
let XPcap = 2
let multiplier: [String: Double] = ["laxed": 0.8, "gentle": 0.9, "normal": 1.0, "strict": 1.1, "hard": 1.2, "extreme": 1.25]
var courseXP = Array(repeating: 0, count: courses.count)
var longest = Array(repeating: 0, count: courses.count)

let sites = ["youtube.com", "reddit.com", "x.com", "news.ycombinator.com", "twitch.tv"]
let searches = ["youtube: lofi beats", "google: standing desk", "google: concert tickets", "youtube: speedrun world record"]
let workTitles = ["Code — heap.py", "Preview — lecture15.pdf", "Notes — eigenvalues", "Pages — lab report 3", "Safari — Khan Academy"]

/// One session: start, a few catches drawn from `drift` (0 calm … 1 drifting), the summary, the xp row, the end — as Store.endSession writes them.
func session(course ci: Int, at start: Date, minutes planned: Int, drift: Double, finishedShare: Double = 0.75) {
    let c = courses[ci]
    let open = c.objectives.filter { o in o.done.map { b in start < day(b) } ?? true }
    let o = open.isEmpty ? c.objectives[0] : pick(open)
    let sid = uuid("s")
    func add(_ ts: Date, _ kind: String, app: String = "", _ detail: String, ms: Int? = nil) {
        rows.append(Row(ts: ts, kind: kind, app: app, detail: detail, ms: ms, session: sid, objective: o.id, tag: o.kind))
    }
    let finished = rnd() < finishedShare
    let seconds = finished ? planned * 60 : Int(Double(planned * 60) * (0.55 + rnd() * 0.35))
    let end = start.addingTimeInterval(TimeInterval(seconds))
    add(start, "session.start", "\(o.title) · \(planned) min · \(o.severity) · \(o.kind)")
    var detour = 0, k = start.addingTimeInterval(240)
    while true {
        k = k.addingTimeInterval(TimeInterval(420 + rnd() * 1200))
        guard k < end.addingTimeInterval(-120) else { break }
        let r = rnd()
        if r < 0.25 + 0.45 * drift {
            let s = pick(sites)
            add(k, "web.visit", app: "Safari", "\(s) → judge · no rule")
            add(k + 2, "judge.verdict", app: "Safari", "distracted 0.90 · unrelated to the goal · \(s)", ms: 1300 + Int(rnd() * 700))
            add(k + 8, "judge.answer", "back · \(s)")
            let secs = 60 + Int(rnd() * 300)
            let kept = rnd() < 0.75   // a quarter of the time the tab is still there at the follow-up
            add(k + 38, "judge.followup", kept ? "followed through · \(s) · at 30 s" : "still in front · \(s) · blocked for the session")
            add(k + 38, "judge.detour", "\(secs) · \(kept ? "followed through" : "blocked") · \(s)"); detour += secs
            add(k + 38 + Double(secs), "judge.verdict", app: "Code", "work 0.92 · on task · \(pick(workTitles))", ms: 1400)   // back: the period ends here
        } else if r < 0.33 + 0.45 * drift {
            let q = pick(searches)
            add(k, "web.search", app: "Safari", "\(q) → judge · no rule")
            add(k + 2, "judge.verdict", app: "Safari", "distracted 0.90 · searching unrelated to the goal · \(q)", ms: 1500)
            add(k + 7, "judge.answer", "back · \(q)")
            add(k + 40, "judge.verdict", app: "Code", "work 0.92 · on task · \(pick(workTitles))", ms: 1400)
        } else if r < 0.36 + 0.2 * drift {
            add(k, "block.close", app: "Steam", "forced · attempt 1 · react 0 ms", ms: 4200)
        } else {
            add(k, "judge.verdict", app: "Code", "work 0.92 · on task · \(pick(workTitles))", ms: 1400)
        }
    }
    let worst = 2 + Int(drift * 14 + rnd() * 4)
    add(end - 3, "switches", "\(worst + Int(rnd() * 20)) · max10 \(worst)")
    add(end - 2, "session.summary", "paused 0 · detour \(detour) · \(finished ? "finished" : "ended")")
    let clean = max(0, (seconds - detour) / 60)
    let xp = Int((Double(clean) * (multiplier[o.severity] ?? 1)).rounded()) + (finished ? 30 : 0)
    add(end - 1, "xp", "\(xp) · ×\(multiplier[o.severity] ?? 1) · \(finished ? "finished" : "ended")")
    add(end, "session.end", "\(seconds)")
    courseXP[ci] += xp; longest[ci] = max(longest[ci], seconds)
}

/// Smooth weighted round-robin: the courses' shares of the sessions come out exact, so the levels land where the README says (4 · 3 · 2 · 1).
var credit = Array(repeating: 0.0, count: courses.count)
func courseIndex() -> Int {
    for i in courses.indices { credit[i] += courses[i].weight }
    let i = credit.indices.max { credit[$0] < credit[$1] }!
    credit[i] -= 1
    return i
}

// Days 34…9 back: most weekdays, about half the weekends. Day 9 is missed (the streak before it ends there); days 8…0 all have sessions
// except day 4, which a freeze bridges — a 9-day streak with one freeze. Today's CS 150 session is the course's longest (a personal best).
var shutdownDays: [Int] = []
for back in stride(from: 34, through: 1, by: -1) {
    let d = day(back)
    let weekend = [1, 7].contains(cal.component(.weekday, from: d))
    if back == 9 || back == 4 { continue }
    if back > 9 && rnd() < (weekend ? 0.5 : 0.12) { continue }
    var t = d.addingTimeInterval(TimeInterval(5 * 3600 + Int(rnd() * 3 * 3600)))   // 9 am … noon
    let n = weekend ? 1 + (rnd() < 0.5 ? 1 : 0) : 3 + (rnd() < 0.3 ? 1 : 0)
    let drift = max(0.05, min(0.9, 0.6 - Double(34 - back) * 0.008 + (rnd() - 0.5) * 0.6))   // calmer over the weeks, never spotless
    for _ in 0..<n {
        let m = pick([25, 50, 50, 50, 75, 90])
        session(course: courseIndex(), at: t, minutes: m, drift: drift)
        t = t.addingTimeInterval(TimeInterval(m * 60 + 1800 + Int(rnd() * 5400)))
    }
    if rnd() < 0.8 { shutdownDays.append(back) }
}
// Today: a calm, strict morning on MATH 221, then the long CS 150 session that ends 20 minutes ago.
let bestMinutes = 130
let bestStart = now.addingTimeInterval(TimeInterval(-(bestMinutes + 20) * 60))
session(course: 1, at: bestStart.addingTimeInterval(-TimeInterval(50 + 60) * 60), minutes: 50, drift: 0.2, finishedShare: 1)
session(course: 0, at: bestStart, minutes: bestMinutes, drift: 0.35, finishedShare: 1)

for back in shutdownDays {
    let d = day(back)
    let json = "{\"day\":\"\(iso.string(from: d))\",\"note\":\"\",\"objectives\":[],\"rating\":\(3 + Int(rnd() * 3)),\"startAt\":\"\(iso.string(from: day(back - 1).addingTimeInterval(5 * 3600)))\",\"tomorrow\":[]}"
    rows.append(Row(ts: day(back - 1).addingTimeInterval(-3.5 * 3600), kind: "day.shutdown", detail: json))   // 00:30 after the day
}
// Freezes: one per five shutdown days, then the one that bridged day 4.
let earned = min(XPcap + 1, shutdownDays.count / 5)   // one is spent, so at most the cap (2) stays in hand, as the app keeps it
for n in 0..<earned { rows.append(Row(ts: day(shutdownDays.sorted(by: >)[min(shutdownDays.count - 1, 5 * (n + 1) - 1)] - 1), kind: "streak.freeze", detail: "earned · 5 shutdowns · \(n + 1)")) }
rows.append(Row(ts: day(3).addingTimeInterval(60), kind: "streak.freeze", detail: "used · \(ymd.string(from: day(4)))"))
// Objectives completed: the app writes `objective.complete · <title> · <id>`.
for c in courses { for o in c.objectives { if let b = o.done { rows.append(Row(ts: day(b).addingTimeInterval(19 * 3600), kind: "objective.complete", detail: "\(o.title) · \(o.id)")) } } }

rows.sort { $0.ts < $1.ts }

// MARK: - write

let logURL = out.appendingPathComponent("log.sqlite")
try? FileManager.default.removeItem(at: logURL)
var db: OpaquePointer?
guard sqlite3_open(logURL.path, &db) == SQLITE_OK else { print("cannot open \(logURL.path)"); exit(1) }
sqlite3_exec(db, """
CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, kind TEXT NOT NULL, app TEXT NOT NULL DEFAULT '', detail TEXT NOT NULL DEFAULT '', latency_ms INTEGER, session_id TEXT, objective_id TEXT, kind_tag TEXT);
CREATE INDEX events_ts ON events(ts); CREATE INDEX events_session ON events(session_id); BEGIN;
""", nil, nil, nil)
var st: OpaquePointer?
sqlite3_prepare_v2(db, "INSERT INTO events (ts, kind, app, detail, latency_ms, session_id, objective_id, kind_tag) VALUES (?,?,?,?,?,?,?,?)", -1, &st, nil)
let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
func bind(_ i: Int32, _ s: String?) { if let s { sqlite3_bind_text(st, i, s, -1, T) } else { sqlite3_bind_null(st, i) } }
for r in rows {
    sqlite3_bind_double(st, 1, r.ts.timeIntervalSince1970); bind(2, r.kind); bind(3, r.app); bind(4, r.detail)
    if let m = r.ms { sqlite3_bind_int(st, 5, Int32(m)) } else { sqlite3_bind_null(st, 5) }
    bind(6, r.session); bind(7, r.objective); bind(8, r.tag)
    sqlite3_step(st); sqlite3_reset(st)
}
sqlite3_finalize(st); sqlite3_exec(db, "COMMIT", nil, nil, nil); sqlite3_close(db)
try! catalogJSON().write(to: out.appendingPathComponent("catalog.json"))

// MARK: - report

let bands = [300, 1080, 2520, 5400, 10800]   // XP.bands
func level(_ xp: Int) -> Int { bands.lastIndex { xp >= $0 }.map { $0 + 1 } ?? 0 }
print("demo · \(rows.count) rows · \(rows.filter { $0.kind == "session.start" }.count) sessions · \(shutdownDays.count) shutdowns · \(earned) freezes earned, 1 used → \(out.path)")
for (i, c) in courses.enumerated() {
    let xp = courseXP[i] + 60 * c.objectives.filter { $0.done != nil }.count
    print("  \(c.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(xp) XP · L\(level(xp)) · longest \(longest[i] / 60) min")
}
