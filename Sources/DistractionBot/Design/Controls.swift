import SwiftUI

/// A dropdown that looks like the app: mono uppercase label in a pill, chevron,
/// native menu behind it. Use instead of Picker everywhere a value is chosen.
struct PillMenu<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var placeholder: String = "choose"
    var kind: PillKind = .neutral
    var accent: Color = Theme.accent
    var width: CGFloat? = nil
    var leadingSymbol: String? = nil

    private var label: String { options.first { $0.0 == selection }?.1 ?? placeholder }
    @Environment(\.snapshot) private var snapshot

    var body: some View {
        if snapshot { pill } else { menu }
    }

    private var pill: some View {
        HStack(spacing: Space.pillGap) {
            if let leadingSymbol { Icon(leadingSymbol, .small, color: fg) }
            Text(label.uppercased()).font(Type.pill).tracking(Type.pillTracking).lineLimit(1)
            Icon("chevron.down", .tiny, color: fg).opacity(0.7)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, Space.pillH)
        .frame(width: width, height: Self.height, alignment: .leading)
        .background(Capsule().fill(kind == .on ? accent : Theme.paper))
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .fixedSize(horizontal: width == nil, vertical: true)
    }

    /// Pill height, shared by the snapshot twin and the real menu so a row of pills lines up with `PillButton` (mono 10 + 5 pt padding ≈ 24; this is 26 with 6 pt).
    static var height: CGFloat { 26 }

    private var menu: some View {
        // Ledger's label, exactly (one capsule, 11/6 padding, symbol · label · one chevron on a single baseline), with the
        // native Menu asked to add nothing: `.menuStyle(.button)` + `.buttonStyle(.plain)` leaves the label as drawn, and
        // `.menuIndicator(.hidden)` keeps the system chevron off. (`.borderlessButton` on macOS 26 dropped the label's
        // chrome in H8 and, with the chrome moved onto the Menu in H9, padded it unevenly — the user's two screenshots.)
        Menu {
            ForEach(options, id: \.0) { opt in
                Button { selection = opt.0 } label: {
                    if opt.0 == selection { Label(opt.1, systemImage: "checkmark") } else { Text(opt.1) }
                }
            }
        } label: {
            HStack(spacing: Space.pillGap) {
                if let leadingSymbol { Icon(leadingSymbol, .small, color: fg) }
                Text(label.uppercased()).font(Type.pill).tracking(Type.pillTracking).lineLimit(1)
                Icon("chevron.down", .tiny, color: fg).opacity(0.7)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, Space.pillH)
            .frame(width: width, height: Self.height, alignment: .leading)
            .background(Capsule().fill(kind == .on ? accent : Theme.paper))
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width == nil, vertical: true)
    }

    private var fg: Color {
        switch kind {
        case .on: return .white
        case .accent: return accent
        case .warn: return Theme.warn
        case .danger: return Theme.danger
        case .ok: return Theme.ok
        case .neutral: return Theme.ink
        }
    }
    private var border: Color {
        switch kind {
        case .on: return .clear
        case .neutral: return Theme.line2
        default: return fg.opacity(0.6)
        }
    }
}

/// Search field in the same language.
struct PillField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 180
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        HStack(spacing: Space.pillGap) {
            Icon("magnifyingglass", .small, color: Theme.muted)
            if snapshot { Text(text.isEmpty ? placeholder : text).font(Type.body).foregroundStyle(text.isEmpty ? Theme.muted2 : Theme.ink).frame(maxWidth: .infinity, alignment: .leading) }
            else { TextField(placeholder, text: $text).textFieldStyle(.plain).font(Type.body).foregroundStyle(Theme.ink) }
            if !text.isEmpty {
                Button { text = "" } label: { Icon("xmark.circle.fill", .small, color: Theme.muted2) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.pillH).padding(.vertical, Space.pillV)
        .frame(width: width)
        .background(Capsule().fill(Theme.paper))
        .overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
    }
}

/// Controls row under a page title: wraps instead of squeezing.
struct ControlsRow<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: Space.stack) { content; Spacer(minLength: 0) }
            .padding(.top, -14)   // pulls the row up under the page title; a layout fudge from Ledger, not a scale value
    }
}


/// R3 (PLAN_REWORK §3.5, §5a Q5): a pill that opens a menu of toggles — `show ▾` on the Today strip (detours · false alarms · blocks · looks).
/// The PillMenu recipe (one capsule, 11/6 padding, label · chevron) with `Toggle` rows; a render shows the pill alone.
struct PillToggles<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Set<Value>
    var label: String = "show"
    @Environment(\.snapshot) private var snapshot

    var body: some View {
        let pill = HStack(spacing: Space.pillGap) {
            Text(label.uppercased()).font(Type.pill).tracking(Type.pillTracking).lineLimit(1)
            Icon("chevron.down", .tiny, color: Theme.ink).opacity(0.7)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, Space.pillH)
        .frame(height: PillMenu<String>.height)
        .background(Capsule().fill(Theme.paper))
        .overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
        .contentShape(Capsule())
        if snapshot { pill }
        else {
            Menu {
                ForEach(options, id: \.0) { opt in
                    Toggle(opt.1, isOn: Binding(get: { selection.contains(opt.0) }, set: { on in if on { selection.insert(opt.0) } else { selection.remove(opt.0) } }))
                }
            } label: { pill }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
