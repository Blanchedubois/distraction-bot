import Foundation

/// X1 (PLAN_CATCHER §3.2): what kind of thing an app or host is, so the catcher judges behaviour, not identity.
/// utility · communication are budgeted (never judged on dwell); entertainment · tool · unknown are judged as before.
/// This file has no AppKit and no Store, so `scripts/catcher-check.swift` compiles it on its own.
enum AppClass: String, Codable, CaseIterable {
    case utility, communication, entertainment, tool, unknown
}

enum Classifier {
    /// The user's own classes (`Rules.classes`), mirrored here by the Store so the watchers need no store; they win over the table.
    nonisolated(unsafe) static var learned: [String: AppClass] = [:]

    /// bundle id → class
    static let apps: [String: AppClass] = [
        // utility: used briefly on the way somewhere
        "com.spotify.client": .utility, "com.apple.Music": .utility, "com.sunsama.app": .utility, "com.todoist.mac.Todoist": .utility,
        "com.culturedcode.ThingsMac": .utility, "com.apple.iCal": .utility, "com.apple.finder": .utility, "com.apple.systempreferences": .utility,
        "com.apple.SystemPreferences": .utility, "com.1password.1password": .utility, "com.agilebits.onepassword7": .utility, "com.apple.reminders": .utility,
        "com.apple.ActivityMonitor": .utility, "com.apple.AppStore": .utility, "com.apple.Passwords": .utility, "com.apple.weather": .utility,
        "com.apple.clock": .utility, "com.apple.calculator": .utility, "com.apple.Dictionary": .utility, "com.apple.Photos": .utility,
        "com.raycast.macos": .utility, "com.runningwithcrayons.Alfred": .utility, "com.apple.Spotlight": .utility, "com.tejasvin.distraction-bot": .utility,
        // communication
        "com.hnc.Discord": .communication, "com.apple.MobileSMS": .communication, "com.tinyspeck.slackmacgap": .communication, "com.apple.mail": .communication,
        "ru.keepcoder.Telegram": .communication, "net.whatsapp.WhatsApp": .communication, "com.apple.FaceTime": .communication, "us.zoom.xos": .communication,
        "com.microsoft.teams2": .communication, "com.microsoft.teams": .communication, "com.microsoft.Outlook": .communication, "com.google.Chrome.app.gmail": .communication,
        "com.readdle.smartemail-Mac": .communication, "com.facebook.archon": .communication, "com.skype.skype": .communication, "org.signal.Signal": .communication,
        // entertainment
        "com.valvesoftware.steam": .entertainment, "com.epicgames.EpicGamesLauncher": .entertainment, "com.netflix.Netflix": .entertainment, "com.apple.TV": .entertainment,
        "com.apple.Chess": .entertainment, "com.apple.Arcade": .entertainment, "com.blizzard.battle.net": .entertainment, "com.riotgames.RiotClient": .entertainment,
        "com.gog.galaxy": .entertainment, "com.apple.podcasts": .entertainment, "tv.plex.desktop": .entertainment, "com.supergiantgames.hades": .entertainment,
        "com.apple.Books": .tool,
        // tool: where the work happens
        "com.microsoft.VSCode": .tool, "com.apple.dt.Xcode": .tool, "com.apple.Terminal": .tool, "com.googlecode.iterm2": .tool, "com.mitchellh.ghostty": .tool,
        "com.overleaf.app": .tool, "com.apple.iWork.Keynote": .tool, "com.apple.iWork.Pages": .tool, "com.apple.iWork.Numbers": .tool, "com.figma.Desktop": .tool,
        "com.anthropic.claudefordesktop": .tool, "com.apple.Preview": .tool, "com.apple.Notes": .tool, "com.mathworks.matlab": .tool, "org.tug.TeXShop": .tool,
        "org.texstudio.TeXstudio": .tool, "com.microsoft.Word": .tool, "com.microsoft.Excel": .tool, "com.microsoft.Powerpoint": .tool, "com.adobe.Acrobat.Pro": .tool,
        "com.jetbrains.intellij": .tool, "com.jetbrains.pycharm": .tool, "org.jupyter.JupyterLab": .tool, "com.sublimetext.4": .tool, "md.obsidian": .tool,
        "notion.id": .tool, "com.openai.chat": .tool, "com.apple.freeform": .tool, "com.apple.TextEdit": .tool, "com.github.GitHubClient": .tool, "com.postmanlabs.mac": .tool,
        "com.wolfram.Mathematica": .tool, "org.rstudio.RStudio": .tool, "com.zotero.zotero": .tool, "net.sourceforge.skim-app.skim": .tool, "com.readdle.PDFExpert-Mac": .tool,
    ]
    /// app name (lower-cased) → class, for apps whose bundle id is not in the table (helpers, games, oddly bundled apps)
    static let names: [String: AppClass] = [
        "spotify": .utility, "music": .utility, "sunsama": .utility, "todoist": .utility, "things": .utility, "calendar": .utility, "finder": .utility,
        "system settings": .utility, "system preferences": .utility, "1password": .utility, "discord": .communication, "messages": .communication,
        "slack": .communication, "mail": .communication, "telegram": .communication, "whatsapp": .communication, "facetime": .communication, "zoom": .communication,
        "zoom.us": .communication, "microsoft teams": .communication, "steam": .entertainment, "steam helper": .entertainment, "epic games launcher": .entertainment,
        "netflix": .entertainment, "tv": .entertainment, "chess": .entertainment, "hades": .entertainment, "minecraft": .entertainment, "league of legends": .entertainment,
        "code": .tool, "visual studio code": .tool, "xcode": .tool, "terminal": .tool, "iterm2": .tool, "overleaf": .tool, "keynote": .tool, "pages": .tool,
        "numbers": .tool, "figma": .tool, "claude": .tool, "preview": .tool, "notes": .tool, "matlab": .tool, "texshop": .tool, "texstudio": .tool, "books": .tool,
        "obsidian": .tool, "notion": .tool, "chatgpt": .tool, "jupyterlab": .tool, "zotero": .tool, "skim": .tool,
    ]
    /// host suffix → class; the longest matching suffix wins (`mail.google.com` before `google.com`)
    static let hosts: [String: AppClass] = [
        // entertainment
        "youtube.com": .entertainment, "youtu.be": .entertainment, "netflix.com": .entertainment, "twitch.tv": .entertainment, "reddit.com": .entertainment,
        "x.com": .entertainment, "twitter.com": .entertainment, "instagram.com": .entertainment, "tiktok.com": .entertainment, "facebook.com": .entertainment,
        "9gag.com": .entertainment, "imgur.com": .entertainment, "hulu.com": .entertainment, "disneyplus.com": .entertainment, "primevideo.com": .entertainment,
        "max.com": .entertainment, "crunchyroll.com": .entertainment, "store.steampowered.com": .entertainment, "steamcommunity.com": .entertainment,
        "epicgames.com": .entertainment, "amazon.com": .entertainment, "ebay.com": .entertainment, "etsy.com": .entertainment, "pinterest.com": .entertainment,
        "tumblr.com": .entertainment, "snapchat.com": .entertainment, "threads.net": .entertainment, "bsky.app": .entertainment, "nytimes.com": .entertainment,
        "cnn.com": .entertainment, "bbc.com": .entertainment, "bbc.co.uk": .entertainment, "theguardian.com": .entertainment, "espn.com": .entertainment,
        "news.ycombinator.com": .entertainment, "buzzfeed.com": .entertainment, "dailymail.co.uk": .entertainment, "vimeo.com": .entertainment,
        "soundcloud.com": .entertainment, "open.spotify.com": .utility, "music.apple.com": .utility, "roblox.com": .entertainment, "chess.com": .entertainment,
        "lichess.org": .entertainment, "fallingfigures.io": .entertainment, "ign.com": .entertainment, "kotaku.com": .entertainment, "polygon.com": .entertainment,
        // communication
        "mail.google.com": .communication, "gmail.com": .communication, "outlook.live.com": .communication, "outlook.office.com": .communication,
        "mail.yahoo.com": .communication, "mail.proton.me": .communication, "slack.com": .communication, "discord.com": .communication,
        "web.whatsapp.com": .communication, "messenger.com": .communication, "teams.microsoft.com": .communication, "web.telegram.org": .communication,
        "meet.google.com": .communication, "zoom.us": .communication, "linkedin.com": .communication,
        // tool
        "github.com": .tool, "gitlab.com": .tool, "overleaf.com": .tool, "docs.google.com": .tool, "drive.google.com": .tool, "sheets.google.com": .tool,
        "slides.google.com": .tool, "colab.research.google.com": .tool, "instructure.com": .tool,
        "stackexchange.com": .tool, "stackoverflow.com": .tool, "mathoverflow.net": .tool, "wikipedia.org": .tool, "arxiv.org": .tool, "scholar.google.com": .tool,
        "pubmed.ncbi.nlm.nih.gov": .tool, "ncbi.nlm.nih.gov": .tool, "sciencedirect.com": .tool, "nature.com": .tool, "springer.com": .tool, "link.springer.com": .tool,
        "wiley.com": .tool, "jstor.org": .tool, "ieee.org": .tool, "acm.org": .tool, "aps.org": .tool, "claude.ai": .tool, "chatgpt.com": .tool, "chat.openai.com": .tool,
        "gemini.google.com": .tool, "perplexity.ai": .tool, "notion.so": .tool, "obsidian.md": .tool, "figma.com": .tool, "miro.com": .tool, "desmos.com": .tool,
        "wolframalpha.com": .tool, "geogebra.org": .tool, "numpy.org": .tool, "docs.python.org": .tool, "pytorch.org": .tool, "developer.apple.com": .tool,
        "developer.mozilla.org": .tool, "readthedocs.io": .tool, "kaggle.com": .tool, "huggingface.co": .tool, "gradescope.com": .tool, "piazza.com": .tool,
        "edstem.org": .tool, "zybooks.com": .tool, "pearson.com": .tool, "mheducation.com": .tool, "webassign.net": .tool, "coursera.org": .tool, "edx.org": .tool,
        "khanacademy.org": .tool, "mit.edu": .tool, "ocw.mit.edu": .tool, "quizlet.com": .tool, "anki.net": .tool, "ankiweb.net": .tool, "zotero.org": .tool,
        "mendeley.com": .tool, "grammarly.com": .tool, "deepl.com": .tool, "translate.google.com": .tool, "learn.microsoft.com": .tool, "localhost": .tool,
        // utility
        "google.com": .utility, "duckduckgo.com": .utility, "bing.com": .utility, "kagi.com": .utility, "maps.google.com": .utility, "calendar.google.com": .utility,
        "sunsama.com": .utility, "app.sunsama.com": .utility, "todoist.com": .utility, "spotify.com": .utility, "apple.com": .utility, "icloud.com": .utility,
        "1password.com": .utility, "weather.com": .utility, "accounts.google.com": .utility, "login.microsoftonline.com": .utility, "dropbox.com": .utility,
        "start-page": .utility,
    ]

    /// The class of an app: the user's own class first, then the bundle table, then the name table, else `.unknown`.
    static func classOf(app bundle: String, name: String) -> AppClass {
        if let c = learned[bundle] { return c }
        if let c = apps[bundle] { return c }
        if let c = names[name.lowercased()] { return c }
        return .unknown
    }
    /// The class of a host: the user's own class first (by any suffix), then the longest table suffix, else `.unknown`.
    static func classOf(host: String) -> AppClass {
        let h = host.lowercased().replacingOccurrences(of: "www.", with: "")
        func match(_ table: [String: AppClass]) -> AppClass? {
            table.filter { h == $0.key || h.hasSuffix("." + $0.key) }.max { $0.key.count < $1.key.count }?.value
        }
        if let c = match(learned) { return c }
        if let c = match(hosts) { return c }
        if h.hasSuffix(".edu") || h.hasSuffix(".ac.uk") { return .tool }
        return .unknown
    }
    /// Whether a class is judged on dwell at all (utility and communication are budgeted only).
    static func judgedOnDwell(_ c: AppClass) -> Bool { c != .utility && c != .communication }
}
