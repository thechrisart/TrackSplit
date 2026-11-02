// Builds AppIcon and the in-app logo from tracksplit-logo.jpg.
// Usage: swift Tools/make_icons.swift tracksplit-logo.jpg TrackSplit/Assets.xcassets
import AppKit

let args = CommandLine.arguments
let source = NSImage(contentsOfFile: args[1])!
let assets = URL(fileURLWithPath: args[2])
var rect = CGRect(origin: .zero, size: source.size)
let cg = source.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
// The artwork's own rounded square, without the lighter purple frame around it.
let inner = CGRect(x: 30, y: 36, width: 932, height: 930)
let cropped = cg.cropping(to: inner)!

func render(size: Int, inset: CGFloat, radius: CGFloat) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(size)
    let box = CGRect(x: s * inset, y: s * inset, width: s * (1 - 2 * inset), height: s * (1 - 2 * inset))
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: box.width * radius, cornerHeight: box.width * radius, transform: nil))
    ctx.clip()
    ctx.draw(cropped, in: box)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconSet = assets.appendingPathComponent("AppIcon.appiconset")
try? FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)@\(scale)x.png"
        // macOS icon grid: 824 of 1024 px, corner radius about 22.5%.
        try! render(size: pixels, inset: 100.0 / 1024.0, radius: 0.225).write(to: iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted]).write(to: iconSet.appendingPathComponent("Contents.json"))

let logoSet = assets.appendingPathComponent("Logo.imageset")
try? FileManager.default.createDirectory(at: logoSet, withIntermediateDirectories: true)
try! render(size: 720, inset: 0, radius: 0.09).write(to: logoSet.appendingPathComponent("logo.png"))
let logo: [String: Any] = ["images": [["idiom": "universal", "filename": "logo.png"]], "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: logo, options: [.prettyPrinted]).write(to: logoSet.appendingPathComponent("Contents.json"))
try! JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]], options: []).write(to: assets.appendingPathComponent("Contents.json"))
print("ok")
