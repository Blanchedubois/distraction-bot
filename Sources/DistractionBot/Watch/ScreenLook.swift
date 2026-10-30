import AppKit
import CryptoKit
import ScreenCaptureKit
import Foundation

/// The occasional look (§3.4): every N minutes during a session, when the front window's text has not settled it
/// in the last N minutes, capture the front window (ScreenCaptureKit, in memory), shrink it to 1280 px wide, have the
/// vision model describe it in ≤25 words, and give that to the judge. Pixels never touch the disk; the private list is never captured.
/// X6c (PLAN_CATCHER §3.9): the skips return before the interval is consumed and log nothing; an identical capture (SHA256 of the JPEG) is a
/// `look.same` row and no vision call; a tool with a work verdict < 10 min old is skipped; an unknown app with no title is looked at after 90 s;
/// the capture covers the display the front window is on.
@MainActor
@Observable
final class ScreenLook {
    unowned let store: Store
    var intervalMinutes: Int = UserDefaults.standard.object(forKey: "dbot.lookMinutes") as? Int ?? 3 { didSet { UserDefaults.standard.set(intervalMinutes, forKey: "dbot.lookMinutes") } }
    var scope: String = UserDefaults.standard.string(forKey: "dbot.lookScope") ?? "front" { didSet { UserDefaults.standard.set(scope, forKey: "dbot.lookScope") } }
    var model: String = UserDefaults.standard.string(forKey: "dbot.visionModel") ?? Ollama.visionModel { didSet { UserDefaults.standard.set(model, forKey: "dbot.visionModel") } }
    private(set) var lastDescription: String?
    private(set) var lastAt: Date?
    private(set) var lastApp = ""
    private(set) var lastTiming = ""
    private(set) var looks = 0
    private var lastLookAt = Date.distantPast
    private var busy = false
    private var lastPixels = ""
    private var lastHash: [String: String] = [:]      // X6c: per app, the SHA256 of the last capture
    let client = OllamaClient()

    struct Timing { var capture = 0.0; var describe = 0.0; var judge = 0.0 }

    init(store: Store) { self.store = store }

    /// X6c: the interval for what is in front — 90 s for an unknown app with no title (the look is its only signal), else the setting.
    static let untitledSeconds: TimeInterval = 90
    func interval(for id: String, name: String, title: String) -> TimeInterval {
        if !BrowserReader.browsers.contains(id), title.isEmpty, Classifier.classOf(app: id, name: name) == .unknown { return Self.untitledSeconds }
        return Double(intervalMinutes) * 60
    }

    /// Called every second by the store while a session is on.
    func tick() {
        guard let s = store.session, !s.paused, !busy, let f = NSWorkspace.shared.frontmostApplication, let id = f.bundleIdentifier else { return }
        let due = interval(for: id, name: f.localizedName ?? id, title: AppWatcher.frontTitle(pid: f.processIdentifier))
        guard Date().timeIntervalSince(lastLookAt) >= due else { return }
        Task { await look(reason: "timer") }
    }

    /// nil: skipped, with the reason in the log. The skips before `lastLookAt` consume nothing (X6c).
    @discardableResult
    func look(reason: String) async -> String? {
        guard !busy, let front = NSWorkspace.shared.frontmostApplication, let id = front.bundleIdentifier else { return nil }
        if id == AppWatcher.ownBundle { return nil }      // wait for a real front window; the interval is not consumed
        let name = front.localizedName ?? id
        if Rules.privateApps.contains(name) { if reason != "timer" { Log.write("look skipped: \(name) is on the private list") }; return nil }
        if store.rules.strength(for: id) == .allowed { if reason != "timer" { Log.write("look skipped: \(name) is allowed") }; return nil }
        if reason == "timer", let t = store.lastJudgedAt[name], Date().timeIntervalSince(t) < Double(intervalMinutes) * 60 {
            return nil   // judged by text within the interval: the next tick asks again
        }
        // X6c: a tool with a work verdict less than 10 min old is where the work happens
        if reason == "timer", Classifier.classOf(app: id, name: name) == .tool, store.verdictWord(appId: id) == "work", let t = store.lastJudgedAt[name], Date().timeIntervalSince(t) < 600 { return nil }
        lastLookAt = Date()
        busy = true; defer { busy = false }
        var timing = Timing()
        let t0 = Date()
        guard let jpeg = await capture(pid: front.processIdentifier) else { Log.write("look: capture failed for \(name)"); return nil }
        timing.capture = Date().timeIntervalSince(t0)
        let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        if lastHash[name] == hash {   // X6c: the same pixels as last time — nothing to describe
            EventLog.shared.add("look.same", app: name, detail: "identical to the last look")
            Log.write("look (\(reason)) \(name): identical capture, no vision call"); store.reloadLog(); return nil
        }
        lastHash[name] = hash
        let image = jpeg.base64EncodedString()
        let t1 = Date()
        let description: String
        do {
            let prompt = "This is a screenshot of one window on a Mac. In at most 25 words say which app or site it is, what is shown, and quote any visible title exactly. No preamble."
            let (text, st) = try await client.chat(model: model, messages: [.init(role: "user", content: prompt, images: [image])], budget: 30, maxTokens: 80)
            description = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            Log.write("look: \(lastPixels) · prompt \(st.promptTokens) tok · load \(String(format: "%.1f", st.loadSeconds)) s · eval \(st.evalTokens) tok")
        } catch { Log.write("look: describe failed (\(error))"); return nil }
        timing.describe = Date().timeIntervalSince(t1)
        looks += 1
        lastDescription = description; lastAt = Date(); lastApp = name
        let title = AppWatcher.frontTitle(pid: front.processIdentifier)
        EventLog.shared.add("look", app: name, detail: description, latencyMs: Int((timing.capture + timing.describe) * 1000))
        // text first (§3.4): a verdict for this app in the last 30 s stands; the look only adds its description to the log
        if let t = store.lastJudgedAt[name], Date().timeIntervalSince(t) < 30 {
            lastTiming = String(format: "capture %.2f s · describe %.1f s · judged by text %d s ago", timing.capture, timing.describe, Int(Date().timeIntervalSince(t)))
            Log.write("look (\(reason)) \(name): \(lastTiming) → \"\(description.prefix(80))\""); store.reloadLog(); return description
        }
        let t2 = Date()
        await store.judge(front: name, kind: BrowserReader.browsers.contains(id) ? "web browser" : "app", title: title, url: store.webWatcher.current?.url, what: title.isEmpty ? name : "\(name) — \(title)", subject: .app(id), pid: front.processIdentifier, screen: description,
                          appClass: Classifier.classOf(app: id, name: name).rawValue)
        timing.judge = Date().timeIntervalSince(t2)
        lastTiming = String(format: "capture %.2f s · describe %.1f s · judge %.1f s", timing.capture, timing.describe, timing.judge)
        Log.write("look (\(reason)) \(name): \(lastTiming) → \"\(description.prefix(80))\"")
        store.reloadLog()
        return description
    }

