import SwiftUI
import AppKit

@main
struct DistractionBotApp: App {
    init() {
        // `--permissions` prints what macOS has granted this bundle and quits (B0's rebuild check).
        // `--catalog` prints subjects.json as a table and quits (PLAN_OBJECTIVES_MODEL O0; DBOT_SEED_CATALOG=1 seeds a missing file first).
        if CommandLine.arguments.contains("--catalog") { print(Catalog.load().table); exit(0) }
        // `--symbols` prints how many SF Symbols the picker can browse and how many categories (U0's quiet check).
        if CommandLine.arguments.contains("--symbols") { print("symbols \(Symbols.all.count) · categories \(Symbols.categories.count) · fallback \(Symbols.all == Symbols.fallback)"); exit(0) }
        // `--sessions` (O2's quiet print): every stamped session, newest first, with its objective or the suggested one; `--file-session <session id> <objective id|->` files one.
        if CommandLine.arguments.contains("--sessions") || CommandLine.arguments.contains("--file-session") {
            let store = Store()
            if let i = CommandLine.arguments.firstIndex(of: "--file-session"), CommandLine.arguments.count > i + 2 {
                store.fileSession(CommandLine.arguments[i + 1], under: CommandLine.arguments[i + 2] == "-" ? nil : CommandLine.arguments[i + 2])
            }
            let all = EventLog.shared.sessions()
            print("sessions \(all.count) · unsorted \(store.unsortedSessions.count)")
            let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
            for s in all {
                let filed = store.objective(s.objectiveId).map { "→ \($0.title)" } ?? (store.suggestObjective(for: s.goal).map { "? \($0.title)" } ?? "unsorted")
                print("\(s.id.prefix(14))\t\(f.string(from: s.started))\t\(minutes(Double(s.seconds)))\t\(s.strictness)\t\(s.kind ?? "-")\t\(s.endedBy)\tw\(s.warnings) b\(s.blocks)\t\(filed)\t\(s.goal.prefix(50))")
            }
            exit(0)
        }
        // `--objective-check <objective id>` (O1's quiet check): sets a session from the objective WITHOUT the watchers, logs a few
        // stamped events, ends it, prints session.json and the per-session queries, and quits. No windows, nothing closed.
        if let i = CommandLine.arguments.firstIndex(of: "--objective-check"), CommandLine.arguments.count > i + 1 {
            let store = Store()
            guard let o = store.objective(CommandLine.arguments[i + 1]) else { print("no such objective"); exit(1) }
            let goal = o.title   // O3: the judge reads the title only
            store.session = Session(goal: goal, started: Date(), ends: Date().addingTimeInterval(1500), strictness: o.severity, subjectId: o.subjectId, objectiveId: o.id, kind: o.kind)
            print("session.json: " + (String(data: (try? Data(contentsOf: Session.url)) ?? Data(), encoding: .utf8) ?? "?"))
            let log = EventLog.shared
            log.add("session.start", detail: [goal, "25 min", o.severity.rawValue, o.kind.rawValue].joined(separator: " · "))
            log.add("judge.verdict", app: "Spotify", detail: "distracted 0.80 · music · Spotify — Radiohead", latencyMs: 1500)
            log.add("judge.answer", detail: "back · Spotify — Radiohead")
            log.add("web.warn", app: "Safari", detail: "youtube.com")
            log.add("block.close", app: "Steam", detail: "attempt 1 · react 0 ms", latencyMs: 400)
            log.add("session.end", detail: "9")
            let id = store.session!.id
            store.session = nil
            print("free-text session.json: ", terminator: ""); store.session = Session(goal: "free text", started: Date(), ends: nil, strictness: .normal)
            print(String(data: (try? Data(contentsOf: Session.url)) ?? Data(), encoding: .utf8) ?? "?"); store.session = nil
            print("events(session:) \(log.events(session: id).count) rows: " + log.events(session: id).map(\.kind).joined(separator: " "))
            for s in log.sessions(objective: o.id) { print("sessions(objective:) id=\(s.id.prefix(8)) kind=\(s.kind ?? "-") goal=\(s.goal.prefix(30)) seconds=\(s.seconds) warnings=\(s.warnings) blocks=\(s.blocks) endedBy=\(s.endedBy)") }
            print("sessions(subject:) \(log.sessions(subject: o.subjectId).count) · sessions() \(log.sessions().count)")
            for d in log.distractions(objective: o.id) { print("distraction \(d.key) host=\(d.isHost) count=\(d.count) blocked=\(d.blocked) answers=\(d.answers)") }
            print("CHECK_SESSION_ID=\(id)")
            exit(0)
        }
        // P4 (PLAN_PLANNING §3.7, quiet): `--dismiss-tests-check` files the inbox's test groups under `tests`, prints the counts, undoes it. Refuses without DBOT_LOG_PATH.
        if CommandLine.arguments.contains("--dismiss-tests-check") {
            guard ProcessInfo.processInfo.environment["DBOT_LOG_PATH"] != nil, ProcessInfo.processInfo.environment["DBOT_SESSION_PATH"] != nil else { print("refusing: set DBOT_LOG_PATH and DBOT_SESSION_PATH to scratch files"); exit(2) }
            let store = Store()
            let before = UnsortedGroup.build(store.unsortedSessions)
            print("before: \(before.count) groups · \(before.reduce(0) { $0 + $1.sessions.count }) sessions")
            let ids = store.dismissTests(before)
            let after = UnsortedGroup.build(store.unsortedSessions)
            print("dismissed \(ids.count) → \(after.count) groups · \(after.reduce(0) { $0 + $1.sessions.count }) sessions · left: \(after.map { "\($0.goal.prefix(40)) ×\($0.sessions.count)" }.joined(separator: " | "))")
            print("filed under tests: \(EventLog.shared.sessions(objective: Planning.testsObjectiveId).count)")
            store.toast?.undo?()
            let undone = UnsortedGroup.build(store.unsortedSessions)
            print("undo → \(undone.count) groups · \(undone.reduce(0) { $0 + $1.sessions.count }) sessions")
            exit(0)
        }
        // `--queue-check <objective id>` (PLAN_CURRENT_SESSION C0, quiet: no windows, no log writes): queues the objective, prints the file,
        // reloads it through a second Store, edits the pills in place, clears, and prints each step. Run with DBOT_QUEUE_PATH and DBOT_CATALOG_PATH on scratch copies.
        if let i = CommandLine.arguments.firstIndex(of: "--queue-check"), CommandLine.arguments.count > i + 1 {
            let store = Store()
            guard let o = store.objective(CommandLine.arguments[i + 1]) else { print("no such objective"); exit(1) }
            print("path \(QueuedSession.url.path) · session \(store.session != nil) · queued at init \(store.queued.map { $0.goal } ?? "none")")
            let ok = store.prepareSession(objective: o, source: "queue-check")
            print("prepareSession → \(ok) · minutes \(store.queued?.minutes.map(String.init) ?? "open") · \(store.queued?.strictness.rawValue ?? "-") · screen \(store.screen?.rawValue ?? "-")")
            print("file: " + ((try? String(contentsOf: QueuedSession.url, encoding: .utf8)) ?? "MISSING"))
            let again = Store()
            print("relaunch reads: \(again.queued.map { "\($0.goal) · \($0.minutes.map(String.init) ?? "open") · \($0.strictness.rawValue) · from \($0.source)" } ?? "none")")
            again.queued?.minutes = 25; again.queued?.strictness = .strict
            print("edited in place: " + ((try? String(contentsOf: QueuedSession.url, encoding: .utf8))?.replacingOccurrences(of: "\n", with: " ") ?? "MISSING"))
            print("one-off → \(again.prepareSession(goal: "  ", minutes: 10, strictness: .normal)) (blank refused) · \(again.prepareSession(goal: "read chapter 4", minutes: 10, strictness: .normal)) · \(again.queued?.goal ?? "-") · objective nil \(again.queued?.objective == nil)")
            again.clearQueued()
            print("cleared · file exists \(FileManager.default.fileExists(atPath: QueuedSession.url.path)) · queued \(again.queued == nil ? "nil" : "set")")
            exit(0)
        }
        // `--ui-check` (PLAN_STUDY_DAY K0, quiet: no windows): drives Store.go / open across the tabs and prints the ui.* rows written.
        // Run with DBOT_LOG_PATH on a scratch copy of the log (and DBOT_SESSION_PATH / DBOT_QUEUE_PATH / DBOT_CATALOG_PATH on scratch files).
        // `--shutdown-check` (PLAN_STUDY_DAY K2–K3, quiet: no windows): files a shutdown on a scratch log, reads it back, files a second, prints the plan,
        // the queue, the offer rule and the reminder. Needs DBOT_LOG_PATH and DBOT_QUEUE_PATH on scratch files (refuses without them).
        if CommandLine.arguments.contains("--shutdown-check") {
            let env = ProcessInfo.processInfo.environment
            guard env["DBOT_LOG_PATH"] != nil, env["DBOT_QUEUE_PATH"] != nil else { print("refusing: set DBOT_LOG_PATH and DBOT_QUEUE_PATH to scratch files"); exit(2) }
            let store = Store()
            for line in store.shutdownCheck() { print(line) }
            exit(0)
        }
        if CommandLine.arguments.contains("--ui-check") {
            let store = Store()
            let before = EventLog.shared.count("ui.", since: .distantPast)
            print("log \(ProcessInfo.processInfo.environment["DBOT_LOG_PATH"] ?? "REAL — refusing")"); if ProcessInfo.processInfo.environment["DBOT_LOG_PATH"] == nil { exit(2) }
            print("study day starts \(StudyDay.startHour):00 · today \(StudyDay.start(of: Date()).formatted(date: .abbreviated, time: .shortened)) → \(StudyDay.end(of: Date()).formatted(date: .abbreviated, time: .shortened))")
            for s in [Screen.progress, .calendar, .home, .home, .judge] { store.go(s) }          // home twice: the repeat is not a navigation
            if let o = store.catalog.objectives.first { store.open(objective: o.id); store.open(objective: o.id); store.open(subject: o.subjectId) }
            store.go(.log)
            let rows = EventLog.shared.recent(limit: 50).filter { $0.kind.hasPrefix("ui.") }.reversed()
            print("ui rows before \(before) · written \(EventLog.shared.count("ui.", since: .distantPast) - before) (expect 7: progress · calendar · home · judge · objective · subject · log; the repeated Home writes nothing)")
            for r in rows.suffix(10) { print("  \(clock(r.ts))  \(r.kind)  \(r.detail)  session=\(r.sessionId ?? "-")") }
            print("sessions() unchanged by ui rows: \(EventLog.shared.sessions().count)")
            exit(0)
        }
        if CommandLine.arguments.contains("--permissions") {
            print("accessibility=\(Permissions.accessibilityTrusted) screenRecording=\(Permissions.screenRecordingGranted)")
            exit(0)
        }
        // `--check-url <url>…` runs the web rules on URLs and prints the verdicts (quiet check, no permissions, no windows).
        if let i = CommandLine.arguments.firstIndex(of: "--check-url") {
            let rules = Rules.load()
            for u in CommandLine.arguments[(i + 1)...] {
                let host = URL(string: u)?.host?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
                let search = SearchQuery.extract(u)
                var verdict = "unjudged"
                if rules.isAllowedSite(host) { verdict = "allowed · allow list" }
                else if let hit = search.flatMap({ rules.searchTermHit($0.query) }) { verdict = "block · search term \"\(hit)\"" }
                else if let r = rules.siteRule(for: host) { verdict = "\(r.strength == .warn ? "warn" : r.strength == .close ? "block" : r.strength == .judge ? "judge" : "allowed") · site \(r.rule)" }
                print("\(verdict)\t\(search.map { "\($0.engine): \($0.query)" } ?? host)\t\(u)")
            }
            exit(0)
        }
        // `--describe <png>… [--model m]` runs the vision step on images from disk and prints the description and time (quiet).
        if let i = CommandLine.arguments.firstIndex(of: "--describe") {
            var files = Array(CommandLine.arguments[(i + 1)...]); var model = Ollama.visionModel
            if let m = files.firstIndex(of: "--model"), files.count > m + 1 { model = files[m + 1]; files.removeSubrange(m...(m + 1)) }
            Task { @MainActor in
                for f in files {
                    if let (d, t) = await ScreenLook.describe(file: f, model: model) { print(String(format: "%.1f s\t%@\t%@", t, (f as NSString).lastPathComponent, d.replacingOccurrences(of: "\n", with: " "))) }
                    else { print("failed\t\(f)") }
                }
                exit(0)
            }
            RunLoop.main.run()
        }
        // PLAN_OBJECTIVE_LIFECYCLE L0 (quiet, with DBOT_CATALOG_PATH): `--complete <id>` · `--reopen <id>` · `--delete-objective <id>` run the Store's
        // rule and print the catalogue table and the unsorted-session count, then exit.
        for (flag, action) in [("--complete", { (s: Store, id: String) in s.complete(id) }), ("--reopen", { (s: Store, id: String) in s.reopen(id) }), ("--delete-objective", { (s: Store, id: String) in s.deleteObjective(id) })] {
            if let i = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.count > i + 1 {
                let store = Store(); action(store, CommandLine.arguments[i + 1])
                print(store.catalog.table); print("unsorted sessions: \(store.unsortedSessions.count)"); exit(0)
            }
        }
        // E4 (PLAN_OVERLAY §4, quiet): `--overlay-check` with DBOT_LOG_PATH, DBOT_SESSION_PATH and DBOT_QUEUE_PATH on scratch paths and DBOT_SNAPSHOT=1
        // (no window is ever shown): told → row + RECENT line; allow ×3 → counted skip rows; ✕ with a reason → ui.overlay row; End → the summary, no toast. Prints and exits.
        // HUD7 (PLAN_SESSION_HUD): R0's `--minipanel-check` is gone — the same geometry and drag rule are judged by `scripts/hud-check.swift`, which never starts the app.
        if CommandLine.arguments.contains("--overlay-check") {
            guard ProcessInfo.processInfo.environment["DBOT_LOG_PATH"] != nil, ProcessInfo.processInfo.environment["DBOT_SESSION_PATH"] != nil, ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] != nil else { print("set DBOT_LOG_PATH, DBOT_SESSION_PATH, DBOT_QUEUE_PATH to scratch paths and DBOT_SNAPSHOT=1"); exit(2) }
            let store = Store()
            store.session = Session(goal: "overlay check", started: Date().addingTimeInterval(-31 * 60), ends: nil, strictness: .normal)
            store.judge.lastFacts = Judge.Facts(goal: "overlay check", minutesIn: 31, strictness: "normal", allowed: [], frontApp: "Dia", frontKind: "web browser", title: "r/physics", url: "https://reddit.com/r/physics", screen: nil, behind: [], recent: [], usage: nil)
            store.judge.lastVerdict = Judge.Verdict(distracted: true, confidence: 0.8, reason: "a forum unrelated to the goal", seconds: 1, model: "check")
            store.told("reading the course forum for the problem set")
            print("told → recent:", store.recentAnswers())
            print("facts line:", Banner.shared.factsLine, "| why:", Banner.shared.whyLines)
            for _ in 1...3 { store.watcher.allow("com.example.none", name: "Example") }
            print("extensions:", store.watcher.extensions["com.example.none"] ?? 0, "| skip rows:", EventLog.shared.recent(limit: 10).filter { $0.kind == "skip" }.map(\.detail))
            MiniPanel.shared.teach(.session)
            MiniPanel.shared.note = "two problems done"; MiniPanel.shared.fileNote()
            MiniPanel.shared.hideForSession(reason: "in the way")
            print("ui rows:", EventLog.shared.recent(limit: 10).filter { $0.kind.hasPrefix("ui.") || $0.kind == "session.note" }.map { "\($0.kind) · \($0.detail)" })
            store.toast = nil
            store.endSession(reason: "finished")
            let sum = store.endSummary(for: Session(goal: "overlay check", started: Date().addingTimeInterval(-31 * 60), ends: nil, strictness: .normal), reason: "finished")
            print("end: toast=\(store.toast?.text ?? "none") · summary: \(sum.title) · \(sum.seconds) s · \(sum.scored ? Tally.line(sum.losses, total: sum.score.total) + " · " + sum.score.word : "not scored (no record)") · xp \(sum.xp.map(String.init) ?? "–")")
            exit(0)
        }
        // `--profiles` (O4): prints the six focus levels' weights and the judge lines, plus a sample prompt, and exits (quiet).
        if CommandLine.arguments.contains("--profiles") {
            print("level\tblockList\tthreshold\tdwell\tanswer\tignored→block\tfollowUp\tladder\tcloseOnVerdict\tcoolDown\tusage\tjudge line")
            for l in Strictness.allCases { let p = l.profile
                print("\(l.rawValue)\t\(p.enforceBlockList)\t\(p.threshold)\t\(Int(p.dwell)) s\t\(p.answerSeconds.map { "\(Int($0)) s" } ?? "none")\t\(p.ignoredBlocks)\t\(p.followUp)\t\(p.ladder)\t\(p.closeOnVerdict)\t\(Int(p.coolDown)) s\t\(p.usageMinutes) min / \(p.usageSwitches)\t\(p.judgeLine ?? "—")") }
            for k in SessionKind.allCases { print("kind \(k.rawValue): \(k.hint)") }
            let f = Judge.Facts(goal: "research proposal draft", minutesIn: 12, strictness: "extreme", allowed: ["Discord"], frontApp: "Safari", frontKind: "web browser", title: "r/Physics — Fitting error bars", url: "https://reddit.com/r/Physics", screen: nil, behind: [], recent: [], usage: nil, subject: nil, kind: "write-up — \(SessionKind.writeUp.hint)", leniency: Strictness.extreme.profile.judgeLine)
            print("--- sample prompt (extreme, write-up; KIND sent only when Judge.sendKind = \(Judge.sendKind)) ---\n" + Judge.prompt(f))
            exit(0)
        }
        // X0 (PLAN_CATCHER §3.1): `--replay <from> [<to>] [--model m] [--level l] [--dry]` re-judges logged verdicts with today's prompt (quiet; `--dry` needs no Ollama).
        if CommandLine.arguments.contains("--replay") { Replay.run(CommandLine.arguments) }
        // `--judge-fixture <json> [model]` scores the judge on written scenarios and prints accuracy and latency (quiet: no windows).
        if let i = CommandLine.arguments.firstIndex(of: "--judge-fixture"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            let judge = Judge()
            judge.persist = false
            if CommandLine.arguments.count > i + 2 { judge.model = CommandLine.arguments[i + 2] }
            judge.budget = 60
            Task { @MainActor in
                guard let d = FileManager.default.contents(atPath: path), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let cases = j["cases"] as? [[String: Any]] else { print("bad fixture"); exit(1) }
                let goal = j["goal"] as? String ?? "", allowed = j["allowed"] as? [String] ?? [], behind = j["behind"] as? [String] ?? []
                let subject = j["subject"] as? String   // O3: the composed-goal fixture carries a SUBJECT line
                // O4: DBOT_FIXTURE_KIND=<kind> sends the KIND hint on every case (needs Judge.sendKind); DBOT_FIXTURE_LEVEL=<strictness> sends that level's leniency line
                let fixtureKind = ProcessInfo.processInfo.environment["DBOT_FIXTURE_KIND"].flatMap { SessionKind(rawValue: $0) }
                let level = ProcessInfo.processInfo.environment["DBOT_FIXTURE_LEVEL"].flatMap { Strictness(rawValue: $0) } ?? .normal
                await judge.warm()
                var right = 0, unknown = 0
                var controlRight = 0, controlCases = 0, newRight = 0, newCases = 0   // X5
                for c in cases {
                    let k = (c["sessionKind"] as? String).flatMap { SessionKind(rawValue: $0) } ?? fixtureKind
                    let f = Judge.Facts(goal: goal, minutesIn: 25, strictness: level.rawValue, allowed: allowed, frontApp: c["app"] as? String ?? "", frontKind: c["kind"] as? String ?? "app",
                                        title: c["title"] as? String ?? "", url: c["url"] as? String, screen: nil, behind: behind, recent: [], usage: c["usage"] as? String, subject: subject,
                                        kind: k.map { "\($0.rawValue) — \($0.hint)" }, leniency: level.profile.judgeLine,
                                        dwell: c["dwell"] as? String, appClass: c["class"] as? String, previous: c["previous"] as? String)   // X5: the catcher's lines
                    let want = c["distracted"] as? Bool ?? false
                    let v = await judge.judge(f)
                    let ok = v.map { $0.distracted == want } ?? false
                    if v == nil { unknown += 1 } else if ok { right += 1 }
                    if c["class"] != nil { newCases += 1; if ok { newRight += 1 } } else { controlCases += 1; if ok { controlRight += 1 } }   // X5: the ship rule's two counts
                    print("\(ok ? "✓" : "✗") want \(want ? "distracted" : "work")\tgot \(v.map { "\($0.distracted ? "distracted" : "work") \(Int($0.confidence * 100))% \(String(format: "%.1f", $0.seconds))s" } ?? "unknown")\t\(f.frontApp) — \(f.title.prefix(50))\t\(v?.reason ?? "")")
                }
                print("RESULT model=\(judge.model) right=\(right)/\(cases.count) unknown=\(unknown) p50=\(String(format: "%.2f", judge.p50))s p95=\(String(format: "%.2f", judge.p95))s"
                      + (newCases > 0 ? " control=\(controlRight)/\(controlCases) new=\(newRight)/\(newCases) lines=\(Judge.sendClass ? "class " : "")\(Judge.sendDwell ? "dwell " : "")\(Judge.sendPrevious ? "previous" : "")" : ""))   // X5
                exit(0)
            }
            RunLoop.main.run()
        }
        Theme.registerFonts()
    }
    @State private var store = Store()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("Distraction Bot", id: "main") {
            // DBOT_DEV_VIEW=today (PLAN_TODAY_TIMELINE T2): the window shows only the Today strip, at a fixed screen place, for the pointer-driven checks.
            if ProcessInfo.processInfo.environment["DBOT_DEV_VIEW"] == "today" { TodayDevWindow().environment(store) } else {
            ContentView()
                .environment(store)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    // dev aid for the B1 test: DBOT_AUTOSTART="goal|25|normal" starts a session at launch
                    if let a = ProcessInfo.processInfo.environment["DBOT_AUTOSTART"]?.split(separator: "|"), a.count == 3 {
                        store.startSession(goal: String(a[0]), minutes: Int(a[1]), strictness: Strictness(rawValue: String(a[2])) ?? .normal)
                    }
                    // dev aid (PLAN_OBJECTIVES_MODEL O1): DBOT_AUTOSTART_OBJECTIVE="<objective id>|25" starts a session from a catalogue objective
                    if let a = ProcessInfo.processInfo.environment["DBOT_AUTOSTART_OBJECTIVE"]?.split(separator: "|"), a.count == 2, let o = store.objective(String(a[0])) {
                        store.startSession(objective: o, minutes: Int(a[1]))
                    }
                    Snapshot.armIfRequested(store: store)   // before anything that can wait on Ollama
                    if let report = Stats.checkRun() { print(report); NSApp.terminate(nil) }   // DBOT_STATS_CHECK=1 (PLAN_STATS_TAB S0)
                    await store.refreshStatus()
                    // First launch: ask for what is missing so macOS lists the app in both privacy panes (B0).
                    if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] == nil {
                        if !store.accessibility { Permissions.promptForAccessibility() }
                        if !store.screenRecording { Permissions.promptForScreenRecording() }
                    }
                }
            }
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            // M4 (PLAN_STRUCTURE §3.5): ⌘, opens the Settings tab (the app has no settings window)
            CommandGroup(replacing: .appSettings) { Button("Settings…") { store.go(.settings) }.keyboardShortcut(",", modifiers: .command) }
            // M4 (PLAN_STRUCTURE §3.5): the Go menu — the eight tabs on ⌘1–⌘8, Back on ⌘[, Week | Day on ⌘⇧W / ⌘⇧Y while on Calendar
            CommandMenu("Go") {
                ForEach(Array(Screen.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { store.go(s) }.keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
                Divider()
                Button("Back") { if store.openObjective != nil { store.openObjective = nil } else { store.openSubject = nil } }
                    .keyboardShortcut("[", modifiers: .command).disabled(store.openSubject == nil && store.openObjective == nil)
                Divider()
                Button("Week") { store.calendarMode = .week }.keyboardShortcut("w", modifiers: [.command, .shift]).disabled(store.screen != .calendar || store.calendarMode == .week)
                Button("Day") { store.calendarMode = .day }.keyboardShortcut("y", modifiers: [.command, .shift]).disabled(store.screen != .calendar || store.calendarMode == .day)
            }
            CommandMenu("Session") {
                // C0: ⇧⌘S starts the queued session when there is one, else goes Home to make one
                Button(store.queued == nil ? "Start Focus Session…" : "Start Queued Session") { if store.queued != nil { store.startQueued() } else { store.go(.home) } }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(store.session != nil)
                Button("Clear Queue") { store.clearQueued() }.disabled(store.queued == nil)
                Button(store.session?.onBreak == true ? "End the Break" : "Take a 10-Minute Break") { if store.session?.onBreak == true { store.resumeSession() } else { store.takeBreak(minutes: 10) } }   // HUD3
                    .disabled(store.session == nil || (store.session.map { $0.strictness.isHard && !$0.onBreak && store.breakBank($0) < 10 } ?? true))
                Button("End Session") { store.requestEnd() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(store.session == nil)
                // K3 (PLAN_STUDY_DAY §3.5): the shutdown by hand, ⌘⇧D; disabled while a session is live
                Button("Shut Down the Day…") { store.openShutdown() }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(store.session != nil)
                Divider()
                // PLAN_OBJECTIVE_LIFECYCLE §3.5: the open objective's lifecycle, ⌘⇧K toggles complete / reopen
                let openObj = store.objective(store.openObjective)
                Button(openObj?.isDone == true ? "Reopen Objective" : "Complete Objective") { if let o = openObj { store.archiveObjective(o.id, !o.isDone) } }
                    .keyboardShortcut("k", modifiers: [.command, .shift]).disabled(openObj == nil)
                Button("Delete Objective…") { store.pendingDelete = openObj?.id }.disabled(openObj == nil)
                Divider()
                // C3: the mini panel, hidden for this session or shown again (PLAN_CURRENT_SESSION §3.7)
                Button(MiniPanel.shared.isHidden ? "Show Mini Panel" : "Hide Mini Panel") { MiniPanel.shared.toggleHidden() }.disabled(store.session == nil || !store.settings.miniPanel)
            }
        }
        MenuBarExtra {
            MenuBarMenu(store: store)
        } label: {
            HStack(spacing: Space.tight) {
                Image(systemName: store.session == nil ? "shield.lefthalf.filled" : "shield.fill")
                // HUD2 (PLAN_SESSION_HUD §3.2): the game at a glance — `97% ×2 · 12m` — so a hidden HUD still has its figures
                if let a = store.menuBarAlert { Text(a).font(Type.data) }   // HUD5: an alert the HUD cannot show
                else if let s = store.session {
                    let g = store.liveGame(s)
                    Text("\(Int(SessionGame.shown(g).rounded(.down)))% ×\(g.multiplier)" + (s.remaining.map { " · \(Int($0 / 60) + 1)m" } ?? "")).font(Type.data)
                }
            }
        }
    }
}

