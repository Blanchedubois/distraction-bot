import SwiftUI

enum Screen: String, CaseIterable, Identifiable {
    // M0 (PLAN_STRUCTURE §3.1): eight tabs — Rules = Apps + Websites, Judge absorbs Screen, Calendar absorbs History as its Day view.
    case home, calendar, subjects, rules, judge, progress, log, settings
    var id: String { rawValue }
    /// The old raw values (`DBOT_SNAPSHOT_TAB`, old links) still land: apps · websites → rules, screen → judge, history → calendar (M0).
    init?(legacy raw: String) {
        switch raw {
        case "apps", "websites": self = .rules
        case "screen": self = .judge
        case "history": self = .calendar
        default: guard let s = Screen(rawValue: raw) else { return nil }; self = s
        }
    }
    var title: String {
        switch self {
        case .home: return "Home"
        case .calendar: return "Calendar"
        case .subjects: return "Subjects"
        case .rules: return "Rules"
        case .judge: return "Judge"
        case .progress: return "Progress"
        case .log: return "Log"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "square.grid.2x2"
        case .calendar: return "calendar"
        case .subjects: return "books.vertical"
        case .rules: return "slider.horizontal.3"
        case .judge: return "scale.3d"
        case .progress: return "chart.xyaxis.line"
        case .log: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(Store.self) private var store
    private var screen: Screen? { store.screen }
    @State private var newSubject = false                  // the sidebar's "New subject…" (PLAN_OBJECTIVES_TAB U1)
    @State private var editingSubject: Catalog.Subject? = nil

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            // picking a screen in the sidebar closes an open subject/objective (Transcriber) — done in the binding's setter, not in an
            // `onChange(of: screen)`, which also fired after `open(subject:)` and wiped the subject it had just opened
            // Subjects are selection items of their own (SidebarItem), not buttons: a selectable List on macOS takes the click
            // for selection, so an untagged Button row never fired and the selection fell to nil (user, 2026-10-27).
            List(selection: Binding<SidebarItem?>(
                get: { if let id = store.openSubject { return .subject(id) }; return store.screen.map { .screen($0) } },
                set: { item in
                    switch item {
                    case .screen(let sc)?: store.go(sc)
                    case .subject(let id)?: store.open(subject: id)
                    case nil: break
                    }
                })) {
                Section("Now") { ForEach([Screen.home, .calendar]) { s in row(s) } }   // Calendar at the top (user, 2026-10-28: "add the calendar tab to the top of the left column menu")
                // Study (PLAN_OBJECTIVES_TAB §3.1): the tab, one row per subject in its colour, "New subject…" (editor arrives in U1)
                Section("Study") {
                    row(.subjects)
                    ForEach(store.subjects) { sub in
                        Label { HStack { Text(sub.code ?? sub.shortName); Spacer(); badge(store.objectives(in: sub.id).count, dot: store.nextDue(in: sub.id, within: 2).map { _ in Theme.accent(sub.accent) }) } }   // P3: a dot when something is due within 48 h
                            icon: { Glyph(icon: sub.icon, size: 13, color: Theme.accent(sub.accent)) }
                            .tag(SidebarItem.subject(sub.id))
                            .contextMenu {
                                Button("Edit subject…") { editingSubject = sub }
                                Button("Delete subject", role: .destructive) { store.deleteSubject(sub.id); store.show("subject deleted") }
                            }
                            .dropDestination(for: String.self) { ids, _ in   // U3: an objective card dropped on a sidebar row moves under that subject
                                let moved = ids.compactMap { store.objective($0) }.filter { $0.subjectId != sub.id }
                                for o in moved { store.saveObjective(id: o.id, subject: sub.id, title: o.title, bio: o.bio, icon: o.icon) }
                                if !moved.isEmpty { store.show("moved to \(sub.code ?? sub.shortName)") }
                                return !moved.isEmpty
                            }
                    }
                    .onMove { from, to in var ids = store.subjects.map(\.id); ids.move(fromOffsets: from, toOffset: to); store.reorderSubjects(ids) }   // U3: persisted in `sort`
                    Button { newSubject = true } label: { Label("New subject…", systemImage: "plus").foregroundStyle(Theme.muted) }.buttonStyle(.plain)
                }
                Section("Guard") { ForEach([Screen.rules, .judge]) { s in row(s) } }      // M0: what is blocked · how the judge thinks
                Section("Record") { ForEach([Screen.progress, .log, .settings]) { s in row(s) } }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .sheet(isPresented: $newSubject) { SubjectEditor(existing: nil).environment(store) }
            .sheet(item: $editingSubject) { s in SubjectEditor(existing: s).environment(store) }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: Space.stack) {
                    Circle().fill(store.ollamaOnline ? Theme.ok : Theme.danger).frame(width: 6, height: 6)
                    MonoLabel(store.ollamaOnline ? "judge ready" : "ollama offline")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.card).padding(.vertical, Space.stack)
            }
        } detail: {
            ZStack(alignment: .bottom) {
                Theme.bg.ignoresSafeArea()
                ScreenView(screen: screen ?? .home)
                if let t = store.toast {
                    HStack(spacing: Space.loose) {
                        Text(t.text.uppercased())
                            .font(Type.pill).tracking(Type.pillTracking)
                            .foregroundStyle(t.error ? .white : Theme.paper)
                        if let undo = t.undo {   // PLAN_OBJECTIVE_LIFECYCLE §5a Q8
                            Button { undo(); store.toast = nil } label: {
                                Text("UNDO").font(Type.pill).tracking(Type.pillTracking).foregroundStyle(Theme.ink)
                                    .padding(.horizontal, Space.pillH).padding(.vertical, Space.pillV).background(Capsule().fill(Theme.paper))
                            }.buttonStyle(.plain).keyboardShortcut("z", modifiers: .command)
                        }
                    }
                        .padding(.horizontal, Space.card).padding(.vertical, Space.stack)
                        .background(Capsule().fill(t.error ? Theme.danger : Theme.ink))
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                        .padding(.bottom, Space.sheet)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: store.toast?.text)
            // an open objective titles the window with its title and the subject code (PLAN_OBJECTIVE_OVERVIEW V0, Transcriber's ItemView)
            .navigationTitle(store.objective(store.openObjective)?.title ?? store.subject(store.openSubject)?.shortName ?? (screen ?? .home).title)
            .navigationSubtitle(store.subject(store.objective(store.openObjective)?.subjectId)?.code ?? (screen == .calendar && store.openSubject == nil ? store.calendarSubtitle : ""))   // Calendar: the week's range or the shown day (PLAN_HISTORY_TAB Y1; M2)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { if store.openShutdown != nil { store.openShutdown = nil } else if store.openObjective != nil { store.openObjective = nil } else { store.openSubject = nil } } label: { Label("Back", systemImage: "chevron.left") }   // K2: Back leaves the shutdown screen first
                        .disabled(store.openSubject == nil && store.openObjective == nil && store.openShutdown == nil).help("Back")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { Task { await store.refreshStatus() } } label: { Label("Refresh", systemImage: "arrow.triangle.2.circlepath") }
                        .help("Check Ollama and the permissions again")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func row(_ s: Screen) -> some View {
        Label {
            HStack {
                Text(s.title)
                // C2 (PLAN_CURRENT_SESSION §3.1): Home carries the live session — a dot in the objective's colour and the minutes left
                if s == .home, let live = store.session {
                    Spacer()
                    Circle().fill(store.sessionObjective.map { store.accent(of: $0) } ?? Theme.accent).frame(width: 6, height: 6)
                    TimelineView(.periodic(from: .now, by: 30)) { _ in   // the row is not redrawn by the clock otherwise
                        Text(live.remaining.map { "\(Int($0 / 60) + 1)m" } ?? "\(Int(live.elapsed / 60))m").font(Type.label).foregroundStyle(Theme.muted)
                    }
                }
            }
        } icon: { Image(systemName: s.symbol) }.tag(SidebarItem.screen(s))
    }
    private func badge(_ n: Int, dot: Color? = nil) -> some View {
        HStack(spacing: Space.tight) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }   // P3 (PLAN_PLANNING §3.4): due within 48 h
            if n > 0 { Text("\(n)").font(Type.label).foregroundStyle(Theme.muted).padding(.horizontal, Space.tight).padding(.vertical, Space.hair).background(Capsule().fill(Theme.ghost)) }
        }
    }
}

