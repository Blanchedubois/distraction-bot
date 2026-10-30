import SwiftUI
import Charts

/// Progress (PLAN_STATS_TAB): how the focus is going, in Ledger's charts. S0 the stub, the aggregator and the diagrams;
/// S1 "Right now"; S2 the distractors; S3 the history; S4 the sessions and the week in review.
struct ProgressScreen: View {
    @Environment(Store.self) private var store
    @State private var showAllCreep = false
    @State private var showCreep = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_CREEP"] == "1"   // R4: collapsed unless asked
    @State private var reviewOffset = 0
    @State private var showReview = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] != nil      // open in snapshots so it can be judged

    var body: some View {
        @Bindable var store = store
        let stats = store.stats
        Page(kicker: "the loop · focused · caught · what pulls · when", title: "Progress", trailing: AnyView(
            HStack(spacing: Space.stack) {
                if let h = stats?.hiddenTests, h > 0 { MonoLabel("\(h) test\(h == 1 ? "" : "s") hidden", color: Theme.muted2).help("Sessions whose goal starts \"B1 \" or that ran under 2 minutes · Settings → Hide test sessions") }
                if let subjects = store.statsAll?.subjects, !subjects.isEmpty {
                    PillMenu(options: [(String?.none, "every subject")] + subjects.map { (Optional($0), $0) }, selection: $store.statsSubject, kind: store.statsSubject == nil ? .neutral : .accent, leadingSymbol: "books.vertical")
                }
                PillMenu(options: Period.Kind.allCases.map { ($0, Period.make($0).label) }, selection: $store.statsPeriod, leadingSymbol: "calendar")
            }
        )) {
            if let stats, let week = store.statsWeek, let today = store.statsToday {
                // 1 — The loop (PLAN_REWORK §3.4, R4): the streak · today's score · the courses — the gamified pieces first, said once
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(1, "The loop", note: stats.period.kind == .today ? "the streak · today's score · the courses" : "the streak · the \(stats.period.label)' score · the courses")
                    LoopCard(stats: stats)
                }
                // 2 — Right now
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(2, stats.period.kind == .today ? "Right now" : "The last \(stats.period.label)",
                                  note: stats.focusedSeconds == 0 ? "no session in this range yet · start one on Home" : "focused time · what was caught · how you answered")
                    Pair(firstWidth: 340) {
                        FocusHero(stats: stats, live: store.session)
                    } second: {
                        FocusKpis(stats: stats, week: week)
                    }
                }
                section("Pace · today", note: "cumulative focused minutes through the study day vs your target and the 7-day average", symbol: "speedometer") {
                    PaceCard(today: today, week: week, targetMinutes: store.settings.targetMinutes(on: Date()))
                }
            } else {
                EmptyState(symbol: "chart.xyaxis.line", text: "Reading the log…").card()
            }

            // 2 — What pulls me away
            if let stats {
                let open: (Distractor) -> Void = { d in store.go(.log, query: d.name, from: stats.period.from) }
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(3, "What pulls me away", note: "apps · sites · searches · size is distractions plus blocks", count: stats.distractors.isEmpty ? nil : "\(stats.distractors.count)")
                    SideBySide(firstWidth: 560) {
                        VStack(alignment: .leading, spacing: 0) { DistractorTreemap(stats: stats, onOpen: open) }
                            .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                            .card(watermark: "square.grid.3x3.topleft.filled", watermarkSize: 110)
                    } second: {
                        VStack(spacing: Space.loose) {
                            Panel(title: "Worst first", note: store.statsPrevious == nil ? "count · how you answered" : "count · how you answered · arrow against the previous \(stats.period.label)", symbol: "list.number") {
                                WorstFirst(stats: stats, previous: store.statsPrevious, onOpen: open)
                            }
                            Panel(title: "Searches", note: "queries the judge called a distraction", symbol: "magnifyingglass") {
                                SearchesCard(stats: stats, onOpen: open)
                            }
                        }
                    }
                }
                section("When", note: "hour of day · minutes in session · distractions", symbol: "clock") {
                    HourOfDay(stats: stats)
                }
            }
            // 3 — Over time
            if let stats, let all = store.statsAll, let week = store.statsWeek {
                let open: (Distractor) -> Void = { d in store.go(.log, query: d.name, from: all.period.from) }
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(4, "Over time", note: "every day, one cell · what is creeping")
                    SideBySide(firstWidth: 400) {
                        section("This month", note: "focused time per day", symbol: "calendar") { FocusMonth(all: all) }
                    } second: {
                        section("Day by day", note: stats.period.kind == .today ? "the last 7 days" : "the last \(stats.period.kind == .week ? "7" : "30") days", symbol: "chart.bar.xaxis") {
                            DayByDay(stats: stats.period.kind == .today ? week : stats)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {   // R4 (§5a Q6): collapsed by default — three days of data draw eight identical curves
                    SectionHeader(0, "Creeping", note: "12 weeks per distractor · arrow = the last 3 full weeks against the 3 before") {
                        PillButton(text: showCreep ? (showAllCreep ? "top 8" : "show all") : "show 8", kind: .neutral) { withAnimation { if !showCreep { showCreep = true } else { showAllCreep.toggle() } } }
                    }
                    if showCreep { CreepGrid(all: all, limit: showAllCreep ? nil : 8, onOpen: open) }
                }
                section("Last 52 weeks", note: "every day, one square · focused time", symbol: "square.grid.3x3") { FocusYear(all: all) }
                // R4: the Streaks tiles and the Levels section live in The loop at the top (the calm · followed · unblocked streaks counted nowhere and read 0)
            }
            // 4 — Sessions · the week in review · the judge's funnel
            if let stats {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(5, "Sessions", note: "newest first · the ring is the session's own score · click one to open its log", count: "\(stats.sessions.count)")
                    let latest = stats.sessions.max { $0.start < $1.start }
                    SideBySide(firstWidth: 400) {
                        Panel(title: latest?.live == true ? "Statement · live" : "Statement · latest", note: latest.map { "\($0.goal.prefix(40))" } ?? "no session", symbol: "doc.text", accent: Theme.accent, gradient: true) {
                            if let latest { SessionStatement(s: latest) } else { MonoLabel("start a session on Home", color: Theme.muted2) }
                        }
                    } second: {
                        SessionRows(stats: stats) { s in
                            store.go(.log, query: "", from: s.start, to: s.end, title: "\(s.goal.isEmpty ? "session" : s.goal) · \(clock(s.start))–\(clock(s.end))")
                        }
                    }
                }
                section("The judge's funnel", note: "verdicts → your answers → what happened next", symbol: "arrow.triangle.branch") {
                    JudgeFunnel(stats: stats)
                }
                VStack(alignment: .leading, spacing: 0) {
                    let week = store.weekStats(offset: reviewOffset)
                    SectionHeader(6, "Week in review", note: week.sessions.isEmpty ? "nothing that week" : "\(minutes(Double(week.focusedSeconds))) focused · \(week.caught) caught") {
                        HStack(spacing: Space.stack) {
                            PillMenu(options: [(0, "this week"), (1, "last week"), (2, "2 weeks ago"), (3, "3 weeks ago")], selection: $reviewOffset)
                            // Z5: the Export PDF button went (IMPACT_ANALYSIS §5a Q2.3)
                            PillButton(text: showReview ? "collapse" : "open", kind: .accent) { withAnimation { showReview.toggle() } }
                        }
                    }
                    if showReview {
                        if week.sessions.isEmpty { EmptyState(symbol: "calendar.badge.checkmark", text: "No sessions that week.").card() }
                        else { WeekReview(week: week) }
                    }
                }
            }
        }
        .task {
            // a live session grows the figures: refresh every 30 s while the tab is open
            while !Task.isCancelled {
                store.reloadStats()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// Ledger's Trends section wrapper: a numberless header over one card with a watermark.
    @ViewBuilder private func section<C: View>(_ title: String, note: String, symbol: String, bare: Bool = false, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(0, title, note: note)
            if bare { content() }
            else {
                VStack(alignment: .leading, spacing: 0) { content() }
                    .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                    .card(watermark: symbol, watermarkSize: 110)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
