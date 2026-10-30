import SwiftUI

// Copied from Transcriber (PLAN_OBJECTIVES_TAB §2.6–2.7, U0): the SF Symbol catalogue, the icon picker and its browser,
// the accent picker, and two small helpers. Nothing here is this app's own design.

/// Every SF Symbol installed on this Mac, read from the system catalogue (what the SF Symbols app shows),
/// in Apple's display order, with categories for filtering. Falls back to the curated list offline.
enum Symbols {
    static let base = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/"
    static let all: [String] = {
        // drop only locale variants (a trailing language code such as ".ar", ".zh.traditional", ".rtl"), never real names like "square.and.arrow.up"
        let locale = try! NSRegularExpression(pattern: "\\.(ar|he|hi|ja|ko|th|zh|my|km|el|bn|gu|kn|ml|mr|or|pa|si|ta|te|ur|vi|tr|ne|sat|mn|lo|rtl)(\\.traditional)?$")
        if let arr = NSArray(contentsOfFile: base + "symbol_order.plist") as? [String], !arr.isEmpty {
            return arr.filter { locale.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil && !$0.contains(".rtl") }
        }
        return fallback
    }()
    /// category key → symbol names
    static let categories: [(key: String, label: String, symbols: [String])] = {
        guard let cats = NSArray(contentsOfFile: base + "categories.plist") as? [[String: Any]],
              let map = NSDictionary(contentsOfFile: base + "symbol_categories.plist") as? [String: [String]] else { return [] }
        var bucket: [String: [String]] = [:]
        for (name, keys) in map where all.contains(name) { for k in keys { bucket[k, default: []].append(name) } }
        var out: [(key: String, label: String, symbols: [String])] = cats.compactMap { c in
            // this Mac's categories.plist carries no "label" (only key and icon): the key, capitalised, stands in (U0 §6)
            guard let key = c["key"] as? String, key != "all", let syms = bucket[key], !syms.isEmpty else { return nil }
            let label = (c["label"] as? String) ?? key.replacingOccurrences(of: "_", with: " ").capitalized
            return (key, label, syms.sorted())
        }
        // a hand-picked science shelf for course icons
        let science = ["atom", "function", "x.squareroot", "sum", "flask", "testtube.2", "cross.vial", "camera.macro", "allergens", "microbe", "leaf", "tree", "ant", "ladybug", "bird", "fish", "tortoise", "hare", "lizard", "pawprint", "carrot", "brain", "brain.head.profile", "heart", "lungs", "ear", "eye", "hand.raised", "figure.walk", "figure.run", "bolt.heart", "waveform.path.ecg", "pills", "syringe", "bandage", "stethoscope", "cross.case", "facemask", "ivfluid.bag", "medical.thermometer", "drop", "drop.degreesign", "thermometer.medium", "humidity", "sun.max", "moon.stars", "sparkles", "globe.americas", "mountain.2", "water.waves", "wind", "snowflake", "flame", "tornado", "cloud.sun", "magnifyingglass", "scope", "binoculars", "camera.aperture", "cube.transparent", "circle.hexagongrid", "point.3.connected.trianglepath.dotted", "chart.xyaxis.line", "ruler", "compass.drawing", "scalemass", "gauge.with.needle", "cpu", "lightbulb", "graduationcap", "book", "books.vertical", "pencil.and.outline"]
            .filter { all.contains($0) }
        out.insert(("science", "Science & bio", science), at: 0)
        return out
    }()
    static let fallback = ["waveform", "atom", "function", "flask", "microscope", "lightbulb", "book", "graduationcap", "brain", "sparkles", "bolt",
                           "sun.max", "moon.stars", "globe", "map", "scope", "testtube.2", "x.squareroot", "sum", "chart.xyaxis.line", "chart.bar",
                           "cube", "camera.aperture", "eye", "leaf", "drop", "flame", "snowflake", "wind", "magnet", "cpu", "network", "person.2",
                           "bubble.left.and.bubble.right", "calendar", "clock", "flag", "star", "pin", "folder", "doc.text", "mic", "music.note", "recordingtape"]
}

/// Click the big symbol to choose any SF Symbol: search box, category pills, lazy grid.
extension String {
    /// U4 (PLAN_OBJECTIVES_TAB §3.5): an icon string that is one emoji grapheme rather than an SF Symbol name.
    var isEmojiIcon: Bool {
        guard count == 1, let sc = unicodeScalars.first else { return false }
        return sc.properties.isEmojiPresentation || (sc.properties.isEmoji && sc.value > 0x238C)
    }
}

