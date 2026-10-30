import SwiftUI

// PLAN_OBJECTIVES_TAB U2: a subject's page (Transcriber's `SubjectView`), the objective card (its `ItemCard`) and the objective editor.

/// What an objective's card and header say about the log.
struct ObjectiveFigures {
    var sessions = 0
    var seconds = 0
    var last: Date? = nil
    static let none = ObjectiveFigures()
    /// Figures per objective; `subject` nil → every objective (the Subjects tab's archived group). PLAN_SUBJECT_PROGRESS S0: from the
    /// Stats records the course levels on — tests out, focused seconds (minus away) — so a card, its course and Progress count alike.
    @MainActor static func all(subject: String? = nil, store: Store) -> [String: ObjectiveFigures] {
        var out: [String: ObjectiveFigures] = [:]
        let mine = subject.map { sid in Set(store.catalog.objectives.filter { $0.subjectId == sid }.map(\.id)) }
        for r in store.statsAll?.sessions ?? [] where !r.isTest {
            guard let oid = r.objectiveId, mine?.contains(oid) ?? true else { continue }
            out[oid, default: .none].sessions += 1; out[oid, default: .none].seconds += r.focusedSeconds
            if out[oid]!.last.map({ r.start > $0 }) ?? true { out[oid]!.last = r.start }
        }
        return out
    }
    var line: String {
        [ "\(sessions) session\(sessions == 1 ? "" : "s")",
          seconds >= 3600 ? String(format: "%.1f h", Double(seconds) / 3600) : seconds > 0 ? "\(max(1, seconds / 60)) min" : nil,
          last.map { relativeDate($0) } ].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A subject's page (PLAN_PLANNING §3.5, P3; was Transcriber's greeting + hero + masonry, §2.3): head = code · name · the collapsed
/// bio · one stats row; body = the objectives in three groups — Due soon · In progress · Later — then the completed behind a pill.
struct SubjectPage: View {
    @Environment(Store.self) private var store
    let subjectId: String
    @State private var editing = false
    @State private var newObjective = false
    @State private var openTally: Int64? = Int64(ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_TALLY_OPEN"] ?? "")   // F2: the session row opened to its tally
    @State private var showAllSessions = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_SESSIONS"] == "all"   // S2: every session, for a render

    /// The three groups (§3.5): due ≤ 7 days or overdue, nearest first · a session in the last 14 days, most recent first · the rest in catalogue order.
    struct Groups {
        var dueSoon: [Objective] = [], inProgress: [Objective] = [], later: [Objective] = []
        var filled: Int { [dueSoon, inProgress, later].filter { !$0.isEmpty }.count }
        @MainActor static func build(_ objectives: [Objective], figures: [String: ObjectiveFigures], store: Store, now: Date = Date()) -> Groups {
            var g = Groups()
            let recent = now.addingTimeInterval(-14 * 86400)
            for o in objectives {
                if store.dueState(o, now: now).isUrgent { g.dueSoon.append(o) }
                else if let l = figures[o.id]?.last, l >= recent { g.inProgress.append(o) }
                else { g.later.append(o) }
            }
            g.dueSoon.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            g.inProgress.sort { (figures[$0.id]?.last ?? .distantPast) > (figures[$1.id]?.last ?? .distantPast) }
            return g
        }
    }

    var body: some View {
        if let s = store.subject(subjectId) {
            let accent = Theme.accent(s.accent)
            let objectives = store.objectives(in: s.id)
            let archived = store.objectives(in: s.id, includeArchived: true).filter(\.archived)
            let figures = ObjectiveFigures.all(subject: s.id, store: store)
            let groups = Groups.build(objectives, figures: figures, store: store)
            Page(kicker: s.code ?? "Subject", title: s.shortName, trailing: AnyView(
                HStack(spacing: Space.stack) {
                    GlassActionPill(text: "new objective", symbol: "plus", tint: accent) { newObjective = true }
                    GlassActionPill(text: "edit subject", symbol: "slider.horizontal.3", tint: accent) { editing = true }
                }
            ), tint: accent, watermark: s.icon) {
                VStack(alignment: .leading, spacing: Space.section) {
                    head(s, accent: accent)
                    VStack(alignment: .leading, spacing: Space.stack) {
                        SectionHeader(1, "Objectives", note: objectives.isEmpty ? nil : "due soon · in progress · later", count: "\(objectives.count)")
                        if objectives.isEmpty {
                            EmptyState(symbol: s.icon, text: archived.isEmpty ? "No objectives in \(s.code ?? s.shortName) yet. Add one with the pill above." : "No open objectives in \(s.code ?? s.shortName). Add one with the pill above.").card(wash: true)
                        } else {
                            let single = groups.filled == 1   // one group → one plain list, no head
                            group("Due soon", groups.dueSoon, figures: figures, head: !single)
                            group("In progress", groups.inProgress, figures: figures, head: !single)
                            group("Later", groups.later, figures: figures, head: !single, hint: groups.later.count > 1 ? "drag a card onto another to reorder" : nil)
                        }
                        if !archived.isEmpty {   // PLAN_SUBJECT_PROGRESS S2 (§5a Q7): the completed ones, always shown, as rows — their time in minutes, never XP
                            HStack(spacing: Space.stack) { MonoLabel("Completed", color: Theme.ink2); MonoLabel("\(archived.count)", color: Theme.muted2) }
                                .padding(.top, Space.stack)
                            VStack(spacing: 0) {
                                ForEach(Array(archived.enumerated()), id: \.element.id) { i, o in
                                    if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                                    completedRow(o, figures: figures[o.id] ?? .none, accent: accent)
                                }
                            }
                            .card()
                        }
                    }
                    sessions(s, accent: accent)
                    trends(s, accent: accent)
                }
            }
            .sheet(isPresented: $editing) { SubjectEditor(existing: s).environment(store) }
            .sheet(isPresented: $newObjective) { ObjectiveEditor(existing: nil, subjectId: s.id).environment(store) }
        } else {
            EmptyState(symbol: "book", text: "This subject no longer exists.")
        }
    }

    /// One group: a small-caps head (when there is more than one group) and the cards in a masonry; nothing when empty.
    @ViewBuilder private func group(_ title: String, _ items: [Objective], figures: [String: ObjectiveFigures], head: Bool, hint: String? = nil) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: Space.stack) {
                if head || hint != nil {
                    HStack(spacing: Space.stack) {
                        if head { MonoLabel(title, color: Theme.ink2); MonoLabel("\(items.count)", color: Theme.muted2) }
                        if let hint { MonoLabel(hint, color: Theme.muted2) }
                    }
                    .padding(.top, head ? Space.stack : 0)
                }
                Masonry(minColumnWidth: 300) { ForEach(items) { o in ObjectiveCard(objective: o, figures: figures[o.id] ?? .none) } }
            }
        }
    }

    /// `✓ Research Proposal Presentation · completed 29 Oct · 2 sessions · 2 h 04 focused` (§3.3): what it took, in minutes; a click opens it.
    private func completedRow(_ o: Objective, figures f: ObjectiveFigures, accent: Color) -> some View {
        HStack(spacing: Space.loose) {
            Icon("checkmark.circle.fill", .row, color: accent).frame(width: 18)
            Text(o.title).font(Type.body).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: Space.stack)
            MonoLabel([o.completedLabel, f.sessions > 0 ? "\(f.sessions) session\(f.sessions == 1 ? "" : "s")" : nil, f.seconds > 0 ? Planning.short(f.seconds) + " focused" : nil].compactMap { $0 }.joined(separator: " · ")).fixedSize()
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { store.open(objective: o.id) }
        .help("Open \(o.title)")
    }

    private static let sessionDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM · HH:mm"; return f }()

    /// Section 2 (§3.4, S2): the course's latest sessions — when · objective · clean time (what XP is paid on) · the session score · the XP
    /// it earned; the latest 6, `show all` beyond (§5a Q6); a click opens the objective's pane and its study log. Nothing without sessions.
    @ViewBuilder private func sessions(_ s: Catalog.Subject, accent: Color) -> some View {
        let all = store.sessionRecords(in: s).sorted { $0.start > $1.start }
        if !all.isEmpty {
            let shown = showAllSessions ? all : Array(all.prefix(6))
            VStack(alignment: .leading, spacing: Space.stack) {
                SectionHeader(2, "Sessions", note: "the latest · clean time · score · what each earned the course", count: "\(all.count)")
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                        sessionRow(r, accent: accent)
                    }
                }
                .card()
                if all.count > 6 {
                    PillButton(text: showAllSessions ? "show the latest 6" : "show all \(all.count)", accent: accent) { showAllSessions.toggle() }
                }
            }
        }
    }

    /// Section 3 (S4, the user's word): the course's trends — weeks · when · pace; nothing without sessions.
    @ViewBuilder private func trends(_ s: Catalog.Subject, accent: Color) -> some View {
        let p = store.courseProgress(s)
        if p.sessions > 0 {
            VStack(alignment: .leading, spacing: Space.stack) {
                SectionHeader(3, "Trends", note: "the last 8 weeks · the hours · the pace")
                CourseTrends(progress: p, accent: accent, target: s.weeklyTargetMinutes)
            }
        }
    }

    /// `Wed 28 Oct · 21:27 · Homework #8 · 2 h 43 · 100 · +179 XP`
    private func sessionRow(_ r: SessionRecord, accent: Color) -> some View {
        let clean = XP.clean(seconds: r.focusedSeconds, pausedSeconds: 0, detourSeconds: r.detourSeconds, awaySeconds: 0)
        let losses = Tally.session(r)
        return VStack(alignment: .leading, spacing: Space.tight) {
        HStack(spacing: Space.loose) {
            Text(Self.sessionDay.string(from: r.start)).font(Type.data).foregroundStyle(Theme.muted2).frame(width: 130, alignment: .leading)
            Text(store.objective(r.objectiveId)?.title ?? r.goal).font(Type.body).foregroundStyle(Theme.ink).lineLimit(1)
            if r.live { Pill("in session", kind: .accent, dot: true, accent: accent) }
            Spacer(minLength: Space.stack)
            Text(Planning.short(clean * 60)).font(Type.strong).monospacedDigit().foregroundStyle(Theme.ink).frame(width: 64, alignment: .trailing)
            Button { withAnimation(.easeOut(duration: 0.2)) { openTally = openTally == r.id ? nil : r.id } } label: {
                Text(r.accuracyLabel ?? "\(r.score.total)").font(Type.strong).monospacedDigit().foregroundStyle(openTally == r.id ? Theme.ink : Theme.muted).frame(width: 84, alignment: .trailing)   // HUD6: accuracy · rank
            }
            .buttonStyle(.plain)
            .help((r.game.map { SessionGame.line(r.gameLosses, $0) } ?? Tally.line(losses, total: r.score.total)) + " · click to open")
            Text("+\(XP.earned(r)) XP").font(Type.data).monospacedDigit().foregroundStyle(accent).frame(width: 64, alignment: .trailing)
        }
        if openTally == r.id {   // F2 (PLAN_GAME_FEEL §3.2): the same arithmetic as the end card, one muted line
            Text(r.game.map { SessionGame.line(r.gameLosses, $0) } ?? Tally.line(losses, total: r.score.total)).font(Type.data).foregroundStyle(Theme.muted).lineLimit(2).padding(.leading, 130 + Space.loose)   // lint-ok: under the title column · HUD6: the game's line
        }
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { if let o = r.objectiveId { store.open(objective: o) } }
        .help("\(XP.earned(r)) XP · open the objective's study log")
    }

    /// The head (PLAN_SUBJECT_PROGRESS §3.1, S1): the collapsed bio, then the course's progress card — the stats row and the footnote
    /// bar it replaces said the week, the last session and the level a second time.
    private func head(_ s: Catalog.Subject, accent: Color) -> some View {
        let variants = s.code.map { Planning.codeVariants($0).map { $0.lowercased() } } ?? []
        let unsortedNaming = variants.isEmpty ? 0 : store.unsortedSessions.filter { r in !r.isTest && variants.contains { r.goal.lowercased().contains($0) } }.count
        let p = store.courseProgress(s)
        return VStack(alignment: .leading, spacing: Space.loose) {
            if !s.bio.isEmpty {
                BioText(text: s.bio, font: Type.body, accent: accent)   // markdown, collapsed to a few sentences (§5a Q10–Q11)
                    .frame(maxWidth: 720, alignment: .leading)          // S6: a readable measure, not the page's full width
            } else {
                HStack(spacing: Space.stack) {
                    Text("No bio yet.").font(Type.body).foregroundStyle(Theme.muted)
                    PillButton(text: "write one", kind: .accent, accent: accent) { editing = true }
                }
            }
            CourseProgressCards(progress: p, accent: accent, icon: s.icon, code: s.code ?? s.shortName, unsortedNaming: unsortedNaming)
                .padding(.top, Space.stack)   // S6: the band breathes below the bio
        }
        .padding(.top, Space.tight)
    }
}

