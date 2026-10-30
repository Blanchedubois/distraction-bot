import SwiftUI

/// The daily shutdown (PLAN_STUDY_DAY §3.4, K2; IMPACT_ANALYSIS §4.2 R8): one page, five blocks in one column at the 1040 cap —
/// the day in figures · objectives today with `stuck · moved · done` and a note · how was the day (1–5, one line) · tomorrow
/// (objective chips with minutes, a start time, a one-off goal) · Shut down / Not now. Routed by `store.openShutdown`, never a tab.
/// Snapshot: `DBOT_SNAPSHOT_VIEW=shutdown DBOT_SNAPSHOT_DAY=…` renders it with text stand-ins for the fields.
struct ShutdownScreen: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    let day: Date                                        // the study day to close (its start)

    @State private var loaded: HistoryDay?
    @State private var marks: [String: String] = [:]     // objective id (or "goal:<goal>") → stuck · moved · done · skipped
    @State private var notes: [String: String] = [:]
    @State private var rating: Int? = nil
    @State private var line = ""
    @State private var picked: [String] = []             // objective ids, in the order picked
    @State private var minutesFor: [String: Int] = [:]   // 0 = open
    @State private var startAt = ""                      // "" · "HH:mm" · "calendar"
    @State private var oneOff = ""
    @State private var showOneOff = false
    @State private var jumpRows: [JumpBackInRow] = []

    private var bundle: HistoryDay { loaded ?? HistoryDay.load(day, store: store) }
    private var isToday: Bool { StudyDay.isToday(day) }
    private var tomorrow: Date { StudyDay.shift(day, by: 1) }

    var body: some View {
        let d = bundle
        Page(kicker: "shut down the day · \(StudyDay.label(day, pastMidnight: d.pastMidnight))", title: "Shut down", watermark: "flag.checkered") {
            figures(d)
            objectivesBlock(d)
            ratingBlock
            tomorrowBlock
            footer
        }
        .onAppear {
            loaded = HistoryDay.load(day, store: store)
            jumpRows = JumpBackInRow.build(store: store)
            // objectives planned for this day but not touched arrive pre-marked `skipped`
            let touched = Set(d.sessions.compactMap(\.objectiveId))
            for p in store.plan(for: day) { if let oid = p.objectiveId, !touched.contains(oid) { marks[oid] = "skipped" } }
            if snapshot { rating = 4; line = "a good evening, two sessions"; if let first = jumpRows.first { picked = [first.objective.id]; minutesFor[first.objective.id] = 90 }; startAt = "19:30" }
        }
    }

    // MARK: 1 · the day in figures — the History tiles, read-only, then the day's strip

    private func figures(_ d: HistoryDay) -> some View {
        let f = d.model.figures
        let shown = store.settings.hideTestSessions ? d.sessions.filter { !$0.isTest } : d.sessions
        let done = shown.filter { $0.endedBy != "live" }.count
        let plan = f.target.map { "of \(minutes($0)) · \(Int(((f.progress ?? 0) * 100).rounded())) %" } ?? "no plan"
        let sc = d.stats.score
        let empty = f.sessions == 0
        return VStack(alignment: .leading, spacing: Space.loose) {
            SectionHeader(1, "The day in figures", note: "\(f.sessions) session\(f.sessions == 1 ? "" : "s") · \(f.detours) detour\(f.detours == 1 ? "" : "s") · \(f.blocks) block\(f.blocks == 1 ? "" : "s")")
            Narrow { narrow in KpiGrid(columns: narrow ? 2 : 4) {
                KpiTile(label: "Focused", value: empty ? "—" : minutes(f.focused), sub: plan, symbol: "clock", small: true)
                KpiTile(label: "Sessions", value: empty ? "—" : "\(done) done", sub: shown.isEmpty ? "no sessions" : "longest \(minutes(TimeInterval(shown.map(\.seconds).max() ?? 0)))", symbol: "play.circle", small: true)
                KpiTile(label: "Clean", value: f.clean.map { String(format: "%.0f %%", $0 * 100) } ?? "—", sub: empty ? "no sessions" : "\(minutes(f.distracted)) lost" + (f.falseAlarms > 0 ? " · \(f.falseAlarms) said work" : ""), symbol: "checkmark.seal", small: true)
                KpiTile(label: "Score", value: empty ? "—" : "\(sc.total)", sub: empty ? "no sessions" : sc.word + (d.stats.closed ? " · closed" : " · +10 when shut down"), symbol: "flag.checkered", small: true)   // G4: the tease
            } }
            TodayTimeline(model: d.model, now: isToday ? Date() : nil)
                .cardPadding()
                .card(wash: true, watermark: "calendar.day.timeline.left")
        }
    }

    // MARK: 2 · objectives today — one row per objective with a session (one-offs by goal), plus planned-but-skipped ones

    private struct Row: Identifiable { let id: String; let objective: Objective?; let title: String; let seconds: Int; let caught: Int; let skipped: Bool }
    private func rows(_ d: HistoryDay) -> [Row] {
        let shown = store.settings.hideTestSessions ? d.sessions.filter { !$0.isTest } : d.sessions
        var order: [String] = []; var acc: [String: Row] = [:]
        for s in shown.sorted(by: { $0.started < $1.started }) {
            let key = s.objectiveId ?? "goal:\(s.goal)"
            let o = store.objective(s.objectiveId)
            if acc[key] == nil { order.append(key); acc[key] = Row(id: key, objective: o, title: o?.title ?? (s.goal.isEmpty ? "Focus session" : s.goal), seconds: 0, caught: 0, skipped: false) }
            acc[key] = Row(id: key, objective: o, title: acc[key]!.title, seconds: acc[key]!.seconds + s.seconds, caught: acc[key]!.caught + s.warnings + s.blocks, skipped: false)
        }
        var out = order.map { acc[$0]! }
        for p in store.plan(for: day) { if let oid = p.objectiveId, acc[oid] == nil, let o = store.objective(oid) { out.append(Row(id: oid, objective: o, title: o.title, seconds: 0, caught: 0, skipped: true)) } }
        return out
    }

    private func objectivesBlock(_ d: HistoryDay) -> some View {
        let rows = rows(d)
        return VStack(alignment: .leading, spacing: Space.loose) {
            SectionHeader(2, "Objectives today", note: "how did each one go · a note on what got done", count: rows.isEmpty ? nil : "\(rows.count)")
            VStack(spacing: 0) {
                if rows.isEmpty { EmptyState(symbol: "target", text: "No sessions on this day.") }
                ForEach(Array(rows.enumerated()), id: \.element.id) { n, r in
                    if n > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, Space.loose) }
                    objectiveRow(r)
                }
            }
            .padding(Space.stack)
            .card(watermark: "target")
        }
    }

    private func objectiveRow(_ r: Row) -> some View {
        let tint = r.objective.map { store.accent(of: $0) } ?? Theme.muted2
        let mark = marks[r.id]
        return VStack(alignment: .leading, spacing: Space.stack) {
            HStack(spacing: Space.stack) {
                Icon(r.objective?.icon ?? "text.cursor", .row, color: tint).frame(width: 18)
                Text(r.title).font(Type.strong).foregroundStyle(r.skipped ? Theme.muted : Theme.ink).lineLimit(1)
                if let o = r.objective, let s = store.subject(o.subjectId) { MonoLabel(s.code ?? s.shortName, color: Theme.muted2) }
                Spacer(minLength: Space.stack)
                MonoLabel(r.skipped ? "planned · not touched" : "\(minutes(Double(r.seconds))) · \(r.caught) caught")
                WrapRow {
                    ForEach(Shutdown.marks, id: \.self) { m in
                        PillButton(text: m, kind: mark == m ? .on : .neutral, accent: Theme.ink) { marks[r.id] = mark == m ? (r.skipped ? "skipped" : nil) : m }
                    }
                    if r.skipped { Pill("skipped", kind: mark == "skipped" ? .on : .neutral, accent: Theme.muted2) }
                    if mark == "done", let o = r.objective, !o.isDone { PillButton(text: "complete the objective", kind: .accent, accent: tint) { store.complete(o.id) } }
                    if r.objective?.isDone == true { Pill("completed", kind: .ok) }
                }
            }
            if snapshot { well(notes[r.id] ?? "", placeholder: "what got done") }
            else { TextField("what got done", text: Binding(get: { notes[r.id] ?? "" }, set: { notes[r.id] = $0 })).textFieldStyle(.plain).font(Type.body).foregroundStyle(Theme.ink).padding(.leading, Space.sheet) }
        }
        .rowPadding()
        .opacity(r.skipped ? 0.7 : 1)
    }

    // MARK: 3 · how was the day — five circles, keys 1–5, one line

    private var ratingBlock: some View {
        VStack(alignment: .leading, spacing: Space.loose) {
            SectionHeader(3, "How was the day", note: "1–5 · one line")
            VStack(alignment: .leading, spacing: Space.loose) {
                HStack(spacing: Space.stack) {
                    ForEach(1...5, id: \.self) { n in
                        Button { rating = rating == n ? nil : n } label: {
                            Circle().strokeBorder(Theme.ink.opacity(0.5), lineWidth: 1).background(Circle().fill(n <= (rating ?? 0) ? Theme.ink : .clear)).frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain).keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: []).help("\(n) of 5 · key \(n)")
                    }
                    MonoLabel(rating.map { ["rough", "meh", "fine", "good", "great"][$0 - 1] } ?? "not rated", color: Theme.muted2).padding(.leading, Space.stack)
                }
                if snapshot { well(line, placeholder: "one line about today") }
                else { TextField("one line about today", text: $line).textFieldStyle(.plain).font(Type.body).foregroundStyle(Theme.ink) }
            }
            .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
            .card(watermark: "star")
        }
    }

    // MARK: 4 · tomorrow — chips in Jump back in's order, minutes per pick, a start time, a one-off goal

    private var tomorrowBlock: some View {
        VStack(alignment: .leading, spacing: Space.loose) {
            SectionHeader(4, "Tomorrow", note: "pick what to work on · minutes · when to start · empty is a plan too")
            VStack(alignment: .leading, spacing: Space.loose) {
                if jumpRows.isEmpty && !showOneOff { MonoLabel("no objectives yet · a one-off goal still makes a plan", color: Theme.muted2) }
                WrapRow {
                    ForEach(jumpRows) { r in
                        let on = picked.contains(r.objective.id)
                        PillButton(text: r.objective.title, kind: on ? .on : .neutral, accent: Theme.ink) { toggle(r.objective) }
                    }
                    PillButton(text: showOneOff ? "one-off goal ×" : "+ one-off goal", kind: .neutral) { showOneOff.toggle(); if !showOneOff { oneOff = "" } }
                }
                if showOneOff {
                    if snapshot { well(oneOff, placeholder: "a one-off goal for tomorrow") }
                    else { TextField("a one-off goal for tomorrow", text: $oneOff).textFieldStyle(.plain).font(Type.body).foregroundStyle(Theme.ink) }
                }
                ForEach(picked, id: \.self) { oid in
                    if let o = store.objective(oid) {
                        HStack(spacing: Space.stack) {
                            Icon(o.icon, .row, color: store.accent(of: o)).frame(width: 18)
                            Text(o.title).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer(minLength: Space.stack)
                            PillMenu(options: minuteOptions(o), selection: Binding(get: { minutesFor[oid] ?? defaultMinutes(o) }, set: { minutesFor[oid] = $0 }), leadingSymbol: "timer")
                        }
                    }
                }
                HStack(spacing: Space.stack) {
                    MonoLabel("start at")
                    PillMenu(options: startOptions, selection: $startAt, leadingSymbol: "sunrise")
                    if let t = resolvedStart { MonoLabel(t.formatted(.dateTime.weekday(.abbreviated).hour().minute()), color: Theme.muted2) }
                }
            }
            .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
            .card(watermark: "sunrise")
        }
    }

    private func toggle(_ o: Objective) {
        if let i = picked.firstIndex(of: o.id) { picked.remove(at: i) } else { picked.append(o.id) }
    }
    /// 25 · 50 · 90 · the objective's average real length rounded to 5 · open.
    private func minuteOptions(_ o: Objective) -> [(Int, String)] {
        var ms = [25, 50, 90]
        if let avg = averageMinutes(o), !ms.contains(avg) { ms.append(avg); ms.sort() }
        return ms.map { ($0, "\($0) min" + ($0 == averageMinutes(o) ? " · usual" : "")) } + [(0, "open")]
    }
    private func averageMinutes(_ o: Objective) -> Int? {
        let ss = EventLog.shared.sessions(objective: o.id).filter { !$0.isTest }
        guard !ss.isEmpty else { return nil }
        let avg = ss.reduce(0) { $0 + $1.seconds } / ss.count / 60
        return avg >= 10 ? Int((Double(avg) / 5).rounded() * 5) : nil
    }
    private func defaultMinutes(_ o: Objective) -> Int { averageMinutes(o) ?? o.startMinutes(store.settings) ?? 0 }

    /// Half hours 06:00–23:30, plus `first free hour after the calendar's last event` when the feed has instances tomorrow.
    private var startOptions: [(String, String)] {
        var out: [(String, String)] = [("", "no start time")]
        if calendarStart != nil { out.append(("calendar", "first free hour after the calendar's last event")) }
        out += stride(from: 6, through: 23, by: 1).flatMap { h in ["00", "30"].map { m in (String(format: "%02d:%@", h, m), String(format: "%02d:%@", h, m)) } }
        return out
    }
    private var calendarStart: Date? {
        let end = StudyDay.end(of: tomorrow)
        guard let last = store.feed.instances(from: tomorrow, to: end).filter({ !$0.allDay }).map(\.end).max() else { return nil }
        let cal = Calendar.current
        let h = cal.component(.hour, from: last), m = cal.component(.minute, from: last)
        let t = cal.date(bySettingHour: m == 0 ? h : h + 1, minute: 0, second: 0, of: last) ?? last
        return t < end ? t : nil
    }
    private var resolvedStart: Date? {
        if startAt == "calendar" { return calendarStart }
        let p = startAt.split(separator: ":").compactMap { Int($0) }; guard p.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: tomorrow)
    }

    // MARK: 5 · footer

    private var footer: some View {
        HStack(spacing: Space.stack) {
            ActionButton(title: "Shut down", symbol: "flag.checkered", accent: true, tint: Theme.sage) { file() }.keyboardShortcut(.return, modifiers: .command).help("⌘↩")
            ActionButton(title: "Not now", ghost: true) { store.openShutdown = nil }
            Spacer()
            MonoLabel(isToday ? "files the day · queues tomorrow's first item" : "files \(StudyDay.label(day)) · its plan is for the day after", color: Theme.muted2)
        }
    }

    private func file() {
        let d = bundle
        let objectiveMarks: [Shutdown.ObjectiveMark] = rows(d).compactMap { r in
            guard let oid = r.objective?.id else { return nil }
            let m = marks[r.id] ?? (r.skipped ? "skipped" : nil)
            guard let m else { return (notes[r.id] ?? "").isEmpty ? nil : Shutdown.ObjectiveMark(objectiveId: oid, mark: "", note: notes[r.id] ?? "") }
            return Shutdown.ObjectiveMark(objectiveId: oid, mark: m, note: notes[r.id] ?? "")
        }
        var plan: [Shutdown.PlannedItem] = picked.compactMap { oid in store.objective(oid).map { Shutdown.PlannedItem(objectiveId: $0.id, goal: $0.title, minutes: (minutesFor[oid] ?? defaultMinutes($0)) == 0 ? nil : (minutesFor[oid] ?? defaultMinutes($0))) } }
        let goal = oneOff.trimmingCharacters(in: .whitespaces)
        if showOneOff, !goal.isEmpty { plan.append(Shutdown.PlannedItem(objectiveId: nil, goal: goal, minutes: nil)) }
        store.fileShutdown(Shutdown(day: day, rating: rating, note: line.trimmingCharacters(in: .whitespaces), objectives: objectiveMarks, tomorrow: plan, startAt: resolvedStart))
    }

    /// A render-only stand-in for a text field (the editors' pattern): the typed value, or its placeholder muted, in a paper well.
    private func well(_ text: String, placeholder: String) -> some View {
        Text(text.isEmpty ? placeholder : text).font(Type.body).foregroundStyle(text.isEmpty ? Theme.muted2 : Theme.ink).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).rowPadding()
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.paper2))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

/// Reads `\.narrow` where it is set — inside `Page`'s geometry.
private struct Narrow<Content: View>: View {
    @Environment(\.narrow) private var narrow
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(narrow) }
}
