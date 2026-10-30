import SwiftUI

/// One card's worth of Home's "Jump back in" row (PLAN_JUMP_BACK_IN §3.4): the objective, its subject and the log's figures.
/// Built once per log change (like Home's `objectiveRows`), never per tick.
struct JumpBackInRow: Identifiable, Equatable {
    let objective: Objective
    let subject: Catalog.Subject?
    let lastStarted: Date?
    let sessions: Int
    let weekSeconds: Int
    // PLAN_PLANNING P1/P2: the deadline's state, `spent ÷ estimate` (nil without an estimate), a planned block later today under the subject
    var due: DueState = .none
    var effort: Double? = nil
    var planned: DayModel.Planned? = nil
    var id: String { objective.id }
    var started: Bool { sessions > 0 }

    @MainActor static func build(store: Store, now: Date = Date()) -> [JumpBackInRow] {
        let objectives = store.catalog.objectives.map { JumpBackInOrder.ObjectiveIn(id: $0.id, subjectId: $0.subjectId, sort: $0.sort, archived: $0.archived, due: $0.due) }
        // The one time rule (PLAN_SUBJECT_PROGRESS): tests out, focused seconds — so the card agrees with the course page and Progress.
        let sessions = (store.statsAll?.sessions ?? []).filter { !$0.isTest }.map { JumpBackInOrder.SessionIn(objectiveId: $0.objectiveId, started: $0.start, seconds: $0.focusedSeconds) }
        let figures = JumpBackInOrder.rows(objectives: objectives, subjectOrder: store.subjects.map(\.id), sessions: sessions, live: store.session?.objectiveId, now: now)
        let planned = store.plannedBlocks(day: now).filter { $0.start > now }   // P2: the next planned block per subject
        return figures.compactMap { f in
            guard let o = store.objective(f.objectiveId) else { return nil }
            return JumpBackInRow(objective: o, subject: store.subject(o.subjectId), lastStarted: f.lastStarted, sessions: f.sessions, weekSeconds: f.weekSeconds,
                                 due: store.dueState(o, now: now), effort: store.effort(of: o),
                                 planned: planned.first { $0.objectiveId == o.id } ?? planned.first { $0.subjectId == o.subjectId && $0.objectiveId == nil })
        }
    }
}

/// The row (§3.2): a bare `Panel` holding a wrapping grid of `JumpCard`s, newest first; six at most (three when narrow), then `all N ↗`.
/// Home draws it only when there is at least one row (§3.6: with no live objectives nothing is drawn).
struct JumpBackInWidget: View {
    @Environment(Store.self) private var store
    @Environment(\.narrow) private var narrow
    let rows: [JumpBackInRow]

    var body: some View {
        let cap = narrow ? 3 : 6
        let shown = Array(rows.prefix(cap))
        let started = rows.filter(\.started).count
        let n = rows.count
        let note = started == 0 ? "\(n) objective\(n == 1 ? "" : "s") · none started yet" : "\(n) objective\(n == 1 ? "" : "s") · most recent first"
        let subjects = Screen(rawValue: "subjects")
        let door: AnyView? = subjects.map { s in AnyView(PillButton(text: n > cap ? "all \(n) ↗" : "objectives ↗", kind: .accent) { store.go(s) }) }
        Panel(title: "Jump back in", note: note, trailing: door, bare: true) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: Space.card, alignment: .top)], alignment: .leading, spacing: Space.card) {
                ForEach(shown) { r in JumpCard(row: r) }
                // M3 (PLAN_STRUCTURE §3.4): the `+ new in <subject>` ghost tile is the grid's last cell — the Session card's idle grid is gone.
                if let s = shown.last?.subject ?? store.subjects.first, store.session == nil {
                    NewObjectiveButton(subject: s.id, minutes: store.queued?.minutes, strictness: store.queued?.strictness ?? store.settings.defaultStrictness, tint: nil, help: "New objective in \(s.shortName)",
                                       onCreated: { o, exit in if exit == .start { store.startSession(objective: o, minutes: store.queued?.minutes) } else { store.prepareSession(objective: o, source: "new-objective") } }) {
                        // One dashed card the height of its neighbours (2026-10-29: the tile's own dashed frame inside a second dashed frame "looks weird").
                        VStack(spacing: Space.stack) {
                            Icon("plus", .row, color: Theme.muted2)
                            Text("New objective").font(Type.strong).foregroundStyle(Theme.muted)
                            MonoLabel("in \(s.code ?? s.shortName)", color: Theme.muted2)
                        }
                        .cardPadding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                        .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    }
                }
            }
        }
    }
}

