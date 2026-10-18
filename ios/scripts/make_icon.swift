// Renders the VoiceTrim icon: the 4:3 iMessage App Icon set for the extension and a square app icon.
// Usage: swift scripts/make_icon.swift <output .stickersiconset dir> <output .appiconset dir>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func render(width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let w = CGFloat(width), h = CGFloat(height), s = min(w, h)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Light apricot at the top settling into a deep ember orange, with a soft glass highlight.
    let base = CGGradient(colorsSpace: space, colors: [rgb(0xFFC27A), rgb(0xF2803A), rgb(0xC94A16)] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: w * 0.3, y: h), end: CGPoint(x: w * 0.7, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: w * 0.5, y: h * 1.05), startRadius: 0,
                           endCenter: CGPoint(x: w * 0.5, y: h * 1.05), endRadius: s * 0.75, options: [])

    // Sift: two lines of voice around a single dot, the um, sifted out between them.
    let bar = s * 0.075, barHeight = s * 0.44, spacing = s * 0.13
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.035, color: rgb(0x7A2A08, 0.35))
    ctx.setFillColor(rgb(0xFFFFFF))
    for side: CGFloat in [-1, 1] {
        let rect = CGRect(x: w / 2 + side * spacing - bar / 2, y: h / 2 - barHeight / 2, width: bar, height: barHeight)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: bar / 2, cornerHeight: bar / 2, transform: nil))
        ctx.fillPath()
    }
    let dot = s * 0.115
    ctx.fillEllipse(in: CGRect(x: w / 2 - dot / 2, y: h / 2 - dot / 2, width: dot, height: dot))
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest), "could not write \(url.path)")
}

// (idiom, size in points, scale) as Xcode's iMessage Extension template lists them.
let slots: [(String, String, Int)] = [
    ("iphone", "29x29", 2), ("iphone", "29x29", 3), ("iphone", "60x45", 2), ("iphone", "60x45", 3),
    ("ipad", "29x29", 2), ("ipad", "67x50", 2), ("ipad", "74x55", 2),
    ("universal", "27x20", 2), ("universal", "27x20", 3), ("universal", "32x24", 2), ("universal", "32x24", 3),
    ("ios-marketing", "1024x768", 1),
]

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var images: [[String: String]] = []
for (idiom, size, scale) in slots {
    let dims = size.split(separator: "x").map { Int($0)! * scale }
    let name = "icon-\(idiom)-\(size)@\(scale)x.png"
    write(render(width: dims[0], height: dims[1]), to: out.appendingPathComponent(name))
    var entry = ["idiom": idiom, "size": size, "scale": "\(scale)x", "filename": name]
    if idiom == "universal" || idiom == "ios-marketing" { entry["platform"] = "ios" }  // as the template has it
    images.append(entry)
}
func writeContents(_ images: [[String: String]], to dir: URL) throws {
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: dir.appendingPathComponent("Contents.json"))
}
try writeContents(images, to: out)
print("wrote \(slots.count) icons to \(out.path)")

// The containing app's square icon, at every size explicitly. The single 1024 px form left
// SpringBoard showing a placeholder.
let appIcon = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: appIcon)
try FileManager.default.createDirectory(at: appIcon, withIntermediateDirectories: true)
let squares: [(String, Double, Int)] = [
    ("iphone", 20, 2), ("iphone", 20, 3), ("iphone", 29, 2), ("iphone", 29, 3),
    ("iphone", 40, 2), ("iphone", 40, 3), ("iphone", 60, 2), ("iphone", 60, 3),
    ("ipad", 20, 1), ("ipad", 20, 2), ("ipad", 29, 1), ("ipad", 29, 2), ("ipad", 40, 1), ("ipad", 40, 2),
    ("ipad", 76, 1), ("ipad", 76, 2), ("ipad", 83.5, 2), ("ios-marketing", 1024, 1),
]
var appImages: [[String: String]] = []
for (idiom, points, scale) in squares {
    let size = points == points.rounded() ? "\(Int(points))x\(Int(points))" : "\(points)x\(points)"
    let pixels = Int(points * Double(scale))
    let name = "AppIcon-\(idiom)-\(size)@\(scale)x.png"
    write(render(width: pixels, height: pixels), to: appIcon.appendingPathComponent(name))
    appImages.append(["idiom": idiom, "size": size, "scale": "\(scale)x", "filename": name])
}
try writeContents(appImages, to: appIcon)
print("wrote \(squares.count) square app icons to \(appIcon.path)")
