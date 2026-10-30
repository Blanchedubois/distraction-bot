import SwiftUI

/// A score as a ring with its figure inside (PLAN_REWORK R4's ring on Progress' loop card, lifted by PLAN_SUBJECT_PROGRESS S1 so the
/// course page draws the same one): track `line`, the arc to `value`/100 in `tint`, `—` when there is no score. The loop card passes
/// the verdict's colour; the course page passes the course's (one accent, §5a Q3).
struct ScoreRing: View {
    let value: Int?
    var tint: Color = Theme.accent
    var size: CGFloat = 56
    var lineWidth: CGFloat = 5
    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: lineWidth)
            Circle().trim(from: 0, to: Double(value ?? 0) / 100).stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)).rotationEffect(.degrees(-90))
            Text(value.map { "\($0)" } ?? "—").font(Type.strong).monospacedDigit().foregroundStyle(Theme.ink)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(value.map { "score \($0)" } ?? "no score yet")
    }
}
