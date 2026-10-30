import Foundation

/// Your calendar (PLAN_WEEK_CALENDAR §3.6): one ICS feed fetched on a timer, cached on disk, parsed by `ICSParser`.
/// The only thing that leaves the Mac is this GET. Failures stay quiet: the cache stands, `lastError` is shown in Settings.
@MainActor
@Observable
final class ICSFeed {
    private(set) var calendar = ICSCalendar()
    private(set) var fetchedAt: Date?          // when the cached text was last received (or confirmed by a 304)
    private(set) var lastTried: Date?
    private(set) var lastError: String?
    /// R1 (PLAN_REWORK §3.2, D3): failures in a row and the instant before which the loop must not try again.
    private(set) var failures = 0
    private(set) var nextTryAt: Date?
    private(set) var etag: String?
    private(set) var fetching = false
    var eventCount: Int { calendar.events.count }
    var name: String? { calendar.name }

    static let cacheURL = Store.supportDir.appendingPathComponent("calendar.ics")
    static let metaURL = Store.supportDir.appendingPathComponent("calendar.json")
    static let maxBytes = 5 * 1024 * 1024
    static let timeout: TimeInterval = 20

    private struct Meta: Codable { var etag: String?; var fetchedAt: Date?; var url: String }

    /// Read the cache so the grid is never empty while offline; dropped if it was written for another URL.
    func loadCache(for url: String) {
        guard let d = try? Data(contentsOf: Self.metaURL), let m = try? JSONDecoder().decode(Meta.self, from: d), m.url == url,
              let text = try? String(contentsOf: Self.cacheURL, encoding: .utf8) else { return }
        calendar = ICSParser.parse(text); etag = m.etag; fetchedAt = m.fetchedAt
    }

    /// `DBOT_SNAPSHOT_ICS=path.ics`: a render reads a fixture instead of the cache and never fetches (W4).
    private(set) var fixture = false
    func loadFixture(path: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        calendar = ICSParser.parse(text); fetchedAt = Date(); fixture = true
    }

    /// Forget the feed: the two files this feature wrote, and nothing else.
    func clear() {
        calendar = ICSCalendar(); etag = nil; fetchedAt = nil; lastTried = nil; lastError = nil; failures = 0; nextTryAt = nil
        try? FileManager.default.removeItem(at: Self.cacheURL)
        try? FileManager.default.removeItem(at: Self.metaURL)
    }

    /// Is the cache older than the interval (or never fetched), was the last try long enough ago, and is the backoff over (R1)?
    func isStale(interval minutes: Int, now: Date = Date()) -> Bool {
        let age = fetchedAt.map { now.timeIntervalSince($0) } ?? .infinity
        let sinceTry = lastTried.map { now.timeIntervalSince($0) } ?? .infinity
        if let n = nextTryAt, now < n { return false }
        return age > Double(minutes) * 60 && sinceTry > 60
    }
    /// A failure sets the next try: `FeedBackoff.wait` from the failure count, the interval and a `Retry-After` (seconds or an HTTP date).
    private func failed(retryAfter: String?, interval: Int, now: Date = Date()) {
        failures += 1
        nextTryAt = now.addingTimeInterval(FeedBackoff.wait(failures: failures, intervalMinutes: interval, retryAfter: retryAfter, now: now))
    }

    /// One GET. `webcal://` is rewritten to https; redirects follow; an ETag or Last-Modified is sent back; 304 keeps the cache.
    /// Returns the error text (nil on success) so a manual "fetch now" can toast it; a scheduled refresh never does.
    @discardableResult
    func refresh(url rawURL: String, interval: Int = 30) async -> String? {
        let text = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !fetching else { return nil }
        var s = text
        if s.lowercased().hasPrefix("webcal://") { s = "https://" + s.dropFirst("webcal://".count) }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            lastTried = Date(); lastError = "not a web address"; return lastError
        }
        fetching = true; defer { fetching = false }
        lastTried = Date()
        var req = URLRequest(url: url, timeoutInterval: Self.timeout)
        req.setValue("DistractionBot/1", forHTTPHeaderField: "User-Agent")
        if let etag { req.setValue(etag, forHTTPHeaderField: etag.hasPrefix("\"") || etag.hasPrefix("W/") ? "If-None-Match" : "If-Modified-Since") }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            if http?.statusCode == 304 { fetchedAt = Date(); lastError = nil; failures = 0; nextTryAt = nil; saveMeta(url: text); return nil }
            if let code = http?.statusCode, code >= 400 {
                lastError = code == 429 ? "rate-limited (HTTP 429)" : "HTTP \(code)"; failed(retryAfter: http?.value(forHTTPHeaderField: "Retry-After"), interval: interval)
                Log.write("calendar fetch failed: HTTP \(code) · next try \(nextTryAt.map { clock($0) } ?? "-")"); return lastError
            }
            guard data.count <= Self.maxBytes else { lastError = "feed too large"; failed(retryAfter: nil, interval: interval); return lastError }
            guard let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1), body.contains("BEGIN:VCALENDAR") else {
                lastError = "not an iCalendar file"; failed(retryAfter: nil, interval: interval); Log.write("calendar fetch: not an iCalendar file"); return lastError
            }
            calendar = ICSParser.parse(body)
            etag = http?.value(forHTTPHeaderField: "ETag") ?? http?.value(forHTTPHeaderField: "Last-Modified")
            fetchedAt = Date(); lastError = nil; failures = 0; nextTryAt = nil
            try? body.write(to: Self.cacheURL, atomically: true, encoding: .utf8)
            saveMeta(url: text)
            Log.write("calendar fetched: \(calendar.events.count) events")
            return nil
        } catch {
            lastError = (error as? URLError).map { $0.code == .notConnectedToInternet ? "offline" : $0.code == .timedOut ? "timed out" : $0.localizedDescription } ?? error.localizedDescription
            failed(retryAfter: nil, interval: interval)
            Log.write("calendar fetch failed: \(lastError ?? "") · next try \(nextTryAt.map { clock($0) } ?? "-")")
            return lastError
        }
    }

    private func saveMeta(url: String) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? e.encode(Meta(etag: etag, fetchedAt: fetchedAt, url: url)).write(to: Self.metaURL, options: .atomic)
    }

    /// The occurrences in a window, for the grid (W4).
    func instances(from: Date, to: Date) -> [ICSInstance] { ICSParser.instances(of: calendar, from: from, to: to) }

    /// The Settings status line: "google · 34 events · fetched 12 min ago", "fetched 2 h ago · last try failed: HTTP 404", "not fetched yet".
    func status(now: Date = Date()) -> (text: String, warning: Bool) {
        func ago(_ d: Date) -> String {
            let s = max(0, now.timeIntervalSince(d))
            if s < 60 { return "just now" }; if s < 3600 { return "\(Int(s / 60)) min ago" }; if s < 86400 { return "\(Int(s / 3600)) h ago" }; return "\(Int(s / 86400)) d ago"
        }
        var parts: [String] = []
        if let n = name, !n.isEmpty { parts.append(n) }
        if let f = fetchedAt { parts.append("\(eventCount) event\(eventCount == 1 ? "" : "s")"); parts.append("fetched \(ago(f))") }
        if fetching { parts.append("fetching…") }
        if let e = lastError {
            parts.append("last try failed: \(e)")
            if let n = nextTryAt, n > now { parts.append("next try \(clock(n))") }   // R1: the backoff, said
            return (parts.joined(separator: " · "), true)
        }
        if fetchedAt == nil, !fetching { parts.append("not fetched yet") }
        return (parts.joined(separator: " · "), false)
    }
}
