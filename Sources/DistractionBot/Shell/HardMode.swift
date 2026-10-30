import AppKit
import SwiftUI

/// Hard mode (B6): while a hard session is on, a launchd agent (`KeepAlive`) runs a small shell loop that brings the
/// installed app back within a few seconds if it is killed — ⌘Q is refused by the app itself (`Store.mayQuit`).
/// Armed at session start, disarmed at session end; the loop also ends by itself once session.json is gone.
enum HardMode {
    static let label = "com.tejasvin.distraction-bot.guard"
    static let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static let script = Store.supportDir.appendingPathComponent("guard.sh")
    static let appPath = "/Applications/Distraction Bot.app"
    static let logPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Distraction Bot/guard.log").path

    static var isArmed: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func arm() {
        guard FileManager.default.fileExists(atPath: appPath) else { Log.write("hard mode: no installed app, guard not armed"); return }
        if isArmed { return }
        let sh = """
        #!/bin/sh
        # Distraction Bot hard mode (B6): while a session is saved, bring the app back if it is not running.
        SESSION="$HOME/Library/Application Support/Distraction Bot/session.json"
        APP="\(appPath)"
        while [ -f "$SESSION" ]; do
          if ! /usr/bin/pgrep -q -f "$APP/Contents/MacOS/DistractionBot"; then
            echo "$(date '+%F %T') app not running → relaunch"
            /usr/bin/open -g -a "$APP" --args --menubar
            sleep 5
          fi
          sleep 2
        done
        echo "$(date '+%F %T') no session → guard exits"
        """
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>\(label)</string>
          <key>ProgramArguments</key><array><string>/bin/sh</string><string>\(script.path)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
          <key>ThrottleInterval</key><integer>2</integer>
          <key>ProcessType</key><string>Interactive</string>
          <key>StandardOutPath</key><string>\(logPath)</string>
          <key>StandardErrorPath</key><string>\(logPath)</string>
        </dict></plist>
        """
        do {
            try sh.write(to: script, atomically: true, encoding: .utf8)
            try xml.write(to: plist, atomically: true, encoding: .utf8)
        } catch { Log.write("hard mode: cannot write guard: \(error)"); return }
        let rc = run(["bootstrap", "gui/\(getuid())", plist.path])
        Log.write("hard mode: guard armed (bootstrap rc \(rc))")
    }

    static func disarm() {
        guard isArmed else { return }
        _ = run(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plist)
        Log.write("hard mode: guard disarmed")
    }

    @discardableResult
    private static func run(_ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl"); p.arguments = args
        p.standardOutput = nil; p.standardError = nil
        try? p.run(); p.waitUntilExit(); return p.terminationStatus
    }
}

/// The escape hatch: a glass card that takes the keyboard (the one card that does) and asks for the phrase.
/// Only an exact match (case and surrounding spaces ignored) enables the button.
@MainActor
@Observable
final class EscapeCard {
    static let shared = EscapeCard()
    var title = ""
    var phrase = ""
    var goal = ""
    var typed = ""
    private var panel: NSPanel?
    private var onConfirm: () -> Void = {}
    static let size = NSSize(width: 620, height: 340)

    var matches: Bool { typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    func show(title: String, phrase: String, goal: String, onConfirm: @escaping () -> Void) {
        self.title = title; self.phrase = phrase; self.goal = goal; self.typed = ""; self.onConfirm = onConfirm
        let p = panel ?? makePanel()
        panel = p
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            p.setFrame(NSRect(origin: NSPoint(x: v.midX - Self.size.width / 2, y: v.midY - Self.size.height / 2 + 30), size: Self.size), display: true)
        }
        MiniPanel.shared.suspend("escape")   // C3
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        EventLog.shared.add("session.escape", detail: "asked · \(title)")
    }

    // X6d (PLAN_CATCHER §3.10): the 5-s hold on the End button once the phrase matches
    var holdStarted: Date?
    static let hold: TimeInterval = 5
    var held: Bool { holdStarted.map { Date().timeIntervalSince($0) >= Self.hold } ?? false }

    func confirm() {
        guard matches else { return }
        EventLog.shared.add("session.escape", detail: "phrase typed · \(title)")
        hide()
        onConfirm()
    }

    func cancel() { EventLog.shared.add("session.escape", detail: "kept going"); hide() }

    func hide() { panel?.orderOut(nil); typed = ""; MiniPanel.shared.resume("escape") }   // C3

    private func makePanel() -> NSPanel {
        let p = BannerPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .utilityWindow], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: EscapeView(card: self))
        return p
    }
}

struct EscapeView: View {
    @Bindable var card: EscapeCard
    @FocusState private var focused: Bool
    @Environment(\.snapshot) private var snapshot
    var body: some View {
        VStack(alignment: .leading, spacing: Space.card) {
            HStack(spacing: Space.loose) {
                Icon("lock.shield.fill", .card, color: Theme.danger)
                MonoLabel("hard mode · the phrase is the only way out", color: Theme.muted)
                Spacer()
            }
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(card.title).font(Type.headline).foregroundStyle(Theme.ink)
                if !card.goal.isEmpty { Text("You said you were working on: \(card.goal)").font(Type.body).foregroundStyle(Theme.muted).lineLimit(2) }
            }
            VStack(alignment: .leading, spacing: Space.tight) {
                MonoLabel("type your escape phrase, exactly:", color: Theme.muted)
                Text("“\(AppSettings.masked(card.phrase))”").font(Type.strong).foregroundStyle(Theme.muted2)   // X6d: masked — you have to know it
                if snapshot {   // ImageRenderer paints a TextField as a yellow box; the render shows the empty well
                    Text(" ").font(Type.body).frame(maxWidth: .infinity, alignment: .leading).rowPadding()
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.07)))
                } else {
                    TextField("", text: $card.typed)
                        .textFieldStyle(.plain).font(Type.body)
                        .rowPadding()
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.07)))
                        .focused($focused)
                        .onSubmit { card.confirm() }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.stack) {
                button("Keep going", "arrow.uturn.backward", accent: true) { card.cancel() }
                // X6d: once the phrase matches, hold the button 5 s; a countdown runs on it
                TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                    let left = card.holdStarted.map { max(0, EscapeCard.hold - ctx.date.timeIntervalSince($0)) }
                    button(left.map { $0 > 0 ? "hold… \(Int($0.rounded(.up)))" : (card.title.hasPrefix("Quit") ? "End and quit" : "End session") } ?? (card.title.hasPrefix("Quit") ? "Hold 5 s to end and quit" : "Hold 5 s to end"), "stop.fill") { if card.held { card.confirm() } }
                        .disabled(!card.matches).opacity(card.matches ? 1 : 0.4)
                        .onLongPressGesture(minimumDuration: EscapeCard.hold, pressing: { down in card.holdStarted = down && card.matches ? Date() : nil }) { if card.matches { card.confirm() } }
                }
                Spacer()
            }
        }
        .padding(Space.sheet)
        .frame(width: EscapeCard.size.width, height: EscapeCard.size.height, alignment: .topLeading)
        .modifier(GlassBack(watermark: "lock.shield", accent: Theme.danger))
        .onAppear { focused = true }
    }
    private func button(_ t: String, _ sym: String, accent: Bool = false, _ action: @escaping () -> Void) -> some View { OverlayButton(t, sym, accent: accent, action) }
}
