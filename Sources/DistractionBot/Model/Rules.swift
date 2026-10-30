import Foundation

/// What happens when a listed app launches or comes to front during a session (§3.2),
/// or a listed site is opened (§3.3).
enum Strength: String, Codable, CaseIterable, Identifiable {
    case allowed, warn, shield, close
    /// Sites only (§5a Q18): the page's title and URL go to the judge with the goal; a lecture passes, a keyboard review does not.
    case judge
    var id: String { rawValue }
    var label: String { rawValue }
}

/// The rules you set: apps, sites, search terms, allowed sites. Saved as settings.json (§3.7).
struct Rules: Codable {
    var apps: [String: Strength] = Rules.starterApps
    var sites: [String: Strength] = Rules.starterSites        // "block" is spelled .close for a site
    var searchTerms: [String] = []
    var allowedSites: [String] = []
    /// X1 (PLAN_CATCHER §3.2): the user's own classes, bundle id or host → class; they win over the Classifier's table.
    var classes: [String: AppClass] = [:]
    /// X6a (§3.7): what "always" taught and when (host or bundle id → date), shown on the Rules tab with `forget`.
    var taught: [String: Date] = [:]

    /// §5a Q4
    static let starterApps: [String: Strength] = [
        "com.valvesoftware.steam": .close,
        "ru.keepcoder.Telegram": .close, "net.whatsapp.WhatsApp": .close,
    ]
    static let starterSites: [String: Strength] = ["youtube.com": .judge, "reddit.com": .judge, "x.com": .warn, "instagram.com": .warn, "tiktok.com": .warn, "netflix.com": .warn, "twitch.tv": .warn]

    /// Never blocked, not configurable (§3.2): the system and this app.
    static let alwaysAllowed: Set<String> = ["com.apple.finder", "com.apple.systempreferences", "com.tejasvin.distraction-bot"]
    /// PLAN_PUBLIC_RELEASE §5a Q7: pinned apps are never blocked, only budgeted (X1 §5a Q1); Discord is pinned by default and can be unpinned.
    static let starterPinned = ["com.hnc.Discord"]
    var pinned: [String] = Rules.starterPinned
    /// The names the judge is told are allowed: `com.hnc.Discord` → `Discord`.
    var pinnedNames: [String] { pinned.compactMap { $0.split(separator: ".").last.map(String.init) } }
    func isPinned(_ bundleID: String) -> Bool { pinned.contains(bundleID) }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apps = try c.decodeIfPresent([String: Strength].self, forKey: .apps) ?? Rules.starterApps
        sites = try c.decodeIfPresent([String: Strength].self, forKey: .sites) ?? Rules.starterSites
        searchTerms = try c.decodeIfPresent([String].self, forKey: .searchTerms) ?? []
        allowedSites = try c.decodeIfPresent([String].self, forKey: .allowedSites) ?? []
        classes = (try? c.decodeIfPresent([String: AppClass].self, forKey: .classes)) ?? [:]   // X1
        taught = (try? c.decodeIfPresent([String: Date].self, forKey: .taught)) ?? [:]          // X6a
        pinned = (try? c.decodeIfPresent([String].self, forKey: .pinned)) ?? Rules.starterPinned   // settings saved before pins keep Discord
    }

    /// §5a Q19: an app with no rule is judged; an explicit "allowed" is never judged.
    func strength(for bundleID: String) -> Strength {
        if Rules.alwaysAllowed.contains(bundleID) || isPinned(bundleID) { return .allowed }
        return apps[bundleID] ?? .judge
    }
    /// Apps whose window titles and contents are never read or captured (§3.4, §5a Q10). Blocking still applies.
    static let privateApps = ["Messages", "Mail", "WhatsApp", "Telegram", "Discord", "1Password"]

    /// Host matching: `youtube.com` matches `m.youtube.com`; the allow list wins.
    static func matches(_ host: String, _ rule: String) -> Bool { host == rule || host.hasSuffix("." + rule) }
    func isAllowedSite(_ host: String) -> Bool { allowedSites.contains { Rules.matches(host, $0) } }
    func siteRule(for host: String) -> (rule: String, strength: Strength)? {
        if isAllowedSite(host) { return nil }
        return sites.first { Rules.matches(host, $0.key) }.map { ($0.key, $0.value) }
    }
    func searchTermHit(_ query: String) -> String? {
        let q = query.lowercased()
        return searchTerms.first { !$0.isEmpty && q.contains($0.lowercased()) }
    }

    /// `DBOT_RULES_PATH`: a render reads (and writes) a scratch copy instead (PLAN_PUBLIC_RELEASE P2).
    static let url = ProcessInfo.processInfo.environment["DBOT_RULES_PATH"].map { URL(fileURLWithPath: $0) } ?? Store.supportDir.appendingPathComponent("settings.json")
    static func load() -> Rules {
        guard let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(Rules.self, from: d) else { return Rules() }
        return r
    }
    func save() {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(self).write(to: Rules.url, options: .atomic)
    }
}