/// The menu bar's menu; `openWindow` reopens the main window after a menu-bar-only launch.
struct MenuBarMenu: View {
    let store: Store
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            if let s = store.session {
                Text(s.goal.isEmpty ? "Focus session" : s.goal)
                Text(s.remaining.map { "\(minutes($0)) left" } ?? "\(minutes(s.elapsed)) elapsed")
                // M4 (PLAN_STRUCTURE §3.5): the objective's subject line and today's score, from `statsToday` (refreshed once a minute in a session)
                if let o = store.sessionObjective, let subj = store.subject(o.subjectId) { Text((subj.code.map { "\($0) · " } ?? "") + subj.shortName) }
                if let sc = store.statsToday?.score, (store.statsToday?.focusedSeconds ?? 0) > 0 || s.elapsed > 60 { Text("score \(sc.total) · \(sc.word.lowercased())") }
                Divider()
                if s.onBreak { Button("End the Break") { store.resumeSession() } }   // HUD3
                else if !s.strictness.isHard || store.breakBank(s) >= 10 { Button("Take a 10-Minute Break") { store.takeBreak(minutes: 10) } }
                Button(s.strictness.isHard ? "End Session…" : "End Session") { store.requestEnd() }
                if store.settings.miniPanel { Button(MiniPanel.shared.isHidden ? "Show Mini Panel" : "Hide Mini Panel") { MiniPanel.shared.toggleHidden() } }   // C3
            } else {
                Text("Not in a session")
                Divider()
                Button("Start Focus Session…") { store.go(.home); openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            }
            Button("Open Distraction Bot") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) { Theme.registerFonts() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--menubar") {
            // launched at login (§5a Q14): the watchers run from the menu bar; the window waits for "Open Distraction Bot"
            DispatchQueue.main.async { NSApp.windows.filter { $0.title == "Distraction Bot" }.forEach { $0.close() } }
            return
        }
        if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] == nil { NSApp.activate(ignoringOtherApps: true) }   // R1 (D23): an offscreen render never steals focus
        if let a = ProcessInfo.processInfo.environment["DBOT_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua)
        }
    }
    /// The watchers keep running from the menu bar when the window closes (§3.6).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    /// Hard mode (B6): ⌘Q, Quit and a polite kill are refused during a hard session; the escape card asks for the phrase.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { (Store.current?.mayQuit() ?? true) ? .terminateNow : .terminateCancel }
    }
}

