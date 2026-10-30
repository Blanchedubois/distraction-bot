import SwiftUI

// PLAN_DESIGN_CLEANUP §3 (G0): the one type scale, the one spacing scale, the icon sizes and the per-appearance tint
// strengths. Views use these names; no view picks a number of its own (scripts/type-lint.sh counts the strays).

// MARK: - Type — thirteen text styles (§3.1)

enum Type {
    static let page       = Theme.display(28, .medium)   // the page title under the kicker; overlay headlines
    static let greeting   = Theme.display(34, .medium)   // Home's greeting only
    static let figure     = Theme.display(44, .light)    // hero figures: score, focused today, time left   (+ monospacedDigit)
    static let hero       = Theme.display(64, .light)    // the one figure a card is about: Home's score (PLAN_CURRENT_SESSION C5) (+ monospacedDigit)
    static let figureCard = Theme.display(28, .light)    // a figure that owns a card or tile                (+ monospacedDigit)
    static let figureSmall = Theme.display(22, .light)   // a figure in a row or head                        (+ monospacedDigit)
    static let headline   = Theme.display(22, .medium)   // the one headline inside a card
    static let title      = Theme.title(16)              // section headers and card titles
    static let strong     = Theme.body(13, .medium)      // row titles, emphasised words, numbers in a row (+ monospacedDigit)
    static let body       = Theme.body(13)               // all copy; .lineSpacing(Space.hair) when it wraps
    static let caption    = Theme.body(11, .medium)      // chips and tags with a word in them
    static let label      = Theme.mono(9)                // small caps: kickers, sublines, column heads, legends — via MonoLabel
    static let pill       = Theme.mono(10)               // Pill, PillButton, PillMenu — the 26 pt pill recipe
    static let button     = Theme.mono(11, .medium)      // ActionButton
    static let data       = Theme.mono(10, .regular)     // times, hosts, durations, ms, hour labels — mixed case, no tracking

    static let labelTracking: CGFloat = 0.7
    static let pillTracking: CGFloat = 0.8
}

// MARK: - Space — seven values (§3.2), plus the pill and button recipe insets

enum Space {
    static let hair: CGFloat = 2        // a label under its figure, a subline under its title
    static let tight: CGFloat = 4       // glyph-to-text inside a chip
    static let stack: CGFloat = 8       // the default spacing of every stack inside a card; between pills in a row
    static let loose: CGFloat = 12      // between distinct parts of a card; row horizontal padding; grid gap inside a card
    static let card: CGFloat = 16       // card padding; the gap between widgets
    static let sheet: CGFloat = 24      // editor sheets and popovers; the Pair column gap; the page's top inset
    static let section: CGFloat = 32    // between sections on a page (24 when narrow)
    static func section(narrow: Bool) -> CGFloat { narrow ? sheet : section }

    // the page's own insets (Ledger's), not part of the scale
    static func pageH(narrow: Bool) -> CGFloat { narrow ? 20 : 28 }
    static let pageBottom: CGFloat = 80

    // the 26 pt pill recipe and the primary button, kept as they were
    static let pillH: CGFloat = 11, pillV: CGFloat = 5, pillGap: CGFloat = 7
    static let buttonH: CGFloat = 18, buttonV: CGFloat = 9
}

extension View {
    /// Card padding on every side.
    func cardPadding() -> some View { padding(Space.card) }
    /// A list row's padding: 12 across, 8 down.
    func rowPadding() -> some View { padding(.horizontal, Space.loose).padding(.vertical, Space.stack) }
}

// MARK: - Icon — four symbol sizes

/// An SF Symbol (or emoji) at one of the scale's sizes. `small` and `row` are semibold, `card` and `empty` regular.
struct Icon: View {
    enum Size: CGFloat { case tiny = 8, small = 10, row = 12, card = 20, empty = 36 }
    let name: String
    var size: Size = .row
    var color: Color = Theme.ink
    init(_ name: String, _ size: Size = .row, color: Color = Theme.ink) { self.name = name; self.size = size; self.color = color }
    private var weight: Font.Weight { switch size { case .tiny: return .bold; case .small, .row: return .semibold; case .card, .empty: return .regular } }
    var body: some View {
        if name.isEmojiIcon { Text(name).font(.system(size: size.rawValue)) }
        else { Image(systemName: name).font(.system(size: size.rawValue, weight: weight)).foregroundStyle(color) }
    }
}

// MARK: - Tint — how strongly a subject colour shows, per appearance (§3.5)

enum Tint {
    /// The card gradient's leading and middle stops (`CardStyle(gradient:)`).
    static func cardGradient(dark: Bool) -> (Double, Double) { dark ? (0.30, 0.08) : (0.22, 0.06) }
    /// The page's top gradient (`Page(tint:)`): top and 45 % stops.
    static func page(dark: Bool) -> (Double, Double) { dark ? (0.22, 0.11) : (0.16, 0.05) }
    /// A watermark glyph behind a card (`CardStyle`) and behind a page.
    static func watermark(dark: Bool) -> Double { dark ? 0.10 : 0.07 }
    static func pageWatermark(dark: Bool) -> Double { dark ? 0.13 : 0.09 }
    /// A tile or chip filled with the subject colour.
    static func fill(dark: Bool) -> Double { dark ? 0.18 : 0.12 }
    /// A card border in the accent.
    static func border(dark: Bool) -> Double { dark ? 0.6 : 0.5 }
    /// The week calendar's event skin (event-skin.css), folded in from WeekGeometry.Skin (its own values, unchanged).
    static func weekFill(dark: Bool) -> Double { dark ? 0.16 : 0.22 }
    static func weekEdge(dark: Bool) -> Double { dark ? 0.46 : 0.56 }
    static func weekOutline(dark: Bool) -> Double { dark ? 0.56 : 0.66 }
    static func weekWatermark(dark: Bool) -> Double { dark ? 0.26 : 0.16 }
}