/// The objective card (PLAN_PLANNING §3.5, P3; from Transcriber's `ItemCard`): icon · title · one figures line
/// `due Fri · 3 sessions · 2 h 10 of ~4 h · last yesterday` · the effort bar · `start` / `queue` · the bio in two lines · **no pills**
/// (kind and severity live in the card's help and on the pane). Completed cards keep the check, the `completed d MMM` label and 0.6 opacity.
struct ObjectiveCard: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    let objective: Objective
    var figures: ObjectiveFigures = .none
    private static let glyph: CGFloat = 26   // the icon's column; the figures line starts under the title
    @State private var hover = false
    @State private var editing = false
    @State private var confirmDelete = false

    var body: some View {
        let o = objective
        let accent = store.accent(of: o)
        let live = store.session?.objectiveId == o.id
        let due = store.dueState(o)
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack(alignment: .top, spacing: Space.stack) {
                // a completed objective wears a sage check in place of its icon (PLAN_OBJECTIVE_LIFECYCLE §3.3)
                Icon(o.isDone ? "checkmark.circle.fill" : o.icon, .card, color: o.isDone ? Theme.ok : accent).frame(width: Self.glyph)
                Text(o.title).font(Type.title).foregroundStyle(Theme.ink).lineLimit(2)
                Spacer()
                if live { Pill("in session", kind: .accent, dot: true, accent: accent) }
                else if store.session == nil, !o.isDone { startPill(o, accent: accent) }
            }
            // PLAN_SUBJECT_PROGRESS S2: the figures on one line, under the title and clear of the pill — the full form, else without `last`, else cut
            HStack(spacing: Space.tight) {
                if let d = due.label(due: o.due), !o.isDone { MonoLabel(d, color: due.isOverdue ? Theme.danger : due.isUrgent ? Theme.ink : Theme.muted); MonoLabel("·") }
                ViewThatFits(in: .horizontal) {
                    MonoLabel(line(o)).fixedSize()
                    MonoLabel(line(o, short: true)).fixedSize()
                    MonoLabel(line(o, short: true)).lineLimit(1).truncationMode(.tail)
                }
            }
            .padding(.leading, Self.glyph + Space.stack)
            .padding(.top, -Space.tight)
            if let e = store.effort(of: o), !o.isDone { EffortBar(fraction: e, tint: accent) }
            if !o.bio.isEmpty {
                BioText(text: o.bio, font: Type.body, lines: 3, accent: accent, longAfter: 140)   // S2: a few lines and `more`, never the whole bio
            }
        }
        .cardPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(accent: accent, watermark: o.icon, watermarkSize: 110, gradient: true, watermarkOpacity: hover ? 0.12 : nil)
        .opacity(o.isDone ? 0.6 : 1)   // greyed once completed (§3.3)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onTapGesture { store.open(objective: o.id) }
        .help("\(o.kind.rawValue) · \(o.severity.rawValue)" + (o.estimateMinutes.map { " · ~\(Planning.hours($0))" } ?? ""))   // the pills' words, on hover (§3.5)
        .modifier(ObjectiveCardLive(snapshot: snapshot, objective: o, accent: accent, edit: { editing = true }, confirmDelete: { confirmDelete = true }))
        .sheet(isPresented: $editing) { ObjectiveEditor(existing: o, subjectId: o.subjectId).environment(store) }
        .deleteObjectiveConfirm(o, isPresented: $confirmDelete)
    }

    /// `3 sessions · 2 h 10 of ~4 h · last yesterday` — parts present only when they exist; `completed 28 Oct` on a done card.
    private func line(_ o: Objective, short: Bool = false) -> String {
        var parts: [String] = []
        if let c = o.completedLabel { parts.append(c) }
        if figures.sessions > 0 { parts.append("\(figures.sessions) session\(figures.sessions == 1 ? "" : "s")") }
        if let e = store.effortLabel(of: o) { parts.append(e) }
        else if figures.seconds > 0 { parts.append(Planning.short(figures.seconds)) }
        if let l = figures.last { parts.append((short ? "" : "last ") + relativeDate(l)) }
        return parts.isEmpty ? "not started yet" : parts.joined(separator: " · ")
    }

    /// `queue` when nothing is queued (one click sets the Current Session widget), `queued` when this one is, `start` otherwise (§3.5).
    @ViewBuilder private func startPill(_ o: Objective, accent: Color) -> some View {
        if store.queued?.objective?.id == o.id { Pill("queued", kind: .neutral, dot: true, accent: accent) }
        else if store.queued == nil { PillButton(text: "queue", kind: .accent, accent: accent) { store.prepareSession(objective: o, source: "subject-page") } }
        else { PillButton(text: "start", kind: .accent, accent: accent) { store.startSession(objective: o, minutes: store.startMinutes(for: o)) } }
    }
}