/// One card (§3.3), `ObjectiveCard`'s look minus the pills: glyph · title · subject dot + code · two-line bio · hairline · `last` and `this week`.
/// Home's palette rule: the subject colour only as the glyph tint, the dot, the hairline, the watermark and the card's 0.5 border.
/// The deck slivers of §5a Q1 were dropped on 2026-10-28 (PLAN_DESIGN_CLEANUP §6 G1: "why are these a stack of cards" → "Drop the slivers"). Click → `prepareSession` (§3.5); during a session → the objective pane.
struct JumpCard: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    let row: JumpBackInRow
    @State private var hover = false
    @State private var editing = false

    private var o: Objective { row.objective }
    private var accent: Color { store.accent(of: o) }
    private var live: Bool { store.session?.objectiveId == o.id }
    private var dimmed: Bool { store.session != nil && !live }
    private var queued: Bool { store.queued?.objective?.id == o.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack(alignment: .top, spacing: Space.stack) {
                Icon(o.icon, .card, color: accent).frame(width: 26)
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(o.title).font(Type.title).foregroundStyle(Theme.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    // J3: the status rides on the subject line, not the title row, so a long title keeps its two lines.
                    HStack(spacing: Space.tight) {
                        Circle().fill(accent).frame(width: 6, height: 6)
                        MonoLabel(row.subject.map { $0.code ?? $0.shortName } ?? "no subject")
                        if live { MonoLabel("· in session", color: Theme.ink) }
                        else if queued { MonoLabel("· queued", color: Theme.ink) }
                        if let d = row.due.label(due: o.due), row.due.isUrgent { DueChip(text: d, overdue: row.due.isOverdue).padding(.leading, Space.tight) }   // P1 (§3.2)
                    }
                }
                Spacer(minLength: 0)
            }
            if !o.bio.isEmpty {
                Text(BioMarkdown.inline(BioMarkdown.summary(o.bio))).font(Type.body).foregroundStyle(Theme.ink2).lineSpacing(Space.hair).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let e = row.effort { EffortBar(fraction: e, tint: accent) }   // P1 (§3.2): spent ÷ estimate, only with an estimate
            Rectangle().fill(accent.opacity(0.25)).frame(height: 1)
            // G1 (§3.4): one label that fits — `last yesterday 11:06 PM · 51 min this week` — instead of two columns that truncated.
            // P2 (§3.3): `planned 19:30 · 60 min` when the subject has a planned block later today.
            let plannedLine = row.planned.map { " · planned \(clock($0.start)) · \(Int($0.end.timeIntervalSince($0.start) / 60)) min" } ?? ""
            if row.started {
                MonoLabel("last \(lastLine)" + (row.weekSeconds > 0 ? " · \(minutes(Double(row.weekSeconds))) this week" : " · none this week") + plannedLine).lineLimit(1)
            } else {
                MonoLabel("not started yet" + plannedLine, color: Theme.muted2).lineLimit(1)
            }
        }
        .cardPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(accent: accent, watermark: o.icon, watermarkSize: 110, watermarkOpacity: !row.started ? 0.05 : hover ? 0.12 : 0.07)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(accent.opacity(queued ? 1 : hover ? 0.6 : 0), lineWidth: queued ? 1.5 : 1))
        .offset(y: hover && !dimmed ? -2 : 0)
        .opacity(dimmed ? 0.55 : 1)
        .animation(.easeOut(duration: 0.15), value: hover)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { click() }
        .modifier(JumpCardLive(snapshot: snapshot, objective: o, edit: { editing = true }))
        .sheet(isPresented: $editing) { ObjectiveEditor(existing: o, subjectId: o.subjectId).environment(store) }
    }

    /// `8:04 PM today` · `yesterday 8:04 PM` · else the relative date ("3 days ago").
    private var lastLine: String {
        guard let d = row.lastStarted else { return "—" }
        if StudyDay.isToday(d) { return "\(clock(d)) today" }          // K1: the study day
        if StudyDay.isYesterday(d) { return "yesterday \(clock(d))" }
        return relativeDate(d)
    }

    /// §3.5: queue it; the queued card again clears; during a session the click opens the objective instead.
    private func click() {
        if store.session != nil { store.open(objective: o.id); return }
        if queued { store.clearQueued() } else { store.prepareSession(objective: o, source: "jump-back-in") }
    }
}

/// The due chip (PLAN_PLANNING §3.2, P1): an ink outline with the word, the text in `danger` when overdue — never a coloured pill.
struct DueChip: View {
    let text: String
    var overdue = false
    var body: some View {
        Text(text.uppercased()).font(Type.pill).tracking(Type.pillTracking).lineLimit(1)
            .foregroundStyle(overdue ? Theme.danger : Theme.ink)
            .padding(.horizontal, Space.tight).padding(.vertical, Space.hair)
            .overlay(Capsule().strokeBorder(overdue ? Theme.danger.opacity(0.6) : Theme.line2, lineWidth: 1))
    }
}

/// The effort bar (§3.2): 3 pt, the tint at 0.4 over `ghost`, `spent ÷ estimate`.
struct EffortBar: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ghost)
                Capsule().fill(tint.opacity(0.4)).frame(width: max(3, g.size.width * CGFloat(min(1, max(0, fraction)))))
            }
        }
        .frame(height: 3)
        .help(String(format: "%.0f %% of the estimate spent", fraction * 100))
    }
}

/// Context menu, live window only (`ImageRenderer` paints it as a yellow box, PLAN_OBJECTIVES_TAB U1 §6).
private struct JumpCardLive: ViewModifier {
    @Environment(Store.self) private var store
    let snapshot: Bool
    let objective: Objective
    let edit: () -> Void
    func body(content: Content) -> some View {
        if snapshot { content }
        else {
            content.contextMenu {
                Button("Open") { store.open(objective: objective.id) }
                if store.session == nil { Button("Start now") { store.startSession(objective: objective, minutes: store.startMinutes(for: objective)) } }
                Button("Edit…") { edit() }
            }
        }
    }
}
