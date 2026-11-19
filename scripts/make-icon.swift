// Renders the app icon: two stacked flashcards on a Nord squircle.
// Usage: swift scripts/make-icon.swift <output.png> [--full]
// --full fills the whole opaque square for iOS, which applies its own mask.
import AppKit

let args = CommandLine.arguments.dropFirst()
let out = args.first { !$0.hasPrefix("--") } ?? "icon.png"
let full = args.contains("--full")
let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: (full ? CGImageAlphaInfo.noneSkipLast : CGImageAlphaInfo.premultipliedLast).rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let tile = full ? CGRect(x: 0, y: 0, width: size, height: size) : CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: full ? 0 : 185, cornerHeight: full ? 0 : 185, transform: nil))
ctx.setFillColor(rgb(0x2E3440))
ctx.fillPath()

func card(center: CGPoint, angle: CGFloat, color: CGColor) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)
    let r = CGRect(x: -210, y: -140, width: 420, height: 280)
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x000000, 0.35))
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 36, cornerHeight: 36, transform: nil))
    ctx.setFillColor(color)
    ctx.fillPath()
    ctx.restoreGState()
}

let c = CGPoint(x: 512, y: 512)
card(center: CGPoint(x: c.x - 30, y: c.y + 60), angle: 0.16, color: rgb(0x5E81AC))
card(center: CGPoint(x: c.x + 20, y: c.y - 40), angle: -0.08, color: rgb(0x88C0D0))
// A single line of "text" on the front card.
ctx.saveGState()
ctx.translateBy(x: c.x + 20, y: c.y - 40)
ctx.rotate(by: -0.08)
ctx.addPath(CGPath(roundedRect: CGRect(x: -120, y: -14, width: 240, height: 28), cornerWidth: 14, cornerHeight: 14, transform: nil))
ctx.setFillColor(rgb(0x2E3440, 0.85))
ctx.fillPath()
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