/// What the sidebar selects: a screen, or a subject (its page; PLAN_OBJECTIVES_TAB U0).
enum SidebarItem: Hashable { case screen(Screen), subject(String) }

private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var snapshot: Bool { get { self[SnapshotKey.self] } set { self[SnapshotKey.self] = newValue } } }
private struct PrintingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var printing: Bool { get { self[PrintingKey.self] } set { self[PrintingKey.self] = newValue } } }

/// One breakpoint for the whole app: below this width screens stack and notes hide.
enum Breakpoint { static let narrow: CGFloat = 900 }
private struct NarrowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues { var narrow: Bool { get { self[NarrowKey.self] } set { self[NarrowKey.self] = newValue } } }

/// ScrollView normally; a plain column when rendering offscreen (ImageRenderer cannot draw scroll views).
struct PageScroll<Content: View>: View {
    @Environment(\.snapshot) private var snapshot
    @ViewBuilder let content: Content
    var body: some View {
        if snapshot { VStack(spacing: 0) { content.fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0) } } else { ScrollView { content } }
    }
}

/// Page scaffold: scrolling column, centered, with a page head.
struct Page<Content: View>: View {
    let kicker: String
    let title: String
    var trailing: AnyView? = nil
    var tint: Color? = nil            // Transcriber's subject pages (U0): a soft gradient from the top
    var watermark: String? = nil      // and the subject glyph anchored bottom-trailing, behind the content
    var maxWidth: CGFloat = 1040
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { g in
            let narrow = g.size.width < Breakpoint.narrow
            let dark = scheme == .dark
            ZStack(alignment: .bottomTrailing) {
                if let tint {
                    let (top, mid) = Tint.page(dark: dark)
                    LinearGradient(stops: [.init(color: tint.opacity(top), location: 0), .init(color: tint.opacity(mid), location: 0.45), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                }
                if let watermark {
                    Watermark(symbol: watermark, size: min(g.size.width, g.size.height) * 0.46, color: tint ?? Theme.muted2, opacity: Tint.pageWatermark(dark: dark))
                        .offset(x: g.size.width * 0.06, y: g.size.height * 0.08)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .clipped()
                }
            PageScroll {
                VStack(alignment: .leading, spacing: Space.section(narrow: narrow)) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: Space.tight) {
                            MonoLabel(kicker)
                            Text(title).font(Type.page).foregroundStyle(Theme.ink)
                        }
                        Spacer()
                        if let trailing { trailing }
                    }
                    content
                }
                .frame(maxWidth: maxWidth)
                .padding(.horizontal, Space.pageH(narrow: narrow)).padding(.top, Space.sheet).padding(.bottom, Space.pageBottom)
                .frame(maxWidth: .infinity)
            }
            }
            .environment(\.narrow, narrow)
        }
    }
}

