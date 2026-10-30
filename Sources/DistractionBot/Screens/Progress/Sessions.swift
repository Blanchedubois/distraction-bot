import SwiftUI
import Charts
import AppKit

// Progress §4 "Sessions" (PLAN_STATS_TAB S4): the session rows, the week in review with its PDF, the judge's funnel.

private func scoreColor(_ s: Score) -> Color { s.total >= 75 ? Theme.sage : s.total >= 50 ? Theme.warn : Theme.danger }

/// Ledger's HistoryCard: one row per session, newest first, a small ring with its score; click opens the Log for its span.
struct SessionRows: View {
    let stats: Stats
    let onOpen: (SessionRecord) -> Void
    @State private var all = false
    var body: some View {
        let rows = stats.sessions.sorted { $0.start > $1.start }
        let shown = all ? rows : Array(rows.prefix(8))
        VStack(spacing: Space.hair) {
            if rows.isEmpty { EmptyState(symbol: "play.circle", text: "No sessions in this range. Start one on Home.") }
            ForEach(shown) { s in
                let sc = s.score
                let c = scoreColor(sc)
                Button { onOpen(s) } label: {
                    HStack(spacing: Space.loose) {
                        ZStack {
                            Circle().stroke(Theme.line, lineWidth: 4)
                            // HUD6 (PLAN_SESSION_HUD §3.6): the ring is the session's accuracy, the rank in it; the old score where there is no game
                            Circle().trim(from: 0, to: (s.game.map { SessionGame.shown($0) } ?? Double(sc.total)) / 100).stroke(s.game.map { MiniPanelView.accuracyColor(SessionGame.shown($0)) } ?? c, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90))
                            Text(s.game?.rank.rawValue ?? "\(sc.total)").font(Type.label).foregroundStyle(Theme.ink)
                        }.frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text(s.goal.isEmpty ? "Focus session" : s.goal).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                            MonoLabel("\(StudyDay.isToday(s.start) ? "today" : s.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) \(clock(s.start)) · \(minutes(Double(s.focusedSeconds)))" + (s.plannedMinutes.map { " of \($0) min" } ?? " · open"))
                        }
                        Pill(s.strictness, kind: s.strictness == "hard" ? .danger : s.strictness == "strict" ? .warn : .neutral)
                        if s.live { Pill("live", kind: .accent, dot: true) }
                        Spacer()
                        MonoLabel(s.game != nil ? SessionGame.brief(s.gameLosses) : Tally.brief(Tally.session(s)))   // F2 → HUD6: what was taken off, in accuracy points
                        if let a = s.game.map({ SessionGame.shown($0) }), let lab = s.accuracyLabel { Pill(lab, kind: a >= 90 ? .ok : a >= 80 ? .warn : .danger, dot: true).frame(width: 110, alignment: .trailing) }
                        else { Pill(sc.word, kind: sc.total >= 75 ? .ok : sc.total >= 50 ? .warn : .danger, dot: true).frame(width: 96, alignment: .trailing) }
                        Icon("chevron.right", .small, color: Theme.muted2)
                    }
                    .rowPadding().contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help((s.game.map { SessionGame.line(s.gameLosses, $0) } ?? Tally.line(Tally.session(s), total: sc.total)) + " · click to open the log for this session")   // F2 · HUD6
            }
            if rows.count > 8 { PillButton(text: all ? "latest 8" : "+ \(rows.count - 8) more", kind: .neutral) { withAnimation { all.toggle() } }.frame(maxWidth: .infinity, alignment: .trailing).padding(.top, Space.tight) }
        }
        .padding(Space.stack).card(watermark: "list.number", watermarkSize: 100)
    }
}

