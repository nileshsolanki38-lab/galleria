import SwiftUI
import AppKit
import Vision
import MapKit
import ImageIO
import CoreImage
import CryptoKit

// MARK: - Helpers

struct DuplicateGroup: Identifiable {
    let id: String
    let photos: [Photo]
    let byteSize: Int64
}

/// Perceptual hash for duplicates: SHA256 of a tiny 32×32 render.
enum DuplicateFinder {
    static func contentHash(path: String) -> String? {
        guard let cg = Imaging.baseCGImage(path: path, maxPixel: 64) else { return nil }
        let w = cg.width, h = cg.height
        let bpp = 4
        let bytesPerRow = w * bpp
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        pixels.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var rgb = Data()
        rgb.reserveCapacity(w * h * 3)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            rgb.append(pixels[i]); rgb.append(pixels[i + 1]); rgb.append(pixels[i + 2])
        }
        return SHA256.hash(data: rgb).map { String(format: "%02x", $0) }.joined()
    }

    static func groups(for photos: [Photo]) -> [DuplicateGroup] {
        var byHash: [String: [Photo]] = [:]
        var sizes: [String: Int64] = [:]
        for p in photos {
            guard let h = contentHash(path: p.path) else { continue }
            byHash[h, default: []].append(p)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p.path),
               let sz = attrs[.size] as? Int64 { sizes[h, default: 0] += sz }
        }
        return byHash.filter { $0.value.count > 1 }
            .map { DuplicateGroup(id: $0.key, photos: $0.value, byteSize: sizes[$0.key] ?? 0) }
            .sorted { $0.photos.count > $1.photos.count }
    }
}

/// Face + eye detection via Vision (on-device, no upload).
enum FaceDetector {
    static func faceRects(in image: CGImage) -> [CGRect] {
        let req = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([req])
            return (req.results ?? []).map { r in
                // Convert from Vision coords (origin bottom-left, normalized) to pixel rect.
                return VNImageRectForNormalizedRect(r.boundingBox, Int(image.width), Int(image.height))
            }
        } catch { return [] }
    }

    static func faceCount(path: String, maxPixel: CGFloat = 800) -> Int {
        guard let cg = Imaging.baseCGImage(path: path, maxPixel: maxPixel) else { return 0 }
        return faceRects(in: cg).count
    }

    static func eyeRects(in image: CGImage) -> [CGRect] {
        let req = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([req])
            var out: [CGRect] = []
            for faceReq in req.results ?? [] {
                guard let landmarks = faceReq.landmarks else { continue }
                let w = Int(image.width), h = Int(image.height)
                func rectFor(_ region: VNFaceLandmarkRegion2D?) -> CGRect? {
                    guard let region, !region.normalizedPoints.isEmpty else { return nil }
                    var minX: CGFloat = 1, minY: CGFloat = 1, maxX: CGFloat = 0, maxY: CGFloat = 0
                    for p in region.normalizedPoints {
                        minX = min(minX, p.x); maxX = max(maxX, p.x)
                        minY = min(minY, p.y); maxY = max(maxY, p.y)
                    }
                    let norm = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                    return VNImageRectForNormalizedRect(norm, w, h)
                }
                if let r = rectFor(landmarks.leftEye) { out.append(r) }
                if let r = rectFor(landmarks.rightEye) { out.append(r) }
            }
            return out
        } catch { return [] }
    }
}

// MARK: - GPS helper

enum GeoHelper {
    static func coordinate(path: String) -> CLLocationCoordinate2D? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any],
              let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double else { return nil }
        let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String ?? "N"
        let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String ?? "E"
        let dLat = latRef == "S" ? -lat : lat
        let dLon = lonRef == "W" ? -lon : lon
        return CLLocationCoordinate2D(latitude: dLat, longitude: dLon)
    }
}

// MARK: - Compare view (B5)