struct ScreenView: View {
    @Environment(Store.self) private var store
    let screen: Screen
    var body: some View {
        // an open objective wins over an open subject, which wins over the screen (Transcriber's DetailPane; PLAN_OBJECTIVES_TAB U0)
        if let day = store.openShutdown { ShutdownScreen(day: day) }   // K2 (PLAN_STUDY_DAY §3.4): the shutdown screen, above everything; not a tab
        else if let oid = store.openObjective { ObjectiveView(objectiveId: oid) }
        else if let sid = store.openSubject { SubjectPage(subjectId: sid) }
        else { switch screen {
        case .home: HomeView()
        case .calendar: CalendarScreen()
        case .subjects: SubjectsView()
        case .rules: RulesScreen()       // M1: Apps + Websites
        case .judge: JudgeView()
        case .progress: ProgressScreen()
        case .log: LogView()
        case .settings: SettingsView()
        } }
    }
}

/// A card that says which phase fills this section (B0 stubs, §4).
struct PhaseStub: View {
    let phase: String
    let text: String
    var symbol: String = "hammer"
    var body: some View {
        VStack(alignment: .leading, spacing: Space.stack) {
            Pill("arrives in \(phase)", kind: .warn)
            Text(text).font(Type.body).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .cardPadding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(watermark: symbol)
    }
}
