import SwiftUI

/// R4 (PLAN_REWORK §3.4): the first screen of Progress is the loop — **the streak** (G2's week row, the count, the best and the
/// freezes in words), **today's score** (the ring with its word, the four parts, the plan it is measured against, `closed` open
/// until the shutdown) and **the courses** (G1's rows: the bar, `L2 · 460 to L3`, the week against the target). One card, one
/// accent, the flag watermark. On a period other than Today the score is the period's.
struct LoopCard: View {
    @Environment(Store.self) private var store
    @Environment(\.narrow) private var narrow
    let stats: Stats

    var body: some View {
        VStack(alignment: .leading, spacing: Space.loose) {
            if narrow {
                streak
                Rectangle().fill(Theme.line).frame(height: 1)
                score
            } else {
                HStack(alignment: .top, spacing: Space.sheet) {
                    streak.frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(Theme.line).frame(width: 1, height: 132)
                    score.frame(width: 400, alignment: .leading)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: Space.stack) {
                MonoLabel("courses")
                LevelsPanel()
            }
        }
        .cardPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(watermark: "flag.checkered", watermarkSize: 150)
    }

    // MARK: the streak (G2's pieces, in words)

    private var streak: some View {
        let o = store.overall
        let todayDone = o.weekCells.indices.contains(o.todayIndex) && o.weekCells[o.todayIndex] == .session
        let word = o.streak == 0 ? "start one today" : todayDone ? (o.streak == 1 ? "day · a start" : "days in a row") : (o.streak == 1 ? "day · keep it today" : "days · keep it today")
        let freezes = store.freezes > 0 ? "\(store.freezes) freeze\(store.freezes == 1 ? "" : "s") in hand" : "no freeze in hand"
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("streak")
            HStack(alignment: .firstTextBaseline, spacing: Space.loose) {
                Text("\(o.streak)").font(Type.figureCard).monospacedDigit().foregroundStyle(Theme.ink)
                Text(word).font(Type.strong).foregroundStyle(todayDone && o.streak > 0 ? Theme.sage : Theme.muted)
            }
            WeekRow(cells: o.weekCells, today: o.todayIndex, size: 26)
            MonoLabel("best \(max(o.bestStreak, o.streak)) · \(freezes)" + (o.frozen > 0 ? " · \(o.frozen) frozen in this run" : ""), color: Theme.muted)
                .help(XP.freezeRule)
        }
    }

    // MARK: today's score (the day rule, Z1 — the parts said once)

    private var score: some View {
        let s = stats.score
        let today = stats.period.kind == .today
        let hasFocus = stats.focusedSeconds > 0
        let color: Color = !hasFocus ? Theme.muted2 : s.total >= 75 ? Theme.sage : s.total >= 50 ? Theme.warn : Theme.danger
        let source: String = {
            switch stats.planSource {
            case .shutdown: return "plan \(stats.planSeconds / 60) min from the shutdown"
            case .calendar: return "plan \(stats.planSeconds / 60) min from the calendar"
            case .target: return "target \(Planning.hours(stats.planSeconds / 60))"
            case .none: return "no plan"
            }
        }()
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel(today ? "today's score" : "score · \(stats.period.label)")
            HStack(spacing: Space.loose) {
                ScoreRing(value: hasFocus ? s.total : nil, tint: color)
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(hasFocus ? (stats.unplanned ? "Unplanned day" : s.word) : "No session yet").font(Type.strong).foregroundStyle(hasFocus ? color : Theme.muted2)
                    MonoLabel(hasFocus ? source : "scored after the first minute", color: Theme.muted2)
                }
            }
            if hasFocus { Text(Tally.line(Tally.day(stats), total: s.total)).font(Type.data).foregroundStyle(Theme.muted).lineLimit(3).fixedSize(horizontal: false, vertical: true) }   // F2: the day's tally; an open day carries `− 10 open · +10 at the shutdown`
        }
        .help("100 minus what the day lost: under its plan (the shutdown's, else the calendar's blocks, else the daily target) · detours · warnings ignored · open until the shutdown (⌘⇧D)")
    }
}
