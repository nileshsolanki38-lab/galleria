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
            HStack {
                Label("Collage Maker", systemImage: "square.grid.2x2")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(photos.isEmpty ? "No selection" : "\(photos.count) photos")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(16)

            Divider()

            HSplitView {
                // Controls — frosted panel (scrollable, always reachable)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Layout")
                            .font(.subheadline.weight(.semibold))
                        Picker("Layout", selection: $recipe.layout) {
                            ForEach(CollageLayout.allCases, id: \.rawValue) { l in
                                Text(l.displayName).tag(l)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()

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
                            Picker("Border color", selection: $recipe.borderColor) {
                                Text("Black").tag("black")
                                Text("White").tag("white")
                                Text("Grey").tag("grey")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        HStack(spacing: 10) {
                            Text("Canvas")
                                .font(.callout)
                            Spacer()
                            Picker("Canvas", selection: $recipe.canvasAspect) {
                                Text("Square").tag("square")
                                Text("4:3").tag("4:3")
                                Text("16:9").tag("16:9")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        HStack(spacing: 10) {
                            Text("Background")
                                .font(.callout)
                            Spacer()
                            Picker("Background", selection: $recipe.background) {
                                Text("White").tag("white")
                                Text("Black").tag("black")
                                Text("None (transparent)").tag("none")
                                Text("Grey").tag("#E8E8E8")
                                Text("Blue").tag("#4A90D9")
                                Text("Warm").tag("#F5E6CC")
                                Text("Rose").tag("#F5D5D5")
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Caption (Picasa title band)")
                                .font(.callout)
                            TextField("e.g. Summer 2026 — Family Trip", text: $recipe.caption)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)
                        }

                        HStack(spacing: 8) {
                            Button {
                                photos.shuffle()
                                renderSoon()
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(photos.count < 2)
                            Button {
                                renderSoon()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Divider()

                        Button {
                            exportCollage()
                        } label: {
                            Label(isRendering ? "Rendering…" : "Export Collage (.jpg)…", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(photos.isEmpty || isRendering)

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

    private func resolvePhotos() {
        if photoIDs.isEmpty { return }
        photos = library.photos.filter { photoIDs.contains($0.id) }
        if photos.isEmpty {
            // Selection may have changed; use the current grid order filter.
            photos = library.photos.filter { photoIDs.contains($0.id) }
        }
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
