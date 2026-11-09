import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// makeicon <source.png> <master.png> <iconset-dir>
//
// Full-bleed app icon: crop the artwork's transparent margin, scale it to fill
// the whole rounded tile, and use a blurred copy of the artwork itself to fill
// the transparent gaps. No flat background or visible border is left behind.

let srcPath = CommandLine.arguments[1]
let outMaster = CommandLine.arguments[2]
let iconsetDir = CommandLine.arguments[3]

let srcURL = URL(fileURLWithPath: srcPath)
guard let source = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Could not read \(srcPath)")
}

let W = img.width, H = img.height
var data = [UInt8](repeating: 0, count: W * H * 4)
let rgb = CGColorSpaceCreateDeviceRGB()
guard let probe = CGContext(data: &data, width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: W * 4, space: rgb,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("probe context")
}
probe.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))

// Tight crop around the artwork, ignoring the fully transparent margin.
var minX = W, minY = H, maxX = -1, maxY = -1
for y in 0..<H {
    for x in 0..<W {
        let a = data[(y * W + x) * 4 + 3]
        if a > 8 {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
let crop = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
guard let art = img.cropping(to: crop) else { fatalError("crop failed") }
print("source \(W)x\(H), art \(Int(crop.width))x\(Int(crop.height)) at \(Int(crop.minX)),\(Int(crop.minY))")

let S: CGFloat = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 185
let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Aspect-fill the artwork into the tile, with a little overscan so no hairline
// of the old background can survive at the edges.
let overscan: CGFloat = 1.03
let bleed = tile.insetBy(dx: -tile.width * (overscan - 1) / 2,
                         dy: -tile.height * (overscan - 1) / 2)

func drawArtwork(_ ctx: CGContext, in rect: CGRect) {
    let artAspect = CGFloat(art.width) / CGFloat(art.height)
    let rectAspect = rect.width / rect.height
    var target = rect
    if artAspect > rectAspect {
        target.size.height = rect.width / artAspect
        target.origin.y = rect.midY - target.height / 2
    } else {
        target.size.width = rect.height * artAspect
        target.origin.x = rect.midX - target.width / 2
    }
    ctx.interpolationQuality = .high
    ctx.draw(art, in: target)
}

// Blurred artwork = a soft, colour-matched fill for the transparent gaps.
let bgCtx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                      bytesPerRow: 0, space: rgb,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
bgCtx.interpolationQuality = .high
bgCtx.clear(CGRect(x: 0, y: 0, width: S, height: S))
drawArtwork(bgCtx, in: bleed)
let bgRaw = bgCtx.makeImage()!

let ci = CIImage(cgImage: bgRaw).clampedToExtent()
let blurredCI = ci.applyingGaussianBlur(sigma: 58).cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
let ciContext = CIContext(options: [.useSoftwareRenderer: false])
guard let blurred = ciContext.createCGImage(blurredCI, from: CGRect(x: 0, y: 0, width: S, height: S)) else {
    fatalError("blur failed")
}

// The blurred echo inherits the artwork's transparent corners. Lift it to full
// opacity so the tile has no see-through gaps: divide the premultiplied colour
// by a floored alpha, which keeps the artwork's colour out to the edges while
// still letting the corners fall away into a soft vignette.
let n = Int(S)
var bd = [UInt8](repeating: 0, count: n * n * 4)
guard let bctx = CGContext(data: &bd, width: n, height: n, bitsPerComponent: 8,
                           bytesPerRow: n * 4, space: rgb,
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("blur buffer")
}
bctx.draw(blurred, in: CGRect(x: 0, y: 0, width: S, height: S))

var nd = [UInt8](repeating: 255, count: n * n * 4)
let floorA = 0.34
for i in stride(from: 0, to: bd.count, by: 4) {
    let a = Double(bd[i + 3]) / 255.0
    let f = max(a, floorA)
    for c in 0..<3 {
        nd[i + c] = UInt8(min(255.0, Double(bd[i + c]) / f))
    }
    nd[i + 3] = 255
}
guard let opaqueCtx = CGContext(data: &nd, width: n, height: n, bitsPerComponent: 8,
                                bytesPerRow: n * 4, space: rgb,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let blurredOpaque = opaqueCtx.makeImage() else {
    fatalError("opaque blur")
}

let canvas = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                       bytesPerRow: 0, space: rgb,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
canvas.interpolationQuality = .high
canvas.clear(CGRect(x: 0, y: 0, width: S, height: S))

// Soft echo of the artwork, dimmed so the sharp pinwheel stays the hero.
canvas.saveGState()
canvas.addPath(tilePath)
canvas.clip()
canvas.draw(blurredOpaque, in: CGRect(x: 0, y: 0, width: S, height: S))
canvas.setFillColor(CGColor(red: 0.03, green: 0.025, blue: 0.05, alpha: 0.24))
canvas.fill(tile)
canvas.restoreGState()

// The artwork itself, edge to edge, clipped by the rounded tile.
canvas.saveGState()
canvas.addPath(tilePath)
canvas.clip()
drawArtwork(canvas, in: bleed)
canvas.restoreGState()

guard let master = canvas.makeImage() else { fatalError("master image") }
let masterURL = URL(fileURLWithPath: outMaster)
guard let dest = CGImageDestinationCreateWithURL(masterURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("png destination")
}
CGImageDestinationAddImage(dest, master, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("png write") }

// Full iconset.
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetDir)
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, size) in entries {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: rgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let out = ctx.makeImage() else { continue }
    let url = URL(fileURLWithPath: iconsetDir).appendingPathComponent(name)
    if let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(d, out, nil)
        CGImageDestinationFinalize(d)
    }
}
print("wrote \(outMaster) and iconset")
