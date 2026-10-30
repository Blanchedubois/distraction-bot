import SwiftUI

struct HomeView: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    @State private var newSubject = false
    // C1 (PLAN_CURRENT_SESSION): the form's state lives in `CurrentSessionCard`; the selection is `store.queued`.
    /// Rows that need the log: refreshed when the figures change, not on every tick of the live card.
    /// M3 (PLAN_STRUCTURE §3.4): the masonry panels are gone, so only Jump back in's rows and the tile row's `last ended` remain.
    private func refreshRows() {
        jumpRows = JumpBackInRow.build(store: store)      // PLAN_JUMP_BACK_IN J1: the Jump back in row
        let start = StudyDay.start(of: Date())   // K1
        lastEnded = EventLog.shared.sessions(since: start).compactMap(\.ended).max()
    }
    @State private var lastEnded: Date?
    @State private var jumpRows: [JumpBackInRow] = []

    /// The objective Home is themed by (H5): the live session's, else the selected tile's. Nil → sage, the app's own accent.
    private var themeObjective: Objective? { store.session == nil ? store.queued?.objective : store.sessionObjective }
    private var accent: Color { themeObjective.map { store.accent(of: $0) } ?? Theme.accent }
    /// The watermark glyph: the objective's SF Symbol; an emoji icon cannot be a watermark, so the shield stays.
    private var glyph: String { themeObjective.map { $0.icon.isEmojiIcon ? "shield.lefthalf.filled" : $0.icon } ?? "shield.lefthalf.filled" }

    var body: some View {
        Page(kicker: store.session == nil ? "not in a session" : (store.session!.paused ? "paused" : "in a session"), title: "Home",
             tint: themeObjective == nil ? nil : accent, watermark: themeObjective == nil ? nil : glyph) {
            hero
            CurrentSessionCard()                                       // C1: the Current Session widget at the full width (PLAN_CURRENT_SESSION §3.1)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.top, Space.tight)   // the hero's hairline, now under the widget
            if !jumpRows.isEmpty { JumpBackInWidget(rows: jumpRows) }   // PLAN_JUMP_BACK_IN §3.1: under the hero's hairline, above Today
            // §7.3 (H7): the Today strip at the full width, then Ledger's masonry — four tiles first, then the panels, each a doorway.
            todayStrip
            tileRow                                                    // M3 (§3.4): one row of today's tiles, nothing below it
        }
        .sheet(isPresented: $newSubject) { SubjectEditor(existing: nil).environment(store) }
        .onChange(of: store.overall) { refreshRows() }
        .onChange(of: store.catalog.objectives.count) { refreshRows() }
        .onAppear {
            refreshRows()
        }
    }

    // MARK: - The hero row (§7.3, H6): greeting + the Session card on the left, Ledger's score card on the right, a hairline beneath.

    private var hero: some View {
        VStack(spacing: 0) {
            HomeRow(minFirst: 500, secondWidth: 360, spacing: Space.sheet, stackSpacing: Space.card) { greetingColumn; scoreCard }   // C1: the row is the score card's height
        }
    }

    private var greetingColumn: some View {
        VStack(alignment: .leading, spacing: Space.loose) {
            MonoLabel(dateLine)
            Text(greeting).font(Type.greeting).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
            Text(sentence).font(Type.body).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            UpNext()   // P1 (PLAN_PLANNING §3.2): the next calendar event / due objective, one mono line; empty when there is nothing
            createRow.padding(.top, Space.tight)   // C1: Ledger's pills slot under the greeting (§5a Q12); the Session card is the widget below
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.tight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// `New objective` · `+ subject` · `objectives ↗` (moved from the Session card's header in C1). Create & start uses the queue's
    /// pills when there is a queue, else the defaults; Create queues the new objective (PLAN_NEW_OBJECTIVE_WIDGET §3.1).
    private var createRow: some View {
        let q = store.queued
        let m = q?.minutes ?? (store.settings.defaultMinutes == 0 ? nil : store.settings.defaultMinutes)
        let level = q?.strictness ?? store.settings.defaultStrictness
        return WrapRow {
            NewObjectiveButton(subject: store.subject(themeObjective?.subjectId)?.id, minutes: m, strictness: level, tint: themeObjective == nil ? nil : accent, help: "New objective",
                               shortcut: true,   // ⌘N (PLAN_NEW_OBJECTIVE_WIDGET N3), outside a session
                               onCreated: { o, exit in
                                   switch exit {
                                   case .select: store.prepareSession(objective: o, minutes: m ?? 0, strictness: level, source: "new-objective")
                                   case .start: store.startSession(objective: o, minutes: m, strictness: level)
                                   }
                               }) { NewObjectiveLabel() }
            PillButton(text: "+ subject", kind: .neutral) { newSubject = true }
            if let subjects = Screen(rawValue: "subjects") { PillButton(text: "objectives ↗", kind: .neutral) { store.go(subjects) } }
        }
    }

    private var dateLine: String {
        let day = StudyDay.start(of: Date()).formatted(.dateTime.weekday(.wide).day().month(.wide))   // the study day, so 1 AM still reads as the evening it belongs to (matches the streak row)
        if let s = store.session {
            if s.paused, let p = s.pausedUntil { return "\(day) · paused until \(clock(p))" }
            return day + (s.remaining.map { " · \(minutes($0)) left" } ?? " · until you stop")
        }
        return day
    }

    /// Ledger's greeting rule: the time of day and the first name from the account.
    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Still up" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : h < 22 ? "Good evening" : "Late night"
        let name = (ProcessInfo.processInfo.environment["DBOT_NAME"] ?? NSFullUserName()).split(separator: " ").first.map(String.init) ?? ""   // DBOT_NAME: the demo renders' name (PLAN_PUBLIC_RELEASE P1)
        return name.isEmpty ? "\(part)." : "\(part), \(name)."
    }

    /// One sentence on where the day stands, from the Today model's figures and the catalogue.
    private var sentence: String {
        let f = store.today.figures
        if let s = store.session {
            let what = store.sessionObjective?.title ?? (s.goal.isEmpty ? "a focus session" : s.goal)
            let detours = f.detours == 0 ? "no detours" : f.detours == 1 ? "1 detour" : "\(f.detours) detours"
            return "On \(what) since \(clock(s.started)), \(detours) so far."
        }
        let q = store.queued
        let next = q?.objective ?? store.subjects.lazy.flatMap { store.objectives(in: $0.id) }.first
        let hasObjectives = store.subjects.contains { !store.objectives(in: $0.id).isEmpty }
        let tail = q.map { "\($0.goal) is queued" + ($0.minutes.map { " for \($0) min." } ?? ", until you stop.") }
            ?? next.map { "\($0.title) is up next." } ?? (hasObjectives ? "Pick an objective below." : "Type what you are working on below.")
        // K4 (PLAN_STUDY_DAY §3.7): with a plan for today (yesterday's shutdown), the sentence quotes it
        let plan = store.plan(for: Date())
        let planned = plan.map { p in p.goal + (p.minutes.map { " for \($0) min" } ?? "") }.joined(separator: ", ")
        let startAt = store.shutdown(for: StudyDay.shift(Date(), by: -1))?.startAt.map { " from \(clock($0))" } ?? ""
        let plannedSeconds = plan.reduce(0) { $0 + ($1.minutes ?? 0) * 60 }
        guard f.focused > 0 else { return plan.isEmpty ? "Nothing yet today. " + tail : "You planned \(planned)\(startAt). " + tail }
        let sessions = f.sessions == 1 ? "1 session" : "\(f.sessions) sessions"
        let clean = f.clean.map { ", \(Int(($0 * 100).rounded())) % clean" } ?? ""
        if plannedSeconds > 0 { return "\(minutes(f.focused)) of the \(minutes(Double(plannedSeconds))) you planned, in \(sessions)\(clean); " + tail }
        return "\(minutes(f.focused)) focused in \(sessions)\(clean); " + tail
    }

    /// The streak card (PLAN_GAME_LOOP §3.4, G2; was Ledger's score card, C5): the streak is the hero — kicker `streak` · the figure at
    /// `Type.hero` with its word · the week row of flames · a hairline · the day score as the second figure with its word and one muted line ·
    /// the door to Progress. The flames stay sage (§5a Q6); only the border and today's ring take the live objective's tint. Watermark `flame`.
    /// `DBOT_SNAPSHOT_STREAK=zero|morning` renders the two states the log copy cannot show.
    private var scoreCard: some View {
        let knob = snapshot ? ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_STREAK"] : nil
        let sc = store.statsToday?.score
        let hasFocus = knob == "morning" ? false : ((store.statsToday?.focusedSeconds ?? 0) > 0 || store.session != nil)
        let total = sc?.total ?? 0
        let color: Color = !hasFocus ? Theme.muted2 : total >= 75 ? Theme.sage : total >= 50 ? Theme.warn : Theme.danger
        let liveTint: Color? = store.sessionObjective.map { store.accent(of: $0) } ?? (store.session == nil ? nil : Theme.accent)
        let focused = store.statsToday?.focusedSeconds ?? 0
        let unplanned = store.statsToday?.unplanned ?? false   // Z5 (§5a Q7.2): the focused figure, no word
        let n = store.statsToday?.sessions.count ?? 0
        let o = store.overall
        let streak = knob == "zero" ? 0 : knob == "morning" ? max(0, o.streak - (o.weekCells[o.todayIndex] == .session ? 1 : 0)) : o.streak
        var cells = o.weekCells
        if knob == "zero" { cells = cells.enumerated().map { $0.offset < o.todayIndex ? .missed : .future } }
        if knob == "morning" { cells[o.todayIndex] = .future }
        let todayDone = cells[o.todayIndex] == .session
        let (streakWord, streakColor): (String, Color) = streak == 0 ? ("start one today", Theme.muted)
            : todayDone ? (streak == 1 ? "day · a start" : "days in a row", Theme.sage) : (streak == 1 ? "day · keep it today" : "days · keep it today", Theme.muted)
        let kickerRight = "best \(max(o.bestStreak, streak))" + (store.freezes > 0 ? " · \(store.freezes) freeze\(store.freezes == 1 ? "" : "s") in hand" : o.frozen > 0 ? " · \(o.frozen) frozen" : "")
        let line: String = {   // PLAN_REWORK R3's rule: never the Today head's figure
            if let ls = store.liveSessionScore { return "this session · \(ls.total) · \(ls.word.lowercased())" }
            if !hasFocus { return "today · not scored yet" }
            if unplanned { return "\(n) session\(n == 1 ? "" : "s")" }
            guard let s = store.statsToday else { return "today" }
            let plan = s.planSource == .shutdown || s.planSource == .calendar ? "plan \(s.planSeconds / 60) min" : "target \(Planning.hours(s.planSeconds / 60))"
            return "today · \(plan) · closed \(s.closed ? "✓" : "–")"
        }()
        return VStack(alignment: .leading, spacing: Space.stack) {
            HStack { MonoLabel("streak"); Spacer(); MonoLabel(kickerRight, color: Theme.muted2) }
            HStack(alignment: .firstTextBaseline, spacing: Space.loose) {
                Text("\(streak)").font(Type.hero).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1)
                Text(streakWord).font(Type.headline).foregroundStyle(streakColor).lineLimit(1).minimumScaleFactor(0.8)
            }
            WeekRow(cells: cells, today: o.todayIndex, tint: Theme.sage)
            Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, Space.tight)
            HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
                if unplanned && hasFocus {
                    Text(minutes(TimeInterval(focused + Int(store.session?.elapsed ?? 0)))).font(Type.figureCard).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1)
                    Text("unplanned day").font(Type.strong).foregroundStyle(Theme.muted)
                } else {
                    Text(hasFocus ? "\(total)" : "—").font(Type.figureCard).monospacedDigit().foregroundStyle(hasFocus ? Theme.ink : Theme.muted2).lineLimit(1)
                    Text(hasFocus ? (sc?.word ?? "—") : "No session yet").font(Type.strong).foregroundStyle(color).lineLimit(1)
                }
                Spacer(minLength: Space.stack)
                MonoLabel(line, color: Theme.muted).lineLimit(1).layoutPriority(-1)
            }
            .help(store.statsToday.map { "today " + Tally.line(Tally.day($0), total: $0.score.total) } ?? "")   // F2
            if let p = Screen(rawValue: "progress") { PillButton(text: "open progress ↗", kind: .accent) { store.go(p) } }
        }
        .cardPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .card(accent: liveTint, watermark: "flame", watermarkSize: 190)
    }

    // MARK: - Row 2 (§7.3, H7): the strip, then the masonry's panels

    private var logScreen: Screen? { Screen(rawValue: "log") }
    private var progressScreen: Screen? { Screen(rawValue: "progress") }
    private func door(_ text: String, _ screen: Screen?) -> AnyView? {
        guard let screen else { return nil }
        return AnyView(PillButton(text: text, kind: .accent) { store.go(screen) })
    }

    private var todayStrip: some View {
        let f = store.today.figures
        return Panel(title: "Today", note: "\(f.sessions) session\(f.sessions == 1 ? "" : "s") · \(f.detours) detour\(f.detours == 1 ? "" : "s") · \(f.blocks) block\(f.blocks == 1 ? "" : "s")", trailing: door("log ↗", logScreen), bare: true) {
            TodayTimeline(model: store.today, now: Date())
                .cardPadding()
                .card(wash: true, watermark: "calendar.day.timeline.left")
        }
    }

    // MARK: - The tile row (PLAN_STRUCTURE §3.4, M3): today's figures, four small tiles, each a door; the masonry panels went with it.

    private var tileRow: some View {
        let f = store.today.figures
        let o = store.overall
        _ = f
        // R3 (PLAN_REWORK §3.5, §5a Q2, D10): two tiles — the Today head already says `3 h 04 focused · 2 sessions done`; the score card says the rest
        return VStack(alignment: .leading, spacing: Space.stack) {
            KpiGrid(columns: 2) {
                courseTile   // G2 (PLAN_GAME_LOOP §5a Q4): the course tile — the streak lives on the card above
                weekTile(o)
                    .contentShape(Rectangle()).onTapGesture { store.go(.progress) }.help("This week on Progress")
            }
            // R2 (PLAN_REWORK §3.3, D15): the shutdown's doors are the end card, the Session menu and the one reminder — no pill here.
        }
    }

    /// The course tile (G2): the queued or live objective's course, else the week's most-focused course — its level, the mini bar, `460 to L3`; door → its page.
    private var courseTile: some View {
        let picked = themeObjective.flatMap { store.subject($0.subjectId) } ?? store.subjects.max { store.weekMinutes(of: $0) < store.weekMinutes(of: $1) }
        return Group {
            if let s = picked {
                let tint = Theme.accent(s.accent), lv = store.courseLevel(s), xp = store.courseXP(s)
                VStack(alignment: .leading, spacing: Space.stack) {
                    HStack { MonoLabel("Course"); Spacer(minLength: Space.tight); MonoLabel(s.code ?? s.shortName, color: tint).lineLimit(1) }
                    Text("L\(lv.level)").font(Type.figureSmall).monospacedDigit().foregroundStyle(Theme.ink)
                    LevelBar(level: lv.level, into: lv.into, tint: tint, mini: true)
                    MonoLabel(XP.toNext(xp).map { "\($0) to L\(lv.level + 1)" } ?? "the top band", color: Theme.muted).lineLimit(1)
                }
                .cardPadding()
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                .card(radius: Theme.radiusCell, watermark: s.icon, watermarkSize: 72)
                .contentShape(Rectangle()).onTapGesture { store.open(subject: s.id) }.help(store.courseLabel(s))
            } else {
                KpiTile(label: "Course", value: "—", sub: "add a subject to level it", symbol: "books.vertical", small: true)
            }
        }
    }

    /// This week: the focused total as the figure and seven small bars, Monday first, today in the accent (the old week panel, inside a tile).
    private func weekTile(_ o: OverallFigures) -> some View {
        let total = o.week.reduce(0, +)
        let top = max(o.week.max() ?? 0, 60)
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("This week")
            Text(total > 0 ? minutes(Double(total)) : "—").font(Type.figureSmall).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.6)
            HStack(alignment: .bottom, spacing: Space.stack) {
                ForEach(0..<7, id: \.self) { i in
                    Capsule().fill(i == o.todayIndex ? Theme.accent : Theme.muted2.opacity(0.45))
                        .frame(width: 6, height: max(3, 22 * CGFloat(o.week[i]) / CGFloat(top)))
                }
                Spacer(minLength: 0)
                MonoLabel("progress ↗", color: Theme.muted2).fixedSize()
            }
            .frame(height: 22, alignment: .bottom)
        }
        .cardPadding()
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .card(radius: Theme.radiusCell, watermark: "chart.bar", watermarkSize: 72)
    }
}

