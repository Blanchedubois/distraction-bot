import SwiftUI

// PLAN_OBJECTIVE_OVERVIEW V0: one objective's page, laid out like Transcriber's `ItemView` — the accent backdrop, the identity
// header (subject line · icon picker · title · bio · meta · pill menus · start button), then one scrolling column: the figures
// and the three sections (study log V1, productivity timeline V2, distractions V3).

/// What the log says about one objective: its sessions and their sums (§3.1 figures).
struct ObjectiveLog {
    var sessions: [ObjectiveSession] = []
    var seconds: Int { sessions.reduce(0) { $0 + $1.seconds } }
    var warnings: Int { sessions.reduce(0) { $0 + $1.warnings } }
    var blocks: Int { sessions.reduce(0) { $0 + $1.blocks } }
    var last: Date? { sessions.map(\.started).max() }
    /// Focused minutes per day over the last 14 days, oldest first — the spark under *Focused*.
    var spark: [Double] {
        var out = Array(repeating: 0.0, count: 14)
        for s in sessions {
            let d = StudyDay.daysAgo(s.started)   // K1: study days ago
            if d >= 0, d < 14 { out[13 - d] += Double(s.seconds) / 60 }
        }
        return out
    }
    @MainActor static func load(_ objectiveId: String) -> ObjectiveLog {
        let all = EventLog.shared.sessions(objective: objectiveId)
        // R2 (PLAN_REWORK §3.3, D14): the test rule Progress applies, behind the same setting (a render shows them with DBOT_SNAPSHOT_TESTS)
        let hide = (Store.current?.settings.hideTestSessions ?? true) && ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_TESTS"] == nil
        return ObjectiveLog(sessions: hide ? all.filter { !$0.isTest } : all)
    }
}

