// Renders the Siftr mark alone (two lines around a dot) on a transparent background, for slides and web.
// Usage: swift scripts/make_mark.swift <output.png> <hex color>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let hex = UInt32(CommandLine.arguments[2], radix: 16)!
let color = CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                    blue: CGFloat(hex & 0xff) / 255, alpha: 1)
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Same proportions as the app icon, scaled up to fill the canvas.
let s = CGFloat(size) * 1.6, c = CGFloat(size) / 2
let bar = s * 0.075, barHeight = s * 0.44, spacing = s * 0.13, dot = s * 0.115
ctx.setFillColor(color)
for side: CGFloat in [-1, 1] {
    let rect = CGRect(x: c + side * spacing - bar / 2, y: c - barHeight / 2, width: bar, height: barHeight)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
    ctx.fillPath()
}
ctx.fillEllipse(in: CGRect(x: c - dot / 2, y: c - dot / 2, width: dot, height: dot))
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