/// Two children: the Today column (flexible, never below `minFirst`) and the Overall column (fixed `secondWidth`).
/// Side by side when the width allows both, stacked otherwise. A Layout, not ViewThatFits: the strip reports a wide ideal
/// size, which made `Pair` stack even at the default window; and `\.narrow` is set by Page below HomeView's own level.
struct HomeRow: Layout {
    var minFirst: CGFloat = 640
    var secondWidth: CGFloat = 320
    var spacing: CGFloat = Space.sheet
    var stackSpacing: CGFloat = Space.section

    private func sideBySide(_ width: CGFloat) -> Bool { width - spacing - secondWidth >= minFirst }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? 1040
        if sideBySide(width) {
            let a = subviews[0].sizeThatFits(ProposedViewSize(width: width - spacing - secondWidth, height: nil))
            let b = subviews[1].sizeThatFits(ProposedViewSize(width: secondWidth, height: nil))
            return CGSize(width: width, height: max(a.height, b.height))
        }
        let a = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let b = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: a.height + stackSpacing + b.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let width = bounds.width
        if sideBySide(width) {
            let firstW = width - spacing - secondWidth
            let a = subviews[0].sizeThatFits(ProposedViewSize(width: firstW, height: nil))
            let b = subviews[1].sizeThatFits(ProposedViewSize(width: secondWidth, height: nil))
            let h = max(a.height, b.height)      // both columns get the row's height, so a card that wants to (maxHeight: .infinity) fills it, as Ledger's score card does
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: firstW, height: h))
            subviews[1].place(at: CGPoint(x: bounds.minX + firstW + spacing, y: bounds.minY), proposal: ProposedViewSize(width: secondWidth, height: h))
        } else {
            let a = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let b = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: width, height: a.height))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + a.height + stackSpacing), proposal: ProposedViewSize(width: width, height: b.height))
        }
    }
}
