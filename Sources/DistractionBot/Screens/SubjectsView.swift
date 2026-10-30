import SwiftUI

/// The Subjects tab (PLAN_OBJECTIVES_TAB §3.1): Transcriber's subject grid as a tab of its own, the create tile, the editor as a sheet.
struct SubjectsView: View {
    @Environment(Store.self) private var store
    @State private var newSubject = false
    @State private var showAllUnsorted = false
    @State private var showUnsorted = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_UNSORTED"] == "open"   // P4: the inbox is collapsed by default
    @State private var showArchived = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_COMPLETED"] == "open"
    @State private var tick = 0          // bumped after filing a session: the inbox reads the log, not observable state

    var body: some View {
        let _ = tick
        let figures = SubjectFigures.all(store: store)
        let unsorted = UnsortedGroup.build(store.unsortedSessions.filter { $0.id != store.session?.id && $0.endedBy != "live" })
        let archived = store.catalog.objectives.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }   // newest completion first
        let archivedFigures = archived.isEmpty ? [:] : ObjectiveFigures.all(store: store)
        Page(kicker: "subjects · objectives", title: "Subjects", trailing: AnyView(GlassActionPill(text: "new subject", symbol: "plus") { newSubject = true })) {
            VStack(alignment: .leading, spacing: Space.stack) {
                SectionHeader(1, "Subjects", note: "a course or a project · objectives live under it", count: "\(store.subjects.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 360), spacing: Space.card)], spacing: Space.card) {
                    ForEach(store.subjects) { s in SubjectCard(subject: s, figures: figures[s.id] ?? .none) }
                    Button { newSubject = true } label: {
                        VStack(spacing: Space.stack) {
                            Icon("plus", .card, color: Theme.accent)
                            MonoLabel("create a subject", color: Theme.accent)
                        }
                        .frame(maxWidth: .infinity, minHeight: 96)
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCell, style: .continuous).strokeBorder(Theme.line2, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    }.buttonStyle(.plain)
                }
            }
            // 2 · Completed objectives, collapsed behind a pill (PLAN_OBJECTIVE_LIFECYCLE §3.3; was "archived").
            if !archived.isEmpty {
                VStack(alignment: .leading, spacing: Space.stack) {
                    SectionHeader(2, "Completed objectives", note: "done · still open for their record · reopen from a card's menu", count: "\(archived.count)") {
                        PillButton(text: showArchived ? "hide completed" : "show \(archived.count) completed") { showArchived.toggle() }
                    }
                    if showArchived {
                        Masonry(minColumnWidth: 300) { ForEach(archived) { o in ObjectiveCard(objective: o, figures: archivedFigures[o.id] ?? .none) } }
                    }
                }
            }
            // 3 · Unsorted sessions (U3, from O2's records): Transcriber's Inbox — one card per goal in a masonry, the `✓ file under <objective>`
            // pill when O2's guess scores. PLAN_PLANNING §3.7 (P4, Q5.3): at the bottom, behind a `N unsorted sessions` pill, collapsed by
            // default; `dismiss as tests` files the B-phase groups and the sub-2-minute groups under the hidden id `tests` (one undo toast).
            if !unsorted.isEmpty {
                let shown = showAllUnsorted ? unsorted : Array(unsorted.prefix(6))
                let suggested = unsorted.compactMap { g in store.suggestObjective(for: g.goal).map { (g, $0) } }
                let count = unsorted.reduce(0) { $0 + $1.sessions.count }
                let tests = unsorted.filter { g in Planning.isTestGoal(g.goal) || g.sessions.allSatisfy { $0.seconds < 120 } }.reduce(0) { $0 + $1.sessions.count }
                VStack(alignment: .leading, spacing: Space.stack) {
                    SectionHeader(archived.isEmpty ? 2 : 3, "Unsorted sessions", note: "free-text goals · file each under an objective") {
                        HStack(spacing: Space.stack) {
                            if showUnsorted {
                                if suggested.count > 1 {
                                    PillButton(text: "✓ file all \(suggested.count) suggested", kind: .accent) {
                                        for (g, o) in suggested { for r in g.sessions { EventLog.shared.fileSession(r.id, under: o.id) } }
                                        store.reloadLog(); store.show("\(suggested.reduce(0) { $0 + $1.0.sessions.count }) sessions filed"); tick += 1
                                    }
                                }
                                if tests > 0 { PillButton(text: "dismiss \(tests) as tests", kind: .neutral) { store.dismissTests(unsorted); tick += 1 }.help("B-phase goals and groups of sub-2-minute sessions leave the inbox; the toast undoes it") }
                                if unsorted.count > 6 { PillButton(text: showAllUnsorted ? "show fewer" : "show all \(unsorted.count) goals") { showAllUnsorted.toggle() } }
                            }
                            PillButton(text: showUnsorted ? "hide" : "\(count) unsorted session\(count == 1 ? "" : "s") ▾") { showUnsorted.toggle() }
                        }
                    }
                    if showUnsorted {
                        Masonry(minColumnWidth: 300) { ForEach(shown) { g in UnsortedCard(group: g) { tick += 1 } } }
                    }
                }
            }
        }
        .sheet(isPresented: $newSubject) { SubjectEditor(existing: nil).environment(store) }
    }
}

