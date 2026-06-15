import AppKit

// Renders the Murmur disk-image background: title, a teal->indigo arrow pointing from
// where the app icon sits to the Applications folder, and the first-launch note (the
// app is not notarized, so the first open needs an explicit allow). Finder draws the
// real Murmur and Applications icons on top, at the positions set by scripts/release.sh.
//
// Output: Resources/dmg-background.png, a 2x image carrying its logical (point) size so
// it stays crisp on Retina. Run: swift design/dmg/make-background.swift

let W: CGFloat = 620, H: CGFloat = 420, SCALE: CGFloat = 2

func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1)
}
let teal = c(52, 231, 200), indigo = c(99, 102, 241)

// Pixels are W*SCALE; rep.size is the logical point size, which embeds the 2x density.
// The rep's graphics context already maps point space -> pixels, so we draw in points
// (0...W, 0...H) with NO extra scaling. Origin is bottom-left (AppKit default).
let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                           pixelsWide: Int(W * SCALE), pixelsHigh: Int(H * SCALE),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)

let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext

// Background: a soft, light cool gradient. Light keeps Finder's icon labels readable.
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [c(246, 248, 250).cgColor, c(234, 238, 243).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// One centered line. `y` is the text baseline-bottom (bottom-left origin).
func drawCentered(_ s: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let str = NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ])
    let sz = str.size()
    str.draw(at: NSPoint(x: (W - sz.width) / 2, y: y))
}

drawCentered("Install Murmur", y: H - 58, size: 22, weight: .semibold, color: c(26, 30, 36))
drawCentered("Drag Murmur onto the Applications folder", y: H - 88, size: 13, weight: .regular, color: c(91, 100, 114))

// Arrow from the app icon to Applications, centered in the gap between their positions.
let cx: CGFloat = 310, cy: CGFloat = 225
let a = CGMutablePath()
a.move(to: CGPoint(x: cx - 36, y: cy - 11))
a.addLine(to: CGPoint(x: cx + 8, y: cy - 11))
a.addLine(to: CGPoint(x: cx + 8, y: cy - 24))
a.addLine(to: CGPoint(x: cx + 36, y: cy))
a.addLine(to: CGPoint(x: cx + 8, y: cy + 24))
a.addLine(to: CGPoint(x: cx + 8, y: cy + 11))
a.addLine(to: CGPoint(x: cx - 36, y: cy + 11))
a.closeSubpath()
ctx.saveGState()
ctx.addPath(a); ctx.clip()
let arrowGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [teal.cgColor, indigo.cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(arrowGrad, start: CGPoint(x: cx - 36, y: cy), end: CGPoint(x: cx + 36, y: cy), options: [])
ctx.restoreGState()

// First-launch note (the app is not notarized).
let note = c(107, 114, 128)
drawCentered("First time you open it, if macOS says it can’t be verified:", y: 60, size: 11, weight: .regular, color: note)
drawCentered("open System Settings > Privacy & Security, then click Open Anyway.", y: 42, size: 11, weight: .regular, color: note)

NSGraphicsContext.restoreGraphicsState()

let out = "Resources/dmg-background.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (\(Int(W * SCALE))x\(Int(H * SCALE)) px, \(Int(W))x\(Int(H)) pt)")
