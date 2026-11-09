import AppKit
import ImageIO
import CryptoKit
import CoreImage

// MARK: - Thumbnails

final class ThumbnailService {
    static let shared = ThumbnailService()

    private let mem = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.galleria.thumbs", qos: .userInitiated, attributes: .concurrent)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private init() {
        mem.countLimit = 4000
    }

    func cachedThumbnail(path: String, mtime: Double) -> NSImage? {
        mem.object(forKey: Self.key(path, mtime) as NSString)
    }

    func thumbnail(path: String, mtime: Double, size: CGFloat = 320) async -> NSImage? {
        let k = Self.key(path, mtime)
        if let hit = mem.object(forKey: k as NSString) { return hit }
        return await withCheckedContinuation { cont in
            queue.async {
                if let hit = self.mem.object(forKey: k as NSString) {
                    cont.resume(returning: hit); return
                }
                let img = self.loadThumbnail(path: path, mtime: mtime, size: size)
                if let img { self.mem.setObject(img, forKey: k as NSString) }
                cont.resume(returning: img)
            }
        }
    }

    private static func key(_ path: String, _ mtime: Double) -> String {
        "\(path)|\(Int(mtime))"
    }

    private static func diskName(_ path: String, _ mtime: Double) -> String {
        let digest = SHA256.hash(data: Data("\(path)|\(Int(mtime))".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func loadThumbnail(path: String, mtime: Double, size: CGFloat) -> NSImage? {
        let diskURL = LibraryStore.thumbnailCacheDir
            .appendingPathComponent(Self.diskName(path, mtime))
            .appendingPathExtension("jpg")

        if let img = NSImage(contentsOf: diskURL) { return img }

        guard let cg = Imaging.baseCGImage(path: path, maxPixel: size) else { return nil }

        // Persist as JPEG for instant subsequent loads.
        if let dest = CGImageDestinationCreateWithURL(diskURL as CFURL, "public.jpeg" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }

        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    func clearDiskCache() {
        let dir = LibraryStore.thumbnailCacheDir
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        mem.removeAllObjects()
    }
}

// MARK: - Image loading / metadata

enum Imaging {

    static func pixelSize(path: String) -> CGSize? {
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let w = props[kCGImagePropertyPixelWidth] as? Double ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Double ?? 0
            if w > 0, h > 0 { return CGSize(width: w, height: h) }
        }
        // Vector formats (SVG, ICNS, PDF…) have no ImageIO pixel size.
        if let img = NSImage(contentsOfFile: path), img.size.width > 0, img.size.height > 0 {
            return img.size
        }
        return nil
    }

    /// Rasterises anything AppKit can draw — SVG, ICNS, PDF and friends — which ImageIO
    /// cannot decode. Used as a fallback when `CGImageSourceCreateThumbnailAtIndex` fails.
    static func rasterize(path: String, maxPixel: CGFloat) -> CGImage? {
        guard let img = NSImage(contentsOfFile: path),
              img.size.width > 0, img.size.height > 0 else { return nil }

        let longest = max(img.size.width, img.size.height)
        let scale = min(maxPixel / longest, 8)
        let w = max(1, min(4096, Int((img.size.width * scale).rounded())))
        let h = max(1, min(4096, Int((img.size.height * scale).rounded())))

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    /// Decodes any supported file to a downsampled CGImage, honouring EXIF orientation.
    static func baseCGImage(path: String, maxPixel: CGFloat) -> CGImage? {
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           CGImageSourceGetCount(src) > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return cg
            }
        }
        return rasterize(path: path, maxPixel: maxPixel)
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    /// Capture date from EXIF (`DateTimeOriginal`, falling back to TIFF `DateTime`).
    /// Metadata-only read — the image is never decoded.
    static func captureDate(path: String) -> Double? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts as CFDictionary) as? [String: Any] else { return nil }

        if let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let s = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String,
           let d = exifDateFormatter.date(from: s) {
            return d.timeIntervalSince1970
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
           let s = tiff[kCGImagePropertyTIFFDateTime as String] as? String,
           let d = exifDateFormatter.date(from: s) {
            return d.timeIntervalSince1970
        }
        return nil
    }

    /// Turns raw EXIF "yyyy:MM:dd HH:mm:ss" into something a person can read.
    static func humanDate(_ raw: String) -> String {
        guard let d = exifDateFormatter.date(from: raw) else { return raw }
        let out = DateFormatter()
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: d)
    }

    /// Downsampled full image, fast even for huge files.
    static func load(path: String, maxPixel: CGFloat) -> NSImage? {
        guard let cg = baseCGImage(path: path, maxPixel: maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func exif(path: String) -> [(String, String)] {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [] }

        var out: [(String, String)] = []

        let w = props[kCGImagePropertyPixelWidth] as? Double ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Double ?? 0
        if w > 0 { out.append(("Dimensions", "\(Int(w)) × \(Int(h))")) }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let b = attrs[.size] as? Int {
            out.append(("File size", ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)))
        }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [String: Any] {
            let make = tiff[kCGImagePropertyTIFFMake as String] as? String
            let model = tiff[kCGImagePropertyTIFFModel as String] as? String
            if let make, let model {
                out.append(("Camera", "\(make) \(model)".trimmingCharacters(in: .whitespaces)))
            } else if let model {
                out.append(("Camera", model))
            }
            if let dt = tiff[kCGImagePropertyTIFFDateTime as String] as? String {
                out.append(("Date taken", humanDate(dt)))
            }
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [String: Any] {
            if let lens = exif[kCGImagePropertyExifLensModel as String] as? String {
                out.append(("Lens", lens))
            }
            if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber],
               let first = iso.first {
                out.append(("ISO", "\(first.intValue)"))
            }
            if let exp = exif[kCGImagePropertyExifExposureTime as String] as? Double, exp > 0 {
                out.append(("Shutter", exp < 1 ? "1/\(Int(round(1/exp))) s" : String(format: "%.1f s", exp)))
            }
            if let f = exif[kCGImagePropertyExifFNumber as String] as? Double {
                out.append(("Aperture", String(format: "ƒ/%.1f", f)))
            }
            if let fl = exif[kCGImagePropertyExifFocalLength as String] as? Double {
                out.append(("Focal length", String(format: "%.0f mm", fl)))
            }
            if let dto = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                out.append(("Original date", humanDate(dto)))
            }
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [String: Any],
           let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
            out.append(("Location", String(format: "%.5f° %@, %.5f° %@", lat, latRef, lon, lonRef)))
        }

        out.append(("Path", path))
        return out
    }
}