/// Dev aid, as in Ledger: DBOT_SNAPSHOT=/path.png DBOT_SNAPSHOT_TAB=apps renders the screen offscreen and quits.
enum Snapshot {
    /// The three overlays with fixture text, for judging their shared layout (PLAN_DESIGN_CLEANUP G5). Nothing is shown on screen.
    @MainActor static func overlay(store: Store) -> AnyView? {
        switch ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_VIEW"] {
        case "banner":
            let b = Banner.shared; b.title = "Detour"; b.text = "YouTube · best mechanical keyboards 2026"; b.reason = "A search unrelated to the BIO 210 write-up, 12 minutes into the session."; b.timeout = 20
            // E0: fixture facts for the facts line and the why disclosure; DBOT_SNAPSHOT_SCOPE=1 opens the scope row, DBOT_SNAPSHOT_WHY=1 the why, DBOT_SNAPSHOT_TELL=1 the field
            store.judge.lastFacts = Judge.Facts(goal: "BIO 210 write-up", minutesIn: 12, strictness: "normal", allowed: ["Discord"], frontApp: "Dia", frontKind: "web browser",
                                                title: "best mechanical keyboards 2026 - YouTube", url: "https://www.youtube.com/results?search_query=best+mechanical+keyboards", screen: nil,
                                                behind: ["Overleaf — project.tex"], recent: ["reddit: r/physics → you said: work"], usage: "Dia in front 31 min this session",
                                                dwell: "in front 4 min this session · 3rd visit", appClass: "entertainment")
            let env = ProcessInfo.processInfo.environment
            b.mode = env["DBOT_SNAPSHOT_SCOPE"] == "1" ? .scope : env["DBOT_SNAPSHOT_TELL"] == "1" ? .tell : .answers
            b.why = env["DBOT_SNAPSHOT_WHY"] == "1"
            return AnyView(BannerView(banner: b).padding(Space.sheet))
        case "escape":
            let c = EscapeCard.shared; c.title = "End the session early?"; c.phrase = "let me out"; c.goal = "BIO 210 project part A"
            return AnyView(EscapeView(card: c).padding(Space.sheet))
        case "shield":
            let sh = Shield.shared; sh.store = store; sh.appName = "Steam"; sh.attempts = 2; sh.mode = .wall; sh.shownAt = Date()
            // E3: DBOT_SNAPSHOT_EXTENSIONS=2 shows the counted button (the third: refused on DBOT_SNAPSHOT_LEVEL=strict, free on normal)
            if let n = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_EXTENSIONS"].flatMap(Int.init) { store.watcher.extensions["com.valvesoftware.steam"] = n; sh.bundleID = "com.valvesoftware.steam"; sh.shownAt = Date().addingTimeInterval(-200) }
            if let l = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_LEVEL"].flatMap(Strictness.init(rawValue:)), store.session != nil { store.session?.strictness = l }
            return AnyView(ShieldView(shield: sh).environment(store).padding(Space.sheet))
        case "end-card":   // E2 → PLAN_GAME_FEEL F1: the tally fixture of §3.1 (60 min planned, ended at 52 → 78), CS 150 256 → 310 XP, today 62 → 74, the 4th flame
            // DBOT_SNAPSHOT_FRAME=0…6 draws one frame of the sequence; DBOT_SNAPSHOT_TALLY=clean (nothing taken off) | levelup (CS 150 500 → 554, L1 → L2)
            let env = ProcessInfo.processInfo.environment
            let c = EndCard.shared
            var sum = EndCard.Summary(title: "Problem set 5 — heaps", reason: "ended", seconds: 52 * 60, score: Score(time: 43, calm: 18, follow: 10, blocks: 7))
            sum.losses = [Tally.Loss(name: "ended early", detail: "52 of 60 min", points: 7, part: .time), Tally.Loss(name: "detour", detail: "YouTube · 3 min", points: 2, part: .calm),
                          Tally.Loss(name: "warning ignored", detail: "Reddit", points: 10, part: .kept), Tally.Loss(name: "launched", detail: "Steam", points: 3, part: .control)]
            sum.strictness = "strict"; sum.cleanMinutes = 49; sum.xp = 54
            sum.course = CourseMove(code: "CS 150", icon: "curlybraces", accent: "sky", levelBefore: 1, before: 0.21, level: 1, after: 0.36, gainedXP: 54, toNext: 230)
            sum.dayBefore = 62; sum.dayAfter = 74
            sum.cells = [.session, .session, .session, .session, .future, .future, .future]; sum.today = 3; sum.streak = 4; sum.lit = true
            sum.next = "BIO 210 write-up"; sum.offerShutdown = env["DBOT_SNAPSHOT_SHUTDOWN"] == "1"
            if env["DBOT_SNAPSHOT_TALLY"] == "clean" {
                sum.title = "Lab report 3 — osmosis"; sum.reason = "finished"; sum.seconds = 60 * 60; sum.strictness = "normal"; sum.score = Score(time: 50, calm: 20, follow: 20, blocks: 10)
                sum.losses = []; sum.cleanMinutes = 60; sum.finished = true; sum.xp = 90; sum.dayBefore = 74; sum.dayAfter = 86; sum.lit = false
                sum.course = CourseMove(code: "BIO 210", icon: "leaf", accent: "sage", levelBefore: 1, before: 0.09, level: 1, after: 0.34, gainedXP: 90, toNext: 236)
            }
            // M2 (PLAN_MINUTE_STRIP §3.4): the strip from fixture rows — YouTube 3 min ending at 15, Reddit's minute blocked at 31, Steam at 40;
            // the clean fixture is an hour of focus. Each loss is pointed at its span as `endSummary` does.
            do {
                let t0 = Date().addingTimeInterval(-Double(sum.seconds))
                func row(_ at: Double, _ kind: String, _ app: String = "", _ detail: String = "") -> Event { Event(id: 0, ts: t0.addingTimeInterval(at), kind: kind, app: app, detail: detail, latencyMs: nil) }
                let rows = env["DBOT_SNAPSHOT_TALLY"] == "clean" ? [] : [row(900, "judge.detour", "", "180 · followed through · YouTube — a video"),
                                                                         row(1860, "judge.detour", "", "60 · blocked · Reddit"), row(2400, "block.shield", "Steam")]
                let strip = SessionSpans.build(rows: rows, start: t0, end: t0.addingTimeInterval(Double(sum.seconds)), planned: 3600, pausedTotal: 0)
                sum.strip = strip; sum.losses = Tally.point(sum.losses, strip)
                // HUD6: the same session as a game — `back` on YouTube, still in front on Reddit, Steam launched; 3 of 4 tasks, the 4th carried
                let clean = env["DBOT_SNAPSHOT_TALLY"] == "clean"
                let hitRows = rows + (clean ? [] : [row(1085, "judge.answer", "", "back · YouTube — a video"), row(1920, "judge.followup", "", "still in front · reddit.com · blocked for the session")])
                let hits = SessionGame.hits(rows: hitRows, start: t0, end: t0.addingTimeInterval(Double(sum.seconds)))
                let g = SessionGame.play(spans: strip.spans, hits: hits)
                sum.game = g; sum.gameLosses = SessionGame.losses(spans: strip.spans, hits: hits, state: g, marks: strip.marks)
                sum.comboXP = Int((g.comboMinutes * XP.multiplier(sum.strictness)).rounded()); sum.cleanMinutes = g.cleanSeconds / 60
                if !clean { sum.tasksTotal = 4; sum.tasksDone = 3; sum.taskXP = 30; sum.openTasks = ["problem 4 — the heap proof"]; sum.objectiveId = "fixture" }
                if env["DBOT_SNAPSHOT_TALLY"] == "levelup" { sum.objectiveDone = true }
            }
            if env["DBOT_SNAPSHOT_TALLY"] == "levelup" { sum.course = CourseMove(code: "CS 150", icon: "curlybraces", accent: "sky", levelBefore: 1, before: 0.89, level: 2, after: 0.02, gainedXP: 54, toNext: 706) }
            // HUD6: the course move's gain is the sum the XP line gives (combo + finished + tasks; + 60 on a completion), so the two never disagree
            if var mv = sum.course { mv.gainedXP = (sum.comboXP ?? 0) + (sum.finished ? 30 : 0) + sum.taskXP + (sum.objectiveDone ? 60 : 0); sum.course = mv }
            if env["DBOT_SNAPSHOT_TALLY"] == "best" { sum.best = "longest CS 150 session yet" }   // F4
            c.summary = sum; c.shownAt = Date(); c.skipped = false
            c.frame = env["DBOT_SNAPSHOT_FRAME"].flatMap(Int.init)
            return AnyView(EndCardView(card: c).padding(Space.sheet))
        case "closing":   // G4 (PLAN_GAME_LOOP §3.6): the closing card with a fixture — 5 days, a freeze earned, 87 → 97, CS 150 moving
            let c = ClosingCard.shared
            c.summary = ClosingSummary(dayLabel: "wed 28 oct", stars: "★★★★☆", streak: 5, cells: [.session, .frozen, .session, .session, .session, .future, .future], today: 4,
                                       freezeEarned: true, freezes: 2, scoreBefore: 87, scoreAfter: 97, word: "On track", focused: 3 * 3600 + 4 * 60, sessions: 2,
                                       course: ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_TALLY"] == "levelup"   // F4: the level-up beat
                                           ? CourseMove(code: "CS 150", icon: "curlybraces", accent: "sky", levelBefore: 1, before: 0.80, level: 2, after: 0.05, gainedXP: 184, toNext: 694)
                                           : CourseMove(code: "CS 150", icon: "curlybraces", accent: "sky", levelBefore: 2, before: 0.48, level: 2, after: 0.62, gainedXP: 184, toNext: 460),
                                       losses: [Tally.Loss(name: "under plan", detail: "3 h 04 of 3 h 15", points: 2, part: .plan), Tally.Loss(name: "detours", detail: "1 min", points: 1, part: .calm)])   // F2
            return AnyView(ClosingCardView(card: c).padding(Space.sheet))
        default: return nil
        }
    }

    @MainActor static func armIfRequested(store: Store) {
        guard let path = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] else { return }
        let tab = Screen(legacy: ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_TAB"] ?? "home") ?? .home   // M0: apps · websites · screen · history still render, mapped
        let dark = ProcessInfo.processInfo.environment["DBOT_APPEARANCE"] == "dark"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // DBOT_SNAPSHOT_SESSION="goal" renders Home's live card (H2): a 50-min session 20 min in, one verdict. Cleared again before quitting.
            let fakeSession = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_SESSION"]
            // DBOT_SNAPSHOT_OPEN="subject:<id>" | "objective:<id>" renders a subject page or an objective pane (PLAN_OBJECTIVES_TAB U0)
            if let open = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_OPEN"]?.split(separator: ":", maxSplits: 1).map(String.init), open.count == 2 {
                if open[0] == "subject" { store.openSubject = open[1] } else if open[0] == "objective" { store.openObjective = open[1] }
            }
            // DBOT_SNAPSHOT_QUEUED=<objective id> renders the queued state (PLAN_CURRENT_SESSION C0 / PLAN_JUMP_BACK_IN §3.5); the queue file
            // is cleared again before quitting. Run with DBOT_QUEUE_PATH on a scratch path so a real queue is never replaced.
            var madeQueue = false
            if let id = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_QUEUED"], store.session == nil, store.queued == nil, let o = store.objective(id) {
                madeQueue = store.prepareSession(objective: o, source: "snapshot")
            }
            var madeFake = false
            if let g = fakeSession, store.session == nil {
                madeFake = true
                // DBOT_SNAPSHOT_OBJECTIVE=<id> makes it a session from that objective (H3: subject pill, bio, kind on the live card).
                let o = store.objective(ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_OBJECTIVE"])
                store.session = Session(goal: o?.title ?? g, started: Date().addingTimeInterval(-20 * 60), ends: Date().addingTimeInterval(30 * 60), strictness: o?.severity ?? .normal,
                                        subjectId: o?.subjectId, objectiveId: o?.id, kind: o?.kind)
                store.judge.lastVerdict = Judge.Verdict(distracted: false, confidence: 0.92, reason: "LaTeX write-up for the project", seconds: 1.8, model: "qwen3:14b")
                // M1 (PLAN_MINUTE_STRIP): the strip's fixture rows — the sweep at 2 s, a 40-s heeded YouTube detour, Steam launched at 10 min,
                // a 30-s Reddit detour that was blocked, 3 min away; DBOT_SNAPSHOT_STRIP=open (no end) | paused (paused since 18 min)
                // HUD2: DBOT_SNAPSHOT_STRIP=x3 — 45 min in, one early slip (a 30-s YouTube detour answered `back`), clean since: the combo past 30 min, ×3
                if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_STRIP"] == "x3" { store.session?.started = Date().addingTimeInterval(-45 * 60); store.session?.ends = Date().addingTimeInterval(15 * 60) }
                let t0 = store.session!.started
                func row(_ at: Double, _ kind: String, _ app: String = "", _ detail: String = "") -> Event { Event(id: 0, ts: t0.addingTimeInterval(at), kind: kind, app: app, detail: detail, latencyMs: nil) }
                var rows = [row(2, "block.close", "Telegram"), row(400, "judge.detour", "", "40 · followed through · YouTube — a video"), row(600, "block.shield", "Steam"),
                            row(750, "judge.detour", "", "30 · blocked · Reddit"), row(1020, "session.away", "", "180")]
                if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_STRIP"] == "x3" {
                    rows = [row(2, "block.close", "Telegram"), row(330, "judge.detour", "", "30 · followed through · YouTube — a video"), row(335, "judge.answer", "", "back · YouTube — a video")]
                }
                switch ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_STRIP"] {
                case "open": store.session?.ends = nil
                case "paused": store.session?.pausedUntil = Date().addingTimeInterval(8 * 60); store.session?.onBreak = true; store.breakStartedAt = Date().addingTimeInterval(-2 * 60); rows.append(row(1080, "session.pause", "", "10 min · break"))   // HUD3: a break
                default: break
                }
                store.liveStripRows = rows; store.refreshLiveStrip()
            }
            // DBOT_SNAPSHOT_VIEW=today renders the Today strip alone in its card (PLAN_TODAY_TIMELINE T1); DBOT_SNAPSHOT_DAY=yyyy-MM-dd picks the day (now = 23:40 that day).
            let todayOnly = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_VIEW"] == "today"
            let strip: TodayTimeline = {
                if let d = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_DAY"], let date = ISO8601DateFormatter.ymd.date(from: d) {
                    let day = StudyDay.dayStarting(on: date), next = StudyDay.end(of: day)   // K1: the study day beginning on that date
                    let at = Calendar.current.date(bySettingHour: 23, minute: 40, second: 0, of: date)!
                    return TodayTimeline(model: DayModel.build(events: EventLog.shared.events(from: day, to: next), live: nil, day: day, now: at, threshold: store.judge.threshold, target: TimeInterval(store.settings.targetMinutes(on: day) * 60)), now: at)
                }
                return TodayTimeline(model: store.today, now: Date())
            }()
            let subjectEditor = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_VIEW"] == "subject-editor"   // the sheet's body as a plain view (PLAN_OBJECTIVES_TAB U1)
            let view = VStack(spacing: 0) {
                if todayOnly { strip.cardPadding().card(wash: true, watermark: "calendar.day.timeline.left").padding(Space.sheet) }
                else if subjectEditor { SubjectEditor(existing: store.subjects.first).padding(Space.sheet) }
                else if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_VIEW"] == "objective-editor", let o = store.subjects.first.flatMap({ store.objectives(in: $0.id).first }) { ObjectiveEditor(existing: o, subjectId: o.subjectId).padding(Space.sheet) }
                // DBOT_SNAPSHOT_VIEW=new-objective renders Home's quick-create popover body alone (PLAN_NEW_OBJECTIVE_WIDGET N0); DBOT_SNAPSHOT_TITLE pre-types a title.
                else if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_VIEW"] == "new-objective" {
                    QuickObjectiveForm(subject: store.subjects.last?.id, minutes: 50, strictness: .normal, presetTitle: ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_TITLE"] ?? "") { _, _ in }
                        .card().padding(Space.sheet)
                }
                // DBOT_SNAPSHOT_VIEW=shutdown renders the shutdown screen for DBOT_SNAPSHOT_DAY (today without it) with text stand-ins (PLAN_STUDY_DAY K2)
                // R4 (PLAN_REWORK §4): DBOT_SNAPSHOT_VIEW=loop renders Progress' loop card alone
                else if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_VIEW"] == "loop", let st = store.stats { LoopCard(stats: st).padding(Space.sheet) }
                else if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_VIEW"] == "shutdown" {
                    ShutdownScreen(day: ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_DAY"].flatMap { ISO8601DateFormatter.ymd.date(from: $0) }.map { StudyDay.dayStarting(on: $0) } ?? StudyDay.start(of: Date()))
                }
                // DBOT_SNAPSHOT_VIEW=mini-panel renders the session mini panel alone, top-right as on a screen (PLAN_CURRENT_SESSION C3); DBOT_SNAPSHOT_EXPANDED=1 opens the drawer.
                else if ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_VIEW"] == "mini-panel" {
                    // E1: DBOT_SNAPSHOT_CORNER=bottomLeft places it; DBOT_SNAPSHOT_NOTE=1 the note field; DBOT_SNAPSHOT_TEACH=1 the wrong row (R0: the ✕'s question is gone)
                    let _ = { let e = ProcessInfo.processInfo.environment; let m = MiniPanel.shared
                        m.setExpanded(e["DBOT_SNAPSHOT_EXPANDED"] == "1", animated: false)
                        m.noteOpen = e["DBOT_SNAPSHOT_NOTE"] == "1"; m.teachOpen = e["DBOT_SNAPSHOT_TEACH"] == "1" }()
                    let c = MiniPanel.shared.corner
                    VStack { if c.bottom { Spacer() }
                        HStack { if c == .topRight || c == .bottomRight { Spacer() }; MiniPanelView(panel: MiniPanel.shared); if c == .topLeft || c == .bottomLeft { Spacer() } }
                        if !c.bottom { Spacer() } }
                    .padding(.horizontal, MiniPanel.inset.x).padding(.vertical, MiniPanel.inset.y)
                }
                else if let overlay = Snapshot.overlay(store: store) { overlay }   // G5: DBOT_SNAPSHOT_VIEW=banner|escape|shield renders an overlay with fixture text
                else { ScreenView(screen: tab) }
            }
                .environment(store)
                .frame(width: CGFloat(Int(ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_WIDTH"] ?? "") ?? 1080), height: CGFloat(Int(ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_HEIGHT"] ?? "") ?? 1400), alignment: .top)
                .background(Theme.bg)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.snapshot, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let data = rep.representation(using: .png, properties: [:]) {
                do { try data.write(to: URL(fileURLWithPath: path)); Log.write("snapshot written \(path)") } catch { Log.write("snapshot write failed: \(error)") }
            } else { Log.write("snapshot render failed (nil image) for \(tab)") }
            if madeFake { store.session = nil }      // clears only the fake session.json we wrote; never a real one. terminate() does not return, so no defer
            if madeQueue { store.clearQueued() }     // likewise the snapshot's queue
            NSApp.terminate(nil)
        }
    }
}

