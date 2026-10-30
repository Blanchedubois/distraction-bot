import SwiftUI

// PLAN_NEW_OBJECTIVE_WIDGET N0: one door, one popover, two exits. Every "new objective" control on Home is a
// `NewObjectiveButton`; it opens `QuickObjectiveForm` as a popover and hands the created objective back with the exit
// the user chose, so Home can start a session on it or select its tile. No Store or model change; the full editor
// (`ObjectiveEditor`) stays the Subjects tab's and the objective pane's.

/// What the user asked for after Create: start a session now (↩) or just have it selected in the card (⌘↩).
enum NewObjectiveExit { case start, select }

/// A door to the quick-create popover. The label is the caller's (the header action, a row `+`, an `add one +` link).
struct NewObjectiveButton<Label: View>: View {
    var subject: String? = nil          // preselected subject; nil = the form's default (§3.2)
    var minutes: Int? = nil             // the Session card's length pill, shown in the form's hint line
    var strictness: Strictness = .normal
    var tint: Color? = nil              // the page's accent for Create & start; nil = sage
    var help: String = "New objective"
    var shortcut = false                // N3: ⌘N opens this door, outside a session only (§3.5); one door on Home carries it
    let onCreated: (Objective, NewObjectiveExit) -> Void
    @ViewBuilder let label: () -> Label
    @State private var open = false
    @Environment(Store.self) private var store

    var body: some View {
        Button { open = true } label: { label() }
            .buttonStyle(.plain)
            .keyboardShortcut(shortcut && store.session == nil ? KeyboardShortcut("n", modifiers: .command) : nil)
            .help(shortcut ? help + " (⌘N)" : help)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                QuickObjectiveForm(subject: subject, minutes: minutes, strictness: strictness, tint: tint) { o, exit in
                    open = false
                    onCreated(o, exit)
                }
                .environment(store)
            }
    }
}

/// The header action's chrome: a ghost `ActionButton` look at the pills' 26 pt height (H4's palette rule: ink on paper, no second colour).
struct NewObjectiveLabel: View {
    var body: some View {
        HStack(spacing: Space.tight) {
            Icon("plus", .small)
            Text("NEW OBJECTIVE").font(Type.pill).tracking(Type.pillTracking).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Space.loose)
        .frame(height: PillMenu<String>.height)
        .background(Capsule().fill(Theme.paper))
        .overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
        .contentShape(Capsule())
    }
}

