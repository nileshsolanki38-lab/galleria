import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Groups the long notification-handler chain so the SwiftUI type-checker
/// doesn't have to chew through a single 20-deep modifier stack (which
/// fails on older compilers, e.g. the GitHub macOS runners).
struct ContentViewNotifications: ViewModifier {
    @Binding var showShortcuts: Bool
    @Binding var showCompare: Bool
    @Binding var showFaces: Bool
    @Binding var showPlaces: Bool
    @Binding var showDuplicates: Bool
    @Binding var showBatch: Bool
    @Binding var viewerIndex: Int?
    let addFolder: () -> Void
    let exportSelected: () -> Void
    let consumeOpenQueue: () -> Void
    let choosePhoto: () -> Void
    let openCollageFromViewer: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .galleriaAddFolder)) { _ in addFolder() }
            .onReceive(NotificationCenter.default.publisher(for: .galleriaExport)) { _ in exportSelected() }
            .onReceive(NotificationCenter.default.publisher(for: .galleriaOpenPhoto)) { _ in consumeOpenQueue() }
            .onReceive(NotificationCenter.default.publisher(for: .galleriaOpenPhotoPicker)) { _ in choosePhoto() }
            .onReceive(NotificationCenter.default.publisher(for: .galleriaShowShortcuts)) { _ in
                if viewerIndex == nil { showShortcuts = true }
            }
            .onReceive(NotificationCenter.default.publisher(for: .galleriaMakeCollage)) { _ in
                openCollageFromViewer()
            }
            .onReceive(NotificationCenter.default.publisher(for: .galleriaCompare)) { _ in showCompare = true }
            .onReceive(NotificationCenter.default.publisher(for: .galleriaFaces)) { _ in showFaces = true }
            .onReceive(NotificationCenter.default.publisher(for: .galleriaPlaces)) { _ in showPlaces = true }
            .onReceive(NotificationCenter.default.publisher(for: .galleriaDuplicates)) { _ in showDuplicates = true }
            .onReceive(NotificationCenter.default.publisher(for: .galleriaBatch)) { _ in showBatch = true }
    }
}

struct ContentView: View {
    @EnvironmentObject var library: LibraryStore

    @State private var sidebarSelection: SidebarItem? = .all
    @State private var selectedIDs: Set<Int64> = []
    @State private var searchText: String = ""
    @State private var minRating: Int = 0
    @State private var cellSize: Double = 150
    @State private var viewerIndex: Int? = nil
    /// The photo the viewer should show. The index alone is not enough: a folder
    /// scan can reorder `library.photos` between opening and presenting the viewer.
    @State private var viewerPhotoID: Int64? = nil
    @State private var showNewAlbum = false
    @State private var showShortcuts = false
    @State private var showCollage = false
    @State private var collageIDs: [Int64] = []
    @State private var showCompare = false
    @State private var showFaces = false
    @State private var showPlaces = false
    @State private var showDuplicates = false
    @State private var showBatch = false
    @State private var showSmartAlbums = false
    @State private var newAlbumName = ""
    @State private var gridWidth: CGFloat = 800
    @State private var scrollTargetID: Int64? = nil
    @State private var openRequestToken = UUID()
    @State private var lastExternalOpenPath = ""
    @State private var lastExternalOpenTime = Date.distantPast

    /// Photos grouped by year/month, newest first. Kept in sync with `library.photos`.
    @State private var sections: [TimelineSection] = []

