import SwiftUI

/// The Calendar tab (PLAN_WEEK_CALENDAR §3.1; PLAN_STRUCTURE §3.3, M2): **Week** — Jeff's week grid, read-only, one card that fills the
/// window's height with the canvas scrolling inside it — or **Day** — the old History tab's body (`CalendarDayView`), one study day at a
/// time, in a scrolling column. The head keeps the title and the `your calendar` pill and gains the `Week | Day` segment; the window
/// toolbar's `.principal` group (‹ › · the day menu · today) drives both: a week or a day per step by the segment, ⌘← ⌘→ ⌘T ⇧⌘T.
struct CalendarScreen: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    @State private var landingRequest = 0
    @State private var picking = false
    @State private var picked = Date()

    private var cal: Calendar { Calendar.current }
    private var today: Date { StudyDay.start(of: Date()) }   // K1 (PLAN_STUDY_DAY §3.2): the Day view's days are study days
    private var firstDay: Date { CalendarDayView.firstDay }
    private var isDay: Bool { store.calendarMode == .day }
    private var dayBundle: HistoryDay { HistoryDay.load(store.calendarDay, store: store) }   // the head's title only; the body loads its own

    var body: some View {
        GeometryReader { g in
            let narrow = g.size.width < Breakpoint.narrow
            VStack(alignment: .leading, spacing: Space.sheet) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: Space.tight) {
                        if isDay {
                            let d = dayBundle
                            MonoLabel("one day at a time · ‹ › and the day menu in the toolbar · ⌘T today")
                            (Text(d.title) + Text(d.yearSuffix.map { " \($0)" } ?? "").foregroundStyle(Theme.muted2))
                                .font(Type.page).foregroundStyle(Theme.ink).lineLimit(1)
                        } else {
                            MonoLabel("the week · sessions by subject · your calendar underneath")
                            (Text(store.week.title) + Text(" " + store.week.year).foregroundStyle(Theme.muted2))
                                .font(Type.page).foregroundStyle(Theme.ink).lineLimit(1)
                        }
                    }
                    Spacer()
                    bar
                }
                if isDay {
                    PageScroll {
                        CalendarDayView(day: store.calendarDay)
                            .frame(maxWidth: 1040)
                            .padding(.bottom, Space.pageBottom)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    WeekGrid(model: store.week, now: Date(), landingRequest: landingRequest)
                        .card(radius: 20)
                        // W5: ← → move a week, T returns to today (Jeff's keys), once the grid has focus (a click gives it)
                        .focusable().focusEffectDisabled()
                        .onKeyPress(.leftArrow) { step(-1); return .handled }
                        .onKeyPress(.rightArrow) { step(1); return .handled }
                        .onKeyPress(characters: CharacterSet(charactersIn: "tT")) { _ in goToday(); return .handled }
                }
            }
            .frame(maxWidth: 1040)
            .padding(.horizontal, Space.pageH(narrow: narrow)).padding(.top, Space.sheet).padding(.bottom, Space.sheet)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.narrow, narrow)
        }
        .toolbar { toolbar }
        .onAppear { publishSubtitle() }
        .onDisappear { store.calendarSubtitle = "" }
        .onChange(of: store.calendarMode) { _, _ in publishSubtitle() }
        .onChange(of: store.calendarDay) { _, _ in publishSubtitle() }
        .onChange(of: store.weekStart) { _, _ in publishSubtitle() }
    }

    /// The window subtitle (§3.3): the week's range in Week, the full date in Day (PLAN_HISTORY_TAB §5a Q10).
    private func publishSubtitle() {
        store.calendarSubtitle = isDay ? store.calendarDay.formatted(.dateTime.weekday(.wide).day().month(.wide).year()) : "\(store.week.title) \(store.week.year)"
    }

    /// The head's trailing: the `Week | Day` segment (`.on` in ink), then the `your calendar` toggle in Week (W4, §3.5).
    private var bar: some View {
        HStack(spacing: Space.stack) {
            HStack(spacing: Space.tight) {
                PillButton(text: "week", kind: isDay ? .neutral : .on, accent: Theme.ink) { store.calendarMode = .week }.help("The week · ⌘⇧W")
                PillButton(text: "day", kind: isDay ? .on : .neutral, accent: Theme.ink) { store.calendarMode = .day }.help("One day at a time · ⌘⇧Y")
            }
            if !isDay, !store.settings.icsURL.isEmpty || store.feed.fixture {
                PillButton(text: "your calendar", kind: store.settings.showFeed ? .on : .neutral, accent: Theme.accent(store.settings.icsColor)) {
                    store.settings.showFeed.toggle(); store.reloadWeek()
                }
                .help(store.settings.showFeed ? "Hide your calendar's events" : "Show your calendar's events under the sessions")
            }
        }
    }

    // MARK: the toolbar (PLAN_HISTORY_TAB §3.2, moved here in M2): ‹ · [day ▾ in Day] · › · today, centred; keys ⌘← ⌘→ ⌘T ⇧⌘T

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .principal) {
            Button { step(-1) } label: { Label(isDay ? "Previous day" : "Previous week", systemImage: "chevron.left") }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(isDay && store.calendarDay <= firstDay)
                .help(isDay ? "Previous day · ⌘←" : "Previous week · ⌘←")
            if isDay {
                Menu { dayMenu } label: { Label(dayBundle.shortTitle, systemImage: "calendar") }
                    .menuIndicator(.visible)
                    .help("Pick a day")
                    .popover(isPresented: $picking, arrowEdge: .bottom) { picker }
            }
            Button { step(1) } label: { Label(isDay ? "Next day" : "Next week", systemImage: "chevron.right") }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(isDay && store.calendarDay >= today)
                .help(isDay ? "Next day · ⌘→" : "Next week · ⌘→")
            Button("today") { goToday() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(isDay ? store.calendarDay == today : store.week.holdsToday)
                .help(isDay ? "Back to today · ⌘T" : "This week, scrolled to now · ⌘T")
        }
    }

    /// Today · Yesterday · the last seven days with their focused time · Pick a date… · First day with data · Last day with sessions.
    @ViewBuilder private var dayMenu: some View {
        let days = store.statsAll?.days ?? []
        let byDay = Dictionary(uniqueKeysWithValues: days.map { (StudyDay.start(of: $0.day), $0) })   // K1
        let shown = store.calendarDay
        ForEach(0..<9, id: \.self) { back in
            let date = cal.date(byAdding: .day, value: -back, to: today)!
            if date >= firstDay || back < 2 {
                let name = StudyDay.label(date)   // K1: Today · Yesterday · Tue 28 Oct
                let focused = byDay[date].map { $0.focusedSeconds > 0 ? minutes(Double($0.focusedSeconds)) : "—" } ?? "—"
                Toggle(isOn: Binding(get: { date == shown }, set: { _ in go(date) })) { Text("\(name)\t\(focused)") }
            }
        }
        Divider()
        Button("Pick a date…") { picked = shown; picking = true }.keyboardShortcut("t", modifiers: [.command, .shift])
        Button("First day with data") { go(firstDay) }.disabled(shown == firstDay)
        let last = CalendarDayView.lastDayWithSessions(before: shown, store: store)
        Button("Last day with sessions") { if let p = last { go(p) } }.disabled(last == nil)
    }

    /// `DatePicker(.graphical)` bounded first logged day … today; picking moves at once, Done closes.
    private var picker: some View {
        VStack(alignment: .trailing, spacing: Space.stack) {
            DatePicker("", selection: Binding(get: { picked }, set: { picked = $0; go($0) }), in: firstDay...today, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            PillButton(text: "done", kind: .accent) { picking = false }
        }
        .padding(Space.loose)
    }

    /// One step: a day in Day, a week in Week.
    private func step(_ n: Int) {
        if isDay { go(cal.date(byAdding: .day, value: n, to: store.calendarDay)!) }
        else { store.weekStart = cal.date(byAdding: .day, value: 7 * n, to: store.weekStart)! }
    }
    private func goToday() {
        if isDay { go(today) } else { store.weekStart = WeekModel.start(of: Date()); landingRequest += 1 }
    }
    private func go(_ date: Date) {
        let d = StudyDay.dayStarting(on: date)   // K1: the picker and the menu name calendar dates; a study-day start maps to itself
        guard d >= firstDay || d == today, d <= today else { return }
        store.calendarDay = d
    }
}