/// T2's check window: the strip alone in its card, 1032 × 270, parked at the screen's top-left; the content's screen origin
/// and every chip's frame go to the app log (DBOT_HOVER_LOG), so `scripts/t2-drive.swift` can aim the pointer.
struct TodayDevWindow: View {
    @Environment(Store.self) private var store
    var body: some View {
        let strip: TodayTimeline = {
            if let d = ProcessInfo.processInfo.environment["DBOT_SNAPSHOT_DAY"], let date = ISO8601DateFormatter.ymd.date(from: d) {
                let day = StudyDay.dayStarting(on: date), next = StudyDay.end(of: day)   // K1
                let at = Calendar.current.date(bySettingHour: 23, minute: 40, second: 0, of: date)!
                return TodayTimeline(model: DayModel.build(events: EventLog.shared.events(from: day, to: next), live: nil, day: day, now: at, threshold: store.judge.threshold, target: TimeInterval(store.settings.targetMinutes(on: day) * 60)), now: at)
            }
            return TodayTimeline(model: store.today, now: Date())
        }()
        return strip.cardPadding().card(wash: true, watermark: "calendar.day.timeline.left").padding(Space.sheet)
            .frame(width: 1032, height: 270).background(Theme.bg)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let w = NSApp.windows.first(where: { $0.isVisible }), let screen = NSScreen.main, let cv = w.contentView else { return }
                    w.setContentSize(NSSize(width: 1032, height: 270))
                    w.setFrameTopLeftPoint(NSPoint(x: 40, y: screen.frame.height - 60))
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let originX = w.frame.minX + cv.frame.minX
                        let topCG = screen.frame.height - (w.frame.minY + cv.frame.maxY)
                        Log.write("devwindow content-origin \(originX) \(topCG)")
                    }
                }
            }
    }
}
