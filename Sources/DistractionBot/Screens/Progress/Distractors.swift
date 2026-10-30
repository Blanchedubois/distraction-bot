import SwiftUI

// Progress §2 "What pulls me away" (PLAN_STATS_TAB S2): the distractor treemap, the worst-first rows, the searches, the hour of day.

extension Distractor.Kind {
    var color: Color { switch self { case .site: return Theme.sky; case .app: return Theme.peach; case .search: return Theme.lilac } }
    var word: String { rawValue }
    var plural: String { self == .search ? "searches" : rawValue + "s" }
}

/// Ledger's merchant treemap: size = distractions + blocks, colour = kind, click → Log filtered to it.
struct DistractorTreemap: View {
    let stats: Stats
    let onOpen: (Distractor) -> Void
    var body: some View {
        let ds = stats.distractors.filter { $0.weight > 0 }
        if ds.isEmpty {
            EmptyState(symbol: "exclamationmark.bubble", text: "Nothing pulled you away in this range.")
        } else {
            VStack(alignment: .leading, spacing: Space.stack) {
                TreemapView(tiles: ds.map { d in
                    StatTile(id: d.id, name: d.name, group: d.kind.word, color: d.kind.color, value: Double(d.weight),
                             note: "\(d.count)× · \(d.blocked) blocked · \(d.kind.word)",
                             help: "\(d.name) · \(d.count) distraction\(d.count == 1 ? "" : "s") · \(d.blocked) block\(d.blocked == 1 ? "" : "s") · last \(d.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                }, format: { "\(Int($0))" }, onTap: { t in if let d = ds.first(where: { $0.id == t.id }) { onOpen(d) } })
                .frame(height: 318)
                HStack(spacing: Space.loose) {
                    ForEach([Distractor.Kind.site, .app, .search], id: \.self) { k in
                        let n = ds.filter { $0.kind == k }.reduce(0) { $0 + $1.weight }
                        if n > 0 { HStack(spacing: Space.tight) { Circle().fill(k.color).frame(width: 7, height: 7); MonoLabel("\(k.plural) \(n)") } }
                    }
                    Spacer()
                    MonoLabel("size = distractions + blocks · click to open the log", color: Theme.muted2)
                }
            }
        }
    }
}

/// Ledger's category rows: per distractor, count, how you answered, last seen, a trend arrow against the previous range.
struct WorstFirst: View {
    let stats: Stats
    let previous: Stats?
    let onOpen: (Distractor) -> Void
    @State private var all = false
    var body: some View {
        let ds = stats.distractors.filter { $0.weight > 0 }
        let rows = all ? ds : Array(ds.prefix(9))
        VStack(spacing: Space.stack) {
            if ds.isEmpty { EmptyState(symbol: "list.number", text: "No distractors yet.") }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, d in
                let before = previous?.distractors.first { $0.id == d.id }?.weight ?? 0
                Button { onOpen(d) } label: {
                    HStack(spacing: Space.stack) {
                        Text(String(format: "%02d", i + 1)).font(Type.data).foregroundStyle(Theme.muted2).monospacedDigit().frame(width: 22, alignment: .leading)
                        Circle().fill(d.kind.color).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text(d.name).font(Type.strong).foregroundStyle(Theme.ink).lineLimit(1)
                            MonoLabel(answerLine(d), color: Theme.muted).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if previous != nil { TrendArrow(now: d.weight, before: before) }
                        VStack(alignment: .trailing, spacing: Space.hair) {
                            Text("\(d.weight)").font(Type.strong).foregroundStyle(Theme.ink)
                            MonoLabel(d.blocked > 0 ? "\(d.count) + \(d.blocked) blocked" : "\(d.count) caught", color: Theme.muted2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("last \(d.lastSeen.formatted(date: .abbreviated, time: .shortened)) · click to open the log")
            }
            if ds.count > 9 { PillButton(text: all ? "top 9" : "+ \(ds.count - 9) more", kind: .neutral) { withAnimation { all.toggle() } }.frame(maxWidth: .infinity, alignment: .trailing) }
        }
    }
    private func answerLine(_ d: Distractor) -> String {
        let order = ["back", "work", "snooze", "ignored"]
        let parts = order.compactMap { k in d.answers[k].map { "\(k) \($0)" } }
        let last = "last \(StudyDay.isToday(d.lastSeen) ? clock(d.lastSeen) : d.lastSeen.formatted(.dateTime.day().month(.abbreviated)))"
        return (parts.isEmpty ? [] : ["you said " + parts.joined(separator: " · ")]) .appending(last).joined(separator: " · ")
    }
}

private extension Array where Element == String { func appending(_ s: String) -> [String] { self + [s] } }

/// Ledger's CreepTile arrow: up is worse here, so red; down is sage.
struct TrendArrow: View {
    let now: Int
    let before: Int
    var body: some View {
        let pct: Int? = before > 0 ? Int((Double(now - before) / Double(before) * 100).rounded()) : (now > 0 ? nil : 0)
        HStack(spacing: Space.hair) {
            Image(systemName: before == 0 && now > 0 ? "sparkle" : (pct ?? 0) > 5 ? "arrow.up.right" : (pct ?? 0) < -5 ? "arrow.down.right" : "arrow.right").font(.system(size: Icon.Size.small.rawValue, weight: .semibold))   // lint-ok: an arrow glyph at Icon.small, inheriting the row colour
            if let pct { Text("\(abs(pct))%").font(Type.label) } else { Text("new").font(Type.label) }
        }
        .foregroundStyle(before == 0 && now > 0 ? Theme.warn : (pct ?? 0) > 5 ? Theme.danger : (pct ?? 0) < -5 ? Theme.sage : Theme.muted)
        .help(before == 0 ? "not seen in the previous range" : "\(before) in the previous range")
    }
}

/// The searches that were judged distractions, biggest first: Ledger's capsule bars.
struct SearchesCard: View {
    let stats: Stats
    let onOpen: (Distractor) -> Void
    var body: some View {
        let qs = stats.distractors.filter { $0.kind == .search && $0.weight > 0 }
        let maxW = max(1, qs.first?.weight ?? 1)
        VStack(spacing: Space.stack) {
            if qs.isEmpty { MonoLabel("no distracting searches in this range", color: Theme.muted2).frame(maxWidth: .infinity, alignment: .leading) }
            ForEach(qs.prefix(8)) { q in
                let (engine, query) = split(q.name)
                Button { onOpen(q) } label: {
                    HStack(spacing: Space.stack) {
                        MonoLabel(engine, color: Theme.muted2).frame(width: 60, alignment: .leading)
                        Text(query).font(Type.strong).foregroundStyle(Theme.ink).frame(width: 180, alignment: .leading).lineLimit(1)
                        GeometryReader { g in
                            Capsule().fill(Theme.lilac.opacity(0.75)).frame(width: max(4, g.size.width * CGFloat(q.weight) / CGFloat(maxW)), height: 8)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }.frame(height: 14)
                        Text("\(q.weight)").font(Type.data).foregroundStyle(Theme.muted).frame(width: 28, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
    private func split(_ s: String) -> (String, String) {
        guard let r = s.range(of: ": ") else { return ("", s) }
        return (String(s[..<r.lowerBound]), String(s[r.upperBound...]))
    }
}

/// Hour of day: minutes in session per hour as sage bars, distractions as orange ticks above them. Hand-drawn, like Ledger's strips.
struct HourOfDay: View {
    let stats: Stats
    var body: some View {
        let maxMin = max(1, stats.hours.map { $0.focusedSeconds / 60 }.max() ?? 1)
        let maxCaught = stats.hours.map(\.caught).max() ?? 0
        VStack(alignment: .leading, spacing: Space.stack) {
            HStack(alignment: .bottom, spacing: Space.tight) {
                ForEach(stats.hours) { h in
                    VStack(spacing: Space.hair) {
                        // ticks: one per distraction, capped at 8 with a "+"
                        VStack(spacing: Space.hair) {
                            if h.caught > 8 { MonoLabel("+\(h.caught - 8)", color: Theme.warn) }
                            ForEach(0..<min(8, h.caught), id: \.self) { _ in RoundedRectangle(cornerRadius: 1).fill(Theme.warn).frame(height: 3) }
                        }
                        .frame(height: 50, alignment: .bottom)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(h.focusedSeconds > 0 ? Theme.accent.opacity(0.35 + 0.65 * Double(h.focusedSeconds / 60) / Double(maxMin)) : Theme.ghost)
                            .frame(height: max(3, 70 * CGFloat(h.focusedSeconds / 60) / CGFloat(maxMin)))
                            .frame(height: 70, alignment: .bottom)
                    }
                    .frame(maxWidth: .infinity)
                    .help(String(format: "%02d:00 · %d min in session · %d distraction%@", h.hour, h.focusedSeconds / 60, h.caught, h.caught == 1 ? "" : "s"))
                }
            }
            HStack(spacing: Space.tight) {
                ForEach(stats.hours) { h in
                    MonoLabel(h.hour % 3 == 0 ? String(format: "%02d", h.hour) : "", color: Theme.muted2).frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: Space.loose) {
                HStack(spacing: Space.tight) { RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.7)).frame(width: 10, height: 6); MonoLabel("minutes in session (tallest = \(maxMin) min)") }
                HStack(spacing: Space.tight) { RoundedRectangle(cornerRadius: 1).fill(Theme.warn).frame(width: 10, height: 3); MonoLabel("one distraction" + (maxCaught > 8 ? " · capped at 8" : "")) }
                Spacer()
                if let peak = stats.hours.max(by: { $0.caught < $1.caught }), peak.caught > 0 { MonoLabel(String(format: "most distracted around %02d:00", peak.hour), color: Theme.muted2) }
            }
        }
    }
}
