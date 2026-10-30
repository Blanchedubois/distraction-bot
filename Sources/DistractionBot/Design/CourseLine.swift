import SwiftUI

/// What a session or a day moved on a course (PLAN_GAME_LOOP §3.5, G3): drawn by the end card and the closing card (G4) as one line —
/// icon · code · `L2 · +84 XP · 460 to L3` · the bar, whose current segment shows `before` in the tint at 0.7 and the gain to `after` in the full tint.
struct CourseMove: Equatable {
    var code: String                 // the course's code, else its short name
    var icon: String
    var accent: String?              // the subject's accent name or hex (`Theme.accent(_:)`)
    var levelBefore: Int
    var before: Double               // 0…1 into the band before the move (0 after a level-up)
    var level: Int
    var after: Double                // 0…1 into the band after it
    var gainedXP: Int
    var toNext: Int?                 // XP still to the next band; nil at L5
    var leveledUp: Bool { level > levelBefore }
    /// `L2 · +84 XP · 460 to L3` · `level up · L3 · +84 XP · 1 360 to L4` · `L5 · +84 XP`.
    var label: String { (leveledUp ? "level up · " : "") + plainLabel }
    /// The label without `level up ·`, for a card whose own headline says it (PLAN_GAME_FEEL F4).
    var plainLabel: String { "L\(level) · +\(gainedXP) XP" + (toNext.map { " · \($0) to L\(level + 1)" } ?? "") }
}

struct CourseLine: View {
    let move: CourseMove
    var animate = true               // the bar moves from `before` to `after` over 1 s (static under Reduce Motion and in a render)
    var plain = false                // F4: the card above already says `Level N`
    var body: some View {
        let tint = Theme.accent(move.accent)
        VStack(alignment: .leading, spacing: Space.tight) {
            HStack(spacing: Space.stack) {
                Icon(move.icon, .small, color: tint)
                MonoLabel(move.code, color: tint)
                Spacer(minLength: Space.stack)
                MonoLabel(plain ? move.plainLabel : move.label, color: Theme.ink).lineLimit(1)
            }
            LevelBar(level: move.level, into: move.after, tint: tint, before: move.leveledUp ? 0 : move.before, animate: animate)
        }
        .accessibilityLabel("\(move.code) \(move.label)")
    }
}
