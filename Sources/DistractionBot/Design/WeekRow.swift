import SwiftUI

/// The week row of flames (PLAN_GAME_LOOP §3.3–3.4, G2): Monday first · a filled flame for a session day · a hollow one for a day a
/// freeze bridged · a dot for a miss · an empty dot for a day to come (today, until its first session) · today ringed. One accent.
/// Home's streak card, the closing card (G4) and Progress' loop card (PLAN_REWORK R4) draw it from `OverallFigures.weekCells`.
struct WeekRow: View {
    let cells: [WeekCell]
    let today: Int
    var tint: Color = Theme.accent
    var size: CGFloat = 30
    private static let letters = ["m", "t", "w", "t", "f", "s", "s"]
    var body: some View {
        HStack(spacing: Space.stack) {
            ForEach(0..<7, id: \.self) { i in
                VStack(spacing: Space.tight) {
                    ZStack {
                        if i == today { Circle().strokeBorder(tint.opacity(0.5), lineWidth: 1) }
                        switch i < cells.count ? cells[i] : .future {
                        case .session: Icon("flame.fill", .row, color: tint)
                        case .frozen: Icon("flame", .row, color: Theme.muted)
                        case .missed: Circle().fill(Theme.line2).frame(width: 5, height: 5)
                        case .future: Circle().strokeBorder(Theme.line2, lineWidth: 1).frame(width: 5, height: 5)
                        }
                    }
                    .frame(width: size, height: size)
                    MonoLabel(Self.letters[i], color: i == today ? Theme.ink : Theme.muted2)
                }
                .accessibilityLabel("\(Self.letters[i]) \(i < cells.count ? cells[i].word : "to come")")
            }
        }
    }
}
