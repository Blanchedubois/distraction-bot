import SwiftUI

/// A course's level as a ring (PLAN_SUBJECT_PROGRESS §3.4b, S5): `LevelBar` drawn radially — five arcs from twelve o'clock, one per
/// level, finished ones whole in the tint, the current one filled by `into`, the rest in `Theme.line`. The level and the XP sit in the
/// middle; what is left to the next level goes under it (the caller's line). One accent, the course's.
struct LevelRing: View {
    let level: Int            // 0…5
    let into: Double          // 0…1 toward the next band
    let xp: Int
    var tint: Color = Theme.accent
    var size: CGFloat = 132
    private var lineWidth: CGFloat { size >= 120 ? 10 : 8 }
    private static let gap = 0.035                       // between arcs, as a fraction of the turn (room for the round caps)
    private static let arc = (1 - 5 * gap) / 5

    var body: some View {
        ZStack {
            ForEach(0..<5, id: \.self) { i in
                let start = Double(i) * (Self.arc + Self.gap) + Self.gap / 2
                Circle().trim(from: start, to: start + Self.arc)
                    .stroke(Theme.line, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                if fill(i) > 0 {
                    Circle().trim(from: start, to: start + Self.arc * fill(i))
                        .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                }
            }
            .rotationEffect(.degrees(-90))
            VStack(spacing: Space.hair) {
                Text("L\(level)").font(Type.figureCard).monospacedDigit().foregroundStyle(Theme.ink)
                MonoLabel("\(xp) XP")
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Level \(level) of 5, \(xp) XP")
    }
    /// Arc `i` (0-based) is whole below the level, `into` at the level, empty above.
    private func fill(_ i: Int) -> Double { i < level ? 1 : i == level ? min(1, max(0, into)) : 0 }
}
