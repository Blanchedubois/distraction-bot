import SwiftUI

/// The course's progress on its page (PLAN_SUBJECT_PROGRESS §3.2, S1; S4 on the user's word: three cards, not three columns of one):
/// **this week** (the XP earned and what earned it; S5 moved the level to the header's `LevelRing`) · **streak** (the course's days in a row, the week row of flames in its colour)
/// · **score** (the week's time-weighted session scores as a ring), beside the level ring (S6). One accent, the course's; neutral cards. The three
/// share a height; narrow puts level on its own row and the other two side by side.
struct CourseProgressCards: View {
    let progress: CourseProgress
    let accent: Color
    let icon: String
    var code = ""                   // PLAN_GAME_FEEL F3: the course streak is named for its course, never only `streak` (Home's)
    var unsortedNaming = 0          // §5a Q9: unsorted sessions whose goal names the course — they earn nothing until filed
    @Environment(\.narrow) private var narrow

    var body: some View {
        // S6 (§3.4c): one band — the level ring, then the three cards; neutral cards, no watermarks (the page carries the course's)
        if narrow {
            VStack(spacing: Space.card) {
                HStack(alignment: .center, spacing: Space.sheet) { ring; tile(week) }.fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: Space.card) { tile(streak); tile(score) }.fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(alignment: .center, spacing: Space.card) {
                ring.padding(.trailing, Space.stack)
                HStack(alignment: .top, spacing: Space.card) { tile(week); tile(streak); tile(score) }.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile<C: View>(_ content: C) -> some View {
        content.cardPadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card()
    }

    /// The level ring and what is left (S5, moved into the band by S6): `757 to L2`, `top level` at L5, `new · today` on the day it levelled.
    private var ring: some View {
        let p = progress
        return VStack(spacing: Space.stack) {
            LevelRing(level: p.level, into: p.into, xp: p.xp, tint: accent, size: narrow ? 104 : 124)
            Text(p.toNext.map { "\($0) XP to L\(p.level + 1)" } ?? "top level").font(Type.body).foregroundStyle(Theme.muted)
            if p.leveledToday { MonoLabel("new · today", color: accent) }
        }
        .fixedSize()
        .help(XP.rule)
    }

    // MARK: this week — `+256 XP` and what earned it (S5: the level and what is left to the next one moved to the header's ring)

    private var week: some View {
        let p = progress
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("this week")
            HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
                Text(p.weekXP > 0 ? "+\(p.weekXP)" : "—").font(Type.figureCard).monospacedDigit().foregroundStyle(p.weekXP > 0 ? accent : Theme.muted2)
                Text(p.weekXP > 0 ? "XP" : "no XP yet").font(Type.strong).foregroundStyle(Theme.muted)
            }
            Text(weekLine).font(Type.body).foregroundStyle(Theme.muted).lineSpacing(Space.hair).fixedSize(horizontal: false, vertical: true)   // S6: short, in words
        }
        .help(breakdown + " — " + XP.rule)   // S6: the full breakdown (the combo, the dial, every bonus) on hover
    }

    /// S6: the card's own line — `128 clean minutes · 1 finished · 1 completed`; the empty week keeps `breakdown`'s guidance.
    private var weekLine: String {
        let p = progress
        guard p.weekXP > 0 else { return breakdown }
        return ["\(p.weekClean) clean minute\(p.weekClean == 1 ? "" : "s")",
                p.weekFinished > 0 ? "\(p.weekFinished) finished" : nil,
                p.weekCompleted > 0 ? "\(p.weekCompleted) completed" : nil,
                p.weekTasks > 0 ? "\(p.weekTasks) task\(p.weekTasks == 1 ? "" : "s")" : nil].compactMap { $0 }.joined(separator: " · ")   // HUD4's tasks, on the card too
    }

    /// `256 from 233 clean min × strict 1.1 · +30 for 1 finished · +60 for 1 completed` — parts only when non-zero.
    private var breakdown: String {
        let p = progress
        guard p.weekXP > 0 else {
            if p.xp == 0, unsortedNaming > 0 { return "\(unsortedNaming) unsorted session\(unsortedNaming == 1 ? "" : "s") name this course · file them under an objective to earn XP" }
            return "a clean minute earns 1 XP, ×2 after 10 min in a row and ×3 after 30, × the focus dial · +30 per finished session · +60 per completed objective"   // HUD1
        }
        let dial = p.weekStrictness.map { "× \($0) \(XP.multiplier($0))" } ?? "× the dial"
        return ["\(p.weekMinuteXP) from \(p.weekClean) clean min with the combo \(dial)",   // HUD1: the combo pays ×2 / ×3 on runs
                p.weekFinished > 0 ? "+\(30 * p.weekFinished) for \(p.weekFinished) finished" : nil,
                p.weekTasks > 0 ? "+\(SessionTasks.xpEach * p.weekTasks) for \(p.weekTasks) task\(p.weekTasks == 1 ? "" : "s")" : nil,   // HUD4
                p.weekCompleted > 0 ? "+\(60 * p.weekCompleted) for \(p.weekCompleted) completed" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: streak — the course's days in a row, the week row in its colour (the week's time is the Trends row's Weeks card)

    private var streak: some View {
        let p = progress
        let on = code.isEmpty ? "" : " on \(code)"
        let word = p.streak == 0 ? "start one today" : p.todayDone ? (p.streak == 1 ? "day\(on)" : "days\(on)") : (p.streak == 1 ? "day\(on) · keep it today" : "days\(on) · keep it today")
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("course streak")
            HStack(alignment: .firstTextBaseline, spacing: Space.loose) {
                Text("\(p.streak)").font(Type.figureCard).monospacedDigit().foregroundStyle(Theme.ink)
                Text(word).font(Type.strong).foregroundStyle(p.todayDone ? accent : Theme.muted)
            }
            WeekRow(cells: p.cells, today: p.todayIndex, tint: accent, size: 24)
            MonoLabel("best \(max(p.best, p.streak))")
        }
        .help("days in a row with a session on this course · freezes bridge the day streak only")
    }

    // MARK: score — the week's sessions' own scores, weighted by focused time

    private var score: some View {
        let p = progress
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("score · this week")
            HStack(spacing: Space.loose) {
                ScoreRing(value: p.score?.total, tint: accent)
                VStack(alignment: .leading, spacing: Space.hair) {
                    Text(p.score?.word ?? "No session yet").font(Type.strong).foregroundStyle(p.score == nil ? Theme.muted2 : Theme.ink)
                    Text(p.score == nil ? "this week" : "\(p.scoredSessions) session\(p.scoredSessions == 1 ? "" : "s")").font(Type.body).foregroundStyle(Theme.muted)
                }
            }
            if let s = p.score {   // non-breaking hyphen: `self-control` never splits across the two lines
                Text(Tally.line(p.weekLosses, total: s.total)).font(Type.data).foregroundStyle(Theme.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)   // F2: the week's tally
            }
        }
        .help("the course's week score: its sessions' own scores this week, weighted by focused time — 100 minus what they lost")
    }
}

/// The trends row at the foot of the course page (S4, the user's word): **weeks** (the last 8 study weeks of focused time, this one in
/// the full tint, against the weekly target when there is one) · **when** (the hours of the day this course gets) · **pace** (the
/// average and longest session, the finished share, the next level at this week's pace). Plain bars in the course's colour.
struct CourseTrends: View {
    let progress: CourseProgress
    let accent: Color
    var target: Int? = nil
    @Environment(\.narrow) private var narrow

