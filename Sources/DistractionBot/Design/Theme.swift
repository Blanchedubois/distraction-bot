import SwiftUI
import AppKit
import CoreText

// MARK: - Colors (warm paper, sage accent — copied from Ledger, §2.5)

extension NSColor {
    convenience init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02x%02x%02x", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

extension Color {
    static func dyn(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
    /// A custom "#rrggbb" that lifts itself in dark the way the six families do: 22 % toward white (§3.5).
    static func lifted(hex: String) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            let base = NSColor(hex: hex)
            guard app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return base }
            return base.blended(withFraction: 0.22, of: .white) ?? base
        })
    }
}

enum Theme {
    // Dark column: Ledger's original values (PLAN_DESIGN_CLEANUP §5a, revised 2026-10-28: the mid-tone lift of G0 was reverted —
    // "return it back to its original poppy colors"; only the subject colours below carry a lighter dark variant).
    static let bg     = Color.dyn("#f5f2ec", "#161511")
    static let paper  = Color.dyn("#fffdf9", "#232119")
    static let paper2 = Color.dyn("#f9f6ef", "#2a281f")
    static let ink    = Color.dyn("#17150f", "#f3efe6")
    static let ink2   = Color.dyn("#2f2c24", "#dcd8cc")
    static let muted  = Color.dyn("#716c61", "#9b958a")
    static let muted2 = Color.dyn("#a7a094", "#6c675d")
    static let line   = Color.dyn("#e4e0d6", "#3a372f")
    static let line2  = Color.dyn("#c6c0b3", "#5c574d")
    static let ghost  = Color.dyn("#efebe2", "#2d2a22")
    static let danger = Color.dyn("#c0392b", "#e0705f")
    static let ok     = Color.dyn("#4f8a3f", "#8fc46f")
    static let warn   = Color.dyn("#cf7a23", "#e3a155")

    // The six families carry a slightly lighter dark variant (≈ +10 L*, hue kept), as danger/ok/warn do (§5a Q13, kept in the revision).
    static let peach  = Color.dyn("#ff6a2b", "#ff9156")
    static let butter = Color.dyn("#f3c021", "#f6c640")
    static let sky    = Color.dyn("#2f6bff", "#708aff")
    static let sage   = Color.dyn("#3f9d6b", "#6bbc8d")
    static let lilac  = Color.dyn("#7a52e8", "#9e74fe")
    static let blush  = Color.dyn("#f2566b", "#ff808d")
    static let accent = sage
    static let families: [(String, Color)] = [("peach", peach), ("butter", butter), ("sky", sky), ("sage", sage), ("lilac", lilac), ("blush", blush)]

    /// Family name or "#rrggbb".
    static func accent(_ name: String?) -> Color {
        guard let name else { return peach }
        if name.hasPrefix("#") { return Color.lifted(hex: name) }
        return families.first { $0.0 == name }?.1 ?? peach
    }

    // MARK: Type — Space Grotesk for display, titles and body; SF Mono for labels
    static let family = "Space Grotesk"
    static func display(_ size: CGFloat, _ weight: Font.Weight = .light) -> Font { .custom(family, size: size).weight(weight) }
    static func title(_ size: CGFloat = 17) -> Font { .custom(family, size: size).weight(.regular) }
    static func body(_ size: CGFloat = 13.5, _ weight: Font.Weight = .regular) -> Font { .custom(family, size: size).weight(weight) }
    static func mono(_ size: CGFloat = 10, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .monospaced) }

    static let radius: CGFloat = 16
    static let radiusCell: CGFloat = 14
    static let inset: CGFloat = 16

    /// Register the bundled Space Grotesk faces once, before any view renders.
    static func registerFonts() {
        guard let dir = Bundle.module.url(forResource: "Fonts", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }
}

func titleCase(_ s: String) -> String {
    s.lowercased().split(separator: " ").map { w in
        guard let f = w.first else { return String(w) }
        return f.uppercased() + w.dropFirst()
    }.joined(separator: " ")
}

func openExternal(_ url: String) {
    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
}

extension ISO8601DateFormatter {
    /// Parses timestamps with or without fractional seconds.
    static func flexible(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    /// yyyy-MM-dd in the local calendar day, for comparing with the API's date strings.
    static let ymd: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; f.timeZone = .current; return f }()
}
