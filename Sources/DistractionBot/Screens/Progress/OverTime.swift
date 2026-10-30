import SwiftUI
import Charts

// Progress §3 "Over time" (PLAN_STATS_TAB S3): this month's heatmap, day by day, what is creeping, the last 52 weeks, streaks.

extension HeatCalendar {
    /// Focused seconds per day from an all-time Stats.
    static func focused(_ all: Stats, now: Date = Date()) -> HeatCalendar {
        build(values: Dictionary(uniqueKeysWithValues: all.days.map { ($0.day, Double($0.focusedSeconds)) }),
              counts: Dictionary(uniqueKeysWithValues: all.days.map { ($0.day, $0.sessions) }), now: now)
    }
}

/// Ledger's MonthHeatmap: the cell is a day, the fill is focused time.
struct FocusMonth: View {
    let all: Stats
    var body: some View {
        let cal = HeatCalendar.focused(all)
        MonthHeatmap(cal: cal, format: { minutes($0) }, help: { "\($0.date) · \(minutes($0.value)) · \($0.n) session\($0.n == 1 ? "" : "s")" })
    }
}

/// Ledger's YearStrip: 52 weeks of days, fill = focused time.
struct FocusYear: View {
    let all: Stats
    var body: some View {
        let cal = HeatCalendar.focused(all)
        YearStrip(cal: cal, help: { "\($0.date) · \(minutes($0.value))" })
    }
}

/// Ledger's butterfly: focused minutes up (sage), distractions down (warn), the follow-through rate annotated.
/// The two sides have different units, so the axis is labelled per sign and the legend says which is which.
struct DayByDay: View {
    let stats: Stats                 // the range, or the week when the range is a single day
    private struct Row: Identifiable { var id: Date { day }; let day: Date; let label: String; let minutes: Double; let caught: Int; let rate: Int?; var rating: Int? = nil }   // K4: the shutdown's rating
    var body: some View {
        let cal = Calendar.current
        let byDay = Dictionary(uniqueKeysWithValues: stats.days.map { ($0.day, $0) })
        let from = max(stats.period.from, cal.date(byAdding: .day, value: -29, to: StudyDay.start(of: stats.period.to))!)
        // K4 (PLAN_STUDY_DAY §3.7): the shutdown's 1–5 rating per study day, latest filing wins
        let ratings: [Date: Int] = EventLog.shared.shutdowns(from: from, to: stats.period.to.addingTimeInterval(36 * 3600)).reduce(into: [:]) { acc, s in if let r = s.rating { acc[StudyDay.start(of: s.day)] = r } }
        let days = StudyDay.days(from: from, through: stats.period.to).map { d -> Row in   // K1: study days
            let s = byDay[d]
            let f = DateFormatter(); f.dateFormat = stats.period.kind == .month || stats.period.kind == .all ? "d" : "EEE d"
            return Row(day: d, label: f.string(from: d), minutes: Double(s?.focusedSeconds ?? 0) / 60, caught: s?.caught ?? 0,
                       rate: (s?.followUps ?? 0) > 0 ? Int((Double(s!.followedThrough) / Double(s!.followUps) * 100).rounded()) : nil,
                       rating: ratings[d])   // K4 (PLAN_STUDY_DAY §3.7)
        }
        let maxMin = max(30, days.map(\.minutes).max() ?? 30)
        let maxCaught = max(1, days.map(\.caught).max() ?? 1)
        let scale = maxMin / Double(maxCaught) * 0.5        // a distraction's bar height in "minutes", so the lower half stays readable
        VStack(alignment: .leading, spacing: Space.stack) {
            if days.allSatisfy({ $0.minutes == 0 }) {
                EmptyState(symbol: "chart.bar.xaxis", text: "No sessions in this range yet.")
            } else {
                Chart {
                    ForEach(days) { d in
                        BarMark(x: .value("Day", d.label), y: .value("Focused", d.minutes)).foregroundStyle(Theme.sage.opacity(0.85)).cornerRadius(3)
                        BarMark(x: .value("Day", d.label), y: .value("Caught", -Double(d.caught) * scale)).foregroundStyle(Theme.warn.opacity(0.85)).cornerRadius(3)
                            .annotation(position: .bottom) {   // K4: the day's rating as 1–5 dots under the bars
                                if let rating = d.rating { MonoLabel(["rough", "meh", "fine", "good", "great"][max(0, min(4, rating - 1))], color: Theme.muted2) }   // R4: the shutdown's word, not 4-pt dots
                            }
                        if let r = d.rate {
                            PointMark(x: .value("Day", d.label), y: .value("Focused", d.minutes)).foregroundStyle(Theme.ink).symbolSize(14)
                                .annotation(position: .top) { MonoLabel("\(r)%", color: r >= 50 ? Theme.sage : Theme.danger) }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { v in
                        AxisGridLine().foregroundStyle(Theme.line)
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(d >= 0 ? axisMinutes(d) : "\(Int((-d / scale).rounded()))").font(Type.label).foregroundStyle(d >= 0 ? Theme.muted : Theme.warn)
                            }
                        }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 8)) { _ in AxisValueLabel().font(Type.label).foregroundStyle(Theme.muted) } }
                .frame(height: 200)
                WrapRow {
                    legend("focused minutes, up", Theme.sage); legend("distractions, down", Theme.warn); legend("% = back-to-work checks followed through", Theme.ink)
                }
            }
        }
    }
    private func legend(_ s: String, _ c: Color) -> some View { HStack(spacing: Space.tight) { Circle().fill(c).frame(width: 7, height: 7); MonoLabel(s) } }
}

