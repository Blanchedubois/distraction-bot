import SwiftUI
import Charts

// Progress §1 "Right now" (PLAN_STATS_TAB S1): the hero, the four KPI tiles, the focus score ring and the pace of the day.

/// Ledger's NetHero, re-aimed: the one big number is focused time.
struct FocusHero: View {
    let stats: Stats
    let live: Session?
    var body: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("focused · \(stats.period.label)")
            Text(minutes(Double(stats.focusedSeconds))).font(Type.figure).monospacedDigit()
                .foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.5)
            WrapRow {
                // The loop card's rule: no verdict before the first focused minute, none on an unplanned day — a neutral word instead of a red 0
                if stats.focusedSeconds == 0 && live == nil { Pill("no session yet") }
                else if stats.unplanned { Pill("unplanned day") }
                else { Pill("score \(stats.score.total) · \(stats.score.word)", kind: stats.score.total >= 75 ? .ok : stats.score.total >= 50 ? .warn : .danger, dot: true) }
                if !stats.sessions.isEmpty { Pill("\(stats.sessions.count) session\(stats.sessions.count == 1 ? "" : "s")") }
                if stats.blocked > 0 { Pill("\(stats.blocked) block\(stats.blocked == 1 ? "" : "s")", kind: .danger) }
                if let live, !live.paused { Pill("in a session · \(minutes(live.elapsed))", kind: .accent, dot: true) }
            }
        }
        .cardPadding()
        .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
        .card(accent: Theme.accent, watermark: "clock", watermarkSize: 120, gradient: true)
    }
}

/// The 2×2 beside the hero, each tile with the last 7 days as a faint sparkline (cumulative, so it rises).
struct FocusKpis: View {
    let stats: Stats
    let week: Stats
    private func spark(_ f: (DayStats) -> Int) -> [Double] {
        let cal = Calendar.current
        let today = StudyDay.start(of: Date())   // K1: the days are study days
        let byDay = Dictionary(uniqueKeysWithValues: week.days.map { ($0.day, $0) })
        var run = 0.0
        return (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i - 6, to: today)!
            run += Double(byDay[d].map(f) ?? 0); return run
        }
    }
    var body: some View {
        let focusedHours = Double(stats.focusedSeconds) / 3600
        let n = stats.sessions.count
        let avg = n > 0 ? stats.focusedSeconds / n : 0
        let topBlock = stats.distractors.filter { $0.blocked > 0 }.max { $0.blocked < $1.blocked }
        KpiGrid(columns: 2) {
            KpiTile(label: "Sessions", value: "\(n)", sub: n > 0 ? "\(minutes(Double(avg))) on average" : "none in this range", symbol: "play.circle", spark: spark { $0.sessions })
            KpiTile(label: "Caught", value: "\(stats.caught)", sub: focusedHours > 0 ? String(format: "%.1f per focused hour", Double(stats.caught) / focusedHours) : "distractions", symbol: "exclamationmark.bubble", spark: spark { $0.caught })
            KpiTile(label: "Blocked", value: "\(stats.blocked)", sub: topBlock.map { "\($0.name) · \($0.blocked)" } ?? "closes, shields, redirects", symbol: "xmark.shield", spark: spark { $0.blocked })
            KpiTile(label: "Followed through", value: stats.followUps == 0 ? "—" : "\(stats.followedThrough)/\(stats.followUps)",
                    sub: stats.followUps == 0 ? "no back-to-work checks yet" : "\(Int((Double(stats.followedThrough) / Double(stats.followUps) * 100).rounded()))% of back-to-work checks", symbol: "checkmark.circle", spark: spark { $0.followedThrough })
        }
    }
}