/// Drag, context menu — live window only (ImageRenderer paints them yellow, U1 §6).
private struct ObjectiveCardLive: ViewModifier {
    @Environment(Store.self) private var store
    let snapshot: Bool
    let objective: Objective
    let accent: Color
    let edit: () -> Void
    let confirmDelete: () -> Void
    @State private var dropping = false
    /// Another objective dropped on this card lands just before it (U3); from another subject it moves here first.
    private func receive(_ ids: [String]) {
        let o = objective
        for d in ids.compactMap({ store.objective($0) }) where d.id != o.id {
            if d.subjectId != o.subjectId { store.saveObjective(id: d.id, subject: o.subjectId, title: d.title, bio: d.bio, icon: d.icon) }
            var order = store.objectives(in: o.subjectId, includeArchived: true).map(\.id); order.removeAll { $0 == d.id }
            order.insert(d.id, at: order.firstIndex(of: o.id) ?? order.count)
            store.reorderObjectives(order)
        }
    }
    func body(content: Content) -> some View {
        if snapshot { content }
        else {
            let o = objective
            content
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(accent, lineWidth: 2).opacity(dropping ? 1 : 0))
                .dropDestination(for: String.self) { ids, _ in receive(ids); return true } isTargeted: { dropping = $0 }
                .draggable(o.id) {
                    HStack(spacing: Space.stack) { Icon(o.icon, .row, color: accent); Text(o.title).font(Type.body).lineLimit(1) }
                        .rowPadding().background(Capsule().fill(Theme.paper)).overlay(Capsule().strokeBorder(accent, lineWidth: 1))
                }
                .contextMenu {
                    Button("Open") { store.open(objective: o.id) }
                    if store.session == nil { Button("Start session") { store.startSession(objective: o, minutes: store.startMinutes(for: o)) } }
                    Button("Edit…") { edit() }
                    Button(o.isDone ? "Reopen" : "Complete") { store.archiveObjective(o.id, !o.isDone) }
                    Menu("Move to") {
                        ForEach(store.subjects.filter { $0.id != o.subjectId }) { s in
                            Button(s.code ?? s.shortName) { store.saveObjective(id: o.id, subject: s.id, title: o.title, bio: o.bio, icon: o.icon); store.show("moved to \(s.code ?? s.shortName)") }
                        }
                    }
                    Divider()
                    Button("Delete objective…", role: .destructive) { confirmDelete() }
                }
        }
    }
}

