// Renders Distraction Bot's app icon in Ledger's house style (ledger-mac/scripts/icon.swift):
// the macOS rounded square, a diagonal gradient, a faint sheen on the top half,
// and ONE big SF Symbol as the watermark — rotated −13°, cropped by the square
// at the bottom-right, the way every card in Ledger wears it.
//
// Jeff 2 added Liquid Glass on top of that composition: the watermark is a pane
// of glass rather than flat white. Inside its shape the gradient behind is
// redrawn magnified and brightened (the refraction), a white body tint and a
// top-left specular sheet sit over it, an inner rim catches the light at its
// edges, and a soft shadow lifts it off the background. The square itself gets
// a glass rim: a hairline that is bright at the top and fades down.
//
// Usage: swift icon.swift <out.png> [symbol]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let symbol = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "shield.lefthalf.filled"
let size: CGFloat = 1024

// Distraction Bot: Ledger's peach→ember swapped for sage→deep green.
let top = CGColor(red: 0.45, green: 0.80, blue: 0.58, alpha: 1)      // light sage
let bottom = CGColor(red: 0.08, green: 0.33, blue: 0.20, alpha: 1)   // deep green
let space = CGColorSpaceCreateDeviceRGB()

// one explicit 1024-pixel RGBA canvas: an NSImage's lockFocus would pick up
// the Retina scale and draw at 2048
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// ── the square: Ledger's geometry exactly ────────────────────────────────────
let inset: CGFloat = size * 0.1
let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.height * 0.225, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.03, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.04, green: 0.10, blue: 0.06, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

let grad = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1])!
func background(in r: CGRect) {
    ctx.drawLinearGradient(grad, start: CGPoint(x: r.minX, y: r.maxY), end: CGPoint(x: r.maxX, y: r.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

ctx.saveGState()
ctx.addPath(path); ctx.clip()
background(in: rect)
// Ledger's sheen on the top half
ctx.setFillColor(CGColor(gray: 1, alpha: 0.06))
ctx.fill(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2))

// ── the watermark as a glass mask ────────────────────────────────────────────
// The symbol is rendered once into a full-canvas greyscale mask, already placed
// and rotated, so every glass layer below can clip to exactly the same shape.
let center = CGPoint(x: rect.maxX - rect.width * 0.36, y: rect.minY + rect.height * 0.38)
func symbolMask(dx: CGFloat = 0, dy: CGFloat = 0, inverted: Bool = false) -> CGImage {
    let w = Int(size), h = Int(size)
    // the symbol drawn into an RGBA bitmap (a symbol is vector art and will not
    // draw into a bare greyscale context) ...
    let rgba = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.70, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: rgba, flipped: false)
    rgba.translateBy(x: center.x + dx, y: center.y + dy)
    rgba.rotate(by: -13 * .pi / 180)
    let s = img.size
    img.draw(in: CGRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height))
    NSGraphicsContext.restoreGraphicsState()
    // ... then its alpha copied out as a greyscale mask: white = glass
    let src = rgba.data!.bindMemory(to: UInt8.self, capacity: rgba.bytesPerRow * h)
    let gray = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    let dst = gray.data!.bindMemory(to: UInt8.self, capacity: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let a = src[y * rgba.bytesPerRow + x * 4 + 3]
            dst[y * w + x] = inverted ? 255 - a : a
        }
    }
    return gray.makeImage()!
}
let canvas = CGRect(x: 0, y: 0, width: size, height: size)
let mask = symbolMask()
let maskInverted = symbolMask(inverted: true)

// a mask-shaped image of a single colour, for shadows and rims
func shape(from m: CGImage, color: CGColor) -> CGImage {
    let w = m.width, h = m.height
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.clip(to: CGRect(x: 0, y: 0, width: w, height: h), mask: m)
    c.setFillColor(color)
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return c.makeImage()!
}
// 1 · the lift: a soft shadow under the glass, falling down and right
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: size * 0.008, height: -size * 0.02), blur: size * 0.045, color: CGColor(red: 0.08, green: 0.02, blue: 0.28, alpha: 0.65))
ctx.draw(shape(from: mask, color: CGColor(red: 0.3, green: 0.2, blue: 0.7, alpha: 1)), in: canvas)
ctx.restoreGState()

// 2 · the refraction: inside the glass, the background magnified 1.18× about
// the pane's centre and nudged up-left, as a thick lens would bend it
ctx.saveGState()
ctx.clip(to: canvas, mask: mask)
ctx.translateBy(x: center.x - size * 0.05, y: center.y + size * 0.07)
ctx.scaleBy(x: 1.35, y: 1.35)
ctx.translateBy(x: -center.x, y: -center.y)
background(in: rect)
ctx.restoreGState()

// 3 · the body: a white tint, stronger at the top, so it reads as frosted glass
ctx.saveGState()
ctx.clip(to: canvas, mask: mask)
let body = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.42), CGColor(gray: 1, alpha: 0.14)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(body, start: CGPoint(x: center.x, y: rect.maxY), end: CGPoint(x: center.x, y: rect.minY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
// the specular sheet: a bright band from the top-left that falls away by the middle
let spec = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.55), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(spec, start: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.maxY), end: CGPoint(x: center.x + rect.width * 0.05, y: center.y - rect.height * 0.02), options: [])
ctx.restoreGState()

// 4 · the rim: light caught at the glass's edges — an inner glow made by the
// shadow of everything OUTSIDE the shape, seen only inside it. Bright from the
// top-left (where the light is), a darker refractive edge from the bottom-right.
ctx.saveGState()
ctx.clip(to: canvas, mask: mask)
ctx.setShadow(offset: CGSize(width: -size * 0.004, height: -size * 0.006), blur: size * 0.012, color: CGColor(gray: 1, alpha: 0.95))
ctx.draw(shape(from: maskInverted, color: CGColor(gray: 1, alpha: 1)), in: canvas.offsetBy(dx: size * 0.002, dy: size * 0.003))
ctx.restoreGState()
// the bottom-right edge: a thin violet line where the glass bends light away
ctx.saveGState()
ctx.clip(to: canvas, mask: mask)
ctx.setShadow(offset: CGSize(width: size * 0.004, height: size * 0.005), blur: size * 0.01, color: CGColor(red: 0.25, green: 0.10, blue: 0.60, alpha: 0.5))
ctx.draw(shape(from: maskInverted, color: CGColor(red: 0.62, green: 0.58, blue: 0.95, alpha: 1)), in: canvas.offsetBy(dx: -size * 0.0015, dy: -size * 0.002))
ctx.restoreGState()

ctx.restoreGState()   // the square's clip

// ── the square's glass rim: a hairline bright at the top, fading down ───────
ctx.saveGState()
ctx.addPath(path)
ctx.setLineWidth(size * 0.006)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rim = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.75), CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0.30)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
ctx.restoreGState()

guard let cg = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
