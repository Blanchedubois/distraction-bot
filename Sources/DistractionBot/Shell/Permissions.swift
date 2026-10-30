import AppKit
import ApplicationServices
import CoreGraphics

/// The permissions the watchers need (§2.2): Accessibility (browser URLs, ⌘W to Dia),
/// Screen Recording (window titles, the occasional look), Automation for Safari (asked on first use, B2).
enum Permissions {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// macOS shows its own "Distraction Bot would like to control this computer" sheet.
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    /// Shows the Screen Recording sheet once; after a denial only the settings pane can change it.
    @discardableResult
    static func promptForScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    static func openAutomationSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
    }
}