/// What a subject card and a subject page say about the log: objectives, focused seconds, the last session; P3 (PLAN_PLANNING §3.4):
/// this week's seconds, the nearest due objective, when it was last worked.
struct SubjectFigures {
    var objectives = 0
    var sessions = 0
    var seconds = 0
    var last: Date? = nil
    var weekSeconds = 0
    var nextDue: Objective? = nil
    var dueSoon = 0                      // open objectives due within 7 days or overdue
    var lastWorked: Date? { last }
    static let none = SubjectFigures()
    /// One pass over the sessions, grouped by subject through the catalogue. PLAN_SUBJECT_PROGRESS S1: the Stats records the course
    /// levels on (tests out, focused seconds), so the card's week line agrees with the course page and Progress.
    @MainActor static func all(store: Store, now: Date = Date()) -> [String: SubjectFigures] {
        var out: [String: SubjectFigures] = [:]
        for s in store.catalog.subjects {
            let open = store.objectives(in: s.id)
            out[s.id] = SubjectFigures(objectives: open.count, nextDue: store.nextDue(in: s.id, now: now), dueSoon: open.filter { store.dueState($0, now: now).isUrgent }.count)
        }
        let bySubject = Dictionary(uniqueKeysWithValues: store.catalog.objectives.map { ($0.id, $0.subjectId) })
        let week = Planning.weekStart(now)
        for r in store.statsAll?.sessions ?? [] where !r.isTest {
            guard let oid = r.objectiveId, let sid = bySubject[oid], out[sid] != nil else { continue }
            out[sid]!.sessions += 1; out[sid]!.seconds += r.focusedSeconds
            if StudyDay.start(of: r.start) >= week { out[sid]!.weekSeconds += r.focusedSeconds }
            if out[sid]!.last.map({ r.start > $0 }) ?? true { out[sid]!.last = r.start }
        }
        return out
    }
    /// The tile's one label (kept for the sidebar's help text): objectives · focused time.
    var line: String {
        [ "\(objectives) objective\(objectives == 1 ? "" : "s")",
          seconds >= 3600 ? String(format: "%.1f h", Double(seconds) / 3600) : seconds > 0 ? "\(max(1, seconds / 60)) min" : nil ].compactMap { $0 }.joined(separator: " · ")
    }
    /// Line 1 (§3.4): `3 h 10 this week · of 6 h` — `3 h 10 this week` alone with no target; `nothing this week` with none.
    func weekLine(target: Int?) -> String {
        let week = weekSeconds > 0 ? "\(Planning.short(weekSeconds)) this week" : "nothing yet this week"
        return target.map { "\(week) · of \(Planning.hours($0))" } ?? week
    }
    /// Line 2 (§3.4): `Homework #8 · due Fri` (the `next ·` prefix of the plan dropped: it truncated the title on a 230-pt card, rendered 2026-10-29) ·
    /// `last worked yesterday` · `no objectives yet`.
    @MainActor func nextLine(store: Store, now: Date = Date()) -> String {
        if let o = nextDue { return o.title + (store.dueState(o, now: now).label(due: o.due).map { " · \($0)" } ?? "") }
        if objectives == 0 { return "no objectives yet" }
        if let l = last { return "last worked \(relativeDate(l))" }
        return "\(objectives) objective\(objectives == 1 ? "" : "s") · none started"
    }
    /// `weekSeconds ÷ target`, clamped; nil without a target.
    func ring(target: Int?) -> Double? { target.flatMap { $0 > 0 ? min(1, Double(weekSeconds) / 60 / Double($0)) : nil } }
}

