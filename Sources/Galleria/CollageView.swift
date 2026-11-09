import SwiftUI
import AppKit

/// Picasa-style Collage maker: Grid / Picture-in-Picture / Mosaic / Freestyle,
/// spacing, borders, background, canvas, caption, PIP size/position, shuffle,
/// preview live and export to ~/Pictures/Galleria Exports/Collages.
struct CollageView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let photoIDs: [Int64]

    @State private var recipe = CollageRecipe.default
    @State private var preview: CollageEngine.Result?
    @State private var status = ""
    @State private var photos: [Photo] = []
    @State private var isRendering = false
    @State private var selectedCellKey: String?
    @State private var pinchBase: (String, Double)?
    @State private var renderPending = 0

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: the layout is a row of icons here instead of a
            // dropdown, and every action is a single-tap icon button.
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Label("Collage Maker", systemImage: "square.grid.2x2")
                        .font(.title3.weight(.semibold))

                    Spacer()

                    Text(photos.isEmpty ? "No selection" : "\(photos.count) photos")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    topButton("folder", "Pick a folder of photos", disabled: isRendering) {
                        pickFolder()
                    }
                    topButton("shuffle", "Shuffle photo order", disabled: photos.count < 2) {
                        photos.shuffle()
                        renderSoon()
                    }
                    topButton("arrow.clockwise", "Refresh preview") {
                        renderSoon()
                    }
                    topButton("square.and.arrow.up",
                              "Export Collage (.jpg)…",
                              disabled: photos.isEmpty || isRendering) {
                        exportCollage()
                    }
                    topButton("xmark", "Close") { dismiss() }
                }

                // Style bar: layout, canvas and colours as one-tap controls.
                HStack(spacing: 12) {
                    HStack(spacing: 3) {
                        ForEach(CollageLayout.allCases, id: \.rawValue) { l in
                            styleButton(active: recipe.layout == l,
                                        symbol: layoutIcon(l),
                                        help: l.displayName) {
                                recipe.layout = l
                            }
                        }
                    }
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(0.05)))

                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 20)

                    Picker("Canvas", selection: $recipe.canvasAspect) {
                        Text("Square").tag("square")
                        Text("4:3").tag("4:3")
                        Text("16:9").tag("16:9")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 205)

                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 1, height: 20)

                    HStack(spacing: 6) {
                        ForEach(borderChoices, id: \.hex) { c in
                            swatch(color: c.color,
                                   hollow: false,
                                   selected: recipe.borderColor == c.hex,
                                   help: "Border \(c.name)") {
                                recipe.borderColor = c.hex
                            }
                        }
                    }

                    HStack(spacing: 5) {
                        ForEach(backgroundChoices, id: \.hex) { bg in
                            swatch(color: bg.color,
                                   hollow: bg.hex == "none",
                                   selected: recipe.background == bg.hex,
                                   help: "Background \(bg.name)") {
                                recipe.background = bg.hex
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            HSplitView {
                // Controls — frosted panel (scrollable, always reachable)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Layout — icons in the top bar")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if recipe.layout == .pictureInPicture {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("PIP size")
                                        .font(.callout)
                                    Spacer()
                                    Text("\(Int(recipe.pipSize * 100))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $recipe.pipSize, in: 0.15...0.6, step: 0.01)
                                HStack {
                                    Text("PIP X")
                                        .font(.caption)
                                    Text("Y")
                                        .font(.caption)
                                    Spacer()
                                }
                                HStack(spacing: 8) {
                                    Slider(value: $recipe.pipX, in: 0.1...0.9, step: 0.01)
                                    Slider(value: $recipe.pipY, in: 0.1...0.9, step: 0.01)
                                }
                                .controlSize(.small)
                            }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Spacing (gaps)")
                                    .font(.callout)
                                Spacer()
                                Text("\(Int(recipe.spacing)) pt")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $recipe.spacing, in: 0...32, step: 1)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Corner radius")
                                    .font(.callout)
                                Spacer()
                                Text("\(Int(recipe.cornerRadius)) pt")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $recipe.cornerRadius, in: 0...24, step: 1)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Borders")
                                    .font(.callout)
                                Spacer()
                                Text("\(Int(recipe.borderWidth)) pt")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $recipe.borderWidth, in: 0...12, step: 1)
                            Text("Border colour: swatches in the top bar")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Caption (Picasa title band)")
                                .font(.callout)
                            TextField("e.g. Summer 2026 — Family Trip", text: $recipe.caption)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)
                        }

                        // Per-photo crop: pick what part of each photo shows.
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Per-photo crop")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if photos.isEmpty {
                                Text("Pick photos to adjust them.")
                                    .font(.caption2).foregroundStyle(.secondary)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(Array(photos.enumerated()), id: \.element.id) { i, p in
                                            CellThumb(photo: p,
                                                      selected: selectedCellKey == String(p.id) ? true
                                                        : (selectedCellKey == nil && i == 0),
                                                      tag: i + 1) {
                                                selectedCellKey = String(p.id)
                                            }
                                        }
                                    }
                                }
                                if let key = selectedCellKey ?? photos.first.map({ String($0.id) }), !key.isEmpty {
                                    let adj = recipe.cells[key] ?? CollageCellAdjust()
                                    Picker("Tile fill", selection: Binding(
                                        get: { adj.fit },
                                        set: { fit in mutCell(key) { $0.fit = fit } })) {
                                        Text("Fill tile").tag(false)
                                        Text("Fit whole photo").tag(true)
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(width: 220)

                                    HStack {
                                        Text("Zoom").font(.callout)
                                        Spacer()
                                        Text(String(format: "%.2fx", adj.zoom))
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Slider(value: Binding(
                                        get: { adj.zoom }, set: { v in mutCell(key) { $0.zoom = v } }), in: 1...3)

                                    HStack {
                                        Text("Crop X").font(.caption)
                                        Slider(value: Binding(
                                            get: { adj.panX }, set: { v in mutCell(key) { $0.panX = v } }), in: 0...1)
                                    }
                                    HStack {
                                        Text("Crop Y").font(.caption)
                                        Slider(value: Binding(
                                            get: { adj.panY }, set: { v in mutCell(key) { $0.panY = v } }), in: 0...1)
                                    }

                                    HStack(spacing: 8) {
                                        Button {
                                            mutCell(key) { $0.quarterTurns = (($0.quarterTurns + 3) % 4) }
                                        } label: {
                                            Image(systemName: "rotate.left")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        Button {
                                            mutCell(key) { $0.quarterTurns = ($0.quarterTurns + 1) % 4 }
                                        } label: {
                                            Image(systemName: "rotate.right")
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        Spacer()
                                        Button("Crop reset", role: .destructive) {
                                            recipe.cells[key] = nil
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }

                                    Text("Drag inside a photo in the preview to choose the crop, pinch or pull Zoom to fill it better.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }

                        // Polish
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Polish")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Toggle("Tile drop shadows", isOn: $recipe.shadow)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }

                        // Library source
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Library source")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Button("Pick photos…") { pickPhotos() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                Button("Pick folder…") { pickFolder() }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                            Text("A folder loads every photo inside it, filename order.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }

                        if !status.isEmpty {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }

                        Text("Picasa tips: Grid for clean rows, Mosaic for a hero + strip, Picture-in-Picture for a small inset over a backdrop, Freestyle for offset rows. Originals are never modified.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if photos.isEmpty {
                            Text("You opened the collage maker with no selection — use “Library source” above to start.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
                .frame(width: 320)

                // Preview with an invisible per-cell overlay: drag to choose
                // the crop, pinch to zoom, tap to select the photo.
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let result = preview, let bitmap = result.image {
                        GeometryReader { geo in
                            let canvas = result.plan.canvasSize
                            let cells = result.plan.cells
                            let scale = min((geo.size.width - 48) / max(canvas.width, 1),
                                            (geo.size.height - 48) / max(canvas.height, 1))
                            let dispW = canvas.width * scale
                            let dispH = canvas.height * scale
                            let ox = (geo.size.width - dispW) / 2
                            let oy = (geo.size.height - dispH) / 2
                            ZStack(alignment: .topLeading) {
                                Image(nsImage: bitmap)
                                    .resizable()
                                    .frame(width: dispW, height: dispH)
                                    .offset(x: ox, y: oy)
                                ForEach(0..<min(photos.count, cells.count), id: \.self) { i in
                                    let r = cells[i]
                                    let cellW = max(0, r.width) * scale
                                    let cellH = max(0, r.height) * scale
                                    CropCellOverlay(
                                        selected: selectedCellKey == result.keys[i],
                                        indexLabel: photoName(i),
                                        onDrag: { t in
                                            handleCellPan(key: result.keys[i], index: i,
                                                          scale: scale, translation: t)
                                        },
                                        onMagnify: { m in
                                            let key = result.keys[i]
                                            if pinchBase?.0 != key {
                                                pinchBase = (key, recipe.cells[key]?.zoom ?? 1)
                                            }
                                            let base = pinchBase?.1 ?? 1
                                            mutCell(key) { $0.zoom = base * m }
                                        },
                                        onEnd: { pinchBase = nil },
                                        onTap: { selectedCellKey = result.keys[i] })
                                        .frame(width: cellW, height: cellH)
                                        .offset(x: ox + r.minX * scale,
                                                y: oy + (canvas.height - r.maxY) * scale)
                                }
                            }
                        }
                        .padding(24)
                    } else {
                        VStack(spacing: 10) {
                            Image(systemName: "photo.stack")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("Select photos to see your collage")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if isRendering {
                        ProgressView().controlSize(.large)
                    }
                }
                .frame(minWidth: 480, minHeight: 420)
            }
        }
        .frame(width: 960, height: 660)
        .onAppear { resolvePhotos(); renderSoon() }
        .onChange(of: recipe) { _, _ in renderSoon() }
    }

    // MARK: - Top-bar controls

    private struct NamedColor {
        let name: String
        let hex: String
        let color: Color
    }

    private var borderChoices: [NamedColor] {
        [NamedColor(name: "Black", hex: "black", color: .black),
         NamedColor(name: "White", hex: "white", color: .white),
         NamedColor(name: "Grey", hex: "grey", color: Color(white: 0.75))]
    }

    private var backgroundChoices: [NamedColor] {
        [NamedColor(name: "White", hex: "white", color: .white),
         NamedColor(name: "Black", hex: "black", color: .black),
         NamedColor(name: "Transparent", hex: "none", color: .clear),
         NamedColor(name: "Grey", hex: "#E8E8E8", color: hexColor("#E8E8E8")),
         NamedColor(name: "Blue", hex: "#4A90D9", color: hexColor("#4A90D9")),
         NamedColor(name: "Warm", hex: "#F5E6CC", color: hexColor("#F5E6CC")),
         NamedColor(name: "Rose", hex: "#F5D5D5", color: hexColor("#F5D5D5"))]
    }

    private func layoutIcon(_ layout: CollageLayout) -> String {
        switch layout {
        case .grid: return "square.grid.2x2.fill"
        case .pictureInPicture: return "rectangle.on.rectangle.fill"
        case .mosaic: return "rectangle.split.2x1"
        case .freestyle: return "square.on.square"
        }
    }

    /// Circular icon action button for the collage top bar.
    private func topButton(_ symbol: String, _ help: String,
                           disabled: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.primary)
        .opacity(disabled ? 0.35 : 1)
        .disabled(disabled)
        .help(help)
    }

    /// Selectable icon (layout styles) with an accent-backed active state.
    private func styleButton(active: Bool, symbol: String, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? Color.accentColor : Color.primary.opacity(0.06)))
                .foregroundStyle(active ? Color.white : Color.primary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Small colour circle; gets an accent ring when selected.
    private func swatch(color: Color, hollow: Bool, selected: Bool,
                        help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                if hollow {
                    Circle()
                        .fill(.thinMaterial)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 0.8))
                } else {
                    Circle().fill(color)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                }
                if selected {
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-2)
                }
            }
            .frame(width: 16, height: 16)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func hexColor(_ hex: String) -> Color {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    private func resolvePhotos() {
        guard !photoIDs.isEmpty else { return }
        var found = library.photos.filter { photoIDs.contains($0.id) }
        if found.isEmpty {
            // Grid may be filtered or not yet refreshed — fall back to a
            // direct DB lookup so the selection is never lost.
            found = library.photos(withIDs: photoIDs)
        }
        photos = found
    }

    /// Coalesces bursts of recipe changes (sliders, drags) into one render.
    private func renderSoon() {
        guard !photos.isEmpty else { return }
        renderPending += 1
        let gen = renderPending
        isRendering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard gen == renderPending else { return }
            renderNow()
        }
    }

    private func renderNow() {
        isRendering = true
        let paths = photos.map(\.path)
        let ids = photos.map(\.id)
        let rec = recipe
        DispatchQueue.global(qos: .userInitiated).async {
            var images: [NSImage] = []
            for (i, p) in paths.enumerated() {
                let r = LibraryStore.shared.loadEdit(for: ids[i])
                if let img = Editor.render(path: p, recipe: r, maxPixel: 900) { images.append(img) }
            }
            let out = CollageEngine.render(images: images, keys: ids.map(String.init), recipe: rec)
            DispatchQueue.main.async {
                preview = out
                isRendering = false
            }
        }
    }

    /// Adjusted cell math shared by the drag overlay and the sidebar controls.
    private func mutCell(_ key: String, _ change: (inout CollageCellAdjust) -> Void) {
        var adj = recipe.cells[key] ?? CollageCellAdjust()
        change(&adj)
        adj.zoom = min(3, max(1, adj.zoom))
        adj.panX = min(1, max(0, adj.panX))
        adj.panY = min(1, max(0, adj.panY))
        recipe.cells[key] = adj
    }

    private let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif",
                                   "webp", "gif", "bmp", "avif"]

    /// Loads every photo in a chosen folder, filename order, ready for collage.
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = "Use Folder"
        panel.message = "Choose a folder of photos for the collage"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folderPath = LibraryStore.canonical(url).path
        status = "Indexing \(url.lastPathComponent)…"
        // Handing the library one file indexes the whole folder in the background.
        let files = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let first = files.first else {
            status = "No photos found in that folder"
            return
        }
        library.openPhoto(at: first)
        collectFolderPhotos(folderPath, attempt: 1)
    }

    private func collectFolderPhotos(_ folderPath: String, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            let items = library.photos
                .filter { $0.folder == folderPath }
                .sorted { $0.filename < $1.filename }
            if !items.isEmpty {
                photos = items
                selectedCellKey = nil
                let name = folderPath.split(separator: "/").last.map(String.init) ?? "folder"
                status = "Loaded \(items.count) photos from “\(name)”"
                renderSoon()
            } else if attempt < 4 {
                collectFolderPhotos(folderPath, attempt: attempt + 1)
            } else {
                status = "No photos found in that folder"
            }
        }
    }

    /// Drag-to-crop: view translation mapped into engine pan units 1:1 using
    /// the overflow the engine itself reported for that tile.
    private func handleCellPan(key: String, index: Int, scale: CGFloat, translation: CGSize) {
        guard let result = preview, index < result.overflows.count, scale > 0.0001 else { return }
        let (ovw, ovh) = result.overflows[index]
        mutCell(key) { adj in
            if ovw > 1 { adj.panX += CGFloat(translation.width) / scale / ovw }
            if ovh > 1 { adj.panY -= CGFloat(translation.height) / scale / ovh }
        }
    }

    private func photoName(_ i: Int) -> String {
        i < photos.count ? photos[i].filename : ""
    }

    private func pickPhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        // Index each folder so thumbnails/links exist, then show them.
        for u in urls { library.openPhoto(at: u) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            photos = library.photos.filter { urls.map(\.path).contains($0.path) }
            renderSoon()
        }
    }

    private func exportCollage() {
        guard let preview else { return }
        let panels = NSOpenPanel()
        panels.canChooseDirectories = true
        panels.canChooseFiles = false
        panels.canCreateDirectories = true
        panels.prompt = "Save Here"
        panels.nameFieldStringValue = "Collage.jpg"
        panels.message = "Choose a folder for your collage"
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        panels.directoryURL = pictures.appendingPathComponent("Galleria Exports", isDirectory: true)
        guard panels.runModal() == .OK, let dest = panels.url ?? panels.directoryURL else { return }
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")
        let out = dest.appendingPathComponent("Collage-\(dateStr).jpg")
        status = "Rendering full size…"
        isRendering = true
        let hiPhotos = photos
        let hiRecipe = recipe
        DispatchQueue.global(qos: .userInitiated).async {
            var hiImages: [NSImage] = []
            for p in hiPhotos {
                let r = LibraryStore.shared.loadEdit(for: p.id)
                if let img = Editor.render(path: p.path, recipe: r, maxPixel: 2600) {
                    hiImages.append(img)
                }
            }
            let result = CollageEngine.render(images: hiImages,
                                              keys: hiPhotos.map { String($0.id) },
                                              recipe: hiRecipe,
                                              canvas: CGSize(width: 4000, height: 4000))
            var ok = false
            if let hi = result.image {
                ok = Editor.writeImage(hi, to: out)
            }
            DispatchQueue.main.async {
                status = ok ? "Saved full-size copy to \(out.lastPathComponent)" : "Export failed"
                isRendering = false
            }
        }
    }
}

