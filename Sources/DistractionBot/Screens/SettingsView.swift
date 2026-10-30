import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.snapshot) private var snapshot
    @State private var loginInstalled = LoginItem.isInstalled
    @State private var phrase1 = ""   // X6d
    @State private var phrase2 = ""
    @State private var phraseError: String?

    var body: some View {
        @Bindable var store = store
        Page(kicker: "local only", title: "Settings") {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(1, "Permissions", note: "granted once · kept across rebuilds by the dev signing identity")
                VStack(spacing: 0) {
                    row("Accessibility", sub: "reads the browser's url and title · sends ⌘W to dia", granted: store.accessibility,
                        grant: { Permissions.promptForAccessibility() }, open: Permissions.openAccessibilitySettings)
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, Space.loose)
                    row("Screen Recording", sub: "window titles · the occasional look at the front window", granted: store.screenRecording,
                        grant: { Permissions.promptForScreenRecording() }, open: Permissions.openScreenRecordingSettings)
                    Rectangle().fill(Theme.line).frame(height: 1).padding(.horizontal, Space.loose)
                    HStack {
                        VStack(alignment: .leading, spacing: Space.hair) {
                            Text("Automation · Safari").font(Type.strong).foregroundStyle(Theme.ink)
                            Text("Asked by macOS the first time a Safari tab is blocked.").font(Type.body).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        PillButton(text: "open settings") { Permissions.openAutomationSettings() }
                    }
                    .padding(.horizontal, Space.loose).padding(.vertical, Space.stack)
                }
                .padding(Space.stack)
                .card(watermark: "lock.shield")
            }
            Pair {
              VStack(alignment: .leading, spacing: Space.section) {   // R5 (PLAN_REWORK §3.6, D21): Behaviour in three cards — Sessions · The day · Hard mode
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(2, "Sessions")
                    VStack(alignment: .leading, spacing: Space.loose) {
                        setting("Launch at login", sub: "to the menu bar only; the window opens from there") {
                            SwitchRow(isOn: Binding(get: { loginInstalled }, set: { on in
                                if on { if let e = LoginItem.install() { store.fail(e) } else { loginInstalled = true; store.settings.launchAtLogin = true; store.show("Launches at login") } }
                                else { LoginItem.uninstall(); loginInstalled = false; store.settings.launchAtLogin = false }
                            }))
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        setting("Sound", sub: "with every warning and block") {
                            HStack(spacing: Space.stack) {
                                if store.settings.soundOn { PillMenu(options: AppSettings.sounds.map { ($0, $0) }, selection: $store.settings.soundName, leadingSymbol: "speaker.wave.2") }
                                SwitchRow(isOn: $store.settings.soundOn)
                            }
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        setting("New session defaults", sub: "length and strictness offered on home") {
                            HStack(spacing: Space.stack) {
                                PillMenu(options: [(25, "25 min"), (50, "50 min"), (90, "90 min"), (0, "until I stop")], selection: $store.settings.defaultMinutes, leadingSymbol: "timer")
                                PillMenu(options: Strictness.allCases.map { ($0, $0.rawValue) }, selection: $store.settings.defaultStrictness, leadingSymbol: "shield.lefthalf.filled")
                            }
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        setting("Focus target", sub: "a day's focused time · the Progress tab's pace line and score") {
                            HStack(spacing: Space.stack) {
                                PillMenu(options: [60, 120, 180, 240, 300, 360, 480].map { ($0, "\($0 / 60) h weekdays") }, selection: $store.settings.dailyTargetMinutes, leadingSymbol: "target")
                                PillMenu(options: [0, 60, 120, 180, 240].map { ($0, $0 == 0 ? "weekends off" : "\($0 / 60) h weekends") }, selection: $store.settings.weekendTargetMinutes, leadingSymbol: "sun.max")
                            }
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        setting("Hide test sessions", sub: "goals starting \"B1 \" and sessions under 2 minutes stay out of Progress") { SwitchRow(isOn: $store.settings.hideTestSessions) }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        // X4 (PLAN_CATCHER §3.5): away after 5 min idle is always counted; this is the longer idle that pauses the session
                        setting("Pause when away", sub: "no keyboard or mouse this long pauses the session until you are back · away time never counts as focused") {
                            PillMenu(options: [(0, "never"), (10, "10 min"), (15, "15 min"), (20, "20 min"), (30, "30 min")], selection: $store.settings.autoPauseMinutes, leadingSymbol: "moon.zzz")
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        // C3 (PLAN_CURRENT_SESSION §3.7): the top-right pill while a session runs and the app is out of view
                        setting("Mini panel during a session", sub: "a small glass pill in a corner of your screen when the app is not in front · click opens its drawer · drag it by its top edge · ✕ hides it for the session") {
                            HStack(spacing: Space.stack) {   // E1 (PLAN_OVERLAY §3.2): the corner; a drag is remembered per display
                                if store.settings.miniPanel { PillMenu(options: MiniPanel.Corner.allCases.map { ($0.rawValue, $0.label) }, selection: $store.settings.miniPanelCorner, leadingSymbol: "rectangle.inset.topright.filled") }
                                SwitchRow(isOn: $store.settings.miniPanel)
                            }
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        // HUD2 (PLAN_SESSION_HUD §3.7, §5a Q17): system-wide keys for the HUD; off gives the keys back to other apps
                        setting("Session keys", sub: "⌃⌥Space opens the mini panel's drawer · ⌃⌥B takes a 10-minute break · ⌃⌥T adds a task · from any app") {
                            SwitchRow(isOn: $store.settings.hotkeys)
                        }
                        .onChange(of: store.settings.hotkeys) { _, on in Hotkeys.apply(enabled: on) }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        // HUD3 (PLAN_SESSION_HUD §3.3): a quiet line on the mini panel, never a forced break
                        setting("Break reminder", sub: "after this long without a break the mini panel says a break is due · breaks freeze your accuracy and combo and cost nothing") {
                            PillMenu(options: [(25, "25 min"), (50, "50 min"), (90, "90 min"), (0, "never")], selection: $store.settings.breakDueMinutes, leadingSymbol: "cup.and.saucer")
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        AlertsSettings()   // HUD5 (PLAN_SESSION_HUD §3.5)
                    }
                    .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                    .card(watermark: "slider.horizontal.3")
                }
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(0, "The day")
                    VStack(alignment: .leading, spacing: Space.loose) {
                        // K0 (PLAN_STUDY_DAY §3.1, §5a Q4.1): every "today" — Home, History, Progress, streaks, the shutdown — runs from this hour to the next
                        setting("Study day starts", sub: "a session that runs past midnight stays with the evening it began · every today, streak and score follows") {
                            PillMenu(options: [(0, "midnight"), (2, "2 am"), (3, "3 am"), (4, "4 am"), (5, "5 am"), (6, "6 am")], selection: $store.settings.dayStartHour, leadingSymbol: "moon.stars")
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        // K3 (PLAN_STUDY_DAY §3.5, §5a Q4.3): when the shutdown is offered after a session, and the one quiet reminder
                        setting("Shut down the day", sub: "offered after a session ends past this hour · one reminder toast if the day is not shut down · ⌘⇧D any time") {
                            HStack(spacing: Space.stack) {
                                PillMenu(options: [18, 19, 20, 21, 22, 23].map { ($0, "offer from \(String(format: "%02d:00", $0))") }, selection: $store.settings.shutdownOfferHour, leadingSymbol: "flag.checkered")
                                PillMenu(options: [("off", "no reminder")] + ["21:30", "22:00", "22:30", "23:00", "23:30", "00:00", "00:30", "01:00"].map { ($0, "remind \($0)") }, selection: $store.settings.shutdownReminder, leadingSymbol: "bell")
                            }
                        }
                    }
                    .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                    .card(watermark: "moon.stars")
                }
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(0, "Hard mode")
                    VStack(alignment: .leading, spacing: Space.loose) {
                        VStack(alignment: .leading, spacing: Space.tight) {
                            Text("Strictness levels").font(Type.strong).foregroundStyle(Theme.ink)
                            Text("laxed: the judge warns only when sure, no block list, the card just fades · gentle: warns only, nothing closed, 30 s to answer · normal: the block list enforced, the judge warns, ignoring blocks · strict: 10 s to answer, three detours in 15 min → a 5-minute break card · hard: strict, and the app cannot be quit, paused or ended early except by the phrase below; killed, it is back within seconds; no snooze; 5 more minutes after 2 min · extreme: hard, and a confident verdict closes the app or blocks the site at once, 5 s to answer").font(Type.body).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        Rectangle().fill(Theme.line).frame(height: 1)
                        VStack(alignment: .leading, spacing: Space.tight) {
                            // X6d (PLAN_CATCHER §3.10): 12 characters at least, typed twice; the current phrase is shown masked and keeps working until changed
                            setting("Escape phrase", sub: "typed, exactly, to end a hard session or quit during one · \(AppSettings.minPhrase) characters at least, typed twice to change") { EmptyView() }
                            HStack(spacing: Space.stack) {
                                MonoLabel("now: \(AppSettings.masked(store.settings.escapePhrase))", color: Theme.muted2)
                                if store.settings.phraseTooShort { MonoLabel("\(AppSettings.minPhrase) characters at least · set a longer one below", color: Theme.muted) }   // R5 (D20): said once, no colour
                            }
                            if snapshot { well("new phrase", empty: true) }
                            else {
                                HStack(spacing: Space.stack) {
                                    TextField("new phrase", text: $phrase1).textFieldStyle(.roundedBorder).font(Type.body)
                                    TextField("again", text: $phrase2).textFieldStyle(.roundedBorder).font(Type.body)
                                    PillButton(text: "set", kind: .accent) {
                                        if let e = store.settings.setPhrase(phrase1, confirm: phrase2) { phraseError = e } else { phraseError = nil; phrase1 = ""; phrase2 = ""; store.show("Escape phrase set") }
                                    }
                                }
                                if let e = phraseError { Text(e).font(Type.body).foregroundStyle(Theme.warn) }
                            }
                        }
                    }
                    .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                    .card(watermark: "lock.shield")
                }
              }
            } second: {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader(3, "Calendar", note: "your feed · lectures and events become planned sessions")   // P2 (PLAN_PLANNING §3.3, Q4.6): the schedule window went
                    VStack(alignment: .leading, spacing: Space.loose) {
                        // Your calendar (PLAN_WEEK_CALENDAR W3, §3.6): the ICS address, fetched on a timer; the Calendar tab draws it under the sessions
                        let status = store.feed.status()
                        VStack(alignment: .leading, spacing: Space.stack) {
                            setting("Your calendar", sub: store.settings.icsURL.isEmpty ? "paste a secret ical address · drawn under the sessions on the calendar tab" : status.text) {
                                HStack(spacing: Space.stack) {
                                    if !store.settings.icsURL.isEmpty { PillButton(text: store.feed.fetching ? "fetching…" : "fetch now") { store.fetchFeedNow() } }
                                    SwitchRow(isOn: $store.settings.showFeed)
                                }
                            }
                            if status.warning { Text(status.text).font(Type.body).foregroundStyle(Theme.warn) }
                            // the address itself never appears in a render (it grants read access to the calendar)
                            if snapshot { well(store.settings.icsURL.isEmpty ? "not set" : "a secret address is set", empty: true) }
                            else {
                                TextField("https://calendar.google.com/calendar/ical/…/basic.ics", text: $store.settings.icsURL).textFieldStyle(.roundedBorder).font(Type.body)
                                    .onSubmit { store.feedURLChanged() }
                            }
                            HStack(spacing: Space.stack) {
                                PillMenu(options: [15, 30, 60, 180].map { ($0, $0 < 60 ? "every \($0) min" : "every \($0 / 60) h") }, selection: $store.settings.icsRefreshMinutes, leadingSymbol: "arrow.clockwise")
                                PillMenu(options: [("#8aa0d6", "quiet blue")] + Theme.families.map { ($0.0, $0.0) }, selection: $store.settings.icsColor, leadingSymbol: "paintpalette")
                            }
                        }
                        .onChange(of: store.settings.icsURL) { old, new in if new.trimmingCharacters(in: .whitespaces).isEmpty, !old.isEmpty { store.feedURLChanged() } }
                    }
                    .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                    .card(watermark: "calendar.badge.clock")
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(4, "Data")
                VStack(alignment: .leading, spacing: Space.stack) {
                    Text("Rules, settings and the log live in ~/Library/Application Support/Distraction Bot. No images are ever written. Nothing leaves this Mac except the calendar fetch you set up in Calendar.")
                        .font(Type.body).foregroundStyle(Theme.muted).lineSpacing(Space.hair)
                    // K0 (PLAN_STUDY_DAY §3.8, IMPACT_ANALYSIS R0): which tabs and doors get used, so the next look at the app can count them
                    setting("UI usage", sub: "one row in the log per tab, pane or ↗ you open — the name of the tab, never what is in it · so the next review can see which parts earn their place") { SwitchRow(isOn: $store.settings.uiLog) }
                    HStack(spacing: Space.stack) {
                        ActionButton(title: "Export log as CSV", symbol: "square.and.arrow.up", ghost: true) { store.exportCSV() }
                        ActionButton(title: "Clear log", symbol: "trash", ghost: true) { store.clearLog() }
                        ActionButton(title: "Reveal in Finder", symbol: "folder", ghost: true) { NSWorkspace.shared.activateFileViewerSelecting([Store.supportDir]) }
                    }
                }
                .cardPadding().frame(maxWidth: .infinity, alignment: .leading)
                .card(watermark: "internaldrive")
            }
        }
        .task {
            while !Task.isCancelled { await store.refreshStatus(); loginInstalled = LoginItem.isInstalled; try? await Task.sleep(for: .seconds(2)) }
        }
    }

    private var times: [String] { stride(from: 6, through: 23, by: 1).flatMap { h in ["00", "30"].map { String(format: "%02d:%@", h, $0) } } }

    /// A row's title and its one-sentence help (G5, §5a Q3: sentence-case body text in muted ink, not mono caps).
    private func setting<V: View>(_ name: String, sub: String, @ViewBuilder _ v: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(name).font(Type.strong).foregroundStyle(Theme.ink)
                Text(Self.sentence(sub)).font(Type.body).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.card)
            v()
        }
    }
    /// A render-only stand-in for a text field: the typed value (or its placeholder, muted) in a paper well.
    private func well(_ text: String, empty: Bool) -> some View {
        Text(text).font(Type.body).foregroundStyle(empty ? Theme.muted2 : Theme.ink).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).rowPadding()
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.paper2))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
    /// First letter up, a full stop at the end: the subtitles were written for mono caps.
    static func sentence(_ s: String) -> String {
        guard let f = s.first else { return s }
        let t = f.uppercased() + s.dropFirst()
        return t.hasSuffix(".") || t.hasSuffix("?") ? t : t + "."
    }
    private func row(_ name: String, sub: String, granted: Bool, grant: @escaping () -> Void, open: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(name).font(Type.strong).foregroundStyle(Theme.ink)
                Text(Self.sentence(sub)).font(Type.body).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            granted ? Pill("granted", kind: .ok, dot: true) : Pill("not granted", kind: .danger)
            if !granted { PillButton(text: "grant", kind: .accent) { grant(); Task { try? await Task.sleep(for: .seconds(1)); await store.refreshStatus() } } }
            PillButton(text: "open settings") { open() }
        }
        .padding(.horizontal, Space.loose).padding(.vertical, Space.stack)
    }
}