    var body: some View {
        // GeometryReader pins the viewer to the window's real size. Without it,
        // the grid's sidebar minimum can make the overlay wider than a compact
        // photo window, which shifts the floating controls off screen.
        GeometryReader { geo in
            ZStack {
                NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
            } detail: {
                detail
            }
            .navigationSplitViewStyle(.balanced)
            .searchable(text: $searchText, placement: .toolbar, prompt: "Search photos, tags, captions")
            .onChange(of: sidebarSelection) { _, _ in applyFilters() }
            .onChange(of: minRating) { _, _ in applyFilters() }
            .onChange(of: viewerIndex) { _, newValue in
                // Hearts can be toggled inside the viewer; refresh the smart
                // album once it closes so removed photos leave the grid.
                if newValue == nil && sidebarSelection == .favorites { applyFilters() }
            }
            .onChange(of: searchText) { _, _ in
                Task {
                    try? await Task.sleep(nanoseconds: 220_000_000)
                    applyFilters()
                }
            }
            .onChange(of: library.photos) { _, _ in
                rebuildTimeline()
            }
            .onAppear {
                rebuildTimeline()
                consumeOpenQueue()
            }
            .onOpenURL { url in
                guard url.isFileURL else { return }
                openExternal(url)
            }
            .modifier(ContentViewNotifications(
                showShortcuts: $showShortcuts,
                showCompare: $showCompare,
                showFaces: $showFaces,
                showPlaces: $showPlaces,
                showDuplicates: $showDuplicates,
                showBatch: $showBatch,
                viewerIndex: $viewerIndex,
                addFolder: addFolder,
                exportSelected: exportSelected,
                consumeOpenQueue: consumeOpenQueue,
                choosePhoto: choosePhoto,
                openCollageFromViewer: openCollageFromViewer
            ))
            .background {
                // Arrow keys move the grid selection and Return opens it. SwiftUI
                // keyboard shortcuts do not reliably receive these keys (the
                // sidebar or scroll view can consume them), so use AppKit.
                GridKeyMonitor(
                    isActive: { viewerIndex == nil },
                    onMove: { moveSelection(by: $0) },
                    onOpen: {
                        if let index = openIndex() { openViewer(at: index) }
                    }
                )
                .frame(width: 0, height: 0)
            }

            // The viewer is an in-window overlay rather than a sheet so it can go
            // edge-to-edge with its own blurred backdrop and floating glass chrome.
            if let target = viewerTarget {
                ViewerView(
                    startIndex: target.index,
                    startPhotoID: target.photoID,
                    onClose: {
                        viewerIndex = nil
                        viewerPhotoID = nil
                    }
                )
                .environmentObject(library)
                // Re-create the viewer when "Open With" hands us a different
                // photo while it is already on screen.
                .id(target.id)
                .frame(width: geo.size.width, height: geo.size.height)
                .transition(.opacity)
                .zIndex(1)
            }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // The grid needs room for its sidebar and timeline, but the viewer's
        // compact presentation must be free to shrink to the photo's own size.
        .frame(minWidth: viewerIndex == nil ? 980 : 0,
               minHeight: viewerIndex == nil ? 620 : 0)
        .animation(.easeInOut(duration: 0.22), value: viewerIndex)
        .alert("New Album", isPresented: $showNewAlbum) {
            TextField("Album name", text: $newAlbumName)
            Button("Cancel", role: .cancel) { newAlbumName = "" }
            Button("Create") {
                let name = newAlbumName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    library.createAlbum(name: name, photoIDs: Array(selectedIDs))
                    newAlbumName = ""
                }
            }
        } message: {
            Text(selectedIDs.isEmpty ? "Creates an empty album." : "Adds \(selectedIDs.count) selected photo(s).")
        }
        .sheet(isPresented: $showShortcuts) {
            ViewerShortcutsSheet()
        }
        .sheet(isPresented: $showCollage) {
            CollageView(photoIDs: collageIDs)
                .environmentObject(library)
        }
        .sheet(isPresented: $showCompare) {
            CompareView(photoIDs: Array(selectedIDs))
                .environmentObject(library)
        }
        .sheet(isPresented: $showFaces) {
            FacesView().environmentObject(library)
        }
        .sheet(isPresented: $showPlaces) {
            PlacesView().environmentObject(library)
        }
        .sheet(isPresented: $showDuplicates) {
            DuplicatesView().environmentObject(library)
        }
        .sheet(isPresented: $showBatch) {
            BatchToolsView(photoIDs: Array(selectedIDs)).environmentObject(library)
        }
        .sheet(isPresented: $showSmartAlbums) {
            SmartAlbumsView().environmentObject(library)
        }
    }

    private var viewerTarget: ViewerTarget? {
        guard let index = viewerIndex else { return nil }
        let id = viewerPhotoID ?? (library.photos.indices.contains(index) ? library.photos[index].id : nil)
        return ViewerTarget(index: index, photoID: id)
    }

    /// Open the viewer on a photo, remembering its identity as well as its position.
    private func openViewer(at index: Int) {
        guard library.photos.indices.contains(index) else { return }
        viewerPhotoID = library.photos[index].id
        viewerIndex = index
    }