    /// The front window of `pid` (or the display it is on when scope is "display"), 1280 px wide, as JPEG bytes. In memory only.
    private func capture(pid: pid_t) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        let config = SCStreamConfiguration()
        config.showsCursor = false
        let filter: SCContentFilter
        var size: CGSize
        let wins = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width > 200 }
        let win = wins.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        if scope == "display" {
            // X6c: the display the front window is on (its frame's centre), else the pointer's, else the first
            let centre = win.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
            let display = content.displays.first { d in centre.map { d.frame.contains($0) } ?? false }
                ?? content.displays.first(where: { NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == $0.displayID })
                ?? content.displays.first
            guard let display else { return nil }
            let me = content.applications.filter { $0.bundleIdentifier == AppWatcher.ownBundle }
            filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        } else {
            guard let w = win else { return nil }
            filter = SCContentFilter(desktopIndependentWindow: w)
            size = w.frame.size
        }
        let scale = min(1, 1280 / max(size.width, 1), 800 / max(size.height, 1))   // ≤1280×800: Jeff 2's sweet spot was ~1 MP
        config.width = Int(size.width * scale * 2); config.height = Int(size.height * scale * 2)   // Retina points → pixels, then halved below
        config.width = max(2, Int(Double(config.width) / 2)); config.height = max(2, Int(Double(config.height) / 2))
        guard let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        lastPixels = "\(cg.width)x\(cg.height) px (asked \(config.width)x\(config.height))"
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }

    /// X6c's check: the hash of a JPEG on disk, so the `look.same` rule is checked on a fixture file without a capture.
    static func hash(file: String) -> String? {
        guard let d = FileManager.default.contents(atPath: file) else { return nil }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// Quiet check: describe a PNG from disk (the CLI's `--describe`), measuring the vision step alone.
    static func describe(file: String, model: String) async -> (String, Double)? {
        guard let img = NSImage(contentsOfFile: file), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let scale = min(1, 1280 / max(rep.pixelsWide, 1).double, 800 / max(rep.pixelsHigh, 1).double)
        let w = Int(Double(rep.pixelsWide) * scale), h = Int(Double(rep.pixelsHigh) * scale)
        // an exact-pixel resize: NSImage.lockFocus would draw at the Retina scale and send 4× the image tokens
        guard let cg = rep.cgImage, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage(), let jpeg = NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return nil }
        let client = OllamaClient(); let t0 = Date()
        let prompt = "This is a screenshot of one window on a Mac. In at most 25 words say which app or site it is, what is shown, and quote any visible title exactly. No preamble."
        guard let (text, st) = try? await client.chat(model: model, messages: [.init(role: "user", content: prompt, images: [jpeg.base64EncodedString()])], budget: 120, maxTokens: 80) else { return nil }
        let note = String(format: " [%dx%d · load %.1f s · prompt %d tok · eval %d tok]", w, h, st.loadSeconds, st.promptTokens, st.evalTokens)
        return (text.trimmingCharacters(in: .whitespacesAndNewlines) + note, Date().timeIntervalSince(t0))
    }
}

private extension Int { var double: Double { Double(self) } }
