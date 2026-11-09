import SwiftUI
import AppKit
import Vision
import ImageIO

/// Preview-style tools: Resize, Instant Alpha (remove background), Markup helpers,
/// Copy/Paste style — compact like Preview's Tools / Adjust Size.

enum InstantAlpha {
    /// Foreground mask image (scaled to the source resolution, 0=bg 1=fg).
    static func foregroundMask(cgImage: CGImage) -> CGImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        request.revision = VNGenerateForegroundInstanceMaskRequestRevision1
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first else { return nil }
        guard let buffer = try? result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler) else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        let ciCtx = CIContext()
        return ciCtx.createCGImage(ci, from: ci.extent)
    }

    /// Cut-out PNG: foreground from mask, background transparent.
    static func cutout(path: String, maxPixel: CGFloat = 2000) -> NSImage? {
        guard let src = Imaging.baseCGImage(path: path, maxPixel: maxPixel),
              let mask = foregroundMask(cgImage: src) else { return nil }
        // Composite src with mask as alpha via CoreImage.
        let ciSrc = CIImage(cgImage: src)
        let ciMask = CIImage(cgImage: mask)
        if let f = CIFilter(name: "CIBlendWithMask") {
            f.setValue(ciSrc, forKey: kCIInputImageKey)
            f.setValue(ciMask, forKey: kCIInputMaskImageKey)
            // Background = fully transparent, cropped to source extent.
            let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))
                .cropped(to: ciSrc.extent)
            f.setValue(transparent, forKey: "inputBackgroundImage")
            if let out = f.outputImage, let cg = CIContext().createCGImage(out, from: out.extent) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return nil
    }
}

enum ResizeHelper {
    static func resizedImage(path: String, recipe: EditRecipe, maxPixel: CGFloat, targetWidth: Int, targetHeight: Int) -> NSImage? {
        guard let rendered = Editor.render(path: path, recipe: recipe, maxPixel: maxPixel) else { return nil }
        let w = max(1, targetWidth), h = max(1, targetHeight)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        rendered.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: NSRect(origin: .zero, size: rendered.size),
                      operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
}

// MARK: - Resize sheet (Preview Tools > Adjust Size)

struct ResizeSheet: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let photoID: Int64
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var proportional = true
    @State private var status = ""
    @State private var originalSize: CGSize = .zero
    @State private var preview: NSImage?