/// Ledger's YearReviewView, a week at a time: four tiles, a bar per day, the top distractors and the goals. (Export PDF removed, Z5 — IMPACT_ANALYSIS Q2.3.)
struct WeekReview: View {
    let week: Stats
    var forPrint: Bool = false
    private var dayRows: [(String, Date, Int, Int)] {
        let cal = Calendar.current
        let byDay = Dictionary(uniqueKeysWithValues: week.days.map { ($0.day, $0) })
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: StudyDay.start(of: week.period.from))!   // K1
            return (d.formatted(.dateTime.weekday(.abbreviated)), d, byDay[d]?.focusedSeconds ?? 0, byDay[d]?.caught ?? 0)
        }
    }
    var body: some View {
        let days = dayRows
        let best = days.filter { $0.2 > 0 }.max { $0.2 < $1.2 }?.1
        let worst = days.filter { $0.2 > 0 }.min { $0.2 < $1.2 }?.1
        let goals = Dictionary(grouping: week.sessions, by: \.goal).map { (goal: $0.key, seconds: $0.value.reduce(0) { $0 + $1.focusedSeconds }, n: $0.value.count) }.sorted { $0.seconds > $1.seconds }
        let title = "\(week.period.from.formatted(.dateTime.day().month(.abbreviated))) – \(week.period.to.formatted(.dateTime.day().month(.abbreviated)))"
        VStack(alignment: .leading, spacing: Space.sheet) {
            HStack(alignment: .firstTextBaseline) {
                Text("Week of \(title)").font(Type.headline).foregroundStyle(Theme.ink)
                Spacer()
                MonoLabel("\(week.sessions.count) sessions · score \(week.score.total) · \(week.score.word)")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.loose), count: 4), spacing: Space.loose) {
                KpiTile(label: "Focused", value: minutes(Double(week.focusedSeconds)), sub: week.sessions.isEmpty ? "no sessions" : "\(minutes(Double(week.focusedSeconds / max(1, week.days.filter { $0.sessions > 0 }.count)))) per session day", symbol: "clock", accent: true)
                KpiTile(label: "Caught", value: "\(week.caught)", sub: week.focusedSeconds > 0 ? String(format: "%.1f per focused hour", Double(week.caught) / (Double(week.focusedSeconds) / 3600)) : "—", symbol: "exclamationmark.bubble")
                KpiTile(label: "Blocked", value: "\(week.blocked)", sub: week.distractors.filter { $0.blocked > 0 }.max { $0.blocked < $1.blocked }.map { "\($0.name) · \($0.blocked)" } ?? "nothing blocked", symbol: "xmark.shield")
                KpiTile(label: "Followed through", value: week.followUps == 0 ? "—" : "\(week.followedThrough)/\(week.followUps)", sub: "back-to-work checks kept", symbol: "checkmark.circle")
            }
            Chart(days, id: \.1) { d in
                BarMark(x: .value("Day", d.0), y: .value("Focused", Double(d.2) / 60))
                    .foregroundStyle(d.1 == worst && best != worst ? Theme.danger : d.1 == best ? Theme.sage : Theme.accent.opacity(0.8)).cornerRadius(3)
                    .annotation(position: .top) { if d.3 > 0 { MonoLabel("\(d.3) caught", color: Theme.warn) } }
            }
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine().foregroundStyle(Theme.line); AxisValueLabel { if let m = v.as(Double.self) { Text(axisMinutes(m)).font(Type.label).foregroundStyle(Theme.muted) } } } }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(Type.label).foregroundStyle(Theme.muted) } }
            .frame(height: 160)
            HStack(spacing: Space.loose) {
                if let b = best { HStack(spacing: Space.tight) { Circle().fill(Theme.sage).frame(width: 7, height: 7); MonoLabel("most focused \(b.formatted(.dateTime.weekday(.wide)))") } }
                if let w = worst, w != best { HStack(spacing: Space.tight) { Circle().fill(Theme.danger).frame(width: 7, height: 7); MonoLabel("least \(w.formatted(.dateTime.weekday(.wide)))") } }
                Spacer()
            }
            HStack(alignment: .top, spacing: Space.sheet) {
                VStack(alignment: .leading, spacing: Space.stack) {
                    MonoLabel("top distractors")
                    if week.distractors.isEmpty { MonoLabel("none", color: Theme.muted2) }
                    ForEach(Array(week.distractors.prefix(8).enumerated()), id: \.element.id) { i, d in
                        HStack(spacing: Space.stack) {
                            Text(String(format: "%02d", i + 1)).font(Type.data).foregroundStyle(Theme.muted2).monospacedDigit().frame(width: 22, alignment: .leading)
                            Circle().fill(d.kind.color).frame(width: 6, height: 6)
                            Text(d.name).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer()
                            MonoLabel(d.blocked > 0 ? "\(d.blocked) blocked" : "", color: Theme.muted2)
                            Text("\(d.weight)").font(Type.strong).monospacedDigit().foregroundStyle(Theme.ink).frame(width: 40, alignment: .trailing)
                        }
                    }
                }.frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: Space.stack) {
                    MonoLabel("what you worked on")
                    if goals.isEmpty { MonoLabel("no sessions", color: Theme.muted2) }
                    ForEach(goals.prefix(8), id: \.goal) { g in
                        HStack(spacing: Space.stack) {
                            Icon("target", .row, color: Theme.accent).frame(width: 16)
                            Text(g.goal.isEmpty ? "Focus session" : g.goal).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer()
                            MonoLabel(week.focusedSeconds > 0 ? "\(Int((Double(g.seconds) / Double(week.focusedSeconds) * 100).rounded()))%" : "", color: Theme.muted2)
                            MonoLabel("\(g.n)×", color: Theme.muted2)
                            Text(minutes(Double(g.seconds))).font(Type.strong).monospacedDigit().foregroundStyle(Theme.ink).frame(width: 80, alignment: .trailing)
                        }
                    }
                }.frame(maxWidth: .infinity)
            }
        }
        .padding(forPrint ? 0 : Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ConditionalCard(on: !forPrint))
    }
}

struct ConditionalCard: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.card(watermark: "calendar.badge.checkmark", watermarkSize: 120) } else { content }
    }
}