/// Ledger's VerdictStrip: the ring, the word, and what the score is made of as thin bars.
struct FocusScoreCard: View {
    let stats: Stats
    private var color: Color { stats.score.total >= 75 ? Theme.sage : stats.score.total >= 50 ? Theme.warn : Theme.danger }
    var body: some View {
        let s = stats.score
        let focusedH = Double(stats.focusedSeconds) / 3600
        let rate = focusedH > 0 ? Double(stats.caught) / focusedH : 0
        // Z5 (PLAN_SCORING §3.2, §3.6): plan · calm · kept · closed, each tooltip the arithmetic and the plan's source
        let source: String = { switch stats.planSource { case .shutdown: return "the shutdown's plan"; case .calendar: return "the calendar's blocks"; case .target: return "the daily target"; case .none: return "no plan" } }()
        let sessionDays = max(1, stats.days.filter { $0.sessions > 0 }.count)
        let parts: [(String, Int, Int, String)] = [
            ("plan", s.plan, 50, stats.planSeconds > 0 ? "\(minutes(Double(stats.focusedSeconds))) of \(minutes(Double(stats.planSeconds))) (\(source)) → 50 × the share, + 5 per planned objective touched, cap 50 → \(s.plan)/50"
                : "no plan and no target → \(s.plan)/50 (an unplanned day: the focused figure is the number)"),
            ("calm", s.calm, 20, "each session's calm weighted by its length: 10 × (1 − detour share ÷ 25 %) + 10 × (1 − switches above 6 per 10 min ÷ 12)" + (stats.hasDetourData ? " · \(minutes(Double(stats.detourSeconds))) lost to detours" : String(format: " · %.1f caught per focused hour stands in before detours were measured", rate)) + " → \(s.calm)/20"),
            ("kept", s.kept, 20, stats.followUps == 0 ? "no back-to-work checks → 10 of 20 (§5a Q7.8: nothing for free) → \(s.kept)/20" : "\(stats.followedThrough) of \(stats.followUps) back-to-work checks kept, weighted by session length → \(s.kept)/20"),
            ("closed", s.closed, 10, stats.period.kind == .today ? (stats.closed ? "the day was shut down → 10/10" : "no shutdown filed for the day → 0/10") : "\(stats.shutdowns) shutdown\(stats.shutdowns == 1 ? "" : "s") over \(sessionDays) session day\(sessionDays == 1 ? "" : "s") → \(s.closed)/10"),
        ]
        HStack(alignment: .center, spacing: Space.sheet) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 12)
                Circle().trim(from: 0, to: Double(s.total) / 100).stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(s.total)").font(Type.figure).monospacedDigit().foregroundStyle(Theme.ink)
                    MonoLabel("of 100")
                }
            }
            .frame(width: 140, height: 140)
            VStack(alignment: .leading, spacing: Space.stack) {
                Text(stats.focusedSeconds == 0 ? "Nothing yet" : stats.unplanned ? "unplanned" : s.word).font(Type.headline).foregroundStyle(stats.focusedSeconds == 0 || stats.unplanned ? Theme.muted2 : color)   // Z5 (Q7.2)
                MonoLabel("\(minutes(Double(stats.focusedSeconds))) focused · \(stats.caught) caught · \(stats.blocked) blocked · \(stats.period.label)")
                VStack(alignment: .leading, spacing: Space.tight) {
                    ForEach(parts, id: \.0) { name, v, mx, why in
                        HStack(spacing: Space.stack) {
                            MonoLabel(name).frame(width: 64, alignment: .leading)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.line)
                                    Capsule().fill(v == mx ? color : v == 0 ? Theme.danger : Theme.butter).frame(width: g.size.width * CGFloat(v) / CGFloat(mx))
                                }
                            }.frame(height: 4)
                            MonoLabel("\(v)/\(mx)", color: Theme.muted2).frame(width: 36, alignment: .trailing)
                        }
                        .help(why)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(accent: color, watermark: "flag.checkered", watermarkSize: 130, gradient: true)
    }
}

/// Ledger's PaceChart: cumulative focused minutes through today against the target line and the 7-day average.
struct PaceCard: View {
    let today: Stats
    let week: Stats
    let targetMinutes: Int
    @Environment(\.snapshot) private var snapshot

