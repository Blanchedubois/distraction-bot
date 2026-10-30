import SwiftUI

// Copied from Transcriber (PLAN_OBJECTIVES_TAB §2.7, U0): the glass pill chrome used for page-head actions and glyph-tinted choices.

/// Capsule chrome for pill menus: Liquid Glass on macOS 26, paper + hairline elsewhere (and in the offscreen render).
struct GlassCapsule: ViewModifier {
    var fill: Color? = nil
    var border: Color = Theme.line2
    @Environment(\.snapshot) private var snapshot
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !snapshot {
            if let fill {
                content.glassEffect(.regular.tint(fill).interactive(), in: .capsule)
            } else {
                content.glassEffect(.regular.interactive(), in: .capsule)
                    .overlay(Capsule().strokeBorder(border.opacity(0.6), lineWidth: 0.5))
            }
        } else {
            content
                .background(Capsule().fill(fill ?? Theme.paper))
                .overlay(Capsule().strokeBorder(fill == nil ? border : .clear, lineWidth: 1))
        }
    }
}

/// Action button drawn exactly like the glass pill menus (glyph · small caps · glass capsule), minus the chevron.
struct GlassActionPill: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = Theme.accent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.pillGap) {
                if let symbol { Icon(symbol, .small, color: tint) }
                Text(text.uppercased()).font(Type.pill).tracking(Type.pillTracking).lineLimit(1)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, Space.pillH).frame(height: PillMenu<String>.height)
            .modifier(GlassCapsule(fill: nil, border: Theme.line2))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Glyph-tinted pill menu, for subject / kind / severity choices.
struct IconChoice<Value: Hashable>: View {
    let symbol: String
    var tint: Color = Theme.muted
    let options: [(Value, String)]
    @Binding var selection: Value
    var title: String? = nil
    var body: some View {
        PillMenu(options: options, selection: $selection, placeholder: title ?? "choose", kind: .neutral, accent: tint, leadingSymbol: symbol)
            .help(title ?? "")
    }
}
