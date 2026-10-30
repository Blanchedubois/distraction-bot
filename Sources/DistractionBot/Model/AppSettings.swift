import Foundation

/// Behaviour settings (B5): sounds, launch at login, defaults, the schedule. Saved as prefs.json.
struct AppSettings: Codable {
    var soundOn = true
    var soundName = "Tink"            // Tink · Pop · Glass · Funk · Submarine
    var launchAtLogin = false
    var defaultMinutes = 50           // 0 = until I stop
    var defaultStrictness: Strictness = .normal
    /// P2 (PLAN_PLANNING §3.3, Q4.6): the schedule window is no longer offered or run — planned sessions come from the calendar.
    /// The type and key stay so an older prefs.json loads unchanged; `windowToday()` has no caller.
    struct Schedule: Codable {
        var enabled = false
        var start = "09:00"
        var end = "17:00"
        var days: [Int] = [2, 3, 4, 5, 6]     // Calendar weekday numbers: 1 = Sunday
        var goal = "the day's work"
    }
    var schedule = Schedule()
    /// Hard mode (B6): the only way to end a hard session early, quit the app, or pause.
    /// X6d (PLAN_CATCHER §3.10): set through `setPhrase(_:confirm:)` — 12 characters at least, typed twice; a shorter phrase set earlier keeps working until changed.
    var escapePhrase = "I am choosing to stop working"
    static let minPhrase = 12
    var phraseTooShort: Bool { escapePhrase.trimmingCharacters(in: .whitespaces).count < Self.minPhrase }
    /// nil = set; else the reason it was refused.
    mutating func setPhrase(_ p: String, confirm: String) -> String? {
        let t = p.trimmingCharacters(in: .whitespaces)
        if t.count < Self.minPhrase { return "\(Self.minPhrase) characters at least" }
        if t != confirm.trimmingCharacters(in: .whitespaces) { return "the two do not match" }
        escapePhrase = t; return nil
    }
    /// The phrase with its middle masked, for the escape card: `I am ch…orking`.
    static func masked(_ p: String) -> String { p.count <= 8 ? String(repeating: "•", count: p.count) : "\(p.prefix(7))…\(p.suffix(6))" }
    /// Progress tab (PLAN_STATS_TAB §5a Q4, Q6): the focused-time target per day, and whether test sessions are hidden.
    var dailyTargetMinutes = 240
    var weekendTargetMinutes = 0
    var hideTestSessions = true
    /// Your calendar (PLAN_WEEK_CALENDAR §3.6, §5a Q9–Q15): the ICS address pasted into Settings, how often it is fetched, its colour, whether it shows.
    var icsURL = ""
    var icsRefreshMinutes = 30
    var icsColor = "#8aa0d6"           // a family name or "#rrggbb", like a subject's
    var showFeed = true
    /// The mini panel during a session (PLAN_CURRENT_SESSION §3.7, C3): off means never.
    var miniPanel = true
    /// X4 (PLAN_CATCHER §3.5): idle this long pauses the session (10 min, extended while still idle); 0 = off. Away spans open at 5 min regardless.
    var autoPauseMinutes = 15
    /// E1 (PLAN_OVERLAY §3.2): the mini panel's corner and its dragged offset per display (`NSScreen.localizedName` → [x, y] points from the corner's anchor).
    var miniPanelCorner = "topRight"
    var miniPanelOffset: [String: [Double]] = [:]
    /// HUD0 B2 (PLAN_SESSION_HUD §2.3): the display the HUD lives on (`NSScreen.localizedName`), set by a drag; nil = the primary display.
    var miniPanelScreen: String? = nil
    /// HUD2 (PLAN_SESSION_HUD §5a Q17): ⌃⌥Space · ⌃⌥B system-wide while a session runs.
    var hotkeys = true
    /// HUD3 (PLAN_SESSION_HUD §3.3): `a break is due` after this many minutes of work without one (0 = never).
    var breakDueMinutes = 50
    /// HUD5 (PLAN_SESSION_HUD §3.5): each alert kind's route (`off` · `hud` · `notify`), missing = the kind's default; the accuracy line; the check-in interval (0 = off).
    var alerts: [String: String] = [:]
    var accuracyLine = 90
    var checkInMinutes = 0
    // K0 (PLAN_STUDY_DAY §3.1, §3.5, §3.8): the study day's start hour (0…6), the shutdown offer hour, the one reminder ("off" allowed), the UI usage log
    var dayStartHour = 4
    var shutdownOfferHour = 21
    var shutdownReminder = "23:30"
    var uiLog = true
    /// M2 (PLAN_STRUCTURE §3.3): the Calendar tab's last drawing, `week` or `day`.
    var calendarMode = "week"
    /// Z5: the first launch under the new score rules (the Progress line, 7 days). PLAN_GAME_LOOP G0: the `gamification` and `stakes`
    /// keys of the removed dial are ignored when an older prefs.json carries them.
    var scoreRulesSince: Date? = nil