/// Create or edit an objective (§3.4): icon · title · bio · kind and focus · subject; 560 × 520.
struct ObjectiveEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.snapshot) private var snapshot
    let existing: Objective?
    let subjectId: String
    @State private var title = ""
    @State private var bio = ""
    @State private var icon = "target"
    @State private var kind: SessionKind = .other
    @State private var severity: Strictness = .normal
    @State private var subject = ""
    @State private var confirmDelete = false
    // PLAN_PLANNING §3.1 (P0): the deadline (a day) and the effort budget
    @State private var due: Date? = nil
    @State private var estimate: Int = 0          // 0 = none

    var body: some View {
        let accent = Theme.accent(store.subject(subject)?.accent)
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: Space.card) {
                IconPicker(icon: icon, accent: accent, size: 64) { icon = $0 }
                VStack(alignment: .leading, spacing: Space.tight) {
                    MonoLabel(existing == nil ? "new objective in \(store.subject(subject)?.code ?? store.subject(subject)?.shortName ?? "")" : "edit objective", color: accent)
                    if snapshot { Text(title.isEmpty ? "e.g. research proposal draft" : title).font(Type.headline).foregroundStyle(title.isEmpty ? Theme.muted2 : Theme.ink) }
                    else { TextField("e.g. research proposal draft", text: $title).textFieldStyle(.plain).font(Type.headline).foregroundStyle(Theme.ink) }
                }
                Spacer()
            }
            .padding(.horizontal, Space.sheet).padding(.top, Space.sheet).padding(.bottom, Space.card)
            Divider().overlay(Theme.line)

            PageScroll {
                VStack(alignment: .leading, spacing: Space.sheet) {
                    section("Bio", note: "what it entails · shown on the card; the judge reads the title") {
                        if snapshot {
                            Text(bio.isEmpty ? "e.g. a two-page proposal: motivation, method, timeline, in LaTeX on Overleaf" : bio).font(Type.body).foregroundStyle(bio.isEmpty ? Theme.muted2 : Theme.ink)
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading).rowPadding().background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper2))
                        } else {
                            TextField("e.g. a two-page proposal: motivation, method, timeline, in LaTeX on Overleaf", text: $bio, axis: .vertical)
                                .textFieldStyle(.plain).font(Type.body).lineLimit(3...6)
                                .rowPadding().background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper2))
                        }
                    }
                    section("Kind and focus", note: "the session's sub-category · how hard the judge and the blocker press") {
                        VStack(alignment: .leading, spacing: Space.stack) {
                            HStack(spacing: Space.stack) {
                                IconChoice(symbol: "tag", tint: accent, options: SessionKind.allCases.map { ($0, $0.rawValue) }, selection: $kind, title: "Kind")
                                IconChoice(symbol: "shield.lefthalf.filled", tint: accent, options: Strictness.allCases.map { ($0, $0.rawValue) }, selection: $severity, title: "Focus")
                            }
                            Text(severity.blurb).font(Type.body).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    section("Due and estimate", note: "a deadline sorts it first · the budget draws the effort bar") {   // P0 (§3.1)
                        HStack(spacing: Space.stack) {
                            DueRow(due: $due, accent: accent)
                            IconChoice(symbol: "hourglass", tint: accent, options: [(0, "no estimate")] + Planning.estimateOptions.map { ($0, "~\(Planning.hours($0))") }, selection: $estimate, title: "Estimate")
                        }
                    }
                    section("Subject", note: "move it to another subject") {
                        IconChoice(symbol: store.subject(subject)?.icon ?? "book", tint: accent, options: store.subjects.map { ($0.id, $0.code ?? $0.shortName) }, selection: $subject, title: "Subject")
                    }
                }
                .padding(.horizontal, Space.sheet).padding(.vertical, Space.sheet)
            }

            Divider().overlay(Theme.line)
            HStack(spacing: Space.stack) {
                if let o = existing {
                    PillButton(text: "delete objective…", kind: .danger) { confirmDelete = true }
                    PillButton(text: o.isDone ? "reopen" : "complete") { store.archiveObjective(o.id, !o.isDone); dismiss() }
                }
                Spacer()
                ActionButton(title: "Cancel", ghost: true) { dismiss() }
                ActionButton(title: existing == nil ? "Create" : "Save", symbol: "checkmark", accent: true) {
                    guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { store.fail("an objective needs a title"); return }
                    store.saveObjective(id: existing?.id, subject: subject, title: title.trimmingCharacters(in: .whitespaces), bio: bio, icon: icon, kind: kind, severity: severity,
                                        due: .some(due), estimateMinutes: .some(estimate == 0 ? nil : estimate))   // P0
                    store.show(existing == nil ? "objective created" : "objective saved")
                    dismiss()
                }
            }
            .padding(.horizontal, Space.sheet).padding(.vertical, Space.card)
        }
        .frame(width: 560, height: 520)
        .background(Theme.bg)
        .modifier(EditorDeleteConfirm(existing: existing, isPresented: $confirmDelete, dismiss: { dismiss() }))
        .onAppear {
            subject = subjectId
            if let o = existing { title = o.title; bio = o.bio; icon = o.icon; kind = o.kind; severity = o.severity; subject = o.subjectId; due = o.due; estimate = o.estimateMinutes ?? 0 }
            else { icon = store.subject(subjectId)?.icon ?? "target"; severity = store.settings.defaultStrictness }
        }
    }

    private func section<C: View>(_ title: String, note: String? = nil, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
                Text(title).font(Type.strong).foregroundStyle(Theme.ink)
                if let note { MonoLabel(note) }
                Spacer()
            }
            content()
        }
    }
}

