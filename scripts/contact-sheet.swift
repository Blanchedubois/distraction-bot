// PLAN_DESIGN_CLEANUP G6: one sheet per appearance — a row per tab: the G0 baseline (1080) · the G6 render at 1080 · at 760.
// swiftc -O scripts/contact-sheet.swift -o /tmp/sheet && /tmp/sheet light docs/shots/design-g6-contact-light.png
import AppKit
let appearance = CommandLine.arguments[1], out = CommandLine.arguments[2]
let tabs = ["home", "subjects", "progress", "calendar", "history", "settings", "apps", "websites", "screen", "judge", "log"]
let cellW: CGFloat = 540, cellH: CGFloat = 400, pad: CGFloat = 24, labelH: CGFloat = 28
let cols = 3
let sheet = NSImage(size: NSSize(width: pad + CGFloat(cols) * (cellW + pad), height: pad + CGFloat(tabs.count) * (cellH + labelH + pad)))
sheet.lockFocus()
NSColor(white: appearance == "dark" ? 0.09 : 0.96, alpha: 1).setFill(); NSRect(origin: .zero, size: sheet.size).fill()
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: appearance == "dark" ? NSColor.white : NSColor.black]
func draw(_ path: String, at origin: NSPoint, label: String) {
    NSAttributedString(string: label, attributes: attrs).draw(at: NSPoint(x: origin.x, y: origin.y + cellH + 6))
    guard let img = NSImage(contentsOfFile: path) else { NSAttributedString(string: "(no shot)", attributes: attrs).draw(at: NSPoint(x: origin.x + 8, y: origin.y + cellH / 2)); return }
    let scale = cellW / img.size.width
    let h = min(cellH, img.size.height * scale)
    // top of the page: crop the top cellH/scale points of the image
    let srcH = h / scale
    let src = NSRect(x: 0, y: img.size.height - srcH, width: img.size.width, height: srcH)
    img.draw(in: NSRect(x: origin.x, y: origin.y + cellH - h, width: cellW, height: h), from: src, operation: .sourceOver, fraction: 1)
    NSColor.gray.withAlphaComponent(0.5).setStroke(); NSBezierPath(rect: NSRect(x: origin.x, y: origin.y, width: cellW, height: cellH)).stroke()
}
for (i, tab) in tabs.enumerated() {
    let y = sheet.size.height - pad - CGFloat(i + 1) * (cellH + labelH + pad) + pad
    let before = ["screen", "log"].contains(tab) ? "" : "docs/shots/design-g0-before-\(tab)-\(appearance).png"
    draw(before, at: NSPoint(x: pad, y: y), label: "\(tab) · before (G0 baseline, 1080)")
    draw("docs/shots/design-g6-\(tab)-1080-\(appearance).png", at: NSPoint(x: pad * 2 + cellW, y: y), label: "\(tab) · G6 · 1080")
    draw("docs/shots/design-g6-\(tab)-760-\(appearance).png", at: NSPoint(x: pad * 3 + cellW * 2, y: y), label: "\(tab) · G6 · 760")
}
sheet.unlockFocus()
let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote", out, Int(sheet.size.width), "x", Int(sheet.size.height))