/// The ghost tile (N3, §3.1): the Session card's tile shape, dashed, at the end of a subject's tiles — `+ new in BIO 210`.
struct NewObjectiveGhostTile: View {
    let subject: Catalog.Subject
    var body: some View {
        HStack(spacing: Space.stack) {
            Icon("plus", .row, color: Theme.muted2)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line2, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            Text("new in \(subject.code ?? subject.shortName)").font(Type.strong).foregroundStyle(Theme.muted).lineLimit(1)   // G1: the `title · ↩ starts it` subline went; the popover says it
            Spacer(minLength: Space.tight)
        }
        .rowPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// The popover (§3.1): title (focused) · subject pill menu · icon box · the card's length and strictness as a hint ·
/// Create (⌘↩, select) · Create & start (↩). 420 pt wide. Only the title is required.
struct QuickObjectiveForm: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    @Environment(\.dismiss) private var dismiss
    var subject: String? = nil
    var minutes: Int? = nil
    var strictness: Strictness = .normal
    var tint: Color? = nil
    var presetTitle: String = ""        // the snapshot render types a title so the state with text renders
    let onDone: (Objective, NewObjectiveExit) -> Void

    @State private var title = ""
    @State private var subjectId = ""
    @State private var icon = ""        // "" = the guessed kind's symbol, else the subject's icon (§3.2)
    @State private var picked: SessionKind? = nil   // a kind chosen by hand sticks (N1); nil = the guess, else `other`
    @State private var severity: Strictness = .normal
    @State private var bio = ""
    @State private var due: Date? = nil // PLAN_PLANNING §3.1 (P0): the due pill in the fold
    @State private var more = false     // the Bio · Focus fold (N1); opens by itself when the title field is left
    @State private var missing = false  // Create pressed with no title: red border until typing resumes
    @State private var iconOpen = false
    // N2 (§3.3): a new subject made inline — name, one of the six family swatches, an icon — saved together with the objective.
    @State private var newSubject = false
    @State private var subjectName = ""
    @State private var subjectAccent = "sage"
    @State private var subjectIcon = "book"
    @State private var subjectIconOpen = false
    @State private var nameMissing = false
    enum Field: Hashable { case title, name }
    @FocusState private var focus: Field?
    private static let newSubjectId = "__new__"   // the subject menu's last row

    private var subj: Catalog.Subject? { store.subject(subjectId) }
    private var accent: Color { newSubject ? Theme.accent(subjectAccent) : Theme.accent(subj?.accent) }
    private var subjectIconNow: String? { newSubject ? subjectIcon : subj?.icon }
    private var guessed: SessionKind? { KindGuess.guess(title).flatMap(SessionKind.init(rawValue:)) }
    private var kind: SessionKind { picked ?? guessed ?? .other }
    private var shownIcon: String { icon.isEmpty ? (KindGuess.symbol(for: kind.rawValue) ?? subjectIconNow ?? "target") : icon }
    private var lengthText: String { minutes.map { "\($0) min" } ?? "until I stop" }
    /// The header button's default subject (§3.2): the one worked in last, else the first.
    private var defaultSubject: String? {
        EventLog.shared.sessions().lazy.compactMap { [store] in store.objective($0.objectiveId)?.subjectId }.first ?? store.subjects.first?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.loose) {
            HStack(spacing: Space.stack) {
                MonoLabel("new objective")
                Spacer()
                subjectMenu
            }
            if newSubject { newSubjectRow }
            // The one field: icon box (click = the symbol browser) · title.
            HStack(spacing: Space.stack) {
                Button { iconOpen = true } label: {
                    Glyph(icon: shownIcon, size: 15, weight: .light, color: accent)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ghost))
                }
                .buttonStyle(.plain).help("Change icon")
                .popover(isPresented: $iconOpen, arrowEdge: .bottom) { SymbolBrowser(current: shownIcon, accent: accent) { icon = $0; iconOpen = false } }
                if snapshot {
                    Text(title.isEmpty ? "e.g. problem set 4" : title).font(Type.headline).foregroundStyle(title.isEmpty ? Theme.muted2 : Theme.ink).lineLimit(1)
                } else {
                    TextField("e.g. problem set 4", text: $title)
                        .textFieldStyle(.plain).font(Type.headline).foregroundStyle(Theme.ink)
                        .focused($focus, equals: .title)
                        .onSubmit { create(.start) }
                        .onChange(of: title) { missing = false }
                }
            }
            .rowPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.paper2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(missing ? Theme.danger : Theme.line, lineWidth: 1))

            // The kind, guessed from the title until picked by hand (N1, §3.4), and the fold's toggle.
            HStack(spacing: Space.stack) {
                IconChoice(symbol: "tag", tint: accent, options: SessionKind.allCases.map { ($0, $0.rawValue) },
                           selection: Binding(get: { kind }, set: { picked = $0 }), title: "Kind")
                if picked == nil, guessed != nil { MonoLabel("guessed · change ▾", color: Theme.muted2) }
                Spacer(minLength: Space.stack)
                PillButton(text: more ? "less ▴" : "more ▾", kind: .neutral) { more.toggle() }
            }
            if more { fold }

            // The session's parameters come from the card's pills (§5a Q6); shown, not repeated.
            HStack(spacing: Space.tight) {
                Icon("timer", .small, color: Theme.muted2)
                MonoLabel(lengthText)
                if !more {   // with the fold open the Focus pill is on screen; saying the level twice read as a repeat (N1 §6)
                    Icon("shield.lefthalf.filled", .small, color: Theme.muted2).padding(.leading, Space.tight)
                    MonoLabel(strictness.rawValue)
                }
                MonoLabel("· from the card's pills", color: Theme.muted2)
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            // G1 (§3.4): the key hints live on the buttons (hover), not as a third caps line under them.
            HStack(spacing: Space.stack) {
                Spacer(minLength: 0)
                ActionButton(title: "Create", ghost: true) { create(.select) }
                    .keyboardShortcut(.return, modifiers: .command).help("Create and select it (⌘↩) · Esc cancels")
                ActionButton(title: "Create & start", symbol: "play.fill", accent: true, tint: tint) { create(.start) }
                    .keyboardShortcut(.defaultAction).help("Create and start a session (↩)")
            }

            // Escape: a zero-size button carries the cancel shortcut; the popover also closes on a click outside.
            Button("") { dismiss() }.keyboardShortcut(.cancelAction).frame(width: 0, height: 0).opacity(0)
        }
        .padding(Space.sheet)
        .frame(width: 420)
        .background(Theme.paper)
        .onAppear {
            subjectId = subject ?? defaultSubject ?? ""
            title = presetTitle
            severity = store.settings.defaultStrictness
            more = snapshot && ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_MORE"] != nil
            // With an empty catalogue the new-subject row is open on arrival (§3.3), so the first objective is one popover away.
            newSubject = store.subjects.isEmpty || (snapshot && ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_NEWSUBJECT"] != nil)
            focus = newSubject ? .name : .title
        }
        // Tab (or a click) out of the title opens the fold, so the keyboard path reaches the bio without a click (§3.5).
        .onChange(of: focus) { old, new in if old == .title, new != .title, !title.isEmpty { more = true } }
    }

    /// The inline new-subject row (N2, §3.3): icon box · name (the editor's `Course code - Name` split) · six family swatches.
    /// No colour well (a floating system panel over a popover) and no bio: both stay in `SubjectEditor`.
    private var newSubjectRow: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack(spacing: Space.stack) {
                Button { subjectIconOpen = true } label: {
                    Glyph(icon: subjectIcon, size: 13, weight: .light, color: accent)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ghost))
                }
                .buttonStyle(.plain).help("Subject icon")
                .popover(isPresented: $subjectIconOpen, arrowEdge: .bottom) { SymbolBrowser(current: subjectIcon, accent: accent) { subjectIcon = $0; subjectIconOpen = false } }
                if snapshot {
                    Text(subjectName.isEmpty ? "Course code - Name, e.g. CHEM 210 - Organic chemistry" : subjectName).font(Type.body).foregroundStyle(subjectName.isEmpty ? Theme.muted2 : Theme.ink).lineLimit(1)
                } else {
                    TextField("Course code - Name, e.g. CHEM 210 - Organic chemistry", text: $subjectName)
                        .textFieldStyle(.plain).font(Type.body).foregroundStyle(Theme.ink)
                        .focused($focus, equals: .name)
                        .onSubmit { focus = .title }
                        .onChange(of: subjectName) { nameMissing = false }
                }
            }
            .rowPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.paper2))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(nameMissing ? Theme.danger : Theme.line, lineWidth: 1))
            HStack(spacing: Space.stack) {
                MonoLabel("colour", color: Theme.muted2)
                ForEach(Theme.families, id: \.0) { fam in
                    Button { subjectAccent = fam.0 } label: {
                        ZStack {
                            Circle().fill(fam.1).frame(width: 18, height: 18)
                            if subjectAccent == fam.0 { Icon("checkmark", .tiny, color: .white) }
                        }
                    }.buttonStyle(.plain).help(fam.0)
                }
                Spacer()
                MonoLabel("its objectives wear it", color: Theme.muted2)
            }
        }
    }

    /// The fold (N1): Bio (3–6 lines, the editor's markdown rules) and Focus (the severity dial with its blurb).
    private var fold: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack(alignment: .firstTextBaseline, spacing: Space.stack) { Text("Bio").font(Type.strong).foregroundStyle(Theme.ink); MonoLabel("what it entails · shown on the card") }
            if snapshot {
                Text(bio.isEmpty ? "e.g. exercises 1–6 for Thursday's review" : bio).font(Type.body).foregroundStyle(bio.isEmpty ? Theme.muted2 : Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading).padding(Space.stack).background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper2))
            } else {
                TextField("e.g. exercises 1–6 for Thursday's review", text: $bio, axis: .vertical)
                    .textFieldStyle(.plain).font(Type.body).lineLimit(2...5)
                    .padding(Space.stack).background(RoundedRectangle(cornerRadius: 8).fill(Theme.paper2))
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.stack) { Text("Focus").font(Type.strong).foregroundStyle(Theme.ink); MonoLabel("how hard the judge and the blocker press") }
            HStack(alignment: .top, spacing: Space.stack) {
                IconChoice(symbol: "shield.lefthalf.filled", tint: accent, options: Strictness.allCases.map { ($0, $0.rawValue) }, selection: $severity, title: "Focus")
                Text(severity.blurb).font(Type.body).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: Space.stack) { Text("Due").font(Type.strong).foregroundStyle(Theme.ink); MonoLabel("a deadline sorts it first on Home") }   // P0 (§3.1)
            DueRow(due: $due, accent: accent)
        }
        .padding(.top, Space.hair)
    }

    /// The subject (§3.2–3.3): a pill menu of the subjects with `new subject…` as its last row; while the new-subject row is
    /// open, a `new subject` label and, if there are subjects to go back to, an `existing ▾` pill.
    @ViewBuilder private var subjectMenu: some View {
        let subjects = store.subjects
        if newSubject {
            HStack(spacing: Space.stack) {
                MonoLabel("in a new subject", color: Theme.muted2)
                if !subjects.isEmpty { PillButton(text: "existing ▾", kind: .neutral) { newSubject = false; if subjectId.isEmpty { subjectId = defaultSubject ?? "" }; focus = .title } }
            }
        } else {
            let options = subjects.map { ($0.id, $0.code ?? $0.shortName) } + [(Self.newSubjectId, "new subject…")]
            let pick = Binding<String>(get: { subjectId }, set: { v in
                if v == Self.newSubjectId { newSubject = true; focus = .name } else { subjectId = v }
            })
            HStack(spacing: Space.tight) {
                MonoLabel("in", color: Theme.muted2)
                PillMenu(options: options, selection: pick, placeholder: "subject", kind: .neutral, accent: accent, leadingSymbol: subj?.icon ?? "book")
            }
        }
    }

    private func create(_ exit: NewObjectiveExit) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { missing = true; focus = .title; store.fail("an objective needs a title"); return }
        let n = subjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if newSubject, n.isEmpty { nameMissing = true; focus = .name; store.fail("a subject needs a name"); return }
        // Both checked before anything is written: the subject is saved first, then the objective into it (§3.3).
        let s: Catalog.Subject
        if newSubject { s = store.saveSubject(id: nil, name: n, bio: "", icon: subjectIcon, accent: subjectAccent) }
        else { guard let existing = subj else { store.fail("choose a subject first"); return }; s = existing }
        let o = store.saveObjective(id: nil, subject: s.id, title: t, bio: bio.trimmingCharacters(in: .whitespacesAndNewlines), icon: shownIcon, kind: kind, severity: severity, due: .some(due))   // P0
        store.show("objective created")
        onDone(o, exit)
    }
}
