import SwiftUI
import AppKit
import Vision
import ImageIO

/// Preview-style tools: Resize, Instant Alpha (remove background), Markup helpers,
/// Copy/Paste style — compact like Preview's Tools / Adjust Size.

enum RetouchMode: String {
    case keep, erase
}

struct RetouchStroke: Identifiable {
    let id = UUID()
    var mode: RetouchMode
    /// Points normalised to the image (0...1), top-left origin.
    var points: [CGPoint]
}

enum InstantAlpha {
    /// Result background after the subject is lifted.
    enum Background: Equatable {
        case transparent
        case color(NSColor)

        static func == (lhs: Background, rhs: Background) -> Bool {
            switch (lhs, rhs) {
            case (.transparent, .transparent): return true
            case (.color(let a), .color(let b)): return a == b
            default: return false
            }
        }
    }

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
    /// This is Apple's offline subject-lift AI (the engine behind Photos'
    /// "Lift Subject") — no uploads, no accounts.
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

    /// Flattens a transparent cutout onto a solid background colour, keeping
    /// the cutout's pixel size. Nil background returns the cutout unchanged.
    /// `strokes` are optional manual refinements: "keep" restores opacity in
    /// areas the AI missed, "erase" removes areas you don't want.
    static func flattened(_ cutout: NSImage, background: Background,
                          strokes: [RetouchStroke] = []) -> NSImage {
        let base = strokes.isEmpty ? cutout : retouched(cutout, with: strokes)
        guard case .color(let color) = background else { return base }
        let size = base.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return cutout }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        base.draw(in: NSRect(origin: .zero, size: size),
                  from: NSRect(origin: .zero, size: size),
                  operation: .sourceOver, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return cutout }
        return NSImage(cgImage: cg, size: size)
    }

    /// Paints the user's Keep / Erase strokes into the cutout's alpha channel.
    static func retouched(_ cutout: NSImage, with strokes: [RetouchStroke]) -> NSImage {
        guard let cg = cutout.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return cutout }
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return cutout }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(CGFloat(max(8, w / 160)))   // ~1.6 cm brush at export size
        for stroke in strokes where stroke.points.count > 1 {
            if stroke.mode == .erase {
                ctx.setBlendMode(.clear)
            } else {
                ctx.setBlendMode(.normal)
                ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
            }
            ctx.beginPath()
            for (i, pt) in stroke.points.enumerated() {
                // Image points are normalised from the top-left; CG's bitmap
                // context has its origin in the bottom-left.
                let p = CGPoint(x: pt.x * CGFloat(w), y: (1 - pt.y) * CGFloat(h))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.strokePath()
        }
        guard let out = ctx.makeImage() else { return cutout }
        return NSImage(cgImage: out, size: cutout.size)
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

// MARK: - Remove Background sheet (PhotoRoom-style)

/// PhotoRoom-style flow: the sheet opens on the already-selected photo(s) and
/// immediately lifts the subject with Apple's offline AI. Then pick a
/// background — transparent, white, black or a custom colour — and save. Saved
/// PNGs land in the watched "Galleria Exports" folder, so they appear in the
/// library a couple of seconds later. Works on multi-selection: one run
/// processes every selected photo.
struct RemoveBackgroundSheet: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let photoIDs: [Int64]

    @State private var results: [Int64: NSImage] = [:]
    @State private var currentID: Int64?
    @State private var busy = false
    @State private var status = ""
    @State private var background: InstantAlpha.Background = .transparent
    @State private var customColor: Color = .white
    /// Manual refinement: paint over missed areas to Keep, or unwanted areas
    /// to Erase. Stored normalised so each photo in a batch can reuse them.
    @State private var retouchMode: RetouchMode? = nil
    @State private var strokes: [RetouchStroke] = []
    @State private var activeStroke: RetouchStroke?

    private var photos: [Photo] {
        photoIDs.compactMap { id in library.photos.first { $0.id == id } }
    }

    private var current: Photo? {
        photos.first { $0.id == currentID } ?? photos.first
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Remove Background", systemImage: "wand.and.stars")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Offline AI — your photo never leaves this Mac")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Close") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }
            Divider()

            if photos.count > 1 {
                HStack {
                    Text("Batch — \(doneCount) of \(photos.count) ready")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
            }

            previewArea

            retouchBar

            backgroundPicker

            HStack {
                Button("Save to Library") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || readyCount == 0)
                Button("Export PNG…") { doExport() }
                    .buttonStyle(.bordered)
                    .disabled(busy || readyCount == 0)
                Spacer()
                Text(status.isEmpty
                     ? (readyCount > 0 ? "\(readyCount) cutout\(readyCount == 1 ? "" : "s") ready" : "Finding the subject…")
                     : status)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(width: 600, height: 560)
        .onAppear { processAll() }
    }

    private var doneCount: Int { results.values.count }
    private var readyCount: Int { doneCount }

    // MARK: preview

    @ViewBuilder
    private var previewArea: some View {
        ZStack {
            Checkerboard().clipShape(RoundedRectangle(cornerRadius: 10))
            if let p = current, let img = results[p.id] {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .bottomTrailing) {
                        if background == .transparent {
                            // Hint that transparency is real, not white.
                            Text("transparent")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.thinMaterial, in: Capsule())
                                .padding(6)
                        }
                    }
                    .overlay {
                        // Paint directly on the preview to refine the AI mask.
                        GeometryReader { geo in
                            let ir = imageRect(container: geo.size, imageSize: img.size)
                            Path { path in
                                for stroke in strokes + [activeStroke].compactMap({ $0 }) {
                                    for (i, pt) in stroke.points.enumerated() {
                                        let q = CGPoint(x: ir.minX + pt.x * ir.width,
                                                        y: ir.minY + pt.y * ir.height)
                                        if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
                                    }
                                }
                            }
                            .stroke(retouchMode == .erase ? Color.red.opacity(0.8) : Color.orange.opacity(0.85),
                                    style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
                            .allowsHitTesting(false)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard let mode = retouchMode else { return }
                                        let nx = (value.location.x - ir.minX) / ir.width
                                        let ny = (value.location.y - ir.minY) / ir.height
                                        let p = CGPoint(x: min(max(nx, 0), 1), y: min(max(ny, 0), 1))
                                        if activeStroke == nil {
                                            activeStroke = RetouchStroke(mode: mode, points: [p])
                                        } else if activeStroke?.points.last != p {
                                            activeStroke?.points.append(p)
                                        }
                                    }
                                    .onEnded { _ in
                                        if let s = activeStroke {
                                            strokes.append(s)
                                            activeStroke = nil
                                            status = "Refined — Save to apply."
                                        }
                                    }
                            )
                        }
                    }
            } else {
                VStack(spacing: 8) {
                    if busy {
                        ProgressView()
                        Text("Finding the subject…")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if let p = current {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                        Text("No subject found in \(p.filename)")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxHeight: 300)
        .overlay(alignment: .bottomLeading) {
            if let p = current {
                Text("\(p.filename)\(photos.count > 1 ? " · \(indexInBatch + 1) of \(photos.count)" : "")")
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .padding(6)
            }
        }
    }

    private var indexInBatch: Int {
        guard let current else { return 0 }
        return photos.firstIndex { $0.id == current.id } ?? 0
    }

    // MARK: manual refinement

    private func imageRect(container: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale, h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2,
                      width: w, height: h)
    }

    private var retouchBar: some View {
        HStack(spacing: 8) {
            Text("Refine").font(.callout).foregroundStyle(.secondary)
            Button {
                retouchMode = retouchMode == .keep ? nil : .keep
            } label: {
                Label("Keep area", systemImage: "hand.draw.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(retouchMode == .keep ? Color.accentColor : nil)
            Button {
                retouchMode = retouchMode == .erase ? nil : .erase
            } label: {
                Label("Erase area", systemImage: "eraser")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(retouchMode == .erase ? Color.red : nil)
            if !strokes.isEmpty {
                Button("Undo") {
                    strokes.removeLast()
                }
                .buttonStyle(.plain).font(.caption)
                Button("Clear") {
                    strokes.removeAll()
                }
                .buttonStyle(.plain).font(.caption)
            }
            Spacer(minLength: 0)
            if retouchMode != nil {
                Text("Drag on the preview").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: background picker

    private struct BackgroundChoice: Identifiable {
        let id = UUID()
        let name: String
        let swatch: Color
        let apply: (RemoveBackgroundSheet) -> Void
    }

    /// Explicit buttons instead of a 4-up segmented control: "Transparent" is
    /// too long for one segment and used to collide with its neighbours.
    private var backgroundChoices: [BackgroundChoice] {
        [BackgroundChoice(name: "Transparent", swatch: Color(white: 0.75).opacity(0.35)) { $0.background = .transparent },
         BackgroundChoice(name: "White", swatch: .white) { $0.background = .color(.white) },
         BackgroundChoice(name: "Black", swatch: .black) { $0.background = .color(.black) },
         BackgroundChoice(name: "Grey", swatch: Color(white: 0.6)) { $0.background = .color(NSColor(white: 0.6, alpha: 1)) },
         BackgroundChoice(name: "Custom", swatch: customColor) { $0.background = .color(NSColor(customColor)) }]
    }

    private var backgroundPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Background").font(.callout)
                Spacer()
                ColorPicker("Custom", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 36)
                    .help("Pick a custom background colour")
            }
            HStack(spacing: 6) {
                ForEach(backgroundChoices) { choice in
                    Button {
                        choice.apply(self)
                    } label: {
                        VStack(spacing: 3) {
                            Circle()
                                .fill(choice.swatch)
                                .frame(width: 15, height: 15)
                                .overlay {
                                    Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                                }
                            Text(choice.name)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isSelected(choice) ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.08))
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .strokeBorder(isSelected(choice) ? Color.accentColor : Color.clear, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: customColor) { _, c in
            background = .color(NSColor(c))
        }
    }

    private func isSelected(_ choice: BackgroundChoice) -> Bool {
        switch background {
        case .transparent: return choice.name == "Transparent"
        case .color(let c):
            if choice.name == "Custom" {
                return c != .white && c != .black && c != NSColor(white: 0.6, alpha: 1)
            }
            return (choice.name == "White" && c == .white)
                || (choice.name == "Black" && c == .black)
                || (choice.name == "Grey" && c == NSColor(white: 0.6, alpha: 1))
        }
    }

    // MARK: processing

    /// Runs on appear, PhotoRoom-style: every selected photo is processed
    /// once, in order; switching backgrounds afterwards is instant because
    /// the transparent cutouts are cached.
    private func processAll() {
        guard !busy else { return }
        busy = true
        status = ""
        let list = photos
        if let first = list.first { currentID = first.id }
        DispatchQueue.global(qos: .userInitiated).async {
            for (i, p) in list.enumerated() {
                DispatchQueue.main.async {
                    currentID = p.id
                    status = photos.count > 1 ? "Processing \(i + 1) of \(list.count)…" : ""
                }
                let img = InstantAlpha.cutout(path: p.path)
                DispatchQueue.main.async {
                    if let img {
                        results[p.id] = img
                    } else {
                        status = "\(p.filename): no subject found — skipped."
                    }
                }
            }
            DispatchQueue.main.async {
                busy = false
                if !results.isEmpty {
                    status = results.count == list.count
                        ? "Done — pick a background and save."
                        : "\(results.count) of \(list.count) cutouts ready."
                }
            }
        }
    }

    // MARK: saving

    private var exportFolder: URL {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pics.appendingPathComponent("Galleria Exports", isDirectory: true)
    }

    /// Saves every ready cutout with the chosen background into the watched
    /// Galleria Exports folder; the library picks the files up automatically.
    private func save() {
        let list = photos.filter { results[$0.id] != nil }
        guard !list.isEmpty else { return }
        try? FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        busy = true
        status = "Saving…"
        let bg = background
        DispatchQueue.global(qos: .userInitiated).async {
            var saved = 0
            for p in list {
                guard let cut = results[p.id] else { continue }
                let img = InstantAlpha.flattened(cut, background: bg, strokes: strokes)
                let stem = (p.filename as NSString).deletingPathExtension
                let out = exportFolder.appendingPathComponent("\(stem)-cutout.png")
                var url = out
                var n = 1
                while FileManager.default.fileExists(atPath: url.path) {
                    url = exportFolder.appendingPathComponent("\(stem)-cutout-\(n).png")
                    n += 1
                }
                if Editor.writeImage(img, to: url) { saved += 1 }
            }
            DispatchQueue.main.async {
                busy = false
                status = "Saved \(saved) file\(saved == 1 ? "" : "s") to Galleria Exports — they'll appear in the library."
            }
        }
    }

    private func doExport() {
        let list = photos.filter { results[$0.id] != nil }
        guard !list.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save PNG"
        panel.message = "Choose a folder for the cutout PNGs"
        panel.directoryURL = exportFolder
        guard panel.runModal() == .OK, let dest = panel.url ?? panel.directoryURL else { return }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        busy = true
        status = "Exporting…"
        let bg = background
        DispatchQueue.global(qos: .userInitiated).async {
            var saved = 0
            for p in list {
                guard let cut = results[p.id] else { continue }
                let img = InstantAlpha.flattened(cut, background: bg, strokes: strokes)
                let stem = (p.filename as NSString).deletingPathExtension
                if Editor.writeImage(img, to: dest.appendingPathComponent("\(stem)-cutout.png")) { saved += 1 }
            }
            DispatchQueue.main.async {
                busy = false
                status = "Exported \(saved) file\(saved == 1 ? "" : "s")."
            }
        }
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