// MARK: - Non-destructive editor

enum Editor {

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func apply(_ recipe: EditRecipe, to input: CIImage) -> CIImage {
        var ci = input
        guard !recipe.isIdentity else { return ci }

        // Straighten (small angle, before big rotate) + auto enhance.
        // The rotation is scaled to COVER the original frame, then cropped back
        // to it — without the cover scale the rotated corners leave transparent
        // slivers that appeared as white lines at the photo edges.
        if recipe.straighten != 0 {
            let rad = recipe.straighten * .pi / 180.0
            let extent = input.extent
            let w = extent.width
            let h = extent.height
            guard w > 0, h > 0 else {
                let center = CGPoint(x: ci.extent.midX, y: ci.extent.midY)
                let t = CGAffineTransform.identity
                    .translatedBy(x: center.x, y: center.y)
                    .rotated(by: CGFloat(rad))
                    .translatedBy(x: -center.x, y: -center.y)
                ci = ci.transformed(by: t)
                return ci
            }
            let cosA = abs(cos(CGFloat(rad)))
            let sinA = abs(sin(CGFloat(rad)))
            let ratio = max(w, h) / min(w, h)
            let cover = cosA + sinA * ratio
            let center = CGPoint(x: extent.midX, y: extent.midY)
            let t = CGAffineTransform.identity
                .translatedBy(x: center.x, y: center.y)
                .scaledBy(x: cover, y: cover)
                .rotated(by: CGFloat(rad))
                .translatedBy(x: -center.x, y: -center.y)
            ci = ci.transformed(by: t).cropped(to: extent)
        }
        if recipe.autoEnhance {
            for filter in ci.autoAdjustmentFilters() {
                filter.setValue(ci, forKey: kCIInputImageKey)
                if let out = filter.outputImage { ci = out }
            }
        }

        // Exposure, brightness/contrast
        if recipe.exposure != 0 {
            if let f = CIFilter(name: "CIExposureAdjust") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(Float(recipe.exposure), forKey: "inputEV")
                if let out = f.outputImage { ci = out }
            }
        }
        if recipe.brightness != 0 || recipe.contrast != 0 || recipe.saturation != 0 {
            if let f = CIFilter(name: "CIColorControls") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(Float(recipe.brightness * 0.35), forKey: "inputBrightness")
                f.setValue(Float(1.0 + recipe.contrast * 0.8), forKey: "inputContrast")
                f.setValue(Float(1.0 + recipe.saturation), forKey: "inputSaturation")
                if let out = f.outputImage { ci = out }
            }
        }

        // Fill light / highlights / shadows (Picasa-style)
        // CIHighlightShadowAdjust: inputShadowAmount (-1..1, identity 0),
        // inputHighlightAmount (0..1, identity 1). Fill light lifts shadows.
        if recipe.fillLight != 0 || recipe.highlights != 0 || recipe.shadows != 0 {
            if let f = CIFilter(name: "CIHighlightShadowAdjust") {
                f.setValue(ci, forKey: kCIInputImageKey)
                let shadow = max(-1.0, min(1.0, recipe.fillLight * 0.6 + recipe.shadows * 0.4))
                let highlight = max(0.0, min(1.0, 1.0 - recipe.highlights * 0.5))
                f.setValue(Float(shadow), forKey: "inputShadowAmount")
                f.setValue(Float(highlight), forKey: "inputHighlightAmount")
                if let out = f.outputImage { ci = out }
            }
        }

        // Warmth (temperature shift)
        if recipe.warmth != 0 {
            if let f = CIFilter(name: "CITemperatureAndTint") {
                f.setValue(ci, forKey: kCIInputImageKey)
                // 6500K neutral: warm = +1900K, cool = -1900K
                let temp = 6500.0 + recipe.warmth * 1900.0
                f.setValue(CIVector(x: CGFloat(temp), y: 0.0), forKey: "inputNeutral")
                if let out = f.outputImage { ci = out }
            }
        }

        // Sharpen / vignette
        if recipe.sharpen != 0 {
            if let f = CIFilter(name: "CISharpenLuminance") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(Float(recipe.sharpen * 0.9), forKey: "inputSharpness")
                if let out = f.outputImage { ci = out }
            }
        }

        // Artistic filters (use filters that actually exist on macOS 14)
        switch recipe.filter {
        case .none: break
        case .monochrome:
            if let f = CIFilter(name: "CIColorMonochrome") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(CIColor(red: 0.85, green: 0.82, blue: 0.78), forKey: "inputColor")
                if let out = f.outputImage { ci = out }
            }
        case .sepia:
            if let f = CIFilter(name: "CISepiaTone") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(0.75 as NSNumber, forKey: "inputIntensity")
                if let out = f.outputImage { ci = out }
            }
        case .vintage:
            if let f = CIFilter(name: "CIPhotoEffectInstant") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(1 as NSNumber, forKey: "inputExtrapolate")
                if let out = f.outputImage { ci = out }
            }
        case .vivid:
            // CIPhotoEffectVivid doesn't exist on macOS — use Vibrance instead.
            if let f = CIFilter(name: "CIVibrance") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(0.8 as NSNumber, forKey: "inputAmount")
                if let out = f.outputImage { ci = out }
            }
        case .fade:
            if let f = CIFilter(name: "CIPhotoEffectFade") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(1 as NSNumber, forKey: "inputExtrapolate")
                if let out = f.outputImage { ci = out }
            }
        case .silver:
            if let f = CIFilter(name: "CIPhotoEffectNoir") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(1 as NSNumber, forKey: "inputExtrapolate")
                if let out = f.outputImage { ci = out }
            }
        case .warm:
            // CIPhotoEffectWarmify doesn't exist — warm via temperature.
            if let f = CIFilter(name: "CITemperatureAndTint") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(CIVector(x: 7000, y: 10), forKey: "inputNeutral")
                if let out = f.outputImage { ci = out }
            }
        }

        if recipe.vignette != 0 {
            if let f = CIFilter(name: "CIVignette") {
                f.setValue(ci, forKey: kCIInputImageKey)
                f.setValue(Float(recipe.vignette * 1.4), forKey: "inputIntensity")
                f.setValue(Float(recipe.vignette * 90.0), forKey: "inputRadius")
                if let out = f.outputImage { ci = out }
            }
        }

        // Flip + rotate + crop (after tonal work, like Picasa)
        if recipe.flipH {
            ci = ci.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: ci.extent.width, y: 0))
        }
        switch recipe.rotation {
        case 90: ci = ci.oriented(.right)
        case 180: ci = ci.oriented(.down)
        case 270: ci = ci.oriented(.left)
        default: break
        }
        if let c = recipe.crop {
            let e = ci.extent
            let rect = CGRect(
                x: e.minX + c.x * e.width,
                y: e.minY + (1.0 - c.y - c.h) * e.height,
                width: c.w * e.width,
                height: c.h * e.height
            )
            ci = ci.cropped(to: rect)
            ci = ci.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        }
        return ci
    }

    /// Draw Preview-style markup elements onto an image (normalized → pixels).
    static func applyMarkups(_ image: NSImage, markups: [MarkupElement]) -> NSImage {
        guard !markups.isEmpty, !image.representations.isEmpty else { return image }
        let w = Int(image.size.width), h = Int(image.size.height)
        guard w > 0, h > 0,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(origin: .zero, size: image.size))
        for m in markups {
            let color = MarkupColors.color(fromHex: m.color)
            let rect = NSRect(x: m.x * Double(w), y: (1 - m.y - m.h) * Double(h),
                              width: m.w * Double(w), height: m.h * Double(h))
            func stroke(_ path: NSBezierPath) {
                color.setStroke()
                path.lineWidth = CGFloat(m.strokeWidth)
                path.stroke()
                if m.filled {
                    color.setFill()
                    path.fill()
                }
            }
            switch m.type {
            case .rect:
                let p = NSBezierPath(roundedRect: rect, xRadius: 0, yRadius: 0)
                stroke(p)
            case .oval:
                let p = NSBezierPath(ovalIn: rect)
                stroke(p)
            case .line:
                let p = NSBezierPath()
                p.move(to: NSPoint(x: rect.minX, y: rect.maxY))
                p.line(to: NSPoint(x: rect.maxX, y: rect.minY))
                stroke(p)
            case .arrow:
                let p = NSBezierPath()
                let a = NSPoint(x: rect.minX, y: rect.maxY)
                let b = NSPoint(x: rect.maxX, y: rect.minY)
                p.move(to: a); p.line(to: b)
                stroke(p)
                let ang = atan2(a.y - b.y, a.x - b.x)
                let len: CGFloat = 14
                for da in [-0.5, 0.5] {
                    let x = b.x + len * cos(ang + Double(da) * 0.6)
                    let y = b.y + len * sin(ang + Double(da) * 0.6)
                    let head = NSBezierPath(); head.move(to: b); head.line(to: NSPoint(x: x, y: y)); stroke(head)
                }
            case .text:
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: CGFloat(m.strokeWidth * 6), weight: .bold),
                    .foregroundColor: color
                ]
                (m.text as NSString).draw(in: rect, withAttributes: attrs)
            case .freehand:
                guard m.points.count >= 2 else { break }
                let p = NSBezierPath()
                let first = m.points.first!
                p.move(to: NSPoint(x: first.x * Double(w), y: (1 - first.y) * Double(h)))
                for pt in m.points.dropFirst() {
                    p.line(to: NSPoint(x: pt.x * Double(w), y: (1 - pt.y) * Double(h)))
                }
                stroke(p)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = bitmap.cgImage else { return image }
        return NSImage(cgImage: cg, size: image.size)
    }

    static func render(path: String, recipe: EditRecipe, maxPixel: CGFloat) -> NSImage? {
        guard let base = Imaging.baseCGImage(path: path, maxPixel: maxPixel) else { return nil }
        if recipe.isIdentity {
            return NSImage(cgImage: base, size: NSSize(width: base.width, height: base.height))
        }
        let ci = apply(recipe, to: CIImage(cgImage: base))
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        var img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if !recipe.markups.isEmpty { img = applyMarkups(img, markups: recipe.markups) }
        return img
    }

    /// Renders a full-resolution export with edits applied.
    static func export(path: String, recipe: EditRecipe, to destination: URL, maxPixel: CGFloat = 6000, quality: Double = 0.9) -> Bool {
        guard let base = Imaging.baseCGImage(path: path, maxPixel: maxPixel) else { return false }
        var cg = base
        if !recipe.isIdentity {
            let ci = apply(recipe, to: CIImage(cgImage: base))
            if let out = context.createCGImage(ci, from: ci.extent) { cg = out }
        }
        // Bake markups into the export (Preview-style).
        if !recipe.markups.isEmpty {
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            let marked = applyMarkups(img, markups: recipe.markups)
            guard let tiff = marked.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff), let outCG = bmp.cgImage else { return false }
            cg = outCG
        }

        let ext = destination.pathExtension.lowercased()
        let type: CFString
        switch ext {
        case "png": type = "public.png" as CFString
        case "heic", "heif": type = "public.heic" as CFString
        case "tif", "tiff": type = "public.tiff" as CFString
        default: type = "public.jpeg" as CFString
        }
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    /// Write an already-rendered NSImage to disk (used by collage export).
    static func writeImage(_ image: NSImage, to destination: URL, quality: Double = 0.92) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cg = bitmap.cgImage else { return false }
        let ext = destination.pathExtension.lowercased()
        let type: CFString = (ext == "png") ? "public.png" as CFString : "public.jpeg" as CFString
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}