    private struct Pt: Identifiable { var id: Int { hour }; let hour: Int; let minutes: Double }
    /// R1 (PLAN_REWORK §3.2, D4): the axis is the study day — hour 0 is `StudyDay.startHour` (04:00), hour 24 the next one; the bins
    /// are clock hours in `Stats`, so they are rotated by the start hour here. Every "today" on the page then agrees with this card.
    private var start: Int { StudyDay.startHour }
    private func rotated(_ hours: [HourBin]) -> [HourBin] { (0..<24).map { i in hours[(i + start) % 24] } }
    private func cumulative(_ hours: [HourBin], scale: Double = 1) -> [Pt] {
        var run = 0.0
        return [Pt(hour: 0, minutes: 0)] + rotated(hours).enumerated().map { i, h in run += Double(h.focusedSeconds) / 60 * scale; return Pt(hour: i + 1, minutes: run) }
    }
    var body: some View {
        let now = Date()
        let nowHour = min(24, max(0, now.timeIntervalSince(StudyDay.start(of: now)) / 3600))   // hours into the study day
        let todayPts = cumulative(today.hours).filter { Double($0.hour) <= ceil(nowHour) }
        // the average day: the week's hours minus today's, over the other days that had a session
        let otherDays = max(1, week.days.filter { !StudyDay.isToday($0.day) && $0.focusedSeconds > 0 }.count)   // K1
        let avgHours = zip(week.hours, today.hours).map { HourBin(hour: $0.hour, focusedSeconds: max(0, $0.focusedSeconds - $1.focusedSeconds), caught: 0) }
        let avgPts = cumulative(avgHours, scale: 1 / Double(otherDays))
        let hasAvg = (avgPts.last?.minutes ?? 0) > 0
        let focusedNow = todayPts.last?.minutes ?? 0
        let avgNow = avgPts.first { Double($0.hour) >= nowHour }?.minutes ?? avgPts.last?.minutes ?? 0
        let projected = focusedNow + max(0, (avgPts.last?.minutes ?? 0) - avgNow)
        let over = targetMinutes > 0 && projected >= Double(targetMinutes)
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack(spacing: Space.card) {
                stat("so far", minutes(focusedNow * 60), Theme.ink)
                stat("projected", minutes(projected * 60), over || targetMinutes == 0 ? Theme.sage : Theme.danger)
                if targetMinutes > 0 { stat("target", minutes(Double(targetMinutes) * 60), Theme.muted) }
                if hasAvg { stat("7-day avg", minutes((avgPts.last?.minutes ?? 0) * 60), Theme.muted) }
                Spacer()
                if targetMinutes > 0 { Pill(over ? "on pace" : "behind pace", kind: over ? .ok : .warn, dot: true) }
            }
            Chart {
                if targetMinutes > 0 {
                    LineMark(x: .value("Hour", max(0, 7 - start)), y: .value("Target", 0), series: .value("s", "target")).foregroundStyle(Theme.muted2).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    LineMark(x: .value("Hour", start > 0 ? 24 : 23), y: .value("Target", Double(targetMinutes)), series: .value("s", "target"))   // the target is due by the study day's end.foregroundStyle(Theme.muted2).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
                if hasAvg {
                    ForEach(avgPts) { p in
                        LineMark(x: .value("Hour", p.hour), y: .value("Avg", p.minutes), series: .value("s", "avg")).foregroundStyle(Theme.sky.opacity(0.7)).lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                ForEach(todayPts) { p in
                    AreaMark(x: .value("Hour", p.hour), y: .value("Today", p.minutes), series: .value("s", "today"))
                        .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Hour", p.hour), y: .value("Today", p.minutes), series: .value("s", "today")).foregroundStyle(Theme.accent).lineStyle(StrokeStyle(lineWidth: 2.2))
                }
                RuleMark(x: .value("Now", nowHour)).foregroundStyle(Theme.line2).lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading) { MonoLabel("now", color: Theme.muted2) }
                if projected > 0 {
                    PointMark(x: .value("Hour", 24), y: .value("Proj", projected)).foregroundStyle(over || targetMinutes == 0 ? Theme.sage : Theme.danger).symbolSize(40)
                        .annotation(position: .leading) { MonoLabel(minutes(projected * 60), color: over || targetMinutes == 0 ? Theme.sage : Theme.danger) }
                }
            }
            .chartYAxis { AxisMarks(position: .leading) { v in AxisGridLine().foregroundStyle(Theme.line); AxisValueLabel { if let d = v.as(Double.self) { Text(axisMinutes(d)).font(Type.label).foregroundStyle(Theme.muted) } } } }
            .chartXAxis { AxisMarks(values: [0, 4, 8, 12, 16, 20, 24]) { v in AxisValueLabel { if let h = v.as(Int.self) { Text(String(format: "%02d", (h + start) % 24)).font(Type.label).foregroundStyle(Theme.muted) } } } }
            .chartXScale(domain: 0...24)
            .frame(height: 200)
            WrapRow {
                legend("today", Theme.accent); if hasAvg { legend("7-day average", Theme.sky) }; if targetMinutes > 0 { legend("target line", Theme.muted2) }
            }
        }
    }
    private func stat(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) { MonoLabel(k); Text(v).font(Type.strong).monospacedDigit().foregroundStyle(c) }
    }
    private func legend(_ s: String, _ c: Color) -> some View { HStack(spacing: Space.tight) { Circle().fill(c).frame(width: 7, height: 7); MonoLabel(s) } }
}

/// Axis labels for minutes: "45 m", "2 h", "1 h 30".
func axisMinutes(_ m: Double) -> String {
    let n = Int(m.rounded())
    if n < 60 { return "\(n) m" }
    return n % 60 == 0 ? "\(n / 60) h" : String(format: "%d h %02d", n / 60, n % 60)
}

/// Two columns above the page's narrow breakpoint, stacked below it. `Pair` decides with ViewThatFits, which measures a
/// chart's ideal width as very wide and stacks even at 1080 pt; charts here need the breakpoint instead.
struct SideBySide<A: View, B: View>: View {
    var firstWidth: CGFloat? = nil
    @ViewBuilder let first: A
    @ViewBuilder let second: B
    @Environment(\.narrow) private var narrow
    var body: some View {
        if narrow {
            VStack(alignment: .leading, spacing: Space.section) { first; second }
        } else {
            HStack(alignment: .top, spacing: Space.sheet) {
                Group { if let w = firstWidth { first.frame(width: w) } else { first.frame(maxWidth: .infinity) } }.fixedSize(horizontal: false, vertical: true)
                second.frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