    init() {}
    /// Missing keys keep their defaults, so an older prefs.json survives a new field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        soundOn = try c.decodeIfPresent(Bool.self, forKey: .soundOn) ?? soundOn
        soundName = try c.decodeIfPresent(String.self, forKey: .soundName) ?? soundName
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? launchAtLogin
        defaultMinutes = try c.decodeIfPresent(Int.self, forKey: .defaultMinutes) ?? defaultMinutes
        defaultStrictness = try c.decodeIfPresent(Strictness.self, forKey: .defaultStrictness) ?? defaultStrictness
        schedule = try c.decodeIfPresent(Schedule.self, forKey: .schedule) ?? schedule
        escapePhrase = try c.decodeIfPresent(String.self, forKey: .escapePhrase) ?? escapePhrase
        dailyTargetMinutes = try c.decodeIfPresent(Int.self, forKey: .dailyTargetMinutes) ?? dailyTargetMinutes
        weekendTargetMinutes = try c.decodeIfPresent(Int.self, forKey: .weekendTargetMinutes) ?? weekendTargetMinutes
        hideTestSessions = try c.decodeIfPresent(Bool.self, forKey: .hideTestSessions) ?? hideTestSessions
        icsURL = try c.decodeIfPresent(String.self, forKey: .icsURL) ?? icsURL
        icsRefreshMinutes = try c.decodeIfPresent(Int.self, forKey: .icsRefreshMinutes) ?? icsRefreshMinutes
        icsColor = try c.decodeIfPresent(String.self, forKey: .icsColor) ?? icsColor
        showFeed = try c.decodeIfPresent(Bool.self, forKey: .showFeed) ?? showFeed
        miniPanel = try c.decodeIfPresent(Bool.self, forKey: .miniPanel) ?? miniPanel
        autoPauseMinutes = try c.decodeIfPresent(Int.self, forKey: .autoPauseMinutes) ?? autoPauseMinutes   // X4
        miniPanelCorner = try c.decodeIfPresent(String.self, forKey: .miniPanelCorner) ?? miniPanelCorner          // E1
        miniPanelOffset = try c.decodeIfPresent([String: [Double]].self, forKey: .miniPanelOffset) ?? miniPanelOffset
        miniPanelScreen = try c.decodeIfPresent(String.self, forKey: .miniPanelScreen) ?? miniPanelScreen   // HUD0
        hotkeys = try c.decodeIfPresent(Bool.self, forKey: .hotkeys) ?? hotkeys   // HUD2
        breakDueMinutes = try c.decodeIfPresent(Int.self, forKey: .breakDueMinutes) ?? breakDueMinutes   // HUD3
        alerts = try c.decodeIfPresent([String: String].self, forKey: .alerts) ?? alerts                      // HUD5
        accuracyLine = try c.decodeIfPresent(Int.self, forKey: .accuracyLine) ?? accuracyLine
        checkInMinutes = try c.decodeIfPresent(Int.self, forKey: .checkInMinutes) ?? checkInMinutes
        dayStartHour = try c.decodeIfPresent(Int.self, forKey: .dayStartHour) ?? dayStartHour              // K0
        shutdownOfferHour = try c.decodeIfPresent(Int.self, forKey: .shutdownOfferHour) ?? shutdownOfferHour
        shutdownReminder = try c.decodeIfPresent(String.self, forKey: .shutdownReminder) ?? shutdownReminder
        uiLog = try c.decodeIfPresent(Bool.self, forKey: .uiLog) ?? uiLog
        calendarMode = try c.decodeIfPresent(String.self, forKey: .calendarMode) ?? calendarMode   // M2
        scoreRulesSince = try c.decodeIfPresent(Date.self, forKey: .scoreRulesSince) ?? scoreRulesSince
    }
    /// The focused-time target for a day, in minutes.
    func targetMinutes(on day: Date) -> Int {
        let w = Calendar.current.component(.weekday, from: day)
        return (w == 1 || w == 7) ? weekendTargetMinutes : dailyTargetMinutes
    }

    static let sounds = ["Tink", "Pop", "Glass", "Funk", "Submarine"]
    /// `DBOT_PREFS_PATH`: a render reads (and writes) a scratch copy instead (PLAN_PUBLIC_RELEASE P2).
    static let url = ProcessInfo.processInfo.environment["DBOT_PREFS_PATH"].map { URL(fileURLWithPath: $0) } ?? Store.supportDir.appendingPathComponent("prefs.json")
    static func load() -> AppSettings {
        guard let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(AppSettings.self, from: d) else { return AppSettings() }
        return s
    }
    func save() { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; try? e.encode(self).write(to: Self.url, options: .atomic) }

    /// The schedule's window today, if today is a scheduled day.
    func windowToday(now: Date = Date()) -> (start: Date, end: Date)? {
        guard schedule.enabled else { return nil }
        let cal = Calendar.current
        guard schedule.days.contains(cal.component(.weekday, from: now)) else { return nil }
        func at(_ hm: String) -> Date? { let p = hm.split(separator: ":").compactMap { Int($0) }; guard p.count == 2 else { return nil }; return cal.date(bySettingHour: p[0], minute: p[1], second: 0, of: now) }
        guard let s = at(schedule.start), let e = at(schedule.end), e > s else { return nil }
        return (s, e)
    }
}