struct ObjectiveView: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    @Environment(\.colorScheme) private var scheme
    let objectiveId: String
    @State private var editing = false
    @State private var confirmDelete = false
    @State private var title = ""
    @State private var bio = ""
    // the next session's settings (§5a Q7): start from the objective's remembered ones, change them here without touching the editor
    @State private var kind: SessionKind = .other
    @State private var strictness: Strictness = .normal
    @State private var length = "50"
    @State private var primed = false
    // the study log (V1): the kind filter the figures follow (§5a Q8), the expanded session, its event filter, show-all
    @State private var kindFilter = "all"
    @State private var expanded: String? = nil
    @State private var eventFilter = "all"
    @State private var showAllSessions = false
    @State private var showAllDistractions = false

    var body: some View {
        GeometryReader { g in
            let narrow = g.size.width < Breakpoint.narrow
            if let o = store.objective(objectiveId) {
                let accent = store.accent(of: o)
                let _ = store.events.count   // V4 (§3.5): reading `events` subscribes the pane to `reloadLog()`, which the Store runs on every logged event
                let full = ObjectiveLog.load(o.id)
                let log = kindFilter == "all" ? full : ObjectiveLog(sessions: full.sessions.filter { ($0.kind ?? "—") == kindFilter })
                let (top, mid) = Tint.page(dark: scheme == .dark)
                ZStack(alignment: .bottomTrailing) {
                    LinearGradient(stops: [.init(color: accent.opacity(top), location: 0), .init(color: accent.opacity(mid), location: 0.4), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                    Watermark(symbol: o.icon, size: min(g.size.width, g.size.height) * 0.42, color: accent, opacity: Tint.pageWatermark(dark: scheme == .dark))
                        .offset(x: g.size.width * 0.05, y: g.size.height * 0.06)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .clipped()
                    VStack(spacing: 0) {
                        header(o, log: log, accent: accent, narrow: narrow)
                        Divider().overlay(Theme.line)
                        PageScroll {
                            VStack(alignment: .leading, spacing: Space.section) {
                                figures(o, log: log)
                                section(1, "Study log", note: "every session on this objective · click one for its minute-by-minute record") {
                                    if full.sessions.isEmpty { empty(o) } else { studyLog(o, full: full, log: log, accent: accent) }
                                }
                                section(2, "Productivity timeline", note: "the last 14 days · one strip per day you worked on it") {
                                    if log.sessions.isEmpty { empty(o) } else { timeline(o, log: log, accent: accent) }
                                }
                                section(3, "Distractions", note: "what pulled you away, how often, what you answered") {
                                    if log.sessions.isEmpty { empty(o) } else { distractions(o, log: log, accent: accent) }
                                }
                            }
                            .frame(maxWidth: 1040, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Space.pageH(narrow: narrow)).padding(.top, Space.sheet).padding(.bottom, Space.pageBottom)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .environment(\.narrow, narrow)
                .frame(width: g.size.width, height: g.size.height)
                .toolbar { toolbar(o) }
                .deleteObjectiveConfirm(o, isPresented: Binding(get: { confirmDelete || store.pendingDelete == o.id }, set: { v in confirmDelete = v; if !v { store.pendingDelete = nil } }))
                .onAppear { prime(o) }
                .onChange(of: o.id) { _, _ in primed = false; prime(o) }
            } else {
                EmptyState(symbol: "target", text: "This objective no longer exists.")
            }
        }
    }

    private func prime(_ o: Objective) {
        guard !primed else { return }
        if snapshot, ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_EXPAND"] != nil { expanded = EventLog.shared.sessions(objective: o.id).last?.id }   // the newest row, open
        kind = o.kind; strictness = o.severity
        length = store.startMinutes(for: o).map(String.init) ?? "open"   // P0 (Q4.9): the average real length when nothing is remembered
        primed = true
    }

    // MARK: toolbar (window): ⋯ — edit, archive, move, delete (§3.1)
    @ToolbarContentBuilder
    private func toolbar(_ o: Objective) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button(editing ? "Done editing" : "Edit title and bio") { toggleEdit(o) }
                Button(o.isDone ? "Reopen" : "Complete") { store.archiveObjective(o.id, !o.isDone) }
                Menu("Move to") {
                    ForEach(store.subjects.filter { $0.id != o.subjectId }) { s in
                        Button(s.code ?? s.shortName) { store.saveObjective(id: o.id, subject: s.id, title: o.title, bio: o.bio, icon: o.icon); store.show("moved to \(s.code ?? s.shortName)") }
                    }
                }
                Divider()
                Button("Delete objective…", role: .destructive) { confirmDelete = true }
            } label: { Label("More", systemImage: "ellipsis.circle") }
                .help("More actions")
        }
    }

    private func toggleEdit(_ o: Objective) {
        if editing {
            editing = false
            let t = title.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { store.fail("an objective needs a title"); return }
            store.saveObjective(id: o.id, subject: o.subjectId, title: t, bio: bio, icon: o.icon); store.show("objective saved")
        } else { title = o.title; bio = o.bio; editing = true }
    }

    // MARK: header (Transcriber's `ItemView.header`, §2.1)
    private func header(_ o: Objective, log: ObjectiveLog, accent: Color, narrow: Bool) -> some View {
        let live = store.session?.objectiveId == o.id
        return VStack(alignment: .leading, spacing: Space.card) {
            if let s = store.subject(o.subjectId) {
                Button { store.openObjective = nil; store.openSubject = s.id } label: {
                    HStack(spacing: Space.stack) {
                        Icon(s.icon, .small, color: accent)
                        MonoLabel(s.code ?? s.shortName, color: accent)
                    }
                }.buttonStyle(.plain).help("Open \(s.shortName)")
            } else { MonoLabel("no subject", color: Theme.warn) }
            HStack(alignment: .top, spacing: Space.card) {
                IconPicker(icon: o.icon, accent: accent, size: narrow ? 48 : 64) { ic in store.saveObjective(id: o.id, subject: o.subjectId, title: o.title, bio: o.bio, icon: ic) }
                VStack(alignment: .leading, spacing: Space.stack) {
                    if editing && !snapshot {
                        TextField("Title", text: $title).textFieldStyle(.roundedBorder).font(Type.headline)
                        TextField("Bio", text: $bio, axis: .vertical).textFieldStyle(.roundedBorder).font(Type.body).lineLimit(2...5)
                        HStack(spacing: Space.stack) { PillButton(text: "save", kind: .on, accent: accent) { toggleEdit(o) }; PillButton(text: "cancel") { editing = false } }
                    } else {
                        Text(o.title).font(Type.page).foregroundStyle(Theme.ink).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        if !o.bio.isEmpty { BioText(text: o.bio, accent: accent).frame(maxWidth: 760, alignment: .leading) }
                    }
                    MonoLabel(meta(log))
                    HStack(alignment: .top, spacing: Space.card) {
                        WrapRow {
                            if let s = store.subject(o.subjectId) {
                                IconChoice(symbol: s.icon, tint: accent, options: store.subjects.map { ($0.id, $0.code ?? $0.shortName) },
                                           selection: Binding<String>(get: { o.subjectId }, set: { v in store.saveObjective(id: o.id, subject: v, title: o.title, bio: o.bio, icon: o.icon) }), title: "Subject")
                            }
                            if o.isDone {   // done: the date in place of the next-session menus (PLAN_OBJECTIVE_LIFECYCLE §3.3)
                                if let c = o.completedLabel { Pill(c, kind: .ok) }
                            } else {
                                IconChoice(symbol: "tag", options: SessionKind.allCases.map { ($0, $0.rawValue) }, selection: $kind, title: "Kind of work for the next session")
                                IconChoice(symbol: "shield.lefthalf.filled", options: Strictness.allCases.map { ($0, $0.rawValue) }, selection: $strictness, title: "Focus for the next session")
                                IconChoice(symbol: "timer", options: [("25", "25 min"), ("50", "50 min"), ("90", "90 min"), ("open", "until I stop")], selection: $length, title: "Length of the next session")
                                // PLAN_PLANNING §3.1 (P0) · R5 (PLAN_REWORK §3.6): the deadline and the budget behind one `plan ▾` pill — `due Fri 31 Oct · ~4 h` when set
                                DuePill(objective: o, accent: accent)
                                if let e = store.effortLabel(of: o) { MonoLabel(e).frame(height: PillMenu<String>.height) }
                            }
                            CompletePill(objective: o, accent: accent)
                        }
                        Spacer(minLength: 0)
                        if o.isDone {
                            Icon("checkmark.circle.fill", .card, color: Theme.ok)
                        } else if live, let s = store.session {
                            VStack(alignment: .trailing, spacing: Space.tight) {
                                // V4: the figure ticks on its own clock, like Home's live card; nothing else re-renders for it
                                TimelineView(.periodic(from: .now, by: 1)) { _ in
                                    HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                                        Text(s.remaining.map { minutes($0) } ?? minutes(s.elapsed)).font(Type.figureSmall).foregroundStyle(accent).monospacedDigit()
                                        MonoLabel(s.remaining == nil ? "elapsed" : "left")
                                    }
                                }
                                ActionButton(title: s.strictness.isHard ? "End session…" : "End session", symbol: "stop.fill") { store.requestEnd() }
                            }
                        } else if store.session == nil {
                            ActionButton(title: "Start focus session", symbol: "play.fill", accent: true) {
                                store.startSession(objective: o, minutes: Int(length), strictness: strictness, kind: kind)
                            }
                        } else {
                            Pill("another session is running", kind: .warn, dot: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Space.pageH(narrow: narrow)).padding(.top, Space.sheet).padding(.bottom, Space.card)
    }

    private func meta(_ log: ObjectiveLog) -> String {
        let n = log.sessions.count
        guard n > 0 else { return "no sessions yet" }
        return "\(n) session\(n == 1 ? "" : "s") · \(minutes(TimeInterval(log.seconds))) focused" + (log.last.map { " · last \(relativeDate($0))" } ?? "")
    }

    // MARK: figures (§3.1)
    private func figures(_ o: Objective, log: ObjectiveLog) -> some View {
        let n = log.sessions.count
        let none = n == 0
        return KpiGrid {
            KpiTile(label: "Focused", value: none ? "—" : minutes(TimeInterval(log.seconds)), sub: none ? "no sessions yet" : "across \(n) session\(n == 1 ? "" : "s")", symbol: "clock", spark: none ? nil : log.spark)
            KpiTile(label: "Sessions", value: none ? "—" : "\(n)", sub: log.last.map { "last \(relativeDate($0))" } ?? "start one above", symbol: "calendar")
            KpiTile(label: "Distractions caught", value: none ? "—" : "\(log.warnings)", sub: "warnings over all sessions", symbol: "exclamationmark.bubble")
            KpiTile(label: "Blocked", value: none ? "—" : "\(log.blocks)", sub: "apps closed or shielded · sites blocked", symbol: "xmark.shield")
        }
    }

    // MARK: study log (§3.2): kind filter pills · one row per session, newest first · a row expands to its events
    private func studyLog(_ o: Objective, full: ObjectiveLog, log: ObjectiveLog, accent: Color) -> some View {
        let kinds = Array(Set(full.sessions.map { $0.kind ?? "—" })).sorted()
        let rows = log.sessions.sorted { $0.started > $1.started }
        let shown = showAllSessions ? rows : Array(rows.prefix(10))
        return VStack(alignment: .leading, spacing: Space.stack) {
            if kinds.count > 1 {
                WrapRow {
                    PillButton(text: "all", kind: kindFilter == "all" ? .on : .neutral, accent: accent) { kindFilter = "all" }
                    ForEach(kinds, id: \.self) { k in PillButton(text: k, kind: kindFilter == k ? .on : .neutral, accent: accent) { kindFilter = k } }
                    MonoLabel("the figures above follow the filter", color: Theme.muted2)
                }
            }
            VStack(spacing: Space.hair) {
                if rows.isEmpty { EmptyState(symbol: "tag", text: "No \(kindFilter) sessions on this objective.") }
                ForEach(Array(shown.enumerated()), id: \.element.id) { n, r in
                    if n > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, Space.loose) }
                    sessionRow(r, accent: accent, firstOfDay: shown.firstIndex { StudyDay.day(for: $0.started) == StudyDay.day(for: r.started) } == n)
                    if expanded == r.id { sessionEvents(r, accent: accent) }
                }
                if rows.count > 10 {
                    HStack { Spacer(); PillButton(text: showAllSessions ? "show fewer" : "show all \(rows.count)") { showAllSessions.toggle() }; Spacer() }.padding(.top, Space.stack)
                }
            }
            .padding(Space.stack)
            .card(watermark: "list.bullet.rectangle")
        }
    }

    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f }()

    /// `Sun 26 Oct · 19:52–20:44   52 min   write-up   normal   3 warnings · 1 block   finished`
    private func sessionRow(_ r: ObjectiveSession, accent: Color, firstOfDay: Bool = true) -> some View {
        let open = expanded == r.id
        let counts = [r.warnings > 0 ? "\(r.warnings) warning\(r.warnings == 1 ? "" : "s")" : nil, r.blocks > 0 ? "\(r.blocks) block\(r.blocks == 1 ? "" : "s")" : nil].compactMap { $0 }
        return HStack(spacing: Space.loose) {
            Icon(open ? "chevron.down" : "chevron.right", .small, color: Theme.muted2).frame(width: 10)
            Text("\(Self.dayFormat.string(from: r.started)) · \(clock(r.started))–\(r.ended.map { clock($0) } ?? "…")").font(Type.data).foregroundStyle(Theme.muted2).lineLimit(1).frame(width: 215, alignment: .leading)
            Text(minutes(TimeInterval(r.seconds))).font(Type.strong).foregroundStyle(Theme.ink).frame(width: 72, alignment: .leading)
            Pill(r.kind ?? "—")
            Pill(r.strictness, kind: severityKind(r.strictness))
            MonoLabel(counts.isEmpty ? "clean" : counts.joined(separator: " · "), color: counts.isEmpty ? Theme.ok : Theme.muted).lineLimit(1)
            Spacer()
            // K4 (PLAN_STUDY_DAY §3.7): the shutdown's mark for that study day (stuck · moved · done), when one was filed.
            // R2 (PLAN_REWORK §3.3, D12): once per day, on the day's first row, neutral — `done` in ok; warn and danger are for detours and blocks.
            if firstOfDay, let oid = r.objectiveId, let m = store.shutdown(for: StudyDay.day(for: r.started))?.objectives.first(where: { $0.objectiveId == oid }), !m.mark.isEmpty {
                Pill("day · \(m.mark)", kind: m.mark == "done" ? .ok : .neutral).help(m.note.isEmpty ? "the day's shutdown" : m.note)
            }
            endingPill(r.endedBy, accent: accent)
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { expanded = open ? nil : r.id } }
    }

    /// The session's events in the Log's row, with the Log's filters local to the expansion.
    private func sessionEvents(_ r: ObjectiveSession, accent: Color) -> some View {
        let events = EventLog.shared.events(session: r.id).filter { EventFilter.matches($0, eventFilter) }
        return VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.tight) {
                ForEach(EventFilter.options.prefix(5), id: \.0) { f in PillButton(text: f.1, kind: eventFilter == f.0 ? .on : .neutral, accent: accent) { eventFilter = f.0 } }
                Spacer()
                MonoLabel("\(events.count) event\(events.count == 1 ? "" : "s")", color: Theme.muted2)
            }
            .padding(.horizontal, Space.loose).padding(.top, Space.hair).padding(.bottom, Space.tight)
            if events.isEmpty { MonoLabel("nothing of that kind in this session").padding(.horizontal, Space.loose).padding(.bottom, Space.tight) }
            ForEach(events) { e in EventRow(event: e) }
        }
        .padding(.leading, Space.sheet).padding(.bottom, Space.stack)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper2).padding(.horizontal, Space.tight))
    }

    // MARK: productivity timeline (§3.3, §5a Q2/Q6): the Today card's strip, one per day with a session, gaps collapsed
    private static let shortDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()

    private func timeline(_ o: Objective, log: ObjectiveLog, accent: Color) -> some View {
        let cal = Calendar.current, today = StudyDay.start(of: Date())   // K1: the strips are study days
        let from = cal.date(byAdding: .day, value: -13, to: today)!
        // this objective's events over the range (stamped by O1/O2), split by day
        let events = EventLog.shared.events(objective: o.id, from: from, to: Date())   // not events(from:to:), which reads only the base columns
        let byDay = Dictionary(grouping: log.sessions.filter { $0.started >= from }) { StudyDay.start(of: $0.started) }
        let days = (0..<14).map { cal.date(byAdding: .day, value: -$0, to: today)! }   // newest first
        let live = store.session.flatMap { $0.objectiveId == o.id ? DayModel.Live(started: $0.started) : nil }
        // rows: a strip for a day with sessions, one line for a run of days without — leading and trailing runs dropped
        var rows: [(day: Date, gap: Date?)] = []
        var gapStart: Date? = nil
        for d in days {
            if byDay[d] != nil {
                if let g = gapStart, !rows.isEmpty { rows.append((day: g, gap: d)) }   // a gap after at least one strip
                rows.append((day: d, gap: nil)); gapStart = nil
            } else if gapStart == nil { gapStart = d }
        }
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { n, row in
                if n > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                if let until = row.gap {
                    // row.day is the newest day of the run, `until` the strip below it: the run is the day after `until` … row.day
                    let first = cal.date(byAdding: .day, value: 1, to: until)!
                    MonoLabel(first == row.day ? "no sessions \(Self.shortDay.string(from: first))" : "no sessions \(Self.shortDay.string(from: first))–\(Self.shortDay.string(from: row.day))", color: Theme.muted2)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Space.card).padding(.vertical, Space.stack)
                } else {
                    let d = row.day, isToday = d == today
                    let sessions = byDay[d] ?? []
                    let dayEvents = events.filter { StudyDay.start(of: $0.ts) == d }
                    let model = DayModel.build(events: dayEvents, live: isToday ? live : nil, day: d, now: isToday ? Date() : nil, threshold: store.judge.threshold)
                    VStack(alignment: .leading, spacing: Space.tight) {
                        HStack(alignment: .firstTextBaseline) {
                            MonoLabel(isToday ? "Today · \(Self.dayFormat.string(from: d))" : Self.dayFormat.string(from: d), color: Theme.ink)
                            Spacer()
                            MonoLabel(dayFigures(sessions))
                        }
                        TodayTimeline(model: model, now: isToday ? Date() : nil, accent: accent, controls: false)   // sizes itself (G4: two head rows when narrow); R3: no controls per day
                    }
                    .padding(.horizontal, Space.card).padding(.top, Space.loose).padding(.bottom, Space.stack)
                }
            }
        }
        .card(wash: true, watermark: "calendar.day.timeline.left")
    }

    /// `1 h 42 min · 4 warnings · 2 blocks` for one day's sessions — the same sums as the study log's rows.
    private func dayFigures(_ sessions: [ObjectiveSession]) -> String {
        let secs = sessions.reduce(0) { $0 + $1.seconds }, w = sessions.reduce(0) { $0 + $1.warnings }, b = sessions.reduce(0) { $0 + $1.blocks }
        var parts = [minutes(TimeInterval(secs))]
        if sessions.count > 1 { parts.append("\(sessions.count) sessions") }
        if w > 0 { parts.append("\(w) warning\(w == 1 ? "" : "s")") }
        if b > 0 { parts.append("\(b) block\(b == 1 ? "" : "s")") }
        if w == 0 && b == 0 { parts.append("clean") }
        return parts.joined(separator: " · ")
    }

    // MARK: distractions (§3.4, §5a Q4): grouped by app or host, the answers as pills, "this is work" items last and dimmed
    private struct DistractionExtra { var bySeverity: [String: Int] = [:]; var lastWork: Date? = nil }

    private func distractions(_ o: Objective, log: ObjectiveLog, accent: Color) -> some View {
        let items = EventLog.shared.distractions(objective: o.id)
        // a second pass for what `Distraction` does not carry: counts per severity, and when "this is work" was last answered
        let severity = Dictionary(uniqueKeysWithValues: log.sessions.map { ($0.id, $0.strictness) })
        var extra: [String: DistractionExtra] = [:]
        for e in EventLog.shared.events(objective: o.id, from: .distantPast, to: Date()) {
            if let (key, _) = EventLog.distractionKey(e), let sid = e.sessionId, let sev = severity[sid] { extra[key, default: .init()].bySeverity[sev, default: 0] += 1 }
            if e.kind == "judge.answer" || e.kind == "web.answer" {
                let parts = e.detail.components(separatedBy: " · ")
                if parts.count >= 2, parts[0] == "work" || parts[0] == "this is work" {
                    for k in items.map(\.key) where parts[1].localizedCaseInsensitiveContains(k) { extra[k, default: .init()].lastWork = e.ts }
                }
            }
        }
        let work = items.filter { extra[$0.key]?.lastWork != nil }, rest = items.filter { extra[$0.key]?.lastWork == nil }
        let ordered = rest + work
        let shown = showAllDistractions ? ordered : Array(ordered.prefix(8))
        return VStack(alignment: .leading, spacing: Space.stack) {
            HStack(spacing: Space.card) {
                MonoLabel("\(items.count) item\(items.count == 1 ? "" : "s")", color: Theme.ink)
                MonoLabel("\(log.warnings) warning\(log.warnings == 1 ? "" : "s")")
                MonoLabel("\(log.blocks) block\(log.blocks == 1 ? "" : "s")")
                Spacer()
                if !work.isEmpty { MonoLabel("\(work.count) answered “this is work” · shown last", color: Theme.muted2) }
            }
            VStack(spacing: Space.hair) {
                if items.isEmpty { EmptyState(symbol: "checkmark.seal", text: "Nothing pulled you away during these sessions.") }
                ForEach(Array(shown.enumerated()), id: \.element.id) { n, d in
                    if n > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, Space.loose) }
                    distractionRow(d, extra: extra[d.key] ?? .init(), accent: accent)
                }
                if ordered.count > 8 {
                    HStack { Spacer(); PillButton(text: showAllDistractions ? "show fewer" : "show all \(ordered.count)") { showAllDistractions.toggle() }; Spacer() }.padding(.top, Space.stack)
                }
            }
            .padding(Space.stack)
            .card(watermark: "exclamationmark.bubble")
        }
    }

    /// `▲ youtube.com   7 ×   last Sun 19:58   back ×4 · ignored ×1 · blocked ×2` (+ `at normal ×5 · at strict ×2` when it varies)
    private func distractionRow(_ d: EventLog.Distraction, extra: DistractionExtra, accent: Color) -> some View {
        let work = extra.lastWork != nil
        let allowedHost = d.isHost && store.rules.isAllowedSite(d.key)
        let answerOrder = ["back", "ignored", "snooze", "work"]
        let answers = d.answers.keys.sorted { (answerOrder.firstIndex(of: $0) ?? 9) < (answerOrder.firstIndex(of: $1) ?? 9) }
        return HStack(alignment: .center, spacing: Space.loose) {
            Icon(d.isHost ? "globe" : "app.badge", .row, color: work ? Theme.ok : d.blocked > 0 ? Theme.danger : Theme.warn).frame(width: 18)
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(d.key).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                if extra.bySeverity.count > 1 {
                    MonoLabel(extra.bySeverity.sorted { $0.value > $1.value }.map { "at \($0.key) ×\($0.value)" }.joined(separator: " · "), color: Theme.muted2)
                }
            }
            .frame(minWidth: 140, alignment: .leading)
            Pill(work ? "✓ \(d.count) ×" : "\(d.count) ×", kind: work ? .ok : d.blocked > 0 ? .danger : .warn)
            Text("last \(Self.dayFormat.string(from: d.last)) \(clock(d.last))").font(Type.data).foregroundStyle(Theme.muted2).lineLimit(1)
            Spacer(minLength: Space.stack)
            WrapRow {
                ForEach(answers, id: \.self) { a in Pill("\(answerLabel(a)) ×\(d.answers[a]!)", kind: a == "work" ? .ok : .neutral) }
                if d.blocked > 0 { Pill("\(d.isHost ? "blocked" : "closed") ×\(d.blocked)", kind: .danger) }
                if let since = extra.lastWork { Pill(allowedHost ? "allowed since \(Self.shortDay.string(from: since))" : "this is work · \(Self.shortDay.string(from: since))", kind: .ok) }
            }
        }
        .rowPadding()
        .opacity(work ? 0.55 : 1)
        .contentShape(Rectangle())
        .modifier(DistractionMenu(snapshot: snapshot, isHost: d.isHost))
    }

    private func answerLabel(_ a: String) -> String {
        switch a { case "snooze": return "snoozed"; case "work": return "this is work"; default: return a }
    }

    private func severityKind(_ s: String) -> PillKind { .neutral }   // R5 (D17): the level is a fact, not a verdict — warn and danger are for detours and blocks
    private func endingPill(_ e: String, accent: Color) -> some View {
        switch e {
        case "finished": return Pill("finished", kind: .ok)
        case "ended": return Pill("ended", kind: .neutral)
        case "quit": return Pill("quit", kind: .warn)
        case "live": return Pill("in session", kind: .accent, dot: true, accent: accent)
        default: return Pill(e, kind: e.contains("phrase") ? .danger : .neutral)
        }
    }

    private func section<C: View>(_ n: Int, _ title: String, note: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            SectionHeader(n, title, note: note)
            content()
        }
    }
    private func empty(_ o: Objective) -> some View {
        EmptyState(symbol: o.icon, text: "No sessions yet. Start one above.").card(wash: true)
    }
}