/// The judge's funnel: verdicts → your answers → what happened next.
struct JudgeFunnel: View {
    let stats: Stats
    var body: some View {
        let a = stats.answers
        let back = a["back"] ?? 0, work = a["work"] ?? 0, snooze = a["snooze"] ?? 0, ignored = a["ignored"] ?? 0
        let answered = back + work + snooze + ignored
        let unanswered = max(0, stats.verdictsDistracted - answered)
        let checks = stats.followUps
        let followed = stats.followedThrough, still = stats.stillInFront, none = stats.noAnswer
        let other = max(0, checks - followed - still - none)
        let notChecked = max(0, back + ignored - checks)
        let nodes: [SankeyNode] = [
            SankeyNode(id: "v:work", label: "work", value: stats.verdictsWork, color: Theme.sage, column: 0),
            SankeyNode(id: "v:dist", label: "distracted", value: stats.verdictsDistracted, color: Theme.warn, column: 0),
            SankeyNode(id: "a:back", label: "back to work", value: back, color: Theme.warn, column: 1),
            SankeyNode(id: "a:work", label: "this is work", value: work, color: Theme.sage, column: 1),
            SankeyNode(id: "a:snooze", label: "snoozed", value: snooze, color: Theme.butter, column: 1),
            SankeyNode(id: "a:ignored", label: "ignored", value: ignored, color: Theme.danger, column: 1),
            SankeyNode(id: "a:none", label: "no card", value: unanswered, color: Theme.muted2, column: 1),
            SankeyNode(id: "a:ok", label: "carried on", value: stats.verdictsWork, color: Theme.sage, column: 1),
            SankeyNode(id: "o:followed", label: "followed through", value: followed, color: Theme.sage, column: 2),
            SankeyNode(id: "o:still", label: "still there → blocked", value: still, color: Theme.danger, column: 2),
            SankeyNode(id: "o:noanswer", label: "no answer → blocked", value: none, color: Theme.danger, column: 2),
            SankeyNode(id: "o:other", label: "checked", value: other, color: Theme.muted2, column: 2),
            SankeyNode(id: "o:unchecked", label: "not checked", value: notChecked, color: Theme.muted2, column: 2),
            SankeyNode(id: "o:taught", label: "taught the judge", value: work, color: Theme.sage, column: 2),
            SankeyNode(id: "o:later", label: "10 min later", value: snooze, color: Theme.butter, column: 2),
        ]
        // back + ignored share the follow-up outcomes in proportion
        let checked = back + ignored
        let share: (Int, Int) -> Int = { n, v in checked == 0 ? 0 : Int((Double(v) * Double(n) / Double(checked)).rounded()) }
        let links: [SankeyLink] = [
            SankeyLink(from: "v:work", to: "a:ok", value: stats.verdictsWork, color: Theme.sage),
            SankeyLink(from: "v:dist", to: "a:back", value: back, color: Theme.warn),
            SankeyLink(from: "v:dist", to: "a:work", value: work, color: Theme.sage),
            SankeyLink(from: "v:dist", to: "a:snooze", value: snooze, color: Theme.butter),
            SankeyLink(from: "v:dist", to: "a:ignored", value: ignored, color: Theme.danger),
            SankeyLink(from: "v:dist", to: "a:none", value: unanswered, color: Theme.muted2),
            SankeyLink(from: "a:back", to: "o:followed", value: share(back, followed), color: Theme.sage),
            SankeyLink(from: "a:back", to: "o:still", value: share(back, still), color: Theme.danger),
            SankeyLink(from: "a:back", to: "o:other", value: share(back, other), color: Theme.muted2),
            SankeyLink(from: "a:back", to: "o:unchecked", value: share(back, notChecked), color: Theme.muted2),
            SankeyLink(from: "a:ignored", to: "o:followed", value: share(ignored, followed), color: Theme.sage),
            SankeyLink(from: "a:ignored", to: "o:still", value: share(ignored, still), color: Theme.danger),
            SankeyLink(from: "a:ignored", to: "o:noanswer", value: none, color: Theme.danger),
            SankeyLink(from: "a:ignored", to: "o:unchecked", value: share(ignored, notChecked), color: Theme.muted2),
            SankeyLink(from: "a:work", to: "o:taught", value: work, color: Theme.sage),
            SankeyLink(from: "a:snooze", to: "o:later", value: snooze, color: Theme.butter),
        ]
        if stats.verdictsWork + stats.verdictsDistracted == 0 {
            EmptyState(symbol: "arrow.triangle.branch", text: "No verdicts in this range.")
        } else {
            VStack(alignment: .leading, spacing: Space.stack) {
                SankeyView(nodes: nodes, links: links).frame(height: max(220, CGFloat(nodes.filter { $0.value > 0 }.count) * 26))
                HStack(spacing: Space.card) {
                    legend("verdicts \(stats.verdictsWork + stats.verdictsDistracted)", Theme.ink)
                    legend("distracted \(stats.verdictsDistracted)", Theme.warn)
                    legend("followed through \(followed)", Theme.sage)
                    legend("blocked after a check \(still + none)", Theme.danger)
                    Spacer()
                    MonoLabel("back-to-work and ignored share the check outcomes in proportion", color: Theme.muted2)
                }
            }
        }
    }
    private func legend(_ s: String, _ c: Color) -> some View { HStack(spacing: Space.tight) { Circle().fill(c).frame(width: 7, height: 7); MonoLabel(s) } }
}