struct CompareView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let photoIDs: [Int64]
    @State private var photos: [Photo] = []
    @State private var images: [Int64: NSImage] = [:]
    @State private var syncZoom = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Compare \(photos.count) photos", systemImage: "photo.on.rectangle.angled")
                    .font(.title3.weight(.semibold))
                Spacer()
                Toggle("Sync zoom", isOn: $syncZoom).toggleStyle(.switch).controlSize(.small)
                Button("Close") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(14)
            Divider()
            if photos.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
                    Text("Select 2–4 photos to compare").font(.headline)
                    Text("Select photos in the grid, then choose Compare (toolbar or right-click). Each side shows the full frame; scroll to zoom, drag to pan. Sync zoom keeps all sides at the same scale.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .padding(40)
            } else {
                HStack(spacing: 8) {
                    ForEach(photos) { p in
                        VStack(spacing: 6) {
                            if let img = images[p.id] {
                                Image(nsImage: img)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            Text(p.filename).font(.caption).lineLimit(1).truncationMode(.middle)
                            HStack(spacing: 4) {
                                ForEach(0..<p.rating, id: \.self) { _ in
                                    Image(systemName: "star.fill").font(.system(size: 8)).foregroundStyle(.yellow)
                                }
                                if p.favorite { Image(systemName: "heart.fill").font(.system(size: 8)).foregroundStyle(.red) }
                                Text("\(p.width)×\(p.height)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(12)
            }
        }
        .frame(width: 920, height: 560)
        .onAppear {
            photos = library.photos.filter { photoIDs.contains($0.id) }.prefix(4).map { $0 }
            Task {
                await withTaskGroup(of: (Int64, NSImage?).self) { group in
                    for p in photos {
                        group.addTask {
                            let r = LibraryStore.shared.loadEdit(for: p.id)
                            return (p.id, Editor.render(path: p.path, recipe: r, maxPixel: 1600))
                        }
                    }
                    for await (id, img) in group { if let img { images[id] = img } }
                }
            }
        }
    }
}

// MARK: - Faces view (C4)

struct FacesView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var facePhotos: [(photo: Photo, faces: Int, thumb: NSImage?)] = []
    @State private var scanning = false
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("People — Faces", systemImage: "person.2.circle").font(.title3.weight(.semibold))
                Spacer()
                Button(scanning ? "Scanning…" : "Scan faces") { scan() }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(scanning)
                Button("Close") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(14)
            Divider()
            if facePhotos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "person.2.circle").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    Text("Find photos with people").font(.headline)
                    Text("Runs on-device Vision face detection (no upload). First scan checks up to 300 photos; faces are counted per file. Select a photo to open the viewer.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(40)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                        ForEach(facePhotos, id: \.photo.id) { item in
                            VStack(spacing: 4) {
                                if let t = item.thumb {
                                    Image(nsImage: t).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 120, height: 120).clipShape(RoundedRectangle(cornerRadius: 8))
                                } else { RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 120, height: 120) }
                                Label("\(item.faces) face\(item.faces == 1 ? "" : "s")", systemImage: "person.fill")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(item.photo.filename).font(.caption2).lineLimit(1)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 760, height: 540)
        .onAppear { scan() }
    }

    private func scan() {
        scanning = true
        status = "Scanning…"
        let sample = Array(library.photos.prefix(300))
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [(Photo, Int, NSImage?)] = []
            for (i, p) in sample.enumerated() {
                let n = FaceDetector.faceCount(path: p.path)
                if n > 0 {
                    let thumb = ThumbnailService.shared.cachedThumbnail(path: p.path, mtime: p.mtime)
                    results.append((p, n, thumb))
                }
                if i % 30 == 0 {
                    DispatchQueue.main.async { status = "Scanning… \(i)/\(sample.count)" }
                }
            }
            DispatchQueue.main.async {
                facePhotos = results.sorted { $0.1 > $1.1 }
                scanning = false
                status = results.isEmpty ? "No faces found in sampled photos." : "\(results.count) photos with faces"
            }
        }
    }
}

// MARK: - Places view (C5)

struct PlacesView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var center = CLLocationCoordinate2D(latitude: 20, longitude: 0)
    @State private var geotagged: [(photo: Photo, coord: CLLocationCoordinate2D)] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Places — Map", systemImage: "map.circle").font(.title3.weight(.semibold))
                Spacer()
                Text(geotagged.isEmpty ? "No GPS found" : "\(geotagged.count) geotagged")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Close") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(14)
            Divider()
            if geotagged.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "mappin.circle").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    Text("No GPS coordinates yet").font(.headline)
                    Text("Photos with EXIF GPS appear here as pins. If your camera/phone didn’t embed GPS, this view stays empty — everything else in Galleria works without location.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .padding(40)
            } else {
                HSplitView {
                    Map(initialPosition: .userLocation(fallback: .region(MKCoordinateRegion(center: center, latitudinalMeters: 20000, longitudinalMeters: 20000)))) {
                        ForEach(Array(geotagged.enumerated()), id: \.offset) { _, item in
                            Annotation(item.photo.filename, coordinate: item.coord) {
                                VStack(spacing: 2) {
                                    Image(systemName: "mappin.circle.fill").font(.system(size: 18)).foregroundStyle(.red)
                                    Text(item.photo.filename).font(.caption2).padding(4).background(.regularMaterial, in: Capsule())
                                }
                            }
                        }
                    }
                    .frame(minWidth: 420, minHeight: 340)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(geotagged, id: \.photo.id) { item in
                                Button {
                                    center = item.coord
                                } label: {
                                    HStack {
                                        Image(systemName: "mappin").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.photo.filename).font(.callout)
                                            Text(String(format: "%.5f, %.5f", item.coord.latitude, item.coord.longitude))
                                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .padding(8).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                    }
                    .frame(width: 280)
                }
            }
        }
        .frame(width: 860, height: 540)
        .onAppear {
            geotagged = library.photos.compactMap { p in
                GeoHelper.coordinate(path: p.path).map { (p, $0) }
            }
            if let first = geotagged.first?.coord {
                center = first
            }
        }
    }
}