/// The header's plan pill (PLAN_PLANNING §3.1, P0; R5 PLAN_REWORK §3.6): `due Fri 31 Oct · ~4 h` (danger when overdue), `plan` when nothing
/// is set; a click opens one popover with the day picker and the estimate menu. Live window only — in a snapshot the pill alone.
struct DuePill: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    let objective: Objective
    let accent: Color
    @State private var open = false
    private static let f: DateFormatter = { let d = DateFormatter(); d.dateFormat = "EEE d MMM"; return d }()
    var body: some View {
        let o = objective
        let state = store.dueState(o)
        let parts = [o.due.map { "due " + Self.f.string(from: $0) }, o.estimateMinutes.map { "~" + Planning.hours($0) }].compactMap { $0 }
        let text = parts.isEmpty ? "plan" : parts.joined(separator: " · ")
        let pill = HStack(spacing: Space.tight) {
            Icon("calendar", .small, color: state.isOverdue ? Theme.danger : accent)
            Text(text.uppercased()).font(Type.pill).tracking(Type.pillTracking).foregroundStyle(state.isOverdue ? Theme.danger : Theme.ink).lineLimit(1)
            if case .overdue(let d) = state { MonoLabel("· \(d) d", color: Theme.danger) }
        }
        .padding(.horizontal, Space.pillH).frame(height: PillMenu<String>.height)
        .background(Capsule().fill(Theme.paper)).overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
        .contentShape(Capsule())
        if snapshot { pill }
        else {
            Button { open = true } label: { pill }.buttonStyle(.plain).help("The deadline and the estimate")
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: Space.stack) {
                        HStack(spacing: Space.stack) {
                            MonoLabel("estimate")
                            IconChoice(symbol: "hourglass", options: [(0, "no estimate")] + Planning.estimateOptions.map { ($0, "~\(Planning.hours($0))") },
                                       selection: Binding<Int>(get: { o.estimateMinutes ?? 0 }, set: { v in store.saveObjective(id: o.id, subject: o.subjectId, title: o.title, bio: o.bio, icon: o.icon, estimateMinutes: .some(v == 0 ? nil : v)) }),
                                       title: "Estimate")
                        }
                        MonoLabel("due date")
                        DatePicker("", selection: Binding(get: { o.due ?? Planning.dueDate(forDay: Date()) }, set: { d in
                            store.saveObjective(id: o.id, subject: o.subjectId, title: o.title, bio: o.bio, icon: o.icon, due: .some(d))
                        }), displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                        HStack {
                            if o.due != nil { PillButton(text: "clear", kind: .neutral) { store.saveObjective(id: o.id, subject: o.subjectId, title: o.title, bio: o.bio, icon: o.icon, due: .some(nil)); open = false } }
                            Spacer()
                            PillButton(text: "done", kind: .on, accent: accent) { open = false }
                        }
                    }
                    .padding(Space.card).frame(width: 260)
                }
        }
    }
}

/// A distraction row's context menu — the only way out of the overview to the rules screens (§3.4: nothing here edits a rule).
private struct DistractionMenu: ViewModifier {
    @Environment(Store.self) private var store
    let snapshot: Bool
    let isHost: Bool
    func body(content: Content) -> some View {
        if snapshot { content }
        else {
            content.contextMenu {
                Button("Open Rules") { store.go(.rules) }   // M0: Apps and Websites are the Rules tab
            }
        }
    }
}
