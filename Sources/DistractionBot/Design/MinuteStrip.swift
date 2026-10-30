import SwiftUI

/// PLAN_MINUTE_STRIP M1 (§3.2): a session drawn as it happened. The track is the whole plan in the course's tint at 0.12; focus is solid,
/// a detour a paper gap with an amber underline (red when its warning was ignored), away a hollow outline, paused a muted fill, what was
/// left of the plan dashed; a launch is a red tick. Detour, away and paused spans narrower than 3 pt are drawn at 3 pt, centred (§5a Q1).
/// `highlight` (M2) thickens one span's underline or outline while the end card's tally points at it.
struct MinuteStrip: View {
    let spans: [StripSpan]
    var marks: [StripMark] = []
    let length: Int                   // seconds the full width stands for
    var tint: Color = Theme.accent
    var height: CGFloat = 8
    var highlight: Set<Int> = []      // span indices; mark indices are offset by `spans.count`

    private static let minWidth: CGFloat = 3

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(tint.opacity(0.12)).frame(height: height)
                ForEach(Array(spans.enumerated()).filter { $0.element.kind == .focus }, id: \.offset) { i, s in piece(i, s, w) }   // focus first,
                ForEach(Array(spans.enumerated()).filter { $0.element.kind != .focus }, id: \.offset) { i, s in piece(i, s, w) }   // the rest over it
                ForEach(Array(marks.enumerated()), id: \.offset) { i, m in
                    let lit = highlight.contains(spans.count + i)
                    let tickW: CGFloat = lit ? 3 : (height > 4 ? 2 : 1.5)   // the 3-pt strip's tick stays inside the line, half-strength
                    Capsule().fill(Theme.danger.opacity(height > 4 ? 1 : 0.6)).frame(width: tickW, height: height + (height > 4 ? 6 : 2))
                        .offset(x: x(m.at, w) - tickW / 2, y: height > 4 ? -3 : -1)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Self.summary(spans, marks))
    }

    private func x(_ seconds: Int, _ w: CGFloat) -> CGFloat { w * CGFloat(seconds) / CGFloat(max(1, length)) }

    /// One span at its place; a short non-focus span widened to 3 pt around its middle.
    private func piece(_ i: Int, _ s: StripSpan, _ w: CGFloat) -> some View {
        let x0 = x(s.from, w), x1 = x(s.to, w)
        let wide = s.kind != .focus && x1 - x0 < Self.minWidth
        let width = wide ? Self.minWidth : max(0.5, x1 - x0 - (s.kind == .focus ? 0 : 1))
        let left = wide ? (x0 + x1) / 2 - Self.minWidth / 2 : x0
        let lit = highlight.contains(i)
        let line: CGFloat = lit ? 3 : (height > 4 ? 2 : 1)
        let r: CGFloat = height > 4 ? 2 : 1
        return Group {
            switch s.kind {
            case .focus: RoundedRectangle(cornerRadius: r).fill(tint)
            case .detour: RoundedRectangle(cornerRadius: r).fill(Theme.paper)
                .overlay { if lit { RoundedRectangle(cornerRadius: r).fill((s.heeded ? Theme.warn : Theme.danger).opacity(0.3)) } }   // M2: the gap lights up
                .overlay(alignment: .bottom) { Rectangle().fill(s.heeded ? Theme.warn : Theme.danger).frame(height: line) }
            case .away: RoundedRectangle(cornerRadius: r).fill(tint.opacity(lit ? 0.25 : 0)).overlay(RoundedRectangle(cornerRadius: r).strokeBorder(tint.opacity(0.7), lineWidth: lit ? 2 : 1))
            case .paused: RoundedRectangle(cornerRadius: r).fill(Theme.muted2.opacity(lit ? 0.7 : 0.4))
            case .short: RoundedRectangle(cornerRadius: r).strokeBorder(lit ? Theme.muted : Theme.line2, style: StrokeStyle(lineWidth: lit ? 2 : 1, dash: [3, 2]))
            }
        }
        .frame(width: max(0.5, width), height: height)
        .offset(x: max(0, left))
    }

    /// `52 minutes: 48 focused, 2 detours, 3 away, launched Steam`.
    static func summary(_ spans: [StripSpan], _ marks: [StripMark]) -> String {
        func mins(_ k: StripSpan.Kind) -> Int { spans.filter { $0.kind == k }.reduce(0) { $0 + $1.seconds } / 60 }
        let total = spans.filter { $0.kind != .short }.reduce(0) { $0 + $1.seconds } / 60
        let detours = spans.filter { $0.kind == .detour }.count
        var parts = ["\(mins(.focus)) focused"]
        if detours > 0 { parts.append("\(detours) detour\(detours == 1 ? "" : "s")") }
        if mins(.away) > 0 { parts.append("\(mins(.away)) away") }
        if mins(.paused) > 0 { parts.append("\(mins(.paused)) paused") }
        parts += marks.map { "launched \($0.site)" }
        return "\(total) minutes: " + parts.joined(separator: ", ")
    }
}
