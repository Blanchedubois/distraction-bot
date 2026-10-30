import AppKit
import Carbon

/// HUD2 (PLAN_SESSION_HUD §3.7, §5a Q17): system-wide keys for the HUD, registered with Carbon's `RegisterEventHotKey` — no
/// Accessibility or Input Monitoring permission, and the keys reach the app while another app is in front.
///   ⌃⌥Space — open or close the HUD's drawer (shows a hidden HUD first)
///   ⌃⌥B     — a 10-minute break, or the end of the break on now (HUD3)
///   ⌃⌥T     — open the drawer on `add a task` (HUD4)
/// Off in Settings → Behaviour unregisters them, so the keys go back to other apps.
@MainActor
enum Hotkeys {
    private static var refs: [EventHotKeyRef] = []
    private static var handler: EventHandlerRef?
    private static let signature: OSType = 0x4442_4854   // 'DBHT'

    enum Key: UInt32, CaseIterable {
        case drawer = 1, pause = 2, task = 3
        var keyCode: UInt32 { switch self { case .drawer: return UInt32(kVK_Space); case .pause: return UInt32(kVK_ANSI_B); case .task: return UInt32(kVK_ANSI_T) } }
        var label: String { switch self { case .drawer: return "⌃⌥Space"; case .pause: return "⌃⌥B"; case .task: return "⌃⌥T" } }
    }

    /// Registers or unregisters the keys; safe to call repeatedly. Never under `DBOT_SNAPSHOT` (a render or a quiet check).
    static func apply(enabled: Bool) {
        guard ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] == nil else { return }
        refs.forEach { UnregisterEventHotKey($0) }; refs = []
        guard enabled else { Log.write("hotkeys off"); return }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let key = Hotkeys.Key(rawValue: id.id)
                DispatchQueue.main.async { MainActor.assumeIsolated { Hotkeys.pressed(key) } }
                return noErr
            }, 1, &type, nil, &handler)
        }
        for k in Key.allCases {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(k.keyCode, UInt32(controlKey | optionKey), EventHotKeyID(signature: signature, id: k.rawValue), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { Log.write("hotkey \(k.label) not registered (\(status)) — another app holds it") }
        }
        Log.write("hotkeys on · \(Key.allCases.map(\.label).joined(separator: " · "))")
    }

    private static func pressed(_ key: Key?) {
        guard let key, let store = Store.current, store.session != nil else { return }
        switch key {
        case .drawer:
            if MiniPanel.shared.isHidden { MiniPanel.shared.showAgain() }
            MiniPanel.shared.toggleDrawer()
        case .pause:   // HUD3: a break, or the end of the one on now
            if store.session?.onBreak == true { store.resumeSession() } else { store.takeBreak(minutes: 10) }
            EventLog.shared.ui("overlay", "hotkey break")
        case .task:    // HUD4: the drawer, on `add a task`
            MiniPanel.shared.startAddingTask()
        }
    }
}