// MARK: - Collage engine

enum MarkupColors {
    static func color(fromHex hex: String) -> NSColor {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        return NSColor(calibratedRed: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

enum CollageEngine {
    /// Renders a Picasa-style collage: Grid (even cells), Picture-in-Picture
    /// (backdrop + small inset), Mosaic (first image large), Freestyle (offset
    /// rows). Supports spacing, borders, captions and Picasa backgrounds.
    static func render(images: [NSImage], recipe: CollageRecipe, canvas: CGSize = CGSize(width: 2000, height: 2000)) -> NSImage? {
        guard !images.isEmpty else { return nil }
        let spacing = CGFloat(recipe.spacing)
        var size = canvas
        switch recipe.canvasAspect {
        case "4:3": size = CGSize(width: canvas.width, height: canvas.width * 3 / 4)
        case "16:9": size = CGSize(width: canvas.width, height: canvas.width * 9 / 16)
        case "square": size = canvas
        default: size = canvas
        }
        // Reserve bottom caption strip (Picasa title band).
        let captionH: CGFloat = recipe.caption.isEmpty ? 0 : 110
        let tileAreaH = size.height - captionH
        let tileArea = CGRect(x: 0, y: captionH, width: size.width, height: tileAreaH)
        let bg: NSColor?
        switch recipe.background {
        case "none": bg = nil
        case "black": bg = .black
        case "white": bg = .white
        default:
            let hex = recipe.background.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            var v: UInt64 = 0
            Scanner(string: hex).scanHexInt64(&v)
            bg = NSColor(calibratedRed: CGFloat((v >> 16) & 0xFF) / 255,
                         green: CGFloat((v >> 8) & 0xFF) / 255,
                         blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        let borderColor: NSColor
        switch recipe.borderColor {
        case "white": borderColor = .white
        case "grey": borderColor = NSColor(white: 0.75, alpha: 1)
        default: borderColor = .black
        }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        if let bg {
            bg.setFill()
            NSBezierPath.fill(NSRect(origin: .zero, size: size))
        } else {
            NSColor.clear.setFill()
            NSBezierPath.fill(NSRect(origin: .zero, size: size))
        }

        let frames = layoutFrames(count: images.count, in: tileArea, spacing: spacing, layout: recipe.layout, recipe: recipe)
        for (i, img) in images.enumerated() {
            guard i < frames.count else { break }
            drawImage(img, in: frames[i], corner: CGFloat(recipe.cornerRadius),
                      borderWidth: CGFloat(recipe.borderWidth), borderColor: borderColor)
        }

        if !recipe.caption.isEmpty {
            NSColor.black.withAlphaComponent(0.85).setFill()
            NSBezierPath.fill(NSRect(x: 0, y: 0, width: size.width, height: captionH))
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
                .paragraphStyle: {
                    let p = NSMutableParagraphStyle()
                    p.alignment = .center
                    return p
                }()
            ]
            (recipe.caption as NSString).draw(in: NSRect(x: 30, y: captionH / 2 - 28, width: size.width - 60, height: 56),
                                              withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    private static func layoutFrames(count: Int, in canvas: CGRect, spacing: CGFloat, layout: CollageLayout, recipe: CollageRecipe) -> [NSRect] {
        guard count > 0 else { return [] }
        switch layout {
        case .grid:
            let cols = Int(ceil(sqrt(Double(count))))
            let rows = Int(ceil(Double(count) / Double(cols)))
            let cw = (canvas.width - spacing * CGFloat(cols + 1)) / CGFloat(cols)
            let ch = (canvas.height - spacing * CGFloat(rows + 1)) / CGFloat(rows)
            var out: [NSRect] = []
            for r in 0..<rows {
                for c in 0..<cols where out.count < count {
                    let x = canvas.minX + spacing + CGFloat(c) * (cw + spacing)
                    let y = canvas.minY + spacing + CGFloat(rows - 1 - r) * (ch + spacing)
                    out.append(NSRect(x: x, y: y, width: cw, height: ch))
                }
            }
            return out
        case .pictureInPicture:
            // Backdrop fills tile area, remaining images are stacked insets (PIP).
            guard count > 1 else {
                return [NSRect(x: canvas.minX + spacing, y: canvas.minY + spacing,
                               width: canvas.width - spacing * 2, height: canvas.height - spacing * 2)]
            }
            var out = [NSRect(x: canvas.minX + spacing, y: canvas.minY + spacing,
                              width: canvas.width - spacing * 2, height: canvas.height - spacing * 2)]
            let rest = count - 1
            let pipW = canvas.width * CGFloat(recipe.pipSize)
            let pipH = canvas.height * CGFloat(recipe.pipSize)
            // Stack PIPs diagonally from pipX/pipY toward centre.
            for i in 0..<rest {
                let f = Double(i) / Double(max(rest, 1))
                let cx = canvas.minX + canvas.width * CGFloat(recipe.pipX) - (pipW / 2) * CGFloat(1 - f * 0.5)
                let cy = canvas.minY + canvas.height * CGFloat(recipe.pipY) - (pipH / 2) * CGFloat(1 - f * 0.5)
                out.append(NSRect(x: cx, y: cy, width: pipW, height: pipH))
            }
            return out
        case .mosaic:
            guard count > 1 else { return [NSRect(x: canvas.minX + spacing, y: canvas.minY + spacing, width: canvas.width - spacing * 2, height: canvas.height - spacing * 2)] }
            let heroH = canvas.height * 0.62 - spacing
            let hero = NSRect(x: canvas.minX + spacing, y: canvas.minY + spacing + canvas.height * 0.38, width: canvas.width - spacing * 2, height: heroH)
            let n = count - 1
            let bottomY = canvas.minY + spacing
            let bottomH = canvas.height * 0.38 - spacing * 2
            let cw = (canvas.width - spacing * CGFloat(n + 1)) / CGFloat(max(n, 1))
            var out = [hero]
            for i in 0..<n {
                out.append(NSRect(x: canvas.minX + spacing + CGFloat(i) * (cw + spacing), y: bottomY, width: cw, height: bottomH))
            }
            return out
        case .freestyle:
            // Simple offset rows: alternate indent, slight overlap feel via spacing.
            let perRow = max(2, Int(ceil(sqrt(Double(count)))))
            let rows = Int(ceil(Double(count) / Double(perRow)))
            let cw = (canvas.width - spacing * CGFloat(perRow + 1)) / CGFloat(perRow)
            let ch = (canvas.height - spacing * CGFloat(rows + 1)) / CGFloat(rows)
            var out: [NSRect] = []
            for r in 0..<rows {
                let inRow = min(perRow, count - r * perRow)
                let indent = (r % 2 == 0) ? 0 : cw * 0.25
                for c in 0..<inRow {
                    let x = canvas.minX + spacing + indent + CGFloat(c) * (cw + spacing)
                    let y = canvas.minY + spacing + CGFloat(rows - 1 - r) * (ch + spacing)
                    out.append(NSRect(x: min(x, canvas.maxX - spacing - cw), y: y, width: cw, height: ch))
                }
            }
            return out
        }
    }

    private static func drawImage(_ image: NSImage, in rect: NSRect, corner: CGFloat, borderWidth: CGFloat, borderColor: NSColor) {
        // Aspect-fill crop into the tile.
        let imgSize = image.size
        let scale = max(rect.width / max(imgSize.width, 1), rect.height / max(imgSize.height, 1))
        let drawn = NSSize(width: imgSize.width * scale, height: imgSize.height * scale)
        let origin = NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
        let clip = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        NSGraphicsContext.current?.saveGraphicsState()
        clip.addClip()
        image.draw(in: NSRect(origin: origin, size: drawn), from: NSRect(origin: .zero, size: imgSize),
                   operation: .copy, fraction: 1.0)
        NSGraphicsContext.current?.restoreGraphicsState()
        if borderWidth > 0 {
            borderColor.setStroke()
            clip.lineWidth = borderWidth
            clip.stroke()
        }
        NSColor.black.withAlphaComponent(0.08).setStroke()
        clip.lineWidth = 1
        clip.stroke()
    }
}
