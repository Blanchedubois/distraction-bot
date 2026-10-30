import SwiftUI

/// A course's level as five segments (PLAN_SCORING Z2 → PLAN_GAME_LOOP G1): filled ones in the tint, the current band's segment part-filled
/// by `into`, the rest in `Theme.line`. `mini` is the subject card's 2-pt form; the page and Progress draw the 3-pt one. With `before`
/// (G3) the current segment shows the old fill at 0.7 and the gain in the full tint, animated from `before` to `into` over 1 s unless
/// `animate` is false or Reduce Motion is on.
struct LevelBar: View {
    let level: Int            // 0…5
    let into: Double          // 0…1 toward the next band
    var tint: Color = Theme.accent
    var mini: Bool = false
    var before: Double? = nil
    var animate: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.snapshot) private var snapshot
    @State private var shown: Double? = nil   // the animated `into`; nil before the first appearance
    var body: some View {
        let current = shown ?? (before ?? into)
        HStack(spacing: mini ? Space.hair : Space.tight) {
            ForEach(0..<5, id: \.self) { i in
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        if let b = before, i == level {
                            Capsule().fill(tint).frame(width: g.size.width * CGFloat(min(1, max(0, current))))
                            Capsule().fill(tint.opacity(0.7)).frame(width: g.size.width * CGFloat(min(1, max(0, b))))
                        } else {
                            Capsule().fill(tint).frame(width: g.size.width * fill(i))
                        }
                    }
                }
            }
        }
        .frame(height: mini ? 2 : 3)
        .onAppear {
            guard before != nil else { return }
            if animate, !reduceMotion, !snapshot { shown = before; withAnimation(.easeOut(duration: 1).delay(0.4)) { shown = into } }
            else { shown = into }
        }
        .accessibilityLabel("Level \(level) of 5")
    }
    /// Segment `i` (0-based) is whole below the level, `into` at the level, empty above.
    private func fill(_ i: Int) -> CGFloat { i < level ? 1 : i == level ? CGFloat(min(1, max(0, into))) : 0 }
}
