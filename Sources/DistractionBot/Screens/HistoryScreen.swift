import SwiftUI

/// Calendar · Day (PLAN_STRUCTURE §3.3, M2; was the History tab, PLAN_HISTORY_TAB): one day's progress at a time — the figures, the
/// day's strip, sessions by objective, detours, the day's log. The day is `store.calendarDay`; `CalendarScreen` hosts it with the
/// head, the `Week | Day` segment and the toolbar date control (‹ ›, the day menu, the picker, today; ⌘← ⌘→ ⌘T ⇧⌘T).
struct CalendarDayView: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    @Environment(\.narrow) private var narrow
    let day: Date                                // the study day's start (K1), from the host
    @State private var loaded: HistoryDay?
    @State private var eventFilter = "all"      // Y3: the Log's filter, local to the day's log card
    @State private var allEvents = false

    private var bundle: HistoryDay { loaded ?? HistoryDay.load(day, store: store) }
    private var cal: Calendar { Calendar.current }
    private var today: Date { StudyDay.start(of: Date()) }   // K1
    /// The bounds (§5a Q4): the first logged day … today. An empty log bounds to today alone.
    private var firstDay: Date { Self.firstDay }
    /// The bounds (§5a Q4): the first logged day … today. An empty log bounds to today alone. Shared with the host's toolbar.
    static var firstDay: Date { EventLog.shared.firstDay() ?? StudyDay.start(of: Date()) }   // K1: study days
    /// The latest day before `date` with a session (the Progress aggregate's per-day rows, tests hidden per the setting).
    @MainActor static func lastDayWithSessions(before date: Date, store: Store) -> Date? {
        let cal = Calendar.current
        return (store.statsAll?.days ?? []).filter { $0.sessions > 0 && StudyDay.start(of: $0.day) < date }.map { StudyDay.start(of: $0.day) }.max()   // K1
    }

    var body: some View {
        let d = bundle
        let _ = store.events.count   // subscribes the page to reloadLog() (the objective overview's trick), so a live day and filing refresh it
        VStack(alignment: .leading, spacing: Space.section(narrow: narrow)) {
            figures(d)
            shutdownCard(d)   // K4 (PLAN_STUDY_DAY §3.7): the day's shutdown record, or `not shut down`
            dayStrip(d)
            if d.isEmpty { empty(d) }
            else {
                sessions(d)
                detours(d)
                log(d)
            }
        }
        .onAppear { reload() }
        .onChange(of: day) { _, _ in reload(); allEvents = false }
        .onChange(of: store.events.count) { _, _ in reload() }
        .onChange(of: store.today.figures) { _, _ in if StudyDay.isToday(day) { reload() } }   // K1
    }

    private func reload() { loaded = HistoryDay.load(day, store: store) }
    // MARK: the figures (§3.3 ¶1, §5a Q6): Focused with the delta vs the previous day and a 14-day spark · Sessions · Clean · Score

    private static let shortDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE"; return f }()

    private func figures(_ d: HistoryDay) -> some View {
        let f = d.model.figures
        let shown = visibleSessions(d)
        let done = shown.filter { $0.endedBy != "live" }.count
        let hidden = d.sessions.count - shown.count
        let longest = shown.map(\.seconds).max() ?? 0
        let average = shown.isEmpty ? 0 : shown.reduce(0) { $0 + $1.seconds } / shown.count
        // the delta: focused against the day before, as a percentage (KpiTile's grammar); the words in the sub
        let prev = d.previous?.focused ?? 0
        let delta: Int? = d.previous == nil ? nil : prev > 0 ? Int(((f.focused - prev) / prev * 100).rounded()) : (f.focused > 0 ? 100 : 0)
        let diff = f.focused - prev
        let vs = d.previous == nil ? nil : "\(diff >= 0 ? "+" : "−")\(brief(abs(diff))) vs \(Self.shortDay.string(from: cal.date(byAdding: .day, value: -1, to: d.day)!))"
        let plan = f.target.map { "of \(brief($0)) · \(Int(((f.progress ?? 0) * 100).rounded())) %" }
        let sc = d.stats.score
        let empty = f.sessions == 0
        return Narrow { narrow in KpiGrid(columns: narrow ? 2 : 4) {
            KpiTile(label: "Focused", value: empty ? "—" : minutes(f.focused), sub: [plan, vs].compactMap { $0 }.joined(separator: " · "), symbol: "clock",
                    delta: empty ? nil : delta, spark: spark(ending: d.day), small: true)
            KpiTile(label: "Sessions", value: empty ? "—" : "\(done) done", sub: shown.isEmpty ? (hidden > 0 ? "\(hidden) test\(hidden == 1 ? "" : "s") hidden" : "no sessions") : "longest \(brief(TimeInterval(longest))) · avg \(brief(TimeInterval(average)))" + (hidden > 0 ? " · \(hidden) hidden" : ""), symbol: "play.circle", small: true)
            KpiTile(label: "Clean", value: f.clean.map { String(format: "%.0f %%", $0 * 100) } ?? "—", sub: empty ? "no sessions" : "\(f.detours) detour\(f.detours == 1 ? "" : "s") · \(brief(f.distracted)) lost" + (f.falseAlarms > 0 ? " · \(f.falseAlarms) said work" : ""), symbol: "checkmark.seal", small: true)
            // Z5 (PLAN_SCORING §3.6): the day score with its parts; `unplanned` when the day had no plan and a 0 target
            KpiTile(label: d.stats.unplanned ? "Focused · unplanned" : "Score", value: empty ? "—" : d.stats.unplanned ? minutes(f.focused) : "\(sc.total)",
                    sub: empty ? "no sessions" : d.stats.unplanned ? "no plan · no target · not scored" : "\(sc.word) · 100 − \(100 - sc.total)", symbol: "flag.checkered", small: true)
                .help(Tally.line(Tally.day(d.stats), total: sc.total) + " · plan from the \(d.stats.planSource.rawValue)")   // F2
        } }
    }
    /// The strip's short duration: `3 h 12`, `44 min`, `9 s`.
    private func brief(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        return m >= 60 ? "\(m / 60) h \(String(format: "%02d", m % 60))" : m > 0 ? "\(m) min" : "\(Int(t)) s"
    }
    /// Focused minutes per day over the 14 days ending on `day` (the Progress aggregate's per-day rows; tests per the setting).
    private func spark(ending day: Date) -> [Double]? {
        guard let days = store.statsAll?.days, !days.isEmpty else { return nil }
        let byDay = Dictionary(days.map { (StudyDay.start(of: $0.day), Double($0.focusedSeconds) / 60) }, uniquingKeysWith: +)   // K1
        let out = (0..<14).reversed().map { byDay[cal.date(byAdding: .day, value: -$0, to: day)!] ?? 0 }
        return out.allSatisfy { $0 == 0 } ? nil : out
    }
    private func visibleSessions(_ d: HistoryDay) -> [ObjectiveSession] {
        store.settings.hideTestSessions && ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_TESTS"] == nil ? d.sessions.filter { !$0.isTest } : d.sessions
    }

    // MARK: sessions by objective (§3.3 ¶3, §5a Q7–Q8)

    /// What a group wears (the strip's `Dress` rules): the subject's tint, the objective's glyph and title; grey for a one-off,
    /// a removed objective or a B-phase test.
    private struct GroupDress { let key: String; let tint: Color; let icon: String; let title: String; let code: String?; let objectiveId: String? }
    private func dress(_ s: ObjectiveSession) -> GroupDress {
        if s.goal.range(of: #"^B\d+\s"#, options: .regularExpression) != nil { return GroupDress(key: "test:\(s.goal)", tint: Theme.muted2, icon: "wrench", title: s.goal, code: "test", objectiveId: nil) }
        guard let oid = s.objectiveId else { return GroupDress(key: "goal:\(s.goal)", tint: Theme.muted2, icon: "text.cursor", title: s.goal, code: "one-off goal", objectiveId: nil) }
        guard let o = store.objective(oid) else { return GroupDress(key: "orphan:\(oid)", tint: Theme.muted2, icon: "questionmark", title: s.goal, code: "objective removed", objectiveId: nil) }
        let sub = store.subject(o.subjectId)
        return GroupDress(key: "objective:\(oid)", tint: sub.map { Theme.accent($0.accent) } ?? Theme.accent, icon: o.icon.isEmpty ? (sub?.icon ?? "target") : o.icon,
                          title: o.title.isEmpty ? s.goal : o.title, code: sub?.code ?? sub?.shortName, objectiveId: o.id)
    }

    private func sessions(_ d: HistoryDay) -> some View {
        let shown = visibleSessions(d)
        let hidden = d.sessions.count - shown.count
        // groups in order of focused time, longest first; sessions inside a group oldest first
        var order: [String] = []; var groups: [String: (dress: GroupDress, rows: [ObjectiveSession])] = [:]
        for s in shown.sorted(by: { $0.started < $1.started }) {
            let g = dress(s)
            if groups[g.key] == nil { order.append(g.key); groups[g.key] = (g, []) }
            groups[g.key]!.rows.append(s)
        }
        let sorted = order.map { groups[$0]! }.sorted { $0.rows.reduce(0) { $0 + $1.seconds } > $1.rows.reduce(0) { $0 + $1.seconds } }
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(1, "Sessions", note: "by objective · click a session for its minute-by-minute record" + (hidden > 0 ? " · \(hidden) test\(hidden == 1 ? "" : "s") hidden" : ""), count: "\(shown.count)")
            VStack(spacing: 0) {
                if shown.isEmpty { EmptyState(symbol: "play.circle", text: hidden > 0 ? "Only test sessions that day (Settings → Hide test sessions)." : "No sessions that day.") }
                ForEach(Array(sorted.enumerated()), id: \.element.dress.key) { n, g in
                    if n > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, Space.loose).padding(.vertical, Space.tight) }
                    group(g.dress, rows: g.rows)
                }
            }
            .padding(Space.stack)
            .card(watermark: "list.bullet.rectangle")
        }
    }

    /// The group head: a hairline in the tint, the glyph, the title, the subject code, the sums; its lines beneath.
    private func group(_ g: GroupDress, rows: [ObjectiveSession]) -> some View {
        let secs = rows.reduce(0) { $0 + $1.seconds }, w = rows.reduce(0) { $0 + $1.warnings }, b = rows.reduce(0) { $0 + $1.blocks }
        var parts = [minutes(TimeInterval(secs))]
        if rows.count > 1 { parts.append("\(rows.count) sessions") }
        if w > 0 { parts.append("\(w) warning\(w == 1 ? "" : "s")") }
        if b > 0 { parts.append("\(b) block\(b == 1 ? "" : "s")") }
        if w == 0 && b == 0 { parts.append("clean") }
        let openable = g.objectiveId != nil
        return VStack(alignment: .leading, spacing: Space.hair) {
            HStack(spacing: Space.stack) {
                Icon(g.icon, .row, color: g.tint).frame(width: 18)
                Text(g.title).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                if let code = g.code { MonoLabel(code, color: Theme.muted2) }
                Spacer()
                MonoLabel(parts.joined(separator: " · "))
                if openable { Icon("arrow.up.right", .small, color: Theme.muted2) }
            }
            .padding(.horizontal, Space.loose).padding(.top, Space.stack).padding(.bottom, Space.tight)
            .contentShape(Rectangle())
            .onTapGesture { if let oid = g.objectiveId { store.open(objective: oid) } }
            .help(openable ? "Open \(g.title)" : "")
            ForEach(rows) { r in
                SessionLine(session: r, accent: g.tint) {
                    store.go(.log, query: "", from: r.started.addingTimeInterval(-2), to: (r.ended ?? Date()).addingTimeInterval(2), title: "session · \(g.title)")
                }
            }
        }
        .padding(.bottom, Space.tight)
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(g.tint.opacity(0.25)).frame(width: 2).padding(.vertical, Space.stack) }
    }

    // MARK: detours (§3.3 ¶4): the strip's periods as rows, in order; false alarms last and faded

    private func detours(_ d: HistoryDay) -> some View {
        let real = d.model.periods.filter { !$0.falseAlarm }, alarms = d.model.periods.filter(\.falseAlarm)
        let f = d.model.figures
        var roll = ["\(f.detours) detour\(f.detours == 1 ? "" : "s")", "\(minutes(f.distracted)) lost"]
        if f.falseAlarms > 0 { roll.append("\(f.falseAlarms) false alarm\(f.falseAlarms == 1 ? "" : "s")") }
        roll.append("\(f.blocks) block\(f.blocks == 1 ? "" : "s")")
        let rows = real + alarms
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(2, "Detours", note: "what pulled you away, in order · click one for its rows", count: rows.isEmpty ? nil : "\(rows.count)")
            VStack(spacing: 0) {
                if rows.isEmpty { EmptyState(symbol: "checkmark.seal", text: "Nothing pulled you away that day.") }
                else {
                    MonoLabel(roll.joined(separator: " · ")).padding(.horizontal, Space.loose).padding(.top, Space.stack).padding(.bottom, Space.tight).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(Array(rows.enumerated()), id: \.offset) { n, p in
                        if n > 0 { Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, Space.loose) }
                        detourRow(p)
                    }
                }
            }
            .padding(Space.stack)
            .card(watermark: "exclamationmark.bubble")
        }
    }

    /// `19:40 · Spotify — Radiohead · 34 s · [came back] · 1 block`; the front app in muted2 when the title is a page.
    private func detourRow(_ p: DayModel.Period) -> some View {
        let outcome: (String, PillKind) = {
            switch p.outcome {
            case .back: return ("came back", .neutral); case .blocked: return ("blocked", .danger); case .work: return ("said work", .ok)
            case .snoozed: return ("snoozed", .warn); case .open: return ("open", .accent)
            }
        }()
        return HStack(spacing: Space.loose) {
            Text(clock(p.start)).font(Type.data).foregroundStyle(Theme.muted2).frame(width: 64, alignment: .leading)
            Icon(p.kind == .site ? "globe" : p.kind == .look ? "eye" : "app.badge", .row, color: p.falseAlarm ? Theme.ok : p.outcome == .blocked ? Theme.danger : Theme.warn).frame(width: 16)
            Text(p.title).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
            if p.kind == .site, !p.front.isEmpty { Narrow { narrow in if !narrow { MonoLabel(p.front, color: Theme.muted2).lineLimit(1) } } }
            Spacer(minLength: 8)
            MonoLabel(p.duration >= 1 ? minutes(p.duration) : "—")
            Pill(outcome.0, kind: outcome.1)
            if !p.blocks.isEmpty { MonoLabel("\(p.blocks.count) block\(p.blocks.count == 1 ? "" : "s")", color: Theme.danger) }
            Icon("chevron.right", .small, color: Theme.muted2)
        }
        .rowPadding()
        .opacity(p.falseAlarm ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { store.go(.log, query: p.subject, from: p.start.addingTimeInterval(-2), to: p.end.addingTimeInterval(2), title: "detour · \(p.title)") }
        .help(p.reason.isEmpty ? "Open the log for this detour" : p.reason)
    }

    // MARK: the day's log (§3.3 ¶5, §5a Q9): the latest 60 rows, the Log's filter pills, show all, a door to the Log

    private func log(_ d: HistoryDay) -> some View {
        let rows = d.events.filter { EventFilter.matches($0, eventFilter) }
        let shown = allEvents ? rows : Array(rows.prefix(60))
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(3, "Log", note: "every event that day · newest first", count: "\(rows.count)") {
                PillMenu(options: EventFilter.options, selection: $eventFilter, leadingSymbol: "line.3.horizontal.decrease")
            }
            VStack(spacing: Space.hair) {
                if rows.isEmpty { EmptyState(symbol: "list.bullet.rectangle", text: "Nothing of that kind that day.") }
                ForEach(shown) { e in EventRow(event: e) }
                HStack {
                    if rows.count > 60 { PillButton(text: allEvents ? "latest 60" : "show all \(rows.count)", kind: .neutral) { withAnimation { allEvents.toggle() } } }
                    Spacer()
                    PillButton(text: "open in Log ↗", kind: .accent) { openLog(d) }
                }
                .padding(.top, Space.stack).padding(.horizontal, Space.tight)
            }
            .padding(Space.stack)
            .card(watermark: "list.bullet.rectangle")
        }
    }

    // MARK: the day — Home's Today card for the chosen day (§3.3 ¶2)
    // MARK: K4 (PLAN_STUDY_DAY §3.7): the Shutdown card — rating dots · the note · per-objective marks · planned vs what happened
    @ViewBuilder private func shutdownCard(_ d: HistoryDay) -> some View {
        let record = store.shutdown(for: d.day)
        let plan = store.plan(for: d.day)
        let yesterday = StudyDay.isYesterday(d.day)
        if record == nil && plan.isEmpty && !yesterday && !d.isToday {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(0, "Shutdown", note: record.map { "filed \(clock($0.day == StudyDay.start(of: d.day) ? ($0.startAt ?? $0.day) : $0.day))" } ?? "the day's shutdown ritual · ⌘⇧D")
                VStack(alignment: .leading, spacing: Space.loose) {
                    if let r = record {
                        HStack(spacing: Space.stack) {
                            HStack(spacing: Space.tight) { ForEach(1...5, id: \.self) { n in Circle().fill(n <= (r.rating ?? 0) ? Theme.ink : Theme.line2).frame(width: 8, height: 8) } }
                            MonoLabel(r.rating.map { ["rough", "meh", "fine", "good", "great"][$0 - 1] } ?? "not rated", color: Theme.muted2)
                            if !r.note.isEmpty { Text(r.note).font(Type.body).foregroundStyle(Theme.ink).lineLimit(2) }
                        }
                        if !r.objectives.isEmpty {
                            WrapRow {
                                ForEach(r.objectives, id: \.objectiveId) { m in
                                    if let o = store.objective(m.objectiveId) {
                                        Pill("\(o.title) · \(m.mark.isEmpty ? "noted" : m.mark)", kind: m.mark == "done" ? .ok : .neutral)   // R6 (PLAN_REWORK D17): the mark is a fact — done in ok, the rest neutral, as the pane draws it
                                            .help(m.note.isEmpty ? o.title : m.note)
                                    }
                                }
                            }
                        }
                        if !r.tomorrow.isEmpty {
                            MonoLabel("planned for the next day: " + r.tomorrow.map { "\($0.goal)" + ($0.minutes.map { " · \($0) min" } ?? "") }.joined(separator: " · ") + (r.startAt.map { " · from \(clock($0))" } ?? ""), color: Theme.muted).lineLimit(2)
                        }
                    } else {
                        HStack(spacing: Space.stack) {
                            MonoLabel("not shut down", color: Theme.muted2)
                            if yesterday, store.session == nil { PillButton(text: "shut it down now ↗", kind: .accent, log: "shutdown from calendar") { store.openShutdown(day: d.day) } }
                            if d.isToday, store.offerShutdown { PillButton(text: "shut down the day ↗", kind: .accent, log: "shutdown from calendar") { store.openShutdown(day: d.day) } }
                        }
                    }
                    if !plan.isEmpty {
                        // planned vs what happened: each planned item against the day's sessions on it
                        let shown = visibleSessions(d)
                        WrapRow {
                            ForEach(plan) { p in
                                let did = shown.filter { p.objectiveId != nil ? $0.objectiveId == p.objectiveId : $0.goal == p.goal }.reduce(0) { $0 + $1.seconds }
                                let want = p.minutes.map { "\($0) min" } ?? "open"
                                Pill("planned \(p.goal) · \(want) → \(did > 0 ? "done \(minutes(Double(did)))" : "not started")", kind: did > 0 ? .ok : .neutral)
                            }
                        }
                    }
                }
                .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                .card(watermark: "flag.checkered")
            }
        }
    }

    private func dayStrip(_ d: HistoryDay) -> some View {
        let f = d.model.figures
        let title = d.isToday ? "Today" : d.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        return Panel(title: title, note: "\(f.sessions) session\(f.sessions == 1 ? "" : "s") · \(f.detours) detour\(f.detours == 1 ? "" : "s") · \(f.blocks) block\(f.blocks == 1 ? "" : "s")",
                     trailing: AnyView(PillButton(text: "log ↗", kind: .accent) { openLog(d) }), bare: true) {
            TodayTimeline(model: d.model, now: d.isToday ? Date() : nil)
                .cardPadding()
                .card(wash: true, watermark: "calendar.day.timeline.left")
        }
    }

    private func openLog(_ d: HistoryDay) {
        store.go(.log, query: "", from: d.day, to: HistoryDay.dayEnd(d.day), title: d.shortTitle)
    }

    // MARK: an empty day (§3.6): the skip buttons
    private func empty(_ d: HistoryDay) -> some View {
        VStack(spacing: Space.loose) {
            EmptyState(symbol: d.isToday ? "sunrise" : "moon.zzz", text: d.isToday ? "Nothing yet today. Start a session on Home." : "Nothing recorded on \(d.shortTitle).")
            if !snapshot {
                HStack(spacing: Space.stack) {
                    if let p = Self.lastDayWithSessions(before: d.day, store: store) {
                        PillButton(text: "← last day with sessions · \(p.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))", kind: .neutral) { store.calendarDay = p }
                    }
                    if d.isToday { PillButton(text: "home ↗", kind: .accent) { store.go(.home) } }
                    else { PillButton(text: "today", kind: .accent) { store.calendarDay = today } }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, Space.card)
        .card(wash: true)
    }
}

/// Reads `\.narrow` where it is set — inside the host's geometry — for a block whose own environment never sees it.
private struct Narrow<Content: View>: View {
    @Environment(\.narrow) private var narrow
    @ViewBuilder let content: (Bool) -> Content
    var body: some View { content(narrow) }
}