/// The due-date control (PLAN_PLANNING §3.1, P0): a `none` pill, or the day in a `.field` DatePicker with a clear pill; in a
/// snapshot a text stand-in (ImageRenderer paints pickers yellow, U1 §6). The day is stored at 23:59 by `saveObjective`.
struct DueRow: View {
    @Binding var due: Date?
    var accent: Color = Theme.accent
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        HStack(spacing: Space.stack) {
            if let d = due {
                if snapshot { Pill("due " + Planning.dayFormat.string(from: d), kind: .accent, accent: accent) }
                else {
                    HStack(spacing: Space.tight) {
                        Icon("calendar", .small, color: accent)
                        DatePicker("", selection: Binding(get: { d }, set: { due = Planning.dueDate(forDay: $0) }), displayedComponents: .date)
                            .datePickerStyle(.field).labelsHidden().font(Type.body)
                    }
                    PillButton(text: "clear") { due = nil }
                }
            } else {
                PillButton(text: "no due date · set", kind: .neutral) { due = Planning.dueDate(forDay: Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()) }
                    .help("Set a deadline; it starts a week out")
            }
        }
    }
}

extension Catalog.Objective {
    /// The length a start pill uses (§5a Q7): the remembered one, else the Settings default; 0 means "until I stop" → nil.
    /// PLAN_PLANNING Q4.9 (P0): with nothing remembered (nil or 0) and an `average` of the real sessions, the average — `store.startMinutes(for:)` passes it.
    func startMinutes(_ settings: AppSettings, average: Int? = nil) -> Int? {
        if let m = lastMinutes, m > 0 { return m }
        if let a = average { return a }
        let m = settings.defaultMinutes; return m == 0 ? nil : m
    }
}

/// The editor's delete goes through the same confirmation as the card and the pane (PLAN_OBJECTIVE_LIFECYCLE §3.4).
private struct EditorDeleteConfirm: ViewModifier {
    let existing: Objective?
    @Binding var isPresented: Bool
    let dismiss: () -> Void
    func body(content: Content) -> some View {
        if let o = existing { content.deleteObjectiveConfirm(o, isPresented: $isPresented, after: dismiss) } else { content }
    }
}