    var body: some View {
        if narrow {
            VStack(spacing: Space.card) {
                tile(weeks)
                HStack(alignment: .top, spacing: Space.card) { tile(when); tile(pace) }.fixedSize(horizontal: false, vertical: true)
            }
        } else {
            HStack(alignment: .top, spacing: Space.card) {
                tile(weeks)
                tile(when)
                tile(pace)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tile<C: View>(_ content: C) -> some View {
        content.cardPadding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .card()
    }

    /// Bars scaled to the tallest, a 2-pt floor on empty ones so the row still reads as a row; `hot` bars in the full tint.
    private func bars(_ values: [Int], hot: @escaping (Int) -> Bool, height: CGFloat = 56) -> some View {
        let top = max(1, values.max() ?? 1)
        return HStack(alignment: .bottom, spacing: Space.hair) {
            ForEach(values.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(values[i] == 0 ? Theme.line : hot(i) ? accent : accent.opacity(0.45))
                    .frame(height: max(2, height * CGFloat(values[i]) / CGFloat(top)))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    private func headline(_ figure: String, _ word: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
            Text(figure).font(Type.figureSmall).monospacedDigit().foregroundStyle(Theme.ink)
            Text(word).font(Type.strong).foregroundStyle(Theme.muted)
        }
    }

    // MARK: weeks — 8 study weeks, this one last

    private var weeks: some View {
        let p = progress
        let week = p.weeks.last ?? 0
        let average = p.weeks.reduce(0, +) / 8
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("weeks")
            HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
                if let t = target { TargetRing(fraction: Double(week) / 60 / Double(max(1, t)), tint: accent, size: 14) }
                headline(week > 0 ? Planning.short(week) : "—", target.map { "of \(Planning.hours($0)) this week" } ?? "this week")
            }
            bars(p.weeks, hot: { $0 == 7 })
            HStack {
                MonoLabel("8 weeks ago", color: Theme.muted2)
                Spacer()
                MonoLabel(average > 0 ? "avg \(Planning.short(average)) a week" : "no time yet", color: Theme.muted2)
            }
        }
        .help("focused time on this course per study week, the last 8 · this week in the full colour")
    }

    // MARK: when — the hours of the day

    private var when: some View {
        let p = progress
        let peak = p.peakHour
        let span = peak.map { String(format: "%02d:00–%02d:00", $0, ($0 + 3) % 24) } ?? "—"
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("when")
            headline(span, peak == nil ? "no time yet" : "most")
            bars(p.hours, hot: { h in peak.map { (h - $0 + 24) % 24 < 3 } ?? false })
            HStack {
                ForEach(["00", "06", "12", "18"], id: \.self) { l in MonoLabel(l, color: Theme.muted2).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .help("focused time on this course by hour of the day, all time · the busiest three hours in the full colour")
    }

    // MARK: pace — the averages and the next level

    private var pace: some View {
        let p = progress
        return VStack(alignment: .leading, spacing: Space.stack) {
            MonoLabel("pace")
            Grid(alignment: .leading, horizontalSpacing: Space.loose, verticalSpacing: Space.stack) {
                GridRow { stat(p.sessions > 0 ? Planning.short(p.averageClean * 60) : "—", "a session"); stat(p.longestClean > 0 ? Planning.short(p.longestClean * 60) : "—", p.bestToday ? "longest · new" : "longest", accent: p.bestToday) }
                GridRow {
                    stat(p.sessions > 0 ? "\(p.finished) of \(p.sessions)" : "—", "finished")
                    stat(p.daysToNext.map { "~\($0) d" } ?? "—", p.toNext == nil ? "at the top" : "to L\(p.level + 1)")
                }
            }
        }
        .help("clean minutes per session · sessions run to their planned end · the next level at this week's XP per day")
    }

    private func stat(_ value: String, _ label: String, accent on: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(value).font(Type.figureSmall).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1)
            MonoLabel(label, color: on ? accent : Theme.muted)   // F4: `longest · new` on the day of a personal best
        }
    }
}