/// Ledger's CreepGrid: a tile per distractor, 12 weeks of weight, a 3-week arrow. Up is worse here.
struct CreepGrid: View {
    let all: Stats
    var limit: Int? = 8
    let onOpen: (Distractor) -> Void
    var body: some View {
        let ds = all.distractors.filter { $0.weekly.reduce(0, +) > 0 }.sorted { $0.weekly.reduce(0, +) > $1.weekly.reduce(0, +) }
        let rows = limit.map { Array(ds.prefix($0)) } ?? ds
        if rows.isEmpty {
            EmptyState(symbol: "chart.line.uptrend.xyaxis", text: "A few weeks of sessions will show what is creeping.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Space.loose)], spacing: Space.card) {
                ForEach(rows) { d in
                    CreepTile(d: d).contentShape(Rectangle()).onTapGesture { onOpen(d) }
                }
            }
        }
    }
}

struct CreepTile: View {
    let d: Distractor
    var body: some View {
        let series = d.weekly
        // the current week is partial, so the arrow compares the three full weeks before it with the three before those
        let full = Array(series.dropLast())
        let last3 = Array(full.suffix(3)), prev3 = Array(full.dropLast(3).suffix(3))
        let a = Double(last3.reduce(0, +)) / 3, b = Double(prev3.reduce(0, +)) / 3
        let pct: Int? = b > 0 ? Int(((a - b) / b * 100).rounded()) : nil
        let color = d.kind.color
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack {
                Text(d.name).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer()
                if let pct {
                    HStack(spacing: Space.hair) {
                        Image(systemName: pct > 5 ? "arrow.up.right" : pct < -5 ? "arrow.down.right" : "arrow.right").font(.system(size: Icon.Size.small.rawValue, weight: .semibold))   // lint-ok: an arrow glyph at Icon.small, inheriting the row colour
                        Text("\(abs(pct))%").font(Type.label)
                    }.foregroundStyle(pct > 5 ? Theme.danger : pct < -5 ? Theme.sage : Theme.muted)
                } else if a > 0 { MonoLabel("new", color: Theme.warn) }
            }
            Chart(Array(series.enumerated()), id: \.offset) { i, v in
                AreaMark(x: .value("w", i), y: .value("v", v)).foregroundStyle(LinearGradient(colors: [color.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.monotone)
                LineMark(x: .value("w", i), y: .value("v", v)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.6)).interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 44)
            WrapRow { MonoLabel(String(format: "%.1f / week", a)); MonoLabel("· this week \(series.last ?? 0) · \(d.kind.word)", color: Theme.muted2) }
        }
        .padding(Space.loose)
        .card(accent: color.opacity(0.5), radius: 12, watermark: "chart.line.uptrend.xyaxis", watermarkSize: 60, shadow: false)
        .help("\(d.name) · 12 weeks · the last 3 full weeks \(String(format: "%.1f", a)) a week vs \(String(format: "%.1f", b)) the 3 before · this week so far \(series.last ?? 0)")
    }
}

