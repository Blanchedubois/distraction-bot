import CoreGraphics
import Foundation

/// X4 (PLAN_CATCHER §3.5): seconds since the last keyboard, mouse or trackpad event anywhere in the login session.
/// `AppWatcher.poll` reads it each second while a session is on; the maths lives in `AwayTracker` so the check script can fake it.
enum Idle {
    static var seconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