/// One icon, however it is stored: an SF Symbol by name, or an emoji drawn as text at the same size (U4).
struct Glyph: View {
    let icon: String
    var size: CGFloat = 20
    var weight: Font.Weight = .regular
    var color: Color = Theme.ink
    var body: some View {
        if icon.isEmojiIcon { Text(icon).font(.system(size: size)) }   // lint-ok: a tinted glyph sized by its box (Icon is for the scale's four sizes)
        else { Image(systemName: icon).font(.system(size: size, weight: weight)).foregroundStyle(color) }   // lint-ok: same
    }
}

struct IconPicker: View {
    let icon: String
    let accent: Color
    var size: CGFloat = 58
    let onPick: (String) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Glyph(icon: icon, size: size * 0.52, weight: .light, color: accent)
                .frame(width: size, height: size).background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(accent.opacity(0.12)))
        }
        .buttonStyle(.plain).help("Change icon")
        .popover(isPresented: $open, arrowEdge: .bottom) { SymbolBrowser(current: icon, accent: accent) { onPick($0); open = false } }
    }
}

struct SymbolBrowser: View {
    let current: String
    let accent: Color
    let onPick: (String) -> Void
    @State private var q = ""
    @State private var category: String? = nil
    @State private var emoji = ""        // U4: type or paste one emoji instead of a symbol

    private var shown: [String] {
        var xs = category.flatMap { k in Symbols.categories.first { $0.key == k }?.symbols } ?? Symbols.all
        let t = q.trimmingCharacters(in: .whitespaces).lowercased()
        if !t.isEmpty { xs = xs.filter { $0.contains(t) } }
        return xs
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack {
                PillField(placeholder: "search \(Symbols.all.count) symbols", text: $q, width: 260)
                Spacer()
                MonoLabel(current)
            }
            HStack(spacing: Space.stack) {   // U4 §3.5: an emoji is a valid icon — one grapheme, taken as typed
                PillField(placeholder: "or an emoji, e.g. 🧬", text: $emoji, width: 160)
                let e = emoji.trimmingCharacters(in: .whitespaces)
                if e.isEmojiIcon { PillButton(text: "use \(e)", kind: .accent, accent: accent) { onPick(e) } }
                else if !e.isEmpty { MonoLabel("one emoji only", color: Theme.warn) }
                Spacer()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.tight) {
                    PillButton(text: "all", kind: category == nil ? .on : .neutral, accent: accent) { category = nil }
                    ForEach(Symbols.categories, id: \.key) { c in
                        PillButton(text: c.label, kind: category == c.key ? .on : .neutral, accent: accent) { category = c.key }
                    }
                }
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: Space.tight), count: 12), spacing: Space.tight) {
                    ForEach(shown, id: \.self) { ic in
                        Button { onPick(ic) } label: {
                            Image(systemName: ic).font(.system(size: 15)).frame(width: 36, height: 36)   // lint-ok: a browser cell, sized by its 36 pt box
                                .foregroundStyle(ic == current ? accent : Theme.ink)
                                .background(RoundedRectangle(cornerRadius: 8).fill(ic == current ? accent.opacity(0.2) : .clear))
                        }.buttonStyle(.plain).help(ic)
                    }
                }
                .padding(Space.hair)
            }
            .frame(height: 340)
            MonoLabel("\(shown.count) symbols")
        }
        .padding(Space.card)
        .frame(width: 520)
    }
}

extension Color {
    /// "#rrggbb" for storing a custom accent.
    var hexString: String { (NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)).hexString }
}

/// Six family swatches plus a system colour well for any other colour. `accent` is a family name or "#rrggbb".
struct AccentPicker: View {
    @Binding var accent: String
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        HStack(spacing: Space.stack) {
            ForEach(Theme.families, id: \.0) { fam in
                Button { accent = fam.0 } label: {
                    ZStack {
                        Circle().fill(fam.1).frame(width: 26, height: 26)
                        if accent == fam.0 { Icon("checkmark", .small, color: .white) }
                    }
                    .overlay(Circle().strokeBorder(.white.opacity(accent == fam.0 ? 0.9 : 0), lineWidth: 2))
                }.buttonStyle(.plain).help(fam.0)
            }
            Rectangle().fill(Theme.line).frame(width: 1, height: 22)
            if snapshot { Circle().fill(Theme.accent(accent)).frame(width: 22, height: 22) }   // ImageRenderer cannot draw ColorPicker
            else {
                ColorPicker("", selection: Binding(get: { Theme.accent(accent) }, set: { accent = $0.hexString }), supportsOpacity: false)
                    .labelsHidden().help("Any colour")
            }
            if accent.hasPrefix("#") { MonoLabel(accent) }
        }
    }
}

func relativeDate(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
    return f.localizedString(for: d, relativeTo: Date())
}

func timeGreeting() -> String {
    let h = Calendar.current.component(.hour, from: Date())
    return h < 5 ? "Up late" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
}