    var photo: Photo? { library.photos.first { $0.id == photoID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Adjust Size", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }
            Divider()
            if let p = photo {
                Text("\(p.filename) — original \(Int(originalSize.width)) × \(Int(originalSize.height)) px")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Width (px)").font(.callout)
                        TextField("Width", text: $widthText)
                            .textFieldStyle(.roundedBorder).frame(width: 110).onChange(of: widthText) { _, _ in syncHeight() }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Height (px)").font(.callout)
                        TextField("Height", text: $heightText)
                            .textFieldStyle(.roundedBorder).frame(width: 110).onChange(of: heightText) { _, _ in syncWidth() }
                    }
                    Toggle("Proportional", isOn: $proportional).toggleStyle(.switch).controlSize(.small)
                }
                Picker("Resample", selection: $status) { Text("Automatic (High)").tag("") }
                    .labelsHidden()
                if let preview {
                    Image(nsImage: preview).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Button("Export Resized…") { doExport() }
                        .buttonStyle(.borderedProminent).disabled(widthText.isEmpty || heightText.isEmpty)
                    Spacer()
                    Text(previewStatusText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 440, height: 480)
        .onAppear {
            guard let p = photo else { return }
            if p.width > 0 && p.height > 0 {
                originalSize = CGSize(width: p.width, height: p.height)
            } else if let s = Imaging.pixelSize(path: p.path) {
                originalSize = s
            }
            widthText = "\(Int(originalSize.width))"
            heightText = "\(Int(originalSize.height))"
            refreshPreview()
        }
    }

    private var previewStatusText: String {
        if status.isEmpty { return "Preview updates on size change." }
        return status
    }

    private func syncHeight() {
        guard proportional, let w = Double(widthText), originalSize.width > 0 else { return }
        let h = w * originalSize.height / originalSize.width
        heightText = "\(Int(h.rounded()))"
        refreshPreview()
    }

    private func syncWidth() {
        guard proportional, let h = Double(heightText), originalSize.height > 0 else { return }
        let w = h * originalSize.width / originalSize.height
        widthText = "\(Int(w.rounded()))"
        refreshPreview()
    }

    private func refreshPreview() {
        guard let p = photo, let w = Int(widthText), let h = Int(heightText), w > 0, h > 0 else { return }
        let recipe = library.loadEdit(for: p.id)
        preview = ResizeHelper.resizedImage(path: p.path, recipe: recipe, maxPixel: 1200, targetWidth: w, targetHeight: h)
    }

    private func doExport() {
        guard let p = photo, let w = Int(widthText), let h = Int(heightText) else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Save Resized"
        panel.message = "Choose a folder for the resized copy"
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        panel.directoryURL = pics.appendingPathComponent("Galleria Exports", isDirectory: true)
        guard panel.runModal() == .OK, let dest = panel.url ?? panel.directoryURL else { return }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let out = dest.appendingPathComponent("\(p.filename.replacingOccurrences(of: ".", with: "-"))-\(w)x\(h).jpg")
        status = "Exporting…"
        let recipe = library.loadEdit(for: p.id)
        DispatchQueue.global(qos: .userInitiated).async {
            if let img = ResizeHelper.resizedImage(path: p.path, recipe: recipe, maxPixel: 6000, targetWidth: w, targetHeight: h) {
                let ok = Editor.writeImage(img, to: out)
                DispatchQueue.main.async { status = ok ? "Saved \(out.lastPathComponent)" : "Export failed" }
            } else {
                DispatchQueue.main.async { status = "Resize failed" }
            }
        }
    }
}

// MARK: - Instant Alpha sheet

struct InstantAlphaSheet: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let photoID: Int64
    @State private var cutout: NSImage?
    @State private var busy = false
    @State private var status = ""

    var photo: Photo? { library.photos.first { $0.id == photoID } }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Instant Alpha — Remove Background", systemImage: "wand.and.stars")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }
            Divider()
            if let cutout {
                Image(nsImage: cutout).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 320)
                    .background {
                        Checkerboard().clipShape(RoundedRectangle(cornerRadius: 10))
                    }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "wand.and.stars").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
                    Text(busy ? "Finding the subject…" : "Creates a transparent PNG of the subject (Vision).")
                        .font(.callout).foregroundStyle(.secondary)
                    if status.isEmpty { } else { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxHeight: 320)
            }
            HStack {
                Button(busy ? "Working…" : "Remove Background") { run() }
                    .buttonStyle(.borderedProminent).disabled(busy || photo == nil)
                Button("Export PNG…") { doExport() }
                    .buttonStyle(.bordered).disabled(cutout == nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private func run() {
        guard let p = photo else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let img = InstantAlpha.cutout(path: p.path)
            DispatchQueue.main.async {
                cutout = img
                busy = false
                status = img == nil ? "No subject found (try a clearer photo)." : "Cutout ready — export as PNG."
            }
        }
    }

    private func doExport() {
        guard let cutout, let p = photo else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Save PNG"
        panel.message = "Choose a folder for the transparent PNG"
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        panel.directoryURL = pics.appendingPathComponent("Galleria Exports", isDirectory: true)
        guard panel.runModal() == .OK, let dest = panel.url ?? panel.directoryURL else { return }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let out = dest.appendingPathComponent("\(p.filename)-cutout.png")
        let ok = Editor.writeImage(cutout, to: out)
        status = ok ? "Saved \(out.lastPathComponent)" : "Export failed"
    }
}

private struct Checkerboard: View {
    var body: some View {
        GeometryReader { geo in
            let s: CGFloat = 16
            VStack(spacing: 0) {
                ForEach(0..<Int(geo.size.height / s), id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<Int(geo.size.width / s), id: \.self) { col in
                            Color((row + col) % 2 == 0 ? .white.opacity(0.5) : .black.opacity(0.15))
                                .frame(width: s, height: s)
                        }
                    }
                }
            }
        }
    }
}
