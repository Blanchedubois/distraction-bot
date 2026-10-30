import Foundation

/// R1 (PLAN_REWORK §3.2, D3): how long the calendar loop waits after a failed fetch. Pure, so `scripts/ics-check.swift` judges it.
/// The first failure waits the refresh interval (15 min at least), each further failure doubles it, capped at 2 h; a `Retry-After`
/// header (seconds, or an HTTP date) is honoured when it asks for longer. A manual "fetch now" ignores the wait.
enum FeedBackoff {
    static let floor: TimeInterval = 15 * 60
    static let cap: TimeInterval = 2 * 3600

    static func wait(failures: Int, intervalMinutes: Int, retryAfter: String?, now: Date = Date()) -> TimeInterval {
        let base = max(floor, TimeInterval(intervalMinutes) * 60)
        let doubled = min(cap, base * pow(2, Double(max(0, failures - 1))))
        if let asked = retryAfterSeconds(retryAfter, now: now) { return max(doubled, min(cap, asked)) }
        return doubled
    }

    /// `Retry-After: 120` → 120 s; `Retry-After: Wed, 29 Oct 2026 05:00:00 GMT` → the seconds until then; anything else → nil.
    static func retryAfterSeconds(_ header: String?, now: Date) -> TimeInterval? {
        guard let h = header?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if let s = TimeInterval(h) { return max(0, s) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = f.date(from: h) { return max(0, d.timeIntervalSince(now)) }
        return nil
    }
}
