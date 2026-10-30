import SwiftUI

/// The session statement (PLAN_STATS_TAB S4): one session's ledger — planned · elapsed · paused · detours · net focus — and the apps
/// in front, longest first. Rebuilt in R4 (PLAN_REWORK §6) after `Progress/Subjects.swift`, which also held it, was removed with the rings;
/// the lines and words are the ones the earlier render showed (`the length you chose` · `until you stopped` · `from each verdict to when it
/// ended` · `of an open session`).
struct SessionStatement: View {
    @Environment(Store.self) private var store
    let s: SessionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            line("Planned", s.plannedMinutes.map { minutes(Double($0) * 60) } ?? (s.live ? "until you stop" : "until you stopped"),
                 note: s.plannedMinutes == nil ? nil : "the length you chose", bold: false)
            line("Elapsed", minutes(Double(s.focusedSeconds)), plus: true)
            line("Paused", s.pausedSeconds > 0 ? "−" + minutes(Double(s.pausedSeconds)) : "0 s", color: s.pausedSeconds > 0 ? Theme.muted : Theme.muted2)
            line("Detours", s.detourSeconds > 0 ? "−" + minutes(Double(s.detourSeconds)) : (s.caught > 0 ? "−" : "0 s"),
                 note: s.caught > 0 ? "\(s.caught) caught · from each verdict to when it ended" : nil, color: s.detourSeconds > 0 ? Theme.warn : Theme.muted2)
            Rectangle().fill(Theme.line).frame(height: 1)
            line("Net focus", minutes(Double(s.netFocusSeconds)), note: s.plannedMinutes == nil ? "of an open session" : nil, bold: true)
            if !s.usage.isEmpty {
                MonoLabel("in front").padding(.top, Space.tight)
                let top = Array(s.usage.prefix(4))
                let total = max(1, top.reduce(0) { $0 + $1.1 })
                VStack(alignment: .leading, spacing: Space.tight) {
                    ForEach(Array(top.enumerated()), id: \.offset) { _, u in
                        HStack(spacing: Space.stack) {
                            Text(appName(u.0)).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1).frame(width: 120, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(Theme.ghost).frame(height: 6)
                                    .overlay(alignment: .leading) { Capsule().fill(Theme.accent.opacity(0.6)).frame(width: max(6, g.size.width * CGFloat(u.1) / CGFloat(total)), height: 6) }
                            }
                            .frame(height: 6)
                            MonoLabel(minutes(Double(u.1)), color: Theme.muted).frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    /// `Planned   52 min   the length you chose` — the figure in `Type.strong`, a muted note under it, `+` for the elapsed line.
    private func line(_ title: String, _ value: String, note: String? = nil, color: Color = Theme.ink, bold: Bool = false, plus: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.stack) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(title).font(bold ? Type.strong : Type.body).foregroundStyle(bold ? Theme.ink : Theme.ink2)
                if let note { MonoLabel(note, color: Theme.muted2).lineLimit(1) }
            }
            Spacer(minLength: Space.stack)
            Text((plus ? "+" : "") + value).font(bold ? Type.figureSmall : Type.strong).monospacedDigit().foregroundStyle(color)
        }
    }

    /// The app's name from the running list, else the bundle id's last part.
    private func appName(_ bundle: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle), let n = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleName") as? String { return n }
        return bundle.split(separator: ".").last.map(String.init) ?? bundle
    }
}
