// Stand-in for the four week strengths of `Tint` (Design/Type.swift) so `scripts/week-check.swift` compiles without SwiftUI's
// Theme. Keep the values equal to Type.swift's weekFill/weekEdge/weekOutline/weekWatermark (event-skin.css: 22/16 · 56/46 · 66/56 · 16/26).
enum Tint {
    static func weekFill(dark: Bool) -> Double { dark ? 0.16 : 0.22 }
    static func weekEdge(dark: Bool) -> Double { dark ? 0.46 : 0.56 }
    static func weekOutline(dark: Bool) -> Double { dark ? 0.56 : 0.66 }
    static func weekWatermark(dark: Bool) -> Double { dark ? 0.26 : 0.16 }
}
