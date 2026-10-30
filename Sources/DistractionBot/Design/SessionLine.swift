import SwiftUI

/// One session as a line (PLAN_HISTORY_TAB Y2, the objective overview's `sessionRow` recipe lifted so two screens draw
/// it the same): `18:59–19:59 · 60 min · [presentation] [normal] · 3 warnings · 1 block · [finished]`. The date is
/// optional (History knows the day; an objective's log spans days). Narrow drops the kind and strictness pills.
struct SessionLine: View {
    let session: ObjectiveSession
    var accent: Color = Theme.accent
    var showDate: Bool = false
    var action: (() -> Void)? = nil
    @Environment(\.narrow) private var narrow

    private static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f }()

    var body: some View {
        let r = session
        let counts = [r.warnings > 0 ? "\(r.warnings) warning\(r.warnings == 1 ? "" : "s")" : nil, r.blocks > 0 ? "\(r.blocks) block\(r.blocks == 1 ? "" : "s")" : nil].compactMap { $0 }
        let when = (showDate ? "\(Self.dayFormat.string(from: r.started)) · " : "") + "\(clock(r.started))–\(r.ended.map { clock($0) } ?? "…")"
        HStack(spacing: Space.loose) {
            Text(when).font(Type.data).foregroundStyle(Theme.muted2).lineLimit(1).frame(width: showDate ? 215 : 118, alignment: .leading)
            Text(minutes(TimeInterval(r.seconds))).font(Type.strong).foregroundStyle(Theme.ink).frame(width: 72, alignment: .leading)
            if !narrow {
                Pill(r.kind ?? "—")
                Pill(r.strictness, kind: Self.severityKind(r.strictness))
            }
            MonoLabel(counts.isEmpty ? "clean" : counts.joined(separator: " · "), color: counts.isEmpty ? Theme.ok : Theme.muted).lineLimit(1)
            Spacer()
            Self.endingPill(r.endedBy, accent: accent)
            if action != nil { Icon("chevron.right", .small, color: Theme.muted2) }
        }
        .rowPadding()
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .help(action == nil ? "" : "Open the log for this session")
    }

    static func severityKind(_ s: String) -> PillKind { .neutral }   // R5 (PLAN_REWORK D17): the level is a fact, not a verdict
    static func endingPill(_ e: String, accent: Color) -> Pill {
        switch e {
        case "finished": return Pill("finished", kind: .ok)
        case "ended": return Pill("ended", kind: .neutral)
        case "quit": return Pill("quit", kind: .warn)
        case "live": return Pill("in session", kind: .accent, dot: true, accent: accent)
        default: return Pill(e, kind: e.contains("phrase") ? .danger : .neutral)
        }
    }
}

extension ObjectiveSession {
    /// The Stats rule (`SessionRecord.isTest`, PLAN_STATS_TAB §5a Q6): a B-phase test goal, or under two minutes and not live.
    var isTest: Bool {
        if goal.range(of: #"^B\d+\s"#, options: .regularExpression) != nil { return true }
        return endedBy != "live" && seconds < 120
    }
}