// MARK: - Collage pieces

/// Invisible per-tile interaction surface on the preview: drag chooses the
/// crop, pinch zooms, tap selects. A hairline marks the active tile.
private struct CropCellOverlay: View {
    let selected: Bool
    let indexLabel: String
    let onDrag: (CGSize) -> Void
    let onMagnify: (CGFloat) -> Void
    let onEnd: () -> Void
    let onTap: () -> Void

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) {
                Text(indexLabel)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(4)
                    .opacity(selected ? 1 : 0.6)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.18),
                                  lineWidth: selected ? 2.5 : 1)
                    .allowsHitTesting(false)
            }
            .onTapGesture { onTap() }
            .gesture(DragGesture(minimumDistance: 3).onChanged { onDrag($0.translation) })
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { onMagnify($0) }
                    .onEnded { _ in onEnd() }
            )
    }
}

/// Miniature with a number badge, used by the per-photo crop strip.
private struct CellThumb: View {
    let photo: Photo
    let selected: Bool
    let tag: Int
    let action: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .underPageBackgroundColor))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: selected ? 2.5 : 1)
            }
            .overlay(alignment: .topLeading) {
                Text("\(tag)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
        .task(id: photo.id) {
            image = await ThumbnailService.shared.thumbnail(path: photo.path, mtime: photo.mtime, size: 128)
        }
    }
}
