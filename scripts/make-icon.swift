// Renders the neo-node app icon the Apple way: one white glyph (a light bulb) on a single-hue gradient.
// 1024×1024 full bleed; macOS masks it to its rounded shape.
// Usage: swift scripts/make-icon.swift <output.png>
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"
let space = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

// Background: one hue (orange), lighter at the top, like Apple's own icon gradients.
let background = CGGradient(colorsSpace: space, colors: [color(1.00, 0.72, 0.20), color(1.00, 0.48, 0.05)] as CFArray,
                            locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])

// Glyph: a solid white bulb. The glass meets the neck tangentially, so the outline has no kinks.
let glassCenter = CGPoint(x: size / 2, y: 590)
let glassRadius: CGFloat = 235
func point(_ degrees: CGFloat) -> CGPoint {
    let r = degrees * .pi / 180
    return CGPoint(x: glassCenter.x + glassRadius * cos(r), y: glassCenter.y + glassRadius * sin(r))
}
let left = point(240), right = point(300)
let neckLeft = CGPoint(x: 432, y: 330), neckRight = CGPoint(x: 592, y: 330)
let glass = CGMutablePath()
glass.move(to: neckLeft)
glass.addCurve(to: left, control1: CGPoint(x: neckLeft.x, y: neckLeft.y + 45),
               control2: CGPoint(x: left.x + 0.866 * 70, y: left.y - 0.5 * 70))
glass.addArc(center: glassCenter, radius: glassRadius, startAngle: 240 * .pi / 180, endAngle: -60 * .pi / 180, clockwise: true)
glass.addCurve(to: neckRight, control1: CGPoint(x: right.x - 0.866 * 70, y: right.y - 0.5 * 70),
               control2: CGPoint(x: neckRight.x, y: neckRight.y + 45))
glass.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0.55, 0.22, 0.00, 0.30))
ctx.setFillColor(color(1, 1, 1))
ctx.addPath(glass)
ctx.fillPath()
// Screw base: two rounded bars.
for (y, width) in [(CGFloat(268), CGFloat(176)), (CGFloat(200), CGFloat(112))] {
    let bar = CGRect(x: size / 2 - width / 2, y: y - 24, width: width, height: 48)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 24, cornerHeight: 24, transform: nil))
}
ctx.fillPath()
ctx.restoreGState()

let image = ctx.makeImage()!
try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