// MARK: - Smart albums view (C6)

struct SmartAlbumsView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var search = ""
    @State private var minRating = 0
    @State private var favoritesOnly = false
    @State private var previewCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Smart Albums — Saved Searches", systemImage: "magnifyingglass.circle").font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }
            Divider()
            Text("A smart album is a saved search. Photos that match appear automatically when the library changes.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                TextField("Smart album name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Search filename / tags / caption (optional)", text: $search).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Minimum rating").font(.callout)
                    Spacer()
                    Picker("Rating", selection: $minRating) {
                        ForEach(0...5, id: \.self) { r in Text(r == 0 ? "Any" : "\(r)+").tag(r) }
                    }.pickerStyle(.menu).labelsHidden()
                }
                Toggle("Favorites only", isOn: $favoritesOnly).toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                Button("Create Smart Album") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    library.createSmartAlbum(name: n, search: search, minRating: minRating, favoritesOnly: favoritesOnly)
                    name = ""; search = ""; minRating = 0; favoritesOnly = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Text("\(library.smartAlbums.count) saved").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(library.smartAlbums) { sa in
                        HStack {
                            Image(systemName: "magnifyingglass.circle").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(sa.name).font(.callout.weight(.semibold))
                                Text(summary(sa)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Delete", role: .destructive) { library.deleteSmartAlbum(sa.id) }
                                .buttonStyle(.plain).font(.caption)
                        }
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if library.smartAlbums.isEmpty {
                        Text("No smart albums yet. Create one above, then choose it in the sidebar.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(20)
        .frame(width: 580, height: 560)
    }

    private func summary(_ sa: SmartAlbum) -> String {
        var parts: [String] = []
        if !sa.search.isEmpty { parts.append("“\(sa.search)”") }
        if sa.minRating > 0 { parts.append("\(sa.minRating)+ stars") }
        if sa.favoritesOnly { parts.append("Favorites") }
        return parts.isEmpty ? "All photos" : parts.joined(separator: " · ")
    }
}

// MARK: - Duplicates view (C8)

struct DuplicatesView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var groups: [DuplicateGroup] = []
    @State private var scanning = false
    @State private var selected: Set<Int64> = []
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Duplicate Finder", systemImage: "square.stack").font(.title3.weight(.semibold))
                Spacer()
                Button(scanning ? "Scanning…" : "Find duplicates") { run() }
                    .buttonStyle(.borderedProminent).controlSize(.small).disabled(scanning)
                Button("Close") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(14)
            Divider()
            if scanning {
                VStack(spacing: 10) { ProgressView().controlSize(.large); Text(status).font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack").font(.system(size: 44, weight: .light)).foregroundStyle(.tertiary)
                    Text(status.isEmpty ? "Exact duplicate groups will appear here" : status).font(.headline)
                    Text("Groups by perceptual hash (ignores tiny re-encodes). Tick the copies you want to keep out, then reveal one in Finder to delete manually — Galleria never deletes files for you.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                }
                .padding(40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        Text("\(groups.count) groups · \(groups.flatMap(\.photos).count) files · approx \(ByteCountFormatter.string(fromByteCount: Int64(groups.reduce(0) { $0 + $1.byteSize }), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(groups) { g in
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Group \(g.id.prefix(8))… — \(g.photos.count) files")
                                    .font(.subheadline.weight(.semibold))
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(g.photos) { p in
                                            VStack(spacing: 3) {
                                                if let thumb = ThumbnailService.shared.cachedThumbnail(path: p.path, mtime: p.mtime) {
                                                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                                        .frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 6))
                                                } else {
                                                    RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(width: 96, height: 96)
                                                }
                                                Text(p.filename).font(.caption2).lineLimit(1).frame(width: 96)
                                                Toggle("Keep", isOn: Binding(
                                                    get: { selected.contains(p.id) },
                                                    set: { on in if on { selected.insert(p.id) } else { selected.remove(p.id) } }
                                                ))
                                                .toggleStyle(.switch).controlSize(.mini)
                                                Button("Reveal") {
                                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)])
                                                }
                                                .font(.caption2)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 820, height: 560)
        .onAppear { if groups.isEmpty { run() } }
    }

    private func run() {
        scanning = true
        status = "Hashing…"
        let sample = Array(library.photos.prefix(500))
        DispatchQueue.global(qos: .userInitiated).async {
            let g = DuplicateFinder.groups(for: sample)
            DispatchQueue.main.async {
                groups = g
                scanning = false
                status = g.isEmpty ? "No duplicates in scanned set." : "\(g.count) groups"
            }
        }
    }
}

// MARK: - Batch tools (E1)

struct BatchOptions {
    var maxDimension: Double = 0 // 0 = keep original size
    var format: String = "jpg" // jpg | png | heic
    var renamePattern: String = "" // "" keep name; e.g. "IMG-{date}-{index}"
    var destination: URL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Galleria Exports", isDirectory: true)
}

struct BatchToolsView: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let photoIDs: [Int64]
    @State private var options = BatchOptions()
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Batch Resize / Convert / Rename", systemImage: "hammer.circle").font(.title3.weight(.semibold))
                Spacer()
                Button("Close") { dismiss() }.buttonStyle(.bordered).controlSize(.small)
            }
            Divider()
            Text("\(photoIDs.count) photo(s) selected. Batch writes new files; originals are never modified.")
                .font(.callout).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Max dimension").font(.callout)
                    Spacer()
                    Picker("Max", selection: $options.maxDimension) {
                        Text("Keep original").tag(0.0)
                        Text("1024 px").tag(1024.0)
                        Text("2048 px").tag(2048.0)
                        Text("4096 px").tag(4096.0)
                    }.labelsHidden().pickerStyle(.menu)
                }
                Text("Longest side. Everything larger is downscaled; smaller stays as-is.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Format").font(.callout)
                    Spacer()
                    Picker("Format", selection: $options.format) {
                        Text("JPEG").tag("jpg")
                        Text("PNG").tag("png")
                        Text("HEIC").tag("heic")
                    }.labelsHidden().pickerStyle(.segmented)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Rename pattern (optional)").font(.callout)
                TextField("{name}-{index} — use {name} {date} {index}", text: $options.renamePattern)
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty to keep original names. Placeholders: {name} base name, {date} yyyy-mm-dd, {index} 001, 002…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Choose folder…") { pickDest() }.buttonStyle(.bordered).controlSize(.small)
                Text(options.destination.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            Button(busy ? "Working…" : "Run Batch Export") { run() }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(busy || photoIDs.isEmpty)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private func pickDest() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.directoryURL = options.destination
        if p.runModal() == .OK, let u = p.url ?? p.directoryURL { options.destination = u }
    }

    private func run() {
        busy = true
        status = "Exporting…"
        let items = library.photos.filter { photoIDs.contains($0.id) }
        let opts = options
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.createDirectory(at: opts.destination, withIntermediateDirectories: true)
            var ok = 0, fail = 0
            for (i, photo) in items.enumerated() {
                let recipe = LibraryStore.shared.loadEdit(for: photo.id)
                let base = (photo.filename as NSString).deletingPathExtension
                var name = base
                if !opts.renamePattern.isEmpty {
                    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
                    let dateStr = df.string(from: photo.takenAt)
                    name = opts.renamePattern
                        .replacingOccurrences(of: "{name}", with: base)
                        .replacingOccurrences(of: "{date}", with: dateStr)
                        .replacingOccurrences(of: "{index}", with: String(format: "%03d", i + 1))
                }
                var dest = opts.destination.appendingPathComponent("\(name).\(opts.format)")
                var n = 1
                while FileManager.default.fileExists(atPath: dest.path) {
                    dest = opts.destination.appendingPathComponent("\(name)-\(n).\(opts.format)")
                    n += 1
                }
                let maxPix: CGFloat = opts.maxDimension == 0 ? 6000 : CGFloat(opts.maxDimension)
                if Editor.export(path: photo.path, recipe: recipe, to: dest, maxPixel: maxPix, quality: 0.92) { ok += 1 } else { fail += 1 }
            }
            DispatchQueue.main.async {
                status = "Done: \(ok) exported · \(fail) failed to \(opts.destination.lastPathComponent)"
                busy = false
            }
        }
    }
}

// Keep compiler happy about unused import warnings in release.
private var _unused: Bool { true }
