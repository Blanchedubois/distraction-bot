import SwiftUI

/// The Current Session widget (PLAN_CURRENT_SESSION §3.2–3.5): Home's full-width card under the greeting | score row, in one of
/// three states — **idle** (the H4–H9 form: objective tiles under subject rows, a one-off goal, length · level · Start),
/// **queued** (`store.queued` set: the objective leads, the tiles fold under `change objective ▾`), **live** (`store.session`).
/// The selection *is* `store.queued` (C0): a Jump-back-in card, the Objectives panel, a relaunch and this card's own tiles all set it.
/// `form` and `live(_:)` moved here from `HomeView` whole (C1); the live state is restyled in C2.
struct CurrentSessionCard: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    @Environment(\.narrow) private var narrow                // set by Page (this card is inside its subtree, unlike HomeView itself)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    @State private var goal = ""                             // the one-off goal (idle/queued only; an objective's goal is its title)
    @State private var length = "50"
    @State private var customMinutes = "40"                  // H9: "custom…" in the length pill reveals a minutes field
    @State private var editingCustom = false                 // R3 (PLAN_REWORK §3.5, D11): the field shows only while a custom length is being typed; the pill then reads `80 min`
    @State private var strictness: Strictness = .normal
    @State private var freeText = false                      // the one-off goal field is shown (§3.7, H4)
    @State private var showTiles = false                     // queued: `change objective ▾` drops the tile list (§5a Q2)
    @State private var newSubject = false
    @FocusState private var goalFocused: Bool                // H8: the one-off field takes focus when revealed; Return starts

    private var queued: Objective? { store.queued?.objective }
    /// The objective the card is themed by (H5): the live session's, else the queued one. Nil → sage.
    private var themeObjective: Objective? { store.session == nil ? queued : store.sessionObjective }
    private var accent: Color { themeObjective.map { store.accent(of: $0) } ?? Theme.accent }
    private var glyph: String { themeObjective.map { $0.icon.isEmojiIcon ? "shield.lefthalf.filled" : $0.icon } ?? "shield.lefthalf.filled" }

    var body: some View {
        Group {
            if let s = store.session { live(s) } else { form }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.1), value: store.session == nil)   // C2: Start → focused, End → plain
        // the pills edit the queue in place (PLAN_JUMP_BACK_IN §3.5: the widget owns the form), and a queue set anywhere sets the pills
        .onChange(of: length) { _, _ in syncQueue() }
        .onChange(of: customMinutes) { _, _ in syncQueue() }
        .onChange(of: strictness) { _, _ in syncQueue() }
        .onChange(of: goal) { _, g in   // C4: a typed one-off goal is the queue too, so it survives a relaunch
            if freeText, !g.trimmingCharacters(in: .whitespaces).isEmpty { store.prepareSession(goal: g, minutes: chosenMinutes, strictness: strictness, source: "one-off") }
            else if freeText, store.queued?.objective == nil { store.clearQueued() }
        }
        .onChange(of: store.queued) { _, q in
            guard let q else { return }
            if q.objective != nil { freeText = false; showTiles = false } else if !freeText { freeText = true; goal = q.goal }   // C4: a one-off queue shows its field
            if let m = q.minutes { if ["25", "50", "90"].contains(String(m)) { length = String(m) } else { length = "custom"; customMinutes = String(m) } } else { length = "open" }
            strictness = q.strictness
        }
        .onAppear {
            if let q = store.queued {   // a queue from before (a relaunch, another widget, DBOT_SNAPSHOT_QUEUED)
                if q.objective == nil { freeText = true; goal = q.goal }   // C4: a one-off goal queued before
                if let m = q.minutes { if ["25", "50", "90"].contains(String(m)) { length = String(m) } else { length = "custom"; customMinutes = String(m) } } else { length = "open" }
                strictness = q.strictness
            } else {
                let d = store.settings.defaultMinutes
                if d == 0 { length = "open" } else if ["25", "50", "90"].contains(String(d)) { length = String(d) } else { length = "custom"; customMinutes = String(d) }
                strictness = store.settings.defaultStrictness
                if goal.isEmpty, let g = store.recentGoals.first { goal = g }
            }
            if snapshot, ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_FREETEXT"] != nil { freeText = true; store.clearQueued() }
            if snapshot, let m = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_CUSTOM"] { length = "custom"; customMinutes = m }
        }
        .sheet(isPresented: $newSubject) { SubjectEditor(existing: nil).environment(store) }
    }

    /// The pills → the queue, without re-queuing (no new `queuedAt`, no log line).
    private func syncQueue() {
        guard var q = store.queued else { return }
        if q.minutes != chosenMinutes || q.strictness != strictness { q.minutes = chosenMinutes; q.strictness = strictness; store.queued = q }
    }

    private var catalogue: [(Catalog.Subject, [Objective])] { store.subjects.map { ($0, store.objectives(in: $0.id)) }.filter { !$0.1.isEmpty } }
    /// M3: Home draws Jump back in whenever a live objective exists, so the idle grid is needed only when it cannot (never, today; kept for the rule).
    private var jumpHidden: Bool { JumpBackInRow.build(store: store).isEmpty }

    // MARK: - Idle and queued

    private var form: some View {
        let hasObjectives = !catalogue.isEmpty
        let showField = freeText || !hasObjectives
        return VStack(alignment: .leading, spacing: Space.loose) {
            header
            if let o = queued, !showField { queuedHead(o) }
            if store.queued != nil { QueuedTasks() }   // HUD4 (PLAN_SESSION_HUD §3.4): tasks set before the start
            // M3 (PLAN_STRUCTURE §3.4, §5a Q2.2): no tile grid while idle — Jump back in beneath is the list; `change objective ▾` still drops it.
            if showTiles || (hasObjectives && !showField && queued == nil && jumpHidden) { objectives }
            if queued == nil, !showField, hasObjectives, !showTiles { MonoLabel("nothing queued · pick an objective below or type a goal", color: Theme.muted2) }
            if store.subjects.isEmpty {
                HStack(spacing: Space.stack) {
                    MonoLabel("no subjects yet", color: Theme.muted2)
                    Spacer()
                    PillButton(text: "+ new subject", kind: .accent) { newSubject = true }
                }
            }
            if showField { oneOffHead }
            Rectangle().fill(Theme.line).frame(height: 1)
            WrapRow {
                if hasObjectives {
                    PillButton(text: showField ? "hide one-off goal" : "one-off goal", kind: showField ? .accent : .neutral) {
                        freeText.toggle()
                        if freeText { store.clearQueued(); goal = ""; goalFocused = true }
                        else if store.queued?.objective == nil { store.clearQueued() }   // C4: hiding the field drops a one-off queue
                    }
                }
                // R3: picking `custom…` from the menu opens the field; a queue loaded with a custom length shows the pill alone (`80 min`)
                PillMenu(options: [("25", "25 min"), ("50", "50 min"), ("90", "90 min"), ("custom", length == "custom" ? "\(customMinutes) min" : "custom…"), ("open", "until I stop")],
                         selection: Binding(get: { length }, set: { v in if v == "custom" { editingCustom = true }; length = v }), leadingSymbol: "timer")
                if length == "custom", editingCustom { minutesField }
                PillMenu(options: Strictness.allCases.map { ($0, $0.rawValue) }, selection: $strictness, leadingSymbol: "shield.lefthalf.filled")
                Spacer()
                ActionButton(title: (showField ? nil : queued).map { "Start · \($0.title)" } ?? "Start focus session", symbol: "play.fill", accent: true, tint: accent) { start() }
                    .disabled(queued == nil && !showField).opacity(queued == nil && !showField ? 0.5 : 1)   // M3: nothing to start yet
                    .help(queued == nil && !showField ? "pick an objective below or type a goal" : "")
            }
        }
        .cardPadding()
        .card(accent: accent, wash: true, watermark: glyph, gradient: queued != nil)
    }

    /// One kicker, `current session` (`· in queue` while something is queued — G1, §5a Q4: the helper lines went);
    /// queued: `change objective ▾` and `×` at the right.
    private var header: some View {
        HStack(spacing: Space.stack) {
            MonoLabel("current session" + (store.queued != nil ? " · in queue" : ""))
            Spacer()
            if queued != nil, !freeText {
                if catalogue.flatMap(\.1).count > 1 || !showTiles {
                    PillButton(text: showTiles ? "hide objectives" : "change objective ▾", kind: .neutral) { showTiles.toggle() }
                }
                PillButton(text: "×", kind: .neutral) { store.clearQueued(); showTiles = false }
            }
        }
    }

    /// The queued objective leads (§3.4): glyph · title · subject · bio · `kind · last N min · N sessions · T so far`.
    private func queuedHead(_ o: Objective) -> some View {
        let subj = store.subject(o.subjectId)
        let tint = store.accent(of: o)
        let ss = EventLog.shared.sessions(objective: o.id)
        let length = store.queued?.minutes.map { "\($0) min" } ?? "until I stop"
        let history = ss.isEmpty ? "not started yet" : "\(ss.count) session\(ss.count == 1 ? "" : "s") · \(minutes(Double(ss.reduce(0) { $0 + $1.seconds }))) so far"
        return HStack(alignment: .top, spacing: Space.card) {
            Glyph(icon: o.icon, size: 28, weight: .light, color: tint)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.ghost))
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Space.loose) {
                    Text(o.title).font(Type.headline).foregroundStyle(Theme.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let subj { HStack(spacing: Space.tight) { Circle().fill(tint).frame(width: 6, height: 6); MonoLabel((subj.code.map { "\($0) · " } ?? "") + subj.shortName) } }
                }
                if !o.bio.isEmpty { BioText(text: o.bio, font: Type.body, color: Theme.muted, lines: 1, collapsible: false, accent: tint) }
                MonoLabel("\(o.kind.rawValue) · \(length) · \(history)")
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, Space.hair)
    }

    /// The one-off goal: the text-cursor glyph, the field as the title, the recent goals beneath.
    private var oneOffHead: some View {
        HStack(alignment: .top, spacing: Space.card) {
            Glyph(icon: "text.cursor", size: 28, weight: .light, color: Theme.muted)
                .frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.ghost))
            VStack(alignment: .leading, spacing: Space.stack) {
                if snapshot { Text(goal.isEmpty ? "What are you working on?" : goal).font(Type.headline).foregroundStyle(goal.isEmpty ? Theme.muted2 : Theme.ink) }
                else { TextField("What are you working on?", text: $goal).textFieldStyle(.plain).font(Type.headline).foregroundStyle(Theme.ink).focused($goalFocused).onSubmit { start() } }
                if !store.recentGoals.isEmpty {
                    WrapRow { ForEach(store.recentGoals, id: \.self) { g in PillButton(text: g, kind: g == goal ? .accent : .neutral) { goal = g } } }
                }
            }
        }
    }

    /// The objectives, as tiles under their subject rows (§3.7, H4), two columns at the full width (C1). Nothing while the catalogue is empty.
    @ViewBuilder private var objectives: some View {
        let rows = catalogue
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Space.loose) {
                ForEach(rows, id: \.0.id) { s, os in
                    let tint = Theme.accent(s.accent)
                    VStack(alignment: .leading, spacing: Space.stack) {
                        subjectRow(s, tint: tint)
                        // Two tiles per row at the full width (the card is ≈ 950 pt; a title fits in 470), one when the page is narrow.
                        // Pairs in HStacks rather than an adaptive LazyVGrid, which rendered one column offscreen.
                        // The last slot is the ghost tile (PLAN_NEW_OBJECTIVE_WIDGET N3): `+ new in <subject>`, the door to the quick-create popover.
                        let perRow = narrow ? 1 : 2
                        let slots = os.count + 1
                        ForEach(Array(stride(from: 0, to: slots, by: perRow)), id: \.self) { i in
                            HStack(spacing: Space.stack) {
                                ForEach(i..<min(i + perRow, slots), id: \.self) { j in
                                    if j < os.count { tile(os[j], tint: tint) }
                                    else { newObjectiveDoor(in: s, help: "New objective in \(s.shortName)") { NewObjectiveGhostTile(subject: s) } }
                                }
                                if slots - i < perRow { Color.clear.frame(maxWidth: .infinity).frame(height: 1) }
                            }
                        }
                    }
                }
                // Subjects with no live objective yet (G1, §3.4): the same subject row, with the ghost tile as its only tile.
                let empty = store.subjects.filter { store.objectives(in: $0.id).isEmpty }
                ForEach(empty) { s in
                    let tint = Theme.accent(s.accent)
                    VStack(alignment: .leading, spacing: Space.stack) {
                        subjectRow(s, tint: tint)
                        HStack(spacing: Space.stack) {
                            newObjectiveDoor(in: s, help: "New objective in \(s.shortName)") { NewObjectiveGhostTile(subject: s) }
                            if !narrow { Color.clear.frame(maxWidth: .infinity).frame(height: 1) }
                        }
                    }
                }
            }
        }
    }

    /// A subject's row above its tiles: glyph · code · name · a hairline in its colour.
    private func subjectRow(_ s: Catalog.Subject, tint: Color) -> some View {
        HStack(spacing: Space.stack) {
            Icon(s.icon, .row, color: tint)
            MonoLabel((s.code.map { "\($0) · " } ?? "") + s.shortName)
            Rectangle().fill(tint.opacity(0.25)).frame(height: 1)
        }
    }

    /// Every door to a new objective on the card (PLAN_NEW_OBJECTIVE_WIDGET): the popover with the card's current length and level.
    private func newObjectiveDoor<L: View>(in s: Catalog.Subject?, help: String, @ViewBuilder label: @escaping () -> L) -> some View {
        NewObjectiveButton(subject: s?.id, minutes: chosenMinutes, strictness: strictness, tint: themeObjective == nil ? nil : accent, help: help, onCreated: created, label: label)
    }
    /// After Create: `.start` runs a session on the new objective with the card's pills; `.select` queues it.
    private func created(_ o: Objective, _ exit: NewObjectiveExit) {
        switch exit {
        case .select: store.prepareSession(objective: o, minutes: chosenMinutes ?? 0, strictness: strictness, source: "new-objective"); freeText = false
        case .start: store.startSession(objective: o, minutes: chosenMinutes, strictness: strictness)
        }
    }

    private func tile(_ o: Objective, tint: Color) -> some View {
        let on = queued?.id == o.id
        return Button { choose(o) } label: {
            HStack(spacing: Space.stack) {
                Glyph(icon: o.icon, size: 15, weight: .light, color: tint)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ghost))
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(o.title).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                    MonoLabel(o.kind.rawValue + (o.lastMinutes.map { $0 == 0 ? " · until I stop" : " · \($0) min" } ?? " · \(o.severity.rawValue)"))
                }
                Spacer(minLength: Space.tight)
                if on { Icon("checkmark.circle.fill", .row, color: tint) }
            }
            .rowPadding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? tint.opacity(Tint.fill(dark: dark)) : Theme.paper))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? tint.opacity(Tint.border(dark: dark)) : Theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A tile click queues the objective (its remembered length and level); the same tile again clears it (Jump back in's toggle rule).
    private func choose(_ o: Objective) {
        freeText = false
        if queued?.id == o.id { store.clearQueued(); return }
        store.prepareSession(objective: o, source: "home-tile")
        showTiles = false
    }

    /// The exact length, typed: a mono field in a pill, 1–600 minutes; Return starts. Shown while the length pill reads "custom…".
    private var minutesField: some View {
        HStack(spacing: Space.tight) {
            if snapshot { Text(customMinutes).font(Type.data).foregroundStyle(Theme.ink) }
            else {
                TextField("40", text: $customMinutes).textFieldStyle(.plain).font(Type.data).foregroundStyle(Theme.ink).frame(width: 30).multilineTextAlignment(.trailing)
                    .onSubmit { editingCustom = false }
                    .onChange(of: customMinutes) { _, v in customMinutes = String(v.filter(\.isNumber).prefix(3)) }

            }
            MonoLabel("min")
        }
        .padding(.horizontal, Space.pillH)
        .frame(height: PillMenu<String>.height)
        .background(Capsule().fill(Theme.paper)).overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
    }

    /// The chosen length in minutes; nil = until I stop. A custom entry is clamped to 1…600.
    private var chosenMinutes: Int? {
        if length == "custom" { return Int(customMinutes).map { min(600, max(1, $0)) } ?? 40 }
        return Int(length)
    }

    /// Start: the queue when one is shown (its pills are already in it), else the one-off goal.
    private func start() {
        if store.queued != nil, !freeText { syncQueue(); store.startQueued() }
        else { store.startSession(goal: goal, minutes: chosenMinutes, strictness: strictness) }
    }

    // MARK: - Live, the focused state (C2, §3.5)

    /// Today's score colour, as the score card draws it (sage ≥ 75 · warn ≥ 50 · danger), grey until something is focused.
    private func scoreColor(_ total: Int, hasFocus: Bool) -> Color { !hasFocus ? Theme.muted2 : total >= 75 ? Theme.sage : total >= 50 ? Theme.warn : Theme.danger }

    private func live(_ s: Session) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let o = store.sessionObjective, subj = store.subject(o?.subjectId)
            let tint = o.map { store.accent(of: $0) } ?? Theme.accent
            let fraction: Double? = s.ends.map { min(1, s.elapsed / max(1, $0.timeIntervalSince(s.started))) }
            VStack(alignment: .leading, spacing: Space.loose) {
                // Head: glyph box · title on one line · subject · bio · started line; the time figure at the right as the one big number.
                HStack(alignment: .top, spacing: Space.card) {
                    Glyph(icon: o?.icon ?? "text.cursor", size: 28, weight: .light, color: o == nil ? Theme.muted : tint)
                        .frame(width: 56, height: 56)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(o == nil ? Theme.ghost : tint.opacity(Tint.fill(dark: dark))))
                    VStack(alignment: .leading, spacing: Space.tight) {
                        // C4: narrow stacks the subject under the title and drops the started line's wrap guard
                        let subjectLine = subj.map { sj in HStack(spacing: Space.tight) { Circle().fill(tint).frame(width: 6, height: 6); MonoLabel((sj.code.map { "\($0) · " } ?? "") + sj.shortName) } }
                        if narrow {
                            Text(s.goal.isEmpty ? "Focus session" : s.goal).font(Type.headline).foregroundStyle(Theme.ink).lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
                            if let subjectLine { subjectLine }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: Space.loose) {
                                Text(s.goal.isEmpty ? "Focus session" : s.goal).font(Type.headline).foregroundStyle(Theme.ink).lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
                                if let subjectLine { subjectLine }
                            }
                        }
                        if let o, !o.bio.isEmpty { Text(o.bio).font(Type.body).foregroundStyle(Theme.muted).lineLimit(1) }
                        MonoLabel("started \(clock(s.started)) · \(s.strictness.rawValue)" + (s.kind.map { " · \($0.rawValue)" } ?? "") + (s.ends.map { " · ends \(clock($0))" } ?? " · until you stop"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.loose)
                    if !narrow { timeFigure(s) }
                }
                if narrow { timeFigure(s) }   // C4: the one big number on its own row at 600
                // M1 (PLAN_MINUTE_STRIP §3.3): the minute strip in place of the bar — focus fills in the tint, a detour leaves a gap, away is hollow;
                // the label is the focused minutes (and the percentage of a planned session). An open session spans its yardstick, then grows.
                let at = Date()
                let spans = store.liveSpans(s, now: at)
                let focusedMin = spans.filter { $0.kind == .focus }.reduce(0) { $0 + $1.seconds } / 60
                HStack(spacing: Space.stack) {
                    MinuteStrip(spans: spans, marks: store.liveStrip.marks, length: store.liveStripLength(s, now: at), tint: accent)
                    MonoLabel("\(focusedMin) focused" + (fraction.map { " · \(Int(($0 * 100).rounded())) %" } ?? ""))
                }
                // The score row: today's score as a mini ring (the score card's number, refreshed once a minute), the two moving parts, the verdict.
                let sc = store.statsToday?.score
                let hasFocus = (store.statsToday?.focusedSeconds ?? 0) > 0 || s.elapsed > 60
                let total = sc?.total ?? 0
                let color = scoreColor(total, hasFocus: hasFocus)
                HStack(spacing: Space.loose) {
                    ZStack {
                        Circle().stroke(Theme.line, lineWidth: 5)
                        Circle().trim(from: 0, to: Double(total) / 100).stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                        Text(hasFocus ? "\(total)" : "—").font(Type.strong).monospacedDigit().foregroundStyle(Theme.ink)
                    }
                    .frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: Space.hair) {
                        HStack(spacing: Space.stack) {
                            Text(hasFocus ? (sc?.word ?? "—") : "No score yet").font(Type.strong).foregroundStyle(color)
                            MonoLabel("today's score", color: Theme.muted2)
                        }
                        if let st = store.statsToday, hasFocus { MonoLabel(Tally.brief(Tally.day(st))).help(Tally.line(Tally.day(st), total: st.score.total)) }   // F2: what the day has lost so far, by name
                        else { MonoLabel("scored after the first minute", color: Theme.muted2) }
                    }
                    Spacer(minLength: Space.loose)
                    if !narrow { verdictColumn }
                }
                if narrow { verdictColumn }   // C4: the verdict under the score row at 600
                Rectangle().fill(Theme.line).frame(height: 1)
                // Actions, with the Now line at the right.
                HStack(spacing: Space.stack) {
                    if s.paused, let p = s.pausedUntil { Pill("paused until \(clock(p))", kind: .warn, dot: true) }
                    else if s.strictness.isHard { Pill("hard mode · ends by the phrase", kind: .danger, dot: true) }
                    else { PillButton(text: "pause 10 min", kind: .neutral) { store.pauseSession() } }
                    ActionButton(title: s.strictness.isHard ? "End session…" : "End session", symbol: "stop.fill") { store.requestEnd() }
                    Spacer(minLength: Space.loose)
                    now
                }
            }
            .cardPadding()
            .card(accent: accent, wash: true, watermark: glyph, watermarkSize: 220, gradient: true)
        }
    }

    /// The time figure (§3.5): time left, elapsed for an open session, with its word under it.
    private func timeFigure(_ s: Session) -> some View {
        VStack(alignment: narrow ? .leading : .trailing, spacing: 0) {
            Text(s.remaining.map { minutes($0) } ?? minutes(s.elapsed)).font(Type.figure).foregroundStyle(accent).monospacedDigit().lineLimit(1)
            MonoLabel(s.paused ? "paused" : (s.remaining == nil ? "elapsed" : "left"))
        }
    }

    /// The judge's last word and its reason.
    private var verdictColumn: some View {
        VStack(alignment: narrow ? .leading : .trailing, spacing: Space.tight) {
            if let v = store.judge.lastVerdict { Pill(v.distracted ? "distracted \(Int(v.confidence * 100))%" : "work \(Int(v.confidence * 100))%", kind: v.distracted ? .warn : .ok) }
            else { Pill("no verdict yet", kind: .neutral) }
            if let v = store.judge.lastVerdict, !v.reason.isEmpty { Text(v.reason).font(Type.data).foregroundStyle(Theme.muted).lineLimit(1) }
        }
    }

    /// The Now line (§3.3, H2): front app · page · the rule's strength pill, at the right of the action row (the verdict sits in the score row).
    private var now: some View {
        let front = store.watcher.frontName.isEmpty ? (snapshot ? "Overleaf" : "—") : store.watcher.frontName
        let page = store.webWatcher.current.map { ($0.isPrivate ? "private window · " : "") + ($0.title.isEmpty ? $0.host : "\($0.title) · \($0.host)") }
            ?? (snapshot ? "project-a.tex · overleaf.com" : store.watcher.frontBundle)
        let strength = store.rules.strength(for: store.watcher.frontBundle)
        return HStack(spacing: Space.stack) {
            MonoLabel("now", color: Theme.muted2)
            Text(front).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
            Text(page).font(Type.data).foregroundStyle(Theme.muted2).lineLimit(1).layoutPriority(-1)
            Pill(strength.label, kind: strength == .allowed ? .ok : (strength == .judge ? .neutral : .danger), dot: true)
        }
    }
}