/// Unsorted sessions that share a goal word for word (the log had 11 alike): one row, filed together.
struct UnsortedGroup: Identifiable {
    let goal: String
    let sessions: [ObjectiveSession]      // newest first
    var id: String { sessions[0].id }
    var latest: Date { sessions[0].started }
    var seconds: Int { sessions.reduce(0) { $0 + $1.seconds } }
    static func build(_ rows: [ObjectiveSession]) -> [UnsortedGroup] {
        var byGoal: [String: [ObjectiveSession]] = [:]
        for r in rows { byGoal[r.goal.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), default: []].append(r) }
        return byGoal.values.map { UnsortedGroup(goal: $0[0].goal, sessions: $0.sorted { $0.started > $1.started }) }.sorted { $0.latest > $1.latest }
    }
}

/// One inbox card, redesigned in G2 on the user's "too chaotic" (PLAN_DESIGN_CLEANUP §6 G2): one hierarchy — icon · goal at
/// `title` · one muted meta line (`40 min · 15 hr. ago · 13 sessions · normal`) · one short sentence on what the meta line
/// does not say (how they ended, what was caught) · one `file under ▾` menu, with the suggested objective named beside it
/// as a dot and its subject code. The watermark, gradient and accent stay. Padding 16, stack 8.
private struct UnsortedCard: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    let group: UnsortedGroup
    let filed: () -> Void
    @State private var hover = false

    var body: some View {
        let g = group; let r = g.sessions[0]
        let suggestion = store.suggestObjective(for: g.goal)
        let accent = suggestion.map { store.accent(of: $0) } ?? Theme.accent
        let icon = suggestion?.icon ?? "timer"
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack(alignment: .top, spacing: Space.stack) {
                Icon(icon, .card, color: accent).frame(width: 26)
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text(g.goal.isEmpty ? "(no goal)" : g.goal).font(Type.title).foregroundStyle(Theme.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    MonoLabel([length(g.seconds), relativeDate(g.latest), g.sessions.count > 1 ? "\(g.sessions.count) sessions" : nil, r.strictness, r.kind].compactMap { $0 }.joined(separator: " · "))
                }
                Spacer(minLength: 0)
            }
            Text(summary).font(Type.body).foregroundStyle(Theme.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.stack) {
                fileMenu(suggestion: suggestion, accent: accent)
                if let o = suggestion, let s = store.subject(o.subjectId) {
                    HStack(spacing: Space.tight) { Circle().fill(accent).frame(width: 6, height: 6); MonoLabel("\(s.code ?? s.shortName) · suggested") }.lineLimit(1)
                } else {
                    MonoLabel("no match yet", color: Theme.muted2)
                }
                Spacer(minLength: 0)
            }
        }
        .cardPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(accent: accent, watermark: icon, watermarkSize: 110, gradient: true, watermarkOpacity: hover ? 0.12 : nil)
        .onHover { hover = $0 }
        .modifier(LiveOnly(snapshot: snapshot, drop: { _ in }, targeted: { _ in }, menu: {
            if let o = suggestion { Button("File under \(o.title)") { file(o) } }
            Menu("File under") { fileItems }
        }))
    }

    /// One sentence on what the meta line does not say: how the sessions ended and what was caught.
    private var summary: String {
        let g = group
        let warnings = g.sessions.reduce(0) { $0 + $1.warnings }, blocks = g.sessions.reduce(0) { $0 + $1.blocks }
        let endings = Dictionary(grouping: g.sessions, by: \.endedBy).max { $0.value.count < $1.value.count }!.key
        let first = (g.sessions.count == 1 ? ending(endings) : "Most " + ending(endings)).prefix(1).uppercased() + (g.sessions.count == 1 ? ending(endings) : "Most " + ending(endings)).dropFirst() + "."
        let trouble = [warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil, blocks > 0 ? "\(blocks) block\(blocks == 1 ? "" : "s")" : nil].compactMap { $0 }
        return trouble.isEmpty ? first + " Nothing caught." : first + " " + trouble.joined(separator: " and ").prefix(1).uppercased() + trouble.joined(separator: " and ").dropFirst() + "."
    }
    private func ending(_ e: String) -> String {
        switch e { case "finished": return "ran to the end"; case "ended": return "ended early"; case "quit": return "cut off when the app quit"; case "live": return "still running"; default: return "ended by \(e)" }
    }
    private func length(_ s: Int) -> String { s >= 3600 ? String(format: "%.1f h", Double(s) / 3600) : s >= 60 ? "\(s / 60) min" : "\(max(1, s)) s" }
    private func file(_ o: Objective) {
        for r in group.sessions { EventLog.shared.fileSession(r.id, under: o.id) }
        store.reloadLog()
        store.show(group.sessions.count == 1 ? "filed under \(o.title)" : "\(group.sessions.count) sessions filed under \(o.title)")
        filed()
    }
    @ViewBuilder private var fileItems: some View {
        ForEach(store.subjects) { s in
            let os = store.objectives(in: s.id)
            if !os.isEmpty { Menu(s.code ?? s.shortName) { ForEach(os) { o in Button(o.title) { file(o) } } } }
        }
    }
    /// The one control: a pill menu in the `PillMenu` recipe (`.menuStyle(.button)` · `.buttonStyle(.plain)` · `.menuIndicator(.hidden)`),
    /// the suggestion as its first row. Accent when there is a suggestion, neutral when not; never truncated — its text is fixed.
    @ViewBuilder private func fileMenu(suggestion: Objective?, accent: Color) -> some View {
        let label = Pill(suggestion == nil ? "file under ▾" : "✓ file under ▾", kind: suggestion == nil ? .neutral : .accent, accent: accent)
        if snapshot { label }
        else {
            Menu {
                if let o = suggestion { Button("✓ \(o.title) · suggested") { file(o) }; Divider() }
                fileItems
            } label: { label.contentShape(Capsule()) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }
}

/// Subject card (Transcriber's `SubjectCard`, §2.2): solid accent icon tile, code band, name, counts. Drop target for objectives.
struct SubjectCard: View {
    @Environment(Store.self) private var store
    let subject: Catalog.Subject
    var figures: SubjectFigures = .none
    @State private var hover = false
    @State private var dropping = false
    @State private var editing = false
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        let accent = Theme.accent(subject.accent)
        let live = store.session?.subjectId == subject.id
        card(accent: accent, live: live)
            .modifier(LiveOnly(snapshot: snapshot, drag: "subject:" + subject.id, preview: AnyView(dragPreview(accent)), drop: { ids in
                // a subject card dropped here → reorder before this one (U3); objective ids → move them under this subject
                if let other = ids.first(where: { $0.hasPrefix("subject:") }).map({ String($0.dropFirst(8)) }) {
                    guard other != subject.id else { return }
                    var order = store.subjects.map(\.id); order.removeAll { $0 == other }
                    order.insert(other, at: order.firstIndex(of: subject.id) ?? order.count)
                    store.reorderSubjects(order); return
                }
                let moved = ids.compactMap { store.objective($0) }.filter { $0.subjectId != subject.id }
                for o in moved { store.saveObjective(id: o.id, subject: subject.id, title: o.title, bio: o.bio, icon: o.icon) }
                if !moved.isEmpty { store.show(moved.count == 1 ? "moved to \(subject.code ?? subject.shortName)" : "moved \(moved.count) objectives") }
            }, targeted: { dropping = $0 }, menu: {
                Button("Open") { store.open(subject: subject.id) }
                Button("Edit subject…") { editing = true }
                Button("Delete subject", role: .destructive) { store.deleteSubject(subject.id); store.show("subject deleted") }
            }))
            .sheet(isPresented: $editing) { SubjectEditor(existing: subject).environment(store) }
    }

    private func dragPreview(_ accent: Color) -> some View {
        HStack(spacing: Space.stack) { Icon(subject.icon, .row, color: accent); Text(subject.code ?? subject.shortName).font(Type.body).lineLimit(1) }
            .rowPadding().background(Capsule().fill(Theme.paper)).overlay(Capsule().strokeBorder(accent, lineWidth: 1))
    }

    private func card(accent: Color, live: Bool) -> some View {
        HStack(spacing: 0) {
            // accent tile
            VStack {
                Glyph(icon: subject.icon, size: 22, color: .white).shadow(color: .black.opacity(0.35), radius: 3)
            }
            .frame(width: 64)
            .frame(maxHeight: .infinity)
            .background(LinearGradient(colors: [accent, accent.opacity(0.78)], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack {
                    if let c = subject.code { MonoLabel(c, color: accent) }
                    Spacer()
                    if live { Circle().fill(accent).frame(width: 6, height: 6) }
                }
                Text(subject.shortName).font(Type.title).foregroundStyle(Theme.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                // P3 (PLAN_PLANNING §3.4): two lines and a ring — the week against the target, then what is next
                HStack(spacing: Space.tight) {
                    MonoLabel(figures.weekLine(target: subject.weeklyTargetMinutes)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let r = figures.ring(target: subject.weeklyTargetMinutes) { TargetRing(fraction: r, tint: accent, size: 14) }
                }
                MonoLabel(figures.nextLine(store: store), color: figures.nextDue.map { store.dueState($0).isOverdue } == true ? Theme.danger : Theme.muted).lineLimit(1).truncationMode(.tail)
                    .help(figures.nextDue == nil ? "" : "next up in this subject")
                // G1 (PLAN_GAME_LOOP §3.1): the course's level as a 2-pt bar under the lines, `L2` at its end
                let lv = store.courseLevel(subject)
                HStack(spacing: Space.stack) {
                    LevelBar(level: lv.level, into: lv.into, tint: accent, mini: true)
                    MonoLabel("L\(lv.level)", color: Theme.muted2)
                }
                .padding(.top, Space.tight)
                .help(store.courseLabel(subject))
            }
            .padding(.horizontal, Space.card).padding(.vertical, Space.loose)
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(alignment: .bottomTrailing) { Watermark(symbol: subject.icon, size: 96, color: accent, opacity: hover ? 0.14 : 0.08).offset(x: 10, y: 18) }
        .background(RoundedRectangle(cornerRadius: Theme.radiusCell, style: .continuous).fill(Theme.paper))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCell, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusCell, style: .continuous).strokeBorder(dropping ? accent : hover ? accent.opacity(0.6) : Theme.line, lineWidth: dropping ? 2 : 1))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onTapGesture { store.open(subject: subject.id) }
    }
}

/// The week ring (PLAN_PLANNING §3.4, P3): track `ghost`, fill the accent, 2 pt; drawn only with a target.
struct TargetRing: View {
    let fraction: Double
    let tint: Color
    var size: CGFloat = 14
    var body: some View {
        ZStack {
            Circle().stroke(Theme.ghost, lineWidth: 2)
            Circle().trim(from: 0, to: CGFloat(min(1, max(0, fraction)))).stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .help(String(format: "%.0f %% of the weekly target", fraction * 100))
    }
}

/// Context menu and drop target only in the live window: `ImageRenderer` paints both as yellow boxes (U1 §6).
struct LiveOnly<M: View>: ViewModifier {
    let snapshot: Bool
    var drag: String? = nil          // payload when the view can be dragged (U3: subject cards reorder by drop)
    var preview: AnyView? = nil
    let drop: ([String]) -> Void
    let targeted: (Bool) -> Void
    @ViewBuilder let menu: () -> M
    func body(content: Content) -> some View {
        if snapshot { content }
        else {
            let live = content
                .dropDestination(for: String.self) { ids, _ in drop(ids); return true } isTargeted: { targeted($0) }
                .contextMenu { menu() }
            if let drag { live.draggable(drag) { preview ?? AnyView(Text(drag)) } } else { live }
        }
    }
}

/// Create or edit a subject (Transcriber's `SubjectEditor`, §2.5, minus banner, hint and glossary — §5a Q5, Q4): head with the icon picker and the name,
/// sections Colour and Bio, footer with delete / cancel / save. 600 × 520.
struct SubjectEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.snapshot) private var snapshot
    let existing: Catalog.Subject?
    @State private var name = ""
    @State private var icon = "book"
    @State private var accent = "sage"
    @State private var bio = ""
    @State private var target: Int = 0          // PLAN_PLANNING §3.1 (P0): weekly target in minutes; 0 = none

    var body: some View {
        VStack(spacing: 0) {
            // head
            HStack(alignment: .center, spacing: Space.card) {
                IconPicker(icon: icon, accent: Theme.accent(accent), size: 64) { icon = $0 }
                VStack(alignment: .leading, spacing: Space.tight) {
                    MonoLabel(existing == nil ? "new subject" : "edit subject", color: Theme.accent(accent))
                    if snapshot { Text(name.isEmpty ? "Course code - Name" : name).font(Type.headline).foregroundStyle(name.isEmpty ? Theme.muted2 : Theme.ink) }
                    else {
                        TextField("Course code - Name, e.g. BIO 210 - Cell Biology", text: $name)
                            .textFieldStyle(.plain).font(Type.headline).foregroundStyle(Theme.ink)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, Space.sheet).padding(.top, Space.sheet).padding(.bottom, Space.card)
            Divider().overlay(Theme.line)

            PageScroll {
                VStack(alignment: .leading, spacing: Space.sheet) {
                    section("Colour", note: "its objectives wear it · pick any colour with the well") {
                        AccentPicker(accent: $accent)
                    }
                    section("Weekly target", note: "the ring on the card and on Progress measures the week against it") {   // P0 (§3.1)
                        IconChoice(symbol: "target", tint: Theme.accent(accent), options: [(0, "no target")] + Planning.targetOptions.map { ($0, "\(Planning.hours($0)) a week") }, selection: $target, title: "Weekly target")
                    }
                    section("Bio", note: "shown on the subject page") {
                        if snapshot {
                            Text(bio.isEmpty ? "What this course or project is about, in two or three sentences." : bio).font(Type.body).foregroundStyle(bio.isEmpty ? Theme.muted2 : Theme.ink)
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading).rowPadding().background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper2))
                        } else {
                            TextField("What this course or project is about, in two or three sentences.", text: $bio, axis: .vertical)
                                .textFieldStyle(.plain).font(Type.body).lineLimit(3...6)
                                .rowPadding().background(RoundedRectangle(cornerRadius: 10).fill(Theme.paper2))
                        }
                    }
                }
                .padding(.horizontal, Space.sheet).padding(.vertical, Space.sheet)
            }

            Divider().overlay(Theme.line)
            HStack {
                if let s = existing {
                    PillButton(text: "delete subject", kind: .danger) { store.deleteSubject(s.id); store.openSubject = nil; store.show("subject deleted"); dismiss() }
                }
                Spacer()
                ActionButton(title: "Cancel", ghost: true) { dismiss() }
                ActionButton(title: existing == nil ? "Create" : "Save", symbol: "checkmark", accent: true) {
                    guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { store.fail("a subject needs a name"); return }
                    store.saveSubject(id: existing?.id, name: name.trimmingCharacters(in: .whitespaces), bio: bio, icon: icon, accent: accent, weeklyTargetMinutes: .some(target == 0 ? nil : target))   // P0
                    store.show(existing == nil ? "subject created" : "subject saved")
                    dismiss()
                }
            }
            .padding(.horizontal, Space.sheet).padding(.vertical, Space.card)
        }
        .frame(width: 600, height: 520)
        .background(Theme.bg)
        .onAppear { if let s = existing { name = s.name; icon = s.icon; accent = s.accent; bio = s.bio; target = s.weeklyTargetMinutes ?? 0 } }
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
