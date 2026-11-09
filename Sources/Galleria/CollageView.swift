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
    @State private var preview: NSImage?
    @State private var status = ""
    @State private var photos: [Photo] = []
    @State private var isRendering = false

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

                        if !status.isEmpty {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }

                        Text("Picasa tips: Grid for clean rows, Mosaic for a hero + strip, Picture-in-Picture for a small inset over a backdrop, Freestyle for offset rows. Originals are never modified.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if photos.isEmpty {
                            Button("Pick photos…") { pickPhotos() }
                                .buttonStyle(.bordered)
                            Text("You opened the collage maker with no selection. Pick images on disk to start.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(16)
                }
                .frame(width: 320)

                // Preview
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    if let preview {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(24)
                            .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
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

    private func renderSoon() {
        guard !photos.isEmpty else { return }
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
            let out = CollageEngine.render(images: images, recipe: rec)
            DispatchQueue.main.async {
                preview = out
                isRendering = false
            }
        }
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
        status = "Exporting…"
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Editor.writeImage(preview, to: out)
            DispatchQueue.main.async {
                status = ok ? "Saved to \(out.lastPathComponent)" : "Export failed"
            }
        }
    }
}
