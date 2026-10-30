import SwiftUI

// Progress (PLAN_GAME_LOOP §3.1, G1; was PLAN_SCORING Z5's objective panel): the Levels panel — one row per course: its bar, its label, its week ring.

struct LevelsPanel: View {
    @Environment(Store.self) private var store
    var body: some View {
        let subjects = store.subjects
        if subjects.isEmpty {
            EmptyState(symbol: "chart.bar.fill", text: "A course earns XP from every clean focused minute on its objectives. Add a subject to see its level here.")
        } else {
            VStack(alignment: .leading, spacing: Space.loose) {
                ForEach(subjects) { s in
                    let tint = Theme.accent(s.accent)
                    let lv = store.courseLevel(s)
                    let week = store.weekMinutes(of: s)
                    let target = s.weeklyTargetMinutes
                    HStack(spacing: Space.loose) {
                        Icon(s.icon, .row, color: tint).frame(width: 18)
                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text(s.shortName).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                            if let c = s.code { MonoLabel(c, color: tint) }
                        }
                        .frame(width: 200, alignment: .leading)
                        LevelBar(level: lv.level, into: lv.into, tint: tint)
                        MonoLabel(store.courseLabel(s), color: Theme.ink).fixedSize()
                        Spacer(minLength: Space.tight)
                        HStack(spacing: Space.stack) {
                            if let t = target { TargetRing(fraction: Double(week) / Double(max(1, t)), tint: tint, size: 14) }
                            MonoLabel(week > 0 ? Planning.short(week * 60) + (target.map { " of \(Planning.hours($0))" } ?? " this week") : (target.map { "nothing yet of \(Planning.hours($0))" } ?? "nothing yet this week"), color: Theme.muted2).fixedSize()
                        }
                    }
                    .contentShape(Rectangle()).onTapGesture { store.open(subject: s.id) }
                    .help(XP.rule)
                }
            }
        }
    }
}
