import SwiftUI

struct JudgeView: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    @State private var goal = "BIO 210 lab report 3: the osmosis data, the graph and the discussion"
    @State private var app = "Safari"
    @State private var title = "best mechanical keyboards 2026 - YouTube"
    @State private var url = "https://www.youtube.com/results?search_query=best+mechanical+keyboards"
    @State private var verdict: Judge.Verdict?
    @State private var busy = false

    var body: some View {
        @Bindable var judge = store.judge
        // M1 (PLAN_STRUCTURE §3.2): five sections — 1 Ollama · 2 The look · 3 Private list · 4 This session · 5 Try it; the look's rows come from ScreenWatchView.
        Page(kicker: "everything runs on this mac · the model, the look, the threshold", title: "Judge") {
            Pair {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(1, "Ollama", note: "localhost:11434")
                    VStack(alignment: .leading, spacing: Space.loose) {
                        row("Service", sub: store.ollamaOnline ? "\(store.ollamaModels.count) models installed" : "start ollama to enable the judge") {
                            store.ollamaOnline ? Pill("running", kind: .ok, dot: true) : Pill("not running", kind: .danger)
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        row("Judge model", sub: "qwen3:14b is the most accurate; 8b and 4b are faster on smaller Macs and miss more") {
                            PillMenu(options: (store.ollamaModels.isEmpty ? [judge.model] : store.ollamaModels).map { ($0, $0) }, selection: $judge.model, leadingSymbol: "cpu")
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        row("Warn at", sub: "confidence the judge needs before a banner") {
                            PillMenu(options: [(0.5, "50 %"), (0.6, "60 %"), (0.7, "70 %"), (0.8, "80 %"), (0.9, "90 %")], selection: $judge.threshold, leadingSymbol: "gauge.with.needle")
                        }
                    }
                    .cardPadding()
                    .card(watermark: "sparkles")
                }
            } second: {
                ScreenWatchView(part: .look, number: 2)         // M1: interval · scope · vision model · last look
            }
            Pair {
                ScreenWatchView(part: .privateList, number: 3)  // M1
            } second: {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(4, "This session", note: "measured")
                    KpiGrid(columns: 2) {
                        KpiTile(label: "Verdicts", value: "\(judge.calls)", sub: judge.online ? "judge reachable" : "judge offline", symbol: "scale.3d", small: true)
                        KpiTile(label: "Latency p50", value: judge.calls == 0 ? "—" : String(format: "%.1f s", judge.p50), sub: judge.calls == 0 ? "no calls yet" : String(format: "p95 %.1f s", judge.p95), symbol: "timer", small: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(5, "Try it", note: "a front window and a goal → a verdict in ~2 s")
                VStack(alignment: .leading, spacing: Space.stack) {
                    field("goal", $goal)
                    // X0 (PLAN_CATCHER §3.1): a past verdict's facts back into the fields — exact from its judge.facts row, else rebuilt from the verdict
                    HStack(spacing: Space.stack) {
                        PillMenu(options: [(Int64(0), "replay a past verdict")] + pastVerdicts.map { ($0.id, "\(clock($0.ts)) · \($0.app) · \(Stats.what(ofVerdict: $0.detail).prefix(36))") },
                                 selection: Binding(get: { Int64(0) }, set: { id in if let v = pastVerdicts.first(where: { $0.id == id }) { replay(v) } }), leadingSymbol: "arrow.counterclockwise")
                        if let r = replayed { MonoLabel(r, color: Theme.muted2) }
                    }
                    HStack(spacing: Space.stack) { field("app", $app, width: 160); field("window or page title", $title) }
                    field("url (optional)", $url)
                    HStack(spacing: Space.loose) {
                        ActionButton(title: busy ? "Judging…" : "Judge", symbol: "scale.3d", accent: true) { Task { await tryIt() } }.disabled(busy)
                        if let v = verdict {
                            Pill(v.distracted ? "distracted · \(Int(v.confidence * 100)) %" : "work · \(Int(v.confidence * 100)) %", kind: v.distracted ? .warn : .ok, dot: true)
                            Text(v.reason).font(Type.body).foregroundStyle(Theme.ink)
                            MonoLabel(String(format: "%.1f s · %@", v.seconds, v.model), color: Theme.muted2)
                        }
                    }
                    if let f = store.judge.lastFacts {
                        DisclosureGroup { Text(Judge.prompt(f)).font(Type.data).foregroundStyle(Theme.muted).textSelection(.enabled).padding(.top, Space.tight) }
                            label: { MonoLabel("what the judge was told") }
                    }
                }
                .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                .card(watermark: "scale.3d")
            }
        }
    }

    @State private var replayed: String?
    private var pastVerdicts: [Event] { Array(store.events.filter { $0.kind == "judge.verdict" }.prefix(20)) }
    private func replay(_ v: Event) {
        let (f, exact) = Replay.facts(for: v, in: store.events.reversed(), rules: store.rules)
        if !f.goal.isEmpty { goal = f.goal }
        app = f.frontApp; title = f.title; url = f.url ?? ""; verdict = nil
        replayed = "\(exact ? "exact" : "rebuilt") · was \(v.detail.hasPrefix("distracted") ? "distracted" : "work")"
    }

    private func tryIt() async {
        busy = true; defer { busy = false }
        let kind = ["Safari", "Dia", "Chrome", "Firefox"].contains(app) ? "web browser" : "app"
        let facts = Judge.Facts(goal: goal, minutesIn: 12, strictness: "normal", allowed: store.rules.pinnedNames + store.rules.allowedSites, frontApp: app, frontKind: kind, title: title, url: url.isEmpty ? nil : url, screen: nil, behind: [], recent: [], usage: nil)
        verdict = await store.judge.judge(facts)
        if verdict == nil { store.fail(store.judge.online ? "No verdict within the budget" : "Ollama is not reachable") }
    }

    private func row<T: View>(_ name: String, sub: String, @ViewBuilder _ trailing: () -> T) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(name).font(Type.strong).foregroundStyle(Theme.ink)
                Text(SettingsView.sentence(sub)).font(Type.body).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            trailing()
        }
    }
    private func field(_ placeholder: String, _ text: Binding<String>, width: CGFloat? = nil) -> some View {
        Group {
            if snapshot { Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue).font(Type.body).foregroundStyle(Theme.ink) }
            else { TextField(placeholder, text: text).textFieldStyle(.plain).font(Type.body).foregroundStyle(Theme.ink) }
        }
        .padding(.horizontal, Space.pillH).padding(.vertical, Space.tight)
        .frame(width: width).frame(maxWidth: width == nil ? .infinity : nil)
        .background(Capsule().fill(Theme.paper)).overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
    }
}
