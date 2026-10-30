import AppKit
import UserNotifications

/// HUD5 (PLAN_SESSION_HUD §3.5): every alert while you work goes through here, routed by Settings → Behaviour → Alerts:
/// **off**, **in the HUD** (the pill's second line for a few seconds, never the drawer — HUD0 B3; the menu-bar title when the HUD
/// is hidden or the app is in front), or a **notification** (macOS; the permission is asked once, the first time one is needed;
/// refused or unavailable → the HUD). Each kind has its throttle; each delivery files `ui.alert · <kind> · <how>`.
@MainActor
final class Alerts {
    static let shared = Alerts()
    private var throttle = HUDRules.AlertThrottle()
    private var asked = false
    private var menuBarTask: Task<Void, Never>?

    /// A real app bundle (the installed app), not the debug binary or a render: only there can macOS deliver a notification.
    private var canNotify: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil && ProcessInfo.processInfo.environment["DBOT_SNAPSHOT"] == nil
    }

    @discardableResult
    func fire(_ kind: HUDRules.AlertKind, _ text: String, key: String = "", seconds: Double = 6) -> HUDRules.AlertRoute {
        guard let store = Store.current else { return .off }
        let route = HUDRules.route(kind, settings: store.settings.alerts)
        guard route != .off, throttle.allow(kind, key: key, now: Date()) else { return .off }
        showInHUD(text, seconds: seconds)                    // every route but off says it on the HUD (or the menu bar)
        if route == .notify, canNotify { notify(kind, text); return .notify }
        log(kind, MiniPanel.shared.visible ? "shown" : "menu bar")
        return .hud
    }

    /// The pill's second line; when the HUD is hidden or the app is in front, the menu-bar title for the same time.
    private func showInHUD(_ text: String, seconds: Double) {
        if MiniPanel.shared.visible { MiniPanel.shared.attention(text, seconds: seconds); return }
        Store.current?.menuBarAlert = text
        menuBarTask?.cancel()
        menuBarTask = Task { try? await Task.sleep(for: .seconds(seconds)); if !Task.isCancelled { Store.current?.menuBarAlert = nil } }
    }

    /// Asks once (macOS shows its own prompt); later calls only read the answer.
    func prepare() {
        guard canNotify, !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in Log.write("notifications \(ok ? "allowed" : "refused")") }
        }
    }

    private func notify(_ kind: HUDRules.AlertKind, _ text: String) {
        prepare()
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { st in
            let allowed = st.authorizationStatus == .authorized || st.authorizationStatus == .provisional
            Task { @MainActor in
                guard allowed else { self.log(kind, "refused → hud"); return }
                let c = UNMutableNotificationContent()
                c.title = "Distraction Bot"; c.body = text
                if kind == .breakOver { c.sound = .default }
                center.add(UNNotificationRequest(identifier: "dbot.\(kind.rawValue).\(UUID().uuidString)", content: c, trigger: nil))
                self.log(kind, "notified")
            }
        }
    }

    private func log(_ kind: HUDRules.AlertKind, _ how: String) { EventLog.shared.ui("alert", "\(kind.rawValue) · \(how)") }
}