    private func openCollageFromViewer() {
        var ids: [Int64] = []
        if let current = viewerPhotoID {
            for item in library.photos where item.id == current {
                for sib in library.photos where sib.folder == item.folder {
                    ids.append(sib.id)
                }
                break
            }
        }
        if ids.isEmpty { ids = Array(selectedIDs) }
        if ids.isEmpty {
            for item in library.photos.prefix(8) { ids.append(item.id) }
        }
        collageIDs = ids
        showCollage = true
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $sidebarSelection) {
            Section("Library") {
                Label("All Photos", systemImage: "photo.on.rectangle.angled")
                    .tag(SidebarItem.all)
                Label("Favorites", systemImage: "heart.fill")
                    .tag(SidebarItem.favorites)
            }

            Section("Folders") {
                ForEach(library.folders, id: \.self) { folder in
                    Label((folder as NSString).lastPathComponent, systemImage: "folder")
                        .tag(SidebarItem.folder(folder))
                        .contextMenu {
                            Button("Remove from library", role: .destructive) {
                                library.removeFolder(folder)
                            }
                        }
                }
                Button {
                    addFolder()
                } label: {
                    Label("Add Folder…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Section("Albums") {
                ForEach(library.albums) { album in
                    Label(album.name, systemImage: "rectangle.stack")
                        .tag(SidebarItem.album(album.id))
                        .contextMenu {
                            Button("Delete Album", role: .destructive) {
                                library.deleteAlbum(album.id)
                            }
                        }
                }
                Button {
                    showNewAlbum = true
                } label: {
                    Label("New Album…", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Section("Smart Albums") {
                ForEach(library.smartAlbums) { sa in
                    Label(sa.name, systemImage: "magnifyingglass.circle")
                        .tag(SidebarItem.smartAlbum(sa.id))
                        .contextMenu {
                            Button("Edit…", role: .destructive) {
                                showSmartAlbums = true
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                library.deleteSmartAlbum(sa.id)
                            }
                        }
                }
                Button {
                    showSmartAlbums = true
                } label: {
                    Label("New Smart Album…", systemImage: "magnifyingglass.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Section("Discover") {
                Button {
                    showFaces = true
                } label: {
                    Label("People (Faces)", systemImage: "person.2.circle")
                }
                .buttonStyle(.plain)
                Button {
                    showPlaces = true
                } label: {
                    Label("Places (Map)", systemImage: "map.circle")
                }
                .buttonStyle(.plain)
                Button {
                    showDuplicates = true
                } label: {
                    Label("Duplicate Finder", systemImage: "square.stack")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            gallery
            Divider()
            statusBar
        }
        .toolbar { toolbarContent }
    }

    private var gallery: some View {
        ScrollViewReader { proxy in            ZStack(alignment: .trailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                LazyVGrid(columns: gridColumns, spacing: 8) {
                                    ForEach(Array(section.photos.enumerated()), id: \.element.id) { offset, photo in
                                        PhotoCell(
                                            photo: photo,
                                            size: cellSize,
                                            selected: selectedIDs.contains(photo.id),
                                            onOpen: { openViewer(at: section.startIndex + offset) },
                                            onSelect: { additive in
                                                if additive {
                                                    if selectedIDs.contains(photo.id) { selectedIDs.remove(photo.id) }
                                                    else { selectedIDs.insert(photo.id) }
                                                } else {
                                                    selectedIDs = [photo.id]
                                                }
                                            }
                                        )
                                        .id(photo.id)
                                        .contextMenu {
                                            Button("Open") { openViewer(at: section.startIndex + offset) }
                                            Button("Show in Finder") { showInFinder(photo) }
                                            Button("Copy Filename") {
                                                NSPasteboard.general.clearContents()
                                                NSPasteboard.general.setString(photo.filename, forType: .string)
                                            }
                                            Button("Make Collage…") {
                                                var ids = Array(selectedIDs)
                                                if !ids.contains(photo.id) { ids.append(photo.id) }
                                                collageIDs = ids
                                                showCollage = true
                                            }
                                            Button("Compare Selection…") {
                                                var ids = Array(selectedIDs)
                                                if !ids.contains(photo.id) { ids.append(photo.id) }
                                                selectedIDs = Set(ids.prefix(4))
                                                showCompare = true
                                            }
                                            Button("Batch Resize / Convert…") {
                                                var ids = Array(selectedIDs)
                                                if !ids.contains(photo.id) { ids.append(photo.id) }
                                                selectedIDs = Set(ids)
                                                showBatch = true
                                            }
                                            Button(photo.favorite ? "Remove from Favorites" : "Add to Favorites") {
                                                setFavorite(photo.id, favorite: !photo.favorite)
                                            }
                                            Divider()
                                            Menu("Rating") {
                                                ForEach(0...5, id: \.self) { r in
                                                    Button(r == 0 ? "None" : String(repeating: "★", count: r)) {
                                                        library.setRating([photo.id], rating: r)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                                .id(section.id)
                            } header: {
                                sectionHeader(section)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 34)
                }

                if sections.count > 1 {
                    TimelineScrubber(sections: sections) { id in
                        proxy.scrollTo(id, anchor: .top)
                    }
                    .padding(.trailing, 2)
                }
            }
            .overlay {
                if library.photos.isEmpty { emptyState }
            }
            // Selection must never outlive the list it was made in.
            .onChange(of: library.photos.map(\.id)) { _, ids in
                let live = Set(ids)
                if !selectedIDs.isSubset(of: live) {
                    selectedIDs.formIntersection(live)
                }
            }
            // Keep keyboard selection on screen.
            .onChange(of: scrollTargetID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
                scrollTargetID = nil
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { gridWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in gridWidth = w }
            }
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: cellSize, maximum: cellSize * 1.6), spacing: 8)]
    }

    /// Index (in `library.photos`) of the photo to open from the keyboard:
    /// the first selected photo, or the first photo on screen.
    private func openIndex() -> Int? {
        if let id = selectedIDs.first, let i = library.photos.firstIndex(where: { $0.id == id }) {
            return i
        }
        return library.photos.isEmpty ? nil : 0
    }

    private var columnCount: Int {
        // The grid sits inside 12 pt side padding and leaves 34 pt for the scrubber.
        let usable = max(gridWidth - 24 - 34, CGFloat(cellSize))
        return max(1, Int((usable + 8) / (CGFloat(cellSize) + 8)))
    }

    /// Arrow keys move the selection through the grid, a row at a time for ↑/↓.
    private func moveSelection(by direction: GridDirection) {
        guard !library.photos.isEmpty else { return }
        let cols = columnCount
        let current: Int
        if let id = selectedIDs.first, let i = library.photos.firstIndex(where: { $0.id == id }) {
            current = i
        } else {
            current = 0
        }
        let delta: Int
        switch direction {
        case .up: delta = -cols
        case .down: delta = cols
        case .left: delta = -1
        case .right: delta = 1
        }
        let next = min(max(current + delta, 0), library.photos.count - 1)
        let photo = library.photos[next]
        selectedIDs = [photo.id]
        scrollTargetID = photo.id
    }

    private func showInFinder(_ photo: Photo) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: photo.path)])
    }

    // MARK: - Open With / drag-and-drop

    /// Drain files handed to the app before the window existed (Finder "Open With",
    /// Dock drop, or command-line launch).
    private func consumeOpenQueue() {
        for url in OpenQueue.drain() {
            openExternal(url)
        }
    }

    /// Finder "Open With Galleria" hands us one or more files or folders.
    /// A file adds its parent folder to the library and opens the photo itself.
    private func openExternal(_ url: URL) {
        let path = LibraryStore.canonical(url).path
        let now = Date()

        // AppDelegate and SwiftUI's onOpenURL can both see the same file.
        if path == lastExternalOpenPath, now.timeIntervalSince(lastExternalOpenTime) < 1.5 { return }
        lastExternalOpenPath = path
        lastExternalOpenTime = now

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            library.flash("Can’t find “\(url.lastPathComponent)”", seconds: 6)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        NSApp.keyWindow?.makeKeyAndOrderFront(nil)

        // Clear filters so the opened photo is guaranteed to be in `library.photos`.
        sidebarSelection = .all
        searchText = ""
        minRating = 0

        if isDir.boolValue {
            library.addFolder(url)
            applyFilters()
            return
        }

        let folder = LibraryStore.canonical(url).deletingLastPathComponent()
        guard LibraryStore.isReadable(folder: folder) else {
            library.flash("Can’t read “\(folder.lastPathComponent)” — allow access in System Settings › Privacy & Security › Files and Folders", seconds: 12)
            return
        }

        applyFilters()
        library.openPhoto(at: url)

        let token = UUID()
        openRequestToken = token
        waitForOpenedPhoto(path: path, token: token, attempts: 0)
    }

    /// `openPhoto(at:)` indexes the file first and scans the rest of the folder
    /// afterwards, so poll briefly for the row to appear in the current query.
    private func waitForOpenedPhoto(path: String, token: UUID, attempts: Int) {
        guard openRequestToken == token else { return }
        if let index = library.photos.firstIndex(where: { $0.path == path }) {
            let photo = library.photos[index]
            selectedIDs = [photo.id]
            viewerPhotoID = photo.id
            viewerIndex = index
            return
        }
        guard attempts < 80 else {
            library.flash("Couldn’t open “\((path as NSString).lastPathComponent)”", seconds: 8)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            waitForOpenedPhoto(path: path, token: token, attempts: attempts + 1)
        }
    }

    /// File ▸ Open Photo… (⌘O), for people who do not want to use Finder.
    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Open"
        panel.message = "Choose a photo to open"
        if panel.runModal() == .OK, let url = panel.url {
            openExternal(url)
        }
    }

    private func sectionHeader(_ section: TimelineSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(section.title)
                .font(.title3.weight(.semibold))
            Text("\(section.photos.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(library.folders.isEmpty ? "No folders added yet" : "No photos match")
                .font(.title3)
            Text(library.folders.isEmpty
                 ? "Add a folder of photos to get started. Nothing is copied or moved."
                 : "Try clearing the search or rating filter.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if library.folders.isEmpty {
                Button("Add Folder…") { addFolder() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if library.isScanning {
                ProgressView().controlSize(.small)
            }
            Text("\(library.photos.count) \(library.photos.count == 1 ? "photo" : "photos")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if !library.status.isEmpty {
                Text(library.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .transition(.opacity)
            }

            if library.isWatching {
                Label("Watching", systemImage: "eye")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("New photos in your folders appear automatically")
            }

            Spacer()

            if !selectedIDs.isEmpty {
                Text("\(selectedIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach([0, 1, 2, 3, 4, 5], id: \.self) { r in
                    Button {
                        minRating = r
                    } label: {
                        Text(r == 0 ? "All ratings" : "\(r)+ stars")
                    }
                }
            } label: {
                Label(minRating == 0 ? "Filter" : "\(minRating)+", systemImage: "line.3.horizontal.decrease.circle")
            }

            Button {
                toggleFavoriteSelection()
            } label: {
                Label("Favorite",
                      systemImage: selectionAllFavorite ? "heart.fill" : "heart")
            }
            .disabled(selectedIDs.isEmpty)
            .help("Add or remove selected photos from Favorites (.)")

            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20, alignment: .center)
                    .contentShape(Rectangle())
                Slider(value: $cellSize, in: 56...320)
                    .frame(width: 120)
                    .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.55), in: Capsule())
            .help("Thumbnail size")

            Button {
                exportSelected()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .disabled(selectedIDs.isEmpty)
            .help("Export selected photos (⌘E)")

            Button {
                collageIDs = Array(selectedIDs)
                showCollage = true
            } label: {
                Label("Collage", systemImage: "square.stack.3d.up")
            }
            .disabled(selectedIDs.isEmpty)
            .help("Make a collage from the selection (Picasa-style)")

            Button {
                showCompare = true
            } label: {
                Label("Compare", systemImage: "photo.on.rectangle.angled")
            }
            .disabled(selectedIDs.count < 2)
            .help("Compare 2–4 selected photos side-by-side")

            Button {
                showBatch = true
            } label: {
                Label("Batch", systemImage: "hammer.circle")
            }
            .disabled(selectedIDs.isEmpty)
            .help("Batch resize / convert / rename the selection")

            Menu {
                Button("New Album from Selection…") { showNewAlbum = true }
                    .disabled(selectedIDs.isEmpty)
                Button("Make Collage from Selection…") {
                    collageIDs = Array(selectedIDs)
                    showCollage = true
                }
                .disabled(selectedIDs.isEmpty)
                Button("Compare Selection…") { showCompare = true }
                    .disabled(selectedIDs.count < 2)
                Button("Batch Resize / Convert…") { showBatch = true }
                    .disabled(selectedIDs.isEmpty)
                Divider()
                Button("People (Faces)…") { showFaces = true }
                Button("Places (Map)…") { showPlaces = true }
                Button("Duplicate Finder…") { showDuplicates = true }
                Button("Smart Albums…") { showSmartAlbums = true }
                Divider()
                Button("Export Selected…") { exportSelected() }
                    .disabled(selectedIDs.isEmpty)
                Button("Export Selected to Folder…") { exportSelectedTo() }
                    .disabled(selectedIDs.isEmpty)
                Divider()
                Button("Rescan Library") { library.rescanAll() }
                Button("Clear Thumbnail Cache") { ThumbnailService.shared.clearDiskCache() }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: - Timeline

    private func rebuildTimeline() {
        sections = Self.buildTimeline(library.photos)
    }

    private static func buildTimeline(_ photos: [Photo]) -> [TimelineSection] {
        guard !photos.isEmpty else { return [] }
        let calendar = Calendar.current
        let titleFormatter = DateFormatter()
        titleFormatter.dateFormat = "MMMM yyyy"

        var result: [TimelineSection] = []
        var key = ""
        var year = 0
        var month = 0
        var start = 0
        var bucket: [Photo] = []

        func flush() {
            guard !bucket.isEmpty else { return }
            let date = calendar.date(from: DateComponents(year: year, month: month)) ?? Date()
            result.append(TimelineSection(
                id: key,
                title: titleFormatter.string(from: date),
                year: year,
                month: month,
                startIndex: start,
                photos: bucket
            ))
            bucket = []
        }

        for (i, photo) in photos.enumerated() {
            let comps = calendar.dateComponents([.year, .month], from: photo.takenAt)
            let k = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            if k != key {
                flush()
                key = k
                year = comps.year ?? 0
                month = comps.month ?? 0
                start = i
            }
            bucket.append(photo)
        }
        flush()
        return result
    }

    // MARK: - Actions

    private func applyFilters() {
        let folder: String?
        let album: Int64?
        var search = searchText
        var rating = minRating
        var favoritesOnly = sidebarSelection == .favorites
        switch sidebarSelection {
        case .folder(let f): folder = f; album = nil
        case .album(let a): folder = nil; album = a
        case .smartAlbum(let id):
            folder = nil; album = nil
            if let sa = library.smartAlbums.first(where: { $0.id == id }) {
                if search.isEmpty { search = sa.search }
                if rating == 0 { rating = sa.minRating }
                favoritesOnly = favoritesOnly || sa.favoritesOnly
            }
        default: folder = nil; album = nil
        }
        library.refresh(folder: folder, album: album, search: search,
                        minRating: rating, favoritesOnly: favoritesOnly)
    }

    /// Favourite a single photo, keeping the Favorites smart album in sync.
    private func setFavorite(_ id: Int64, favorite: Bool) {
        library.setFavorite([id], favorite: favorite)
        if sidebarSelection == .favorites { applyFilters() }
    }

    /// Toggle favourites for the whole grid selection. Mixed selections become
    /// all-favourites so one click never silently removes existing hearts.
    private func toggleFavoriteSelection() {
        let selected = library.photos.filter { selectedIDs.contains($0.id) }
        guard !selected.isEmpty else { return }
        let makeFavorite = !selected.allSatisfy(\.favorite)
        library.setFavorite(Array(selectedIDs), favorite: makeFavorite)
        if sidebarSelection == .favorites { applyFilters() }
    }

    private var selectionAllFavorite: Bool {
        let selected = library.photos.filter { selectedIDs.contains($0.id) }
        return !selected.isEmpty && selected.allSatisfy(\.favorite)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose a folder of photos to index (files are never moved)"
        if panel.runModal() == .OK {
            for url in panel.urls { library.addFolder(url) }
        }
    }

    /// Where "Export Selected" writes by default. Remembered between launches, and
    /// created on demand so the common case needs no dialog at all.
    private var defaultExportFolder: URL {
        if let saved = UserDefaults.standard.string(forKey: "exportFolder"), !saved.isEmpty {
            return URL(fileURLWithPath: saved, isDirectory: true)
        }
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent("Galleria Exports", isDirectory: true)
    }

    private func exportSelected() {
        let items = library.photos.filter { selectedIDs.contains($0.id) }
        guard !items.isEmpty else {
            library.flash("Select photos to export first", seconds: 4)
            return
        }
        export(items, to: defaultExportFolder)
    }

    private func exportSelectedTo() {
        let items = library.photos.filter { selectedIDs.contains($0.id) }
        guard !items.isEmpty else {
            library.flash("Select photos to export first", seconds: 4)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for \(items.count) exported photo(s)"
        panel.directoryURL = defaultExportFolder
        guard panel.runModal() == .OK else { return }
        // Navigating into a folder leaves `url` nil, so fall back to the folder being browsed.
        guard let dest = panel.url ?? panel.directoryURL else { return }
        UserDefaults.standard.set(dest.path, forKey: "exportFolder")
        export(items, to: dest)
    }

    private func export(_ items: [Photo], to dest: URL) {
        library.flash("Exporting \(items.count) photo(s)…", seconds: 30)
        DispatchQueue.global(qos: .userInitiated).async {
            var ok = 0
            var failed = 0
            for photo in items {
                let recipe = LibraryStore.shared.loadEdit(for: photo.id)
                let out = Self.availableURL(for: photo.filename, in: dest)
                if Editor.export(path: photo.path, recipe: recipe, to: out) { ok += 1 } else { failed += 1 }
            }
            var message = "Exported \(ok) photo\(ok == 1 ? "" : "s") to \(dest.lastPathComponent)"
            if failed > 0 { message += " · \(failed) failed" }
            LibraryStore.shared.flash(message, seconds: 8)
        }
    }

    /// Never clobber an earlier export: name.jpg, name-1.jpg, name-2.jpg…
    private static func availableURL(for filename: String, in folder: URL) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = (filename as NSString).pathExtension.lowercased()
        // The encoder picks its format from the extension, so make the extension honest.
        let exportExt: String = ["png", "heic", "heif", "tif", "tiff"].contains(ext) ? ext : "jpg"
        let base = (filename as NSString).deletingPathExtension
        var candidate = folder.appendingPathComponent("\(base).\(exportExt)")
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(n).\(exportExt)")
            n += 1
        }
        return candidate
    }
}

// MARK: - Timeline model

private struct TimelineSection: Identifiable {
    let id: String
    let title: String
    let year: Int
    let month: Int
    /// Index of the first photo in the flat `library.photos` array.
    let startIndex: Int
    let photos: [Photo]
}

// MARK: - Timeline scrubber

/// Vertical year/month scrubber down the right edge, like Picasa's timeline.
private struct TimelineScrubber: View {
    let sections: [TimelineSection]
    let onSelect: (String) -> Void

    @State private var activeIndex: Int? = nil

    private let topPad: CGFloat = 42
    private let bottomPad: CGFloat = 42
    private let width: CGFloat = 32

    private var yearMarks: [(year: Int, index: Int)] {
        var out: [(year: Int, index: Int)] = []
        var last: Int? = nil
        for (i, s) in sections.enumerated() {
            if s.year != last {
                out.append((s.year, i))
                last = s.year
            }
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.height - topPad - bottomPad)
            let lastIndex = max(1, sections.count - 1)

            // Maps a y position in the track to the nearest section.
            let jump: (CGFloat) -> Void = { y in
                let fraction = min(max((y - topPad) / usable, 0), 1)
                let index = Int((fraction * CGFloat(lastIndex)).rounded())
                activeIndex = index
                if sections.indices.contains(index) {
                    onSelect(sections[index].id)
                }
            }

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: width / 2)
                    .fill(Color.primary.opacity(0.06))

                ForEach(yearMarks, id: \.year) { mark in
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 8, height: 1)
                        Text(verbatim: "\(mark.year)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .offset(y: topPad + CGFloat(mark.index) / CGFloat(lastIndex) * usable - 6)
                }

                if let i = activeIndex, sections.indices.contains(i) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .offset(y: topPad + CGFloat(i) / CGFloat(lastIndex) * usable - 3.5)
                }
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in jump(value.location.y) }
                    .onEnded { _ in activeIndex = nil }
            )
            .simultaneousGesture(
                SpatialTapGesture()
                    .onEnded { value in
                        jump(value.location.y)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { activeIndex = nil }
                    }
            )
            .overlay(alignment: .topTrailing) {
                if let i = activeIndex, sections.indices.contains(i) {
                    Text(sections[i].title)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .fixedSize()
                        .offset(x: -width - 8,
                                y: topPad + CGFloat(i) / CGFloat(lastIndex) * usable - 12)
                }
            }
        }
        .frame(width: width)
        .padding(.vertical, 6)
    }
}

// MARK: - Grid keyboard navigation

private enum GridDirection {
    case up, down, left, right
}

/// Local key monitor for the grid. SwiftUI keyboard shortcuts do not reliably
/// receive arrow keys (and the scroll view often consumes them first).
private struct GridKeyMonitor: NSViewRepresentable {
    let isActive: () -> Bool
    let onMove: (GridDirection) -> Void
    let onOpen: () -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install(isActive: isActive, onMove: onMove, onOpen: onOpen)
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(isActive: isActive, onMove: onMove, onOpen: onOpen)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        private var monitor: Any?
        private var isActive: () -> Bool = { false }
        private var onMove: (GridDirection) -> Void = { _ in }
        private var onOpen: () -> Void = {}

        func install(isActive: @escaping () -> Bool,
                     onMove: @escaping (GridDirection) -> Void,
                     onOpen: @escaping () -> Void) {
            self.isActive = isActive
            self.onMove = onMove
            self.onOpen = onOpen
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive() else { return event }
                // Never steal keys from the search field or a rename field.
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                switch event.keyCode {
                case 126: self.onMove(.up); return nil
                case 125: self.onMove(.down); return nil
                case 123: self.onMove(.left); return nil
                case 124: self.onMove(.right); return nil
                case 36, 76: self.onOpen(); return nil       // Return / keypad Enter
                default: return event
                }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { remove() }
    }
}

// MARK: - Viewer sheet target

struct ViewerTarget: Identifiable {
    let index: Int
    let photoID: Int64?
    var id: Int64 { photoID ?? Int64(index) }
}

// MARK: - Thumbnail cell

/// Transparent click handler for grid cells. AppKit tracks click counts per window,
/// so a double-click is recognised even if the cell re-renders between clicks.
private struct ClickCatcher: NSViewRepresentable {
    let onSingle: (Bool) -> Void
    let onDouble: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onSingle = onSingle
        v.onDouble = onDouble
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onSingle = onSingle
        nsView.onDouble = onDouble
    }

    final class CatcherView: NSView {
        var onSingle: ((Bool) -> Void)?
        var onDouble: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                onDouble?()
            } else {
                onSingle?(event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift))
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}

struct PhotoCell: View {
    let photo: Photo
    let size: CGFloat
    let selected: Bool
    let onOpen: () -> Void
    let onSelect: (_ additive: Bool) -> Void

    @State private var image: NSImage?
    @State private var failed = false

    private var corner: CGFloat { size < 80 ? 4 : 7 }

    var body: some View {
        VStack(spacing: 3) {
            thumbnail
            // Filename under every thumbnail, Picasa-style. Hidden only for the
            // smallest sizes where there is no room for legible text.
            if size >= 72 {
                Text(photo.filename)
                    .font(.system(size: 10))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .frame(width: size)
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.22))

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if failed {
                // A file that cannot be decoded must not spin forever.
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner))
        .overlay {
            RoundedRectangle(cornerRadius: corner)
                .strokeBorder(selected ? Color.accentColor : Color.clear,
                              lineWidth: size < 80 ? 2 : 3)
        }
        .overlay(alignment: .bottomLeading) {
            // Stars are unreadable on very small thumbnails, so only show them when there is room.
            if photo.rating > 0 && size >= 72 {
                HStack(spacing: 1) {
                    ForEach(0..<photo.rating, id: \.self) { _ in
                        Image(systemName: "star.fill").font(.system(size: 8))
                    }
                }
                .foregroundStyle(.yellow)
                .padding(4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if photo.favorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: size < 80 ? 8 : 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(size < 80 ? 4 : 5)
                    .background(.black.opacity(0.35), in: Circle())
                    .padding(5)
            }
        }
        .contentShape(Rectangle())
        // AppKit click handling rather than SwiftUI tap gestures: selecting a cell
        // re-renders it, which used to swallow the second click of a double-click.
        .overlay {
            ClickCatcher(
                onSingle: { additive in onSelect(additive) },
                onDouble: onOpen
            )
        }
        .task(id: photo.id) {
            let loaded = await ThumbnailService.shared.thumbnail(
                path: photo.path, mtime: photo.mtime, size: size * 2
            )
            image = loaded
            failed = (loaded == nil)
        }
    }
}
