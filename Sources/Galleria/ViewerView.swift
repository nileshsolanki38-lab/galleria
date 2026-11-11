import SwiftUI
import AppKit

/// The grid's window chrome, remembered for the whole viewer session.
///
/// SwiftUI recreates `ViewerView` whenever "Open With" hands us a different
/// photo. Per-instance `@State` would then capture the already-compact window
/// instead of the grid's window, so closing the viewer would leave the grid at
/// the last photo's size (and shape). This memory survives those re-creations
/// and is refreshed whenever the window is back to a normal, resizable grid
/// window.
private enum ViewerWindowMemory {
    /// AppKit aborts on setStyleMask during a full-screen visual transition;
    /// window-level guards consult this flag.
    static var fullScreenTransitioning = false
    static var frame: NSRect?
    static var styleMask: NSWindow.StyleMask?
    static var titleVisibility: NSWindow.TitleVisibility = .visible
    static var titlebarTransparent = false
    static var contentMinSize: NSSize?
    static var toolbarVisible: Bool?
}

/// Full-window, Picasa-style viewer: the photo sits on a blurred copy of itself,
/// with floating glass controls that can be hidden for a completely clean view.
struct ViewerView: View {
    @EnvironmentObject var library: LibraryStore

    let startIndex: Int
    let startPhotoID: Int64?
    let onClose: () -> Void

    @State private var index: Int
    @State private var currentPhotoID: Int64?
    @State private var image: NSImage?
    @State private var backdrop: NSImage?
    @State private var isLoading = false
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var panStart: CGSize?
    @State private var showEdit = false
    @State private var hoverFilmstripIndex: Int?
    @State private var filmstripHovering = false
    @AppStorage("viewer.showInfo") private var showInfo = false
    @AppStorage("viewer.showFilmstrip") private var showFilmstrip = false
    @State private var chromeVisible = false
    /// Folder-scoped browsing list. The viewer only steps through photos in the
    /// same folder as the one that was opened, never the whole library.
    @State private var folderPhotos: [Photo] = []
    @State private var recipe: EditRecipe = .identity
    @State private var exif: [(String, String)] = []
    @State private var monitor: Any?
    @State private var scrollMonitor: Any?
    @State private var isCropping = false
    @State private var cropRect: CGRect = .zero
    @State private var dragStart: CGPoint?
    @State private var lastOutsideAction = Date.distantPast

    // Viewer preferences and chrome extras.
    @AppStorage("viewer.filmstripThumbSize") private var filmstripThumbSize: Double = 84
    @AppStorage("viewer.slideshowInterval") private var slideshowInterval: Double = 3
    /// Single tuned presentation: the compact glass window. The old
    /// "Full screen / Compact" setting kept switching window chrome mid-open
    /// and caused top-bar glitches, so it is removed — Full Screen stays
    /// available as a temporary action (F), not a mode.
    private let presentation = "compact"
    @AppStorage("viewer.showTopBar") private var showTopBar = false
    @AppStorage("viewer.startHidden") private var startHidden = false
    @State private var showViewerSettings = false
    @State private var showShortcuts = false
    @State private var showResize = false
    @State private var showInstantAlpha = false
    // Preview-style markup + style copy/paste (compact prefs like Preview).
    @State private var isMarkup = false
    @State private var markupTool: MarkupType = .rect
    @State private var markupColor = "#FF0000"
    @State private var markupStroke: Double = 3
    @State private var markupDraft: MarkupElement?
    @State private var markupDragStart: CGPoint?
    @State private var copiedStyle: String = ""
    @State private var slideshow = false
    @State private var slideshowTask: Task<Void, Never>?

    // Window chrome bookkeeping for the compact presentation.
    @State private var savedWindowFrame: NSRect?
    @State private var savedStyleMask: NSWindow.StyleMask?
    @State private var savedTitleVisibility: NSWindow.TitleVisibility = .visible
    @State private var savedTitlebarTransparent = false
    @State private var savedToolbarVisible: Bool?
    @State private var savedContentMinSize: NSSize?
    @State private var compactApplied = false
    /// Two-stage outside-tap: first tap collapses to photo-sized window, second returns to grid.
    @State private var collapsedToCompact = false
    /// Mirrors the window's full-screen state so SwiftUI re-renders when it
    /// changes (AppKit notifications drive it, not a computed property).
    @State private var fullScreenActive = false
    /// Live content width, used to make the compact top bar responsive.
    @State private var contentWidth: CGFloat = 800

    init(startIndex: Int, startPhotoID: Int64?, onClose: @escaping () -> Void) {
        self.startIndex = startIndex
        self.startPhotoID = startPhotoID
        self.onClose = onClose
        _index = State(initialValue: startIndex)
    }

    /// Photos the viewer browses: the opened photo's folder only.
    private var photos: [Photo] {
        folderPhotos.isEmpty ? library.photos : folderPhotos
    }

    private func photo(at i: Int) -> Photo? {
        photos.indices.contains(i) ? photos[i] : nil
    }

    /// While a folder scan reorders `library.photos`, the index can briefly point
    /// at a different photo. Prefer the identity the viewer is actually showing.
    private var photo: Photo? {
        if let id = currentPhotoID {
            if let p = library.photos.first(where: { $0.id == id }) { return p }
            if let p = photos.first(where: { $0.id == id }) { return p }
        }
        return photo(at: index)
    }

    /// The real library window. Settings popovers and other transient panels can
    /// become the key window, so prefer the main window over `keyWindow`.
    private var targetWindow: NSWindow? {
        NSApp.mainWindow ?? NSApp.keyWindow
    }

    private var isFullScreen: Bool {
        targetWindow?.styleMask.contains(.fullScreen) ?? false
    }

    /// Compact presentation: the window is sized to the photo itself, with no
    /// blurred backdrop and no letterboxing. Full screen still uses the immersive
    /// blurred presentation, whatever mode the viewer was opened in.
    private var isCompactPresentation: Bool { presentation == "compact" }
    private var isCompactWindow: Bool { isCompactPresentation && !isFullScreen }

    private var filmstripThumb: CGFloat { CGFloat(filmstripThumbSize) }
    private var filmstripBarHeight: CGFloat { filmstripThumb + 20 }
    private var filmstripInset: CGFloat { showFilmstrip ? filmstripBarHeight + 26 : 18 }
    /// Height reserved at the compact window's bottom for the filename caption
    /// pill, so it never overlaps the photo or the filmstrip.
    private var statusBarInset: CGFloat { 24 }

    // MARK: - Body

    var body: some View {
        ZStack {
            if isCompactWindow {
                // Glass (transparent) backdrop in compact mode so the photo
                // sits on the same frosted material as the floating controls,
                // instead of a flat black slab.
                Color.clear
                    .background(.ultraThinMaterial)
                    .ignoresSafeArea()
            } else {
                backdropLayer
            }

            photoLayer

            // Chrome is always mounted; its pieces decide their own visibility.
            // Nothing floats over the photo: the only way to show or hide the
            // bars is the right-click menu (or their keyboard shortcuts).
            chrome
                // Pin the floating chrome to the window: the filmstrip's
                // scroll content must never make the compact top bar wider
                // than the photo.
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(white: 0.06))
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { contentWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newValue in
                        contentWidth = newValue
                    }
            }
        }
        // Right-click anywhere for every viewer option. This is the way back if
        // the top bar (or all chrome) has been hidden.
        .contextMenu { viewerContextMenu }
        // In a compact window the photo is the window: don't let the title bar's
        // safe area introduce even a single pixel of margin.
        .ignoresSafeArea((isCompactWindow || isFullScreen) ? .container : [], edges: .all)
        .animation(.easeInOut(duration: 0.22), value: chromeVisible)
        .animation(.easeInOut(duration: 0.22), value: showFilmstrip)
        .animation(.easeInOut(duration: 0.22), value: showInfo)
        .animation(.easeInOut(duration: 0.22), value: showTopBar)
        .sheet(isPresented: $showShortcuts) {
            ViewerShortcutsSheet()
        }
        .sheet(isPresented: $showResize) {
            if let p = photo {
                ResizeSheet(photoID: p.id).environmentObject(library)
            }
        }
        .sheet(isPresented: $showInstantAlpha) {
            if let p = photo {
                InstantAlphaSheet(photoID: p.id).environmentObject(library)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .galleriaShowShortcuts)) { _ in
            showShortcuts = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            fullScreenActive = true
            zoom = 1
            offset = .zero
            // Full screen must stay chrome-free: a native title bar or the
            // grid's unified toolbar flashing over the photo reads as a
            // "second Galleria menu" overlapping the viewer and the gallery.
            // These surface toggles are safe once the transition has settled.
            if let w = targetWindow, w.styleMask.contains(.fullScreen) {
                w.toolbar?.isVisible = false
                w.titleVisibility = .hidden
                w.titlebarAppearsTransparent = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            fullScreenActive = false
            if isCompactPresentation {
                // Keep the returning window chrome-free between the exit
                // animation and the re-compact pass below.
                if let w = targetWindow {
                    w.toolbar?.isVisible = false
                    w.titleVisibility = .hidden
                    w.titlebarAppearsTransparent = true
                }
                // Returning from full screen restores the photo-sized window
                // (with whichever compact controls are selected).
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard let w = targetWindow,
                          !w.styleMask.contains(.fullScreen) else { return }
                    applyCompactWindow()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in
            // A photo-sized window follows the display it is on, so it never
            // spills off a smaller screen or a different resolution.
            guard isCompactWindow, compactApplied else { return }
            resizeCompactWindow()
        }
        .onAppear {
            // Resolve the photo by identity: a scan may have reordered the list
            // between the click and the viewer appearing.
            let anchor: Photo?
            if let id = startPhotoID {
                anchor = library.photos.first(where: { $0.id == id }) ?? photo(at: index)
            } else {
                anchor = photo(at: index)
            }
            if let anchor {
                currentPhotoID = anchor.id
                // Browse only the folder the opened photo lives in. Start with the
                // in-memory slice so the photo appears instantly, then replace it
                // with the full catalogue query (grid filters must not narrow the
                // viewer's folder).
                let siblings = library.photos.filter { $0.folder == anchor.folder }
                folderPhotos = siblings.isEmpty ? [anchor] : siblings
                index = folderPhotos.firstIndex(where: { $0.id == anchor.id }) ?? 0
                refreshFolderScope(anchorID: anchor.id, folder: anchor.folder)
            }
            chromeVisible = !startHidden
            fullScreenActive = isFullScreen
            installKeyMonitor()
            load()
            applyPresentationOnOpen()
        }
        .onDisappear {
            slideshowTask?.cancel()
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
            restoreWindowChrome()
        }
        // Load by identity, not position: if a rescan reorders the folder the
        // index can stay the same while a different photo becomes current (or
        // vice versa), and loading on `index` alone would leave the old image,
        // EXIF and tooltip on screen.
        .onChange(of: currentPhotoID) { _, _ in
            resetView()
            load()
        }
        .onChange(of: zoom) { _, z in
            // In a compact window, dragging an unzoomed photo moves the window;
            // once zoomed, drag pans the photo instead.
            guard isCompactWindow else { return }
            targetWindow?.isMovableByWindowBackground = z <= 1.001
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            ViewerWindowMemory.fullScreenTransitioning = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            ViewerWindowMemory.fullScreenTransitioning = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            ViewerWindowMemory.fullScreenTransitioning = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            ViewerWindowMemory.fullScreenTransitioning = false
        }
        // The catalogue can change while the viewer is open (a folder scan after
        // "Open With"). Keep the folder scope fresh and re-anchor on the photo the
        // user is actually looking at.
        .onChange(of: library.photos.map(\.id)) { _, _ in
            guard let id = currentPhotoID else { return }
            if let p = library.photos.first(where: { $0.id == id }) {
                let fresh = library.photos.filter { $0.folder == p.folder }
                if fresh.map(\.id) != folderPhotos.map(\.id) {
                    folderPhotos = fresh.isEmpty ? [p] : fresh
                }
                refreshFolderScope(anchorID: id, folder: p.folder)
            }
            if let i = folderPhotos.firstIndex(where: { $0.id == id }) {
                if i != index { index = i }
            } else if !folderPhotos.isEmpty {
                index = min(index, folderPhotos.count - 1)
                currentPhotoID = folderPhotos[index].id
            }
        }
    }

    // MARK: - Blurred photo backdrop

    private var backdropLayer: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let backdrop {
                    Image(nsImage: backdrop)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(1.45)
                        .brightness(0.15)
                        .blur(radius: 55, opaque: true)
                        .transition(.opacity)
                }

                // Keep the photo the hero: darken and add a gentle vignette.
                Color.black.opacity(0.22)
                LinearGradient(
                    colors: [.black.opacity(0.15), .clear, .black.opacity(0.15)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [.clear, .black.opacity(0.15)],
                    center: .center,
                    startRadius: geo.size.width * 0.20,
                    endRadius: geo.size.width * 0.72
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // Clicking the backdrop around the photo: collapse out of full screen,
        // and from the compact viewer go straight back to the grid.
        .onTapGesture { handleOutsideTap() }
        .animation(.easeInOut(duration: 0.32), value: photo?.id)
    }

    /// Two-stage outside-tap collapse: first tap leaves full screen and collapses to a
    /// photo-sized compact window (filmstrip stays anchored at the window bottom),
    /// second tap returns to the grid. A stray double-click cannot skip a stage.
    private func handleOutsideTap() {
        if Date.now.timeIntervalSince(lastOutsideAction) < 0.35 { return }
        lastOutsideAction = Date.now
        if isFullScreen {
            toggleFullScreen()
            // After leaving full screen, collapse to the photo-sized window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                guard !isFullScreen else { return }
                applyCompactWindow()
            }
        } else {
            // Already compact (photo-sized): tap goes back to the grid.
            onClose()
        }
    }

    // MARK: - Photo

    private var photoLayer: some View {
        GeometryReader { geo in
            let insets = contentInsets
            let available = CGSize(
                width: max(160, geo.size.width - insets.leading - insets.trailing),
                height: max(160, geo.size.height - insets.top - insets.bottom)
            )
            let fitted = image.map { fittedSize(for: $0.size, in: available) } ?? .zero

            ZStack {
                Color.clear
                    // The empty space around the photo must pass clicks through to the
                    // backdrop, so a click anywhere outside the photo collapses the viewer.
                    .allowsHitTesting(false)

                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: fitted.width, height: fitted.height)
                        .scaleEffect(zoom)
                        .offset(offset)
                        .shadow(color: isCompactWindow ? .clear : .black.opacity(0.5),
                                radius: isCompactWindow ? 0 : 28,
                                y: isCompactWindow ? 0 : 12)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    guard !isCropping else { return }
                                    zoom = min(max(value, 1), 12)
                                    if zoom <= 1 { offset = .zero }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { value in
                                    guard !isCropping, zoom > 1 else { return }
                                    let base = panStart ?? offset
                                    panStart = base
                                    offset = CGSize(
                                        width: base.width + value.translation.width,
                                        height: base.height + value.translation.height
                                    )
                                }
                                .onEnded { _ in panStart = nil }
                        )
                        .onTapGesture(count: 2) {
                            // Double-click on the photo itself goes full screen.
                            guard !isCropping else { return }
                            toggleFullScreen()
                        }

                    if isCropping {
                        cropOverlay(fitted: fitted)
                            .frame(width: fitted.width, height: fitted.height)
                    }

                    if isMarkup {
                        markupOverlay(fitted: fitted)
                            .frame(width: fitted.width, height: fitted.height)
                    }
                } else if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 34, weight: .light))
                        Text("Can't display this file")
                            .font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.65))
                }
            }
            .frame(width: available.width, height: available.height)
            .offset(x: insets.leading, y: insets.top)
        }
    }

    /// Space the photo must leave for the floating chrome. Both presentations use
    /// the same fixed insets so the filmstrip strip stays at the window bottom
    /// and never moves when the photo aspect changes.
    private var contentInsets: EdgeInsets {
        if isCompactWindow {
            // Compact window is the photo, but the filmstrip still reserves its
            // fixed strip at the window bottom so mouse scroll stays over the
            // same pixels. Top bar overlays when chrome is visible.
            return EdgeInsets(
                top: chromeVisible && showTopBar ? 64 : 0,
                leading: showEdit ? 280 : 0,
                bottom: (showFilmstrip ? filmstripBarHeight + 26 : 0)
                    + statusBarInset,
                trailing: showInfo ? 280 : 0
            )
        }
        return EdgeInsets(
            top: showTopBar && chromeVisible ? 76 : 0,
            leading: showEdit ? 288 : 0,
            bottom: showFilmstrip ? filmstripInset : 0,
            trailing: showInfo ? 288 : 0
        )
    }

    private func fittedSize(for imageSize: CGSize, in container: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    // MARK: - Crop overlay

    private func cropOverlay(fitted: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.45)
                .frame(width: fitted.width, height: fitted.height)
                .mask(
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.white)
                        if cropRect.width > 0 {
                            Rectangle()
                                .fill(Color.black)
                                .frame(width: cropRect.width * fitted.width,
                                       height: cropRect.height * fitted.height)
                                .offset(x: cropRect.minX * fitted.width,
                                        y: cropRect.minY * fitted.height)
                        }
                    }
                    .compositingGroup()
                    .luminanceToAlpha()
                )
                .allowsHitTesting(false)

            if cropRect.width > 0 {
                Rectangle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: cropRect.width * fitted.width,
                           height: cropRect.height * fitted.height)
                    .offset(x: cropRect.minX * fitted.width,
                            y: cropRect.minY * fitted.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = dragStart ?? value.startLocation
                    dragStart = start
                    let x0 = min(start.x, value.location.x)
                    let x1 = max(start.x, value.location.x)
                    let y0 = min(start.y, value.location.y)
                    let y1 = max(start.y, value.location.y)
                    let nx = max(0, min(x0 / fitted.width, 1))
                    let ny = max(0, min(y0 / fitted.height, 1))
                    let nw = max(0, min((x1 - x0) / fitted.width, 1 - nx))
                    let nh = max(0, min((y1 - y0) / fitted.height, 1 - ny))
                    cropRect = CGRect(x: nx, y: ny, width: nw, height: nh)
                }
                .onEnded { _ in dragStart = nil }
        )
    }

    // MARK: - Markup overlay (Preview-style)

    private func markupOverlay(fitted: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(recipe.markups.enumerated()), id: \.offset) { idx, m in
                markupShape(m, fitted: fitted, live: false)
            }
            if let draft = markupDraft {
                markupShape(draft, fitted: fitted, live: true)
            }
        }
        .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    guard fitted.width > 0 && fitted.height > 0 else { return }
                    let start = markupDragStart ?? value.startLocation
                    markupDragStart = start
                    let nx = max(0, min(value.location.x / fitted.width, 1))
                    let ny = max(0, min(value.location.y / fitted.height, 1))
                    let sx = max(0, min(start.x / fitted.width, 1))
                    let sy = max(0, min(start.y / fitted.height, 1))
                    if markupTool == .freehand {
                        var pts = markupDraft?.points ?? [CGPoint(x: sx, y: sy)]
                        pts.append(CGPoint(x: nx, y: ny))
                        markupDraft = MarkupElement(type: .freehand, x: 0, y: 0, w: 0, h: 0,
                                                     points: pts, text: "", color: markupColor,
                                                     strokeWidth: markupStroke, filled: false)
                    } else if markupTool == .text {
                        // Text is placed on tap; drag just shows a caret box.
                        markupDraft = MarkupElement(type: .text, x: nx, y: ny, w: 0.2, h: 0.08,
                                                     points: [], text: "Text", color: markupColor,
                                                     strokeWidth: markupStroke, filled: false)
                    } else {
                        let x = min(sx, nx), y = min(sy, ny)
                        let w = abs(nx - sx), h = abs(ny - sy)
                        markupDraft = MarkupElement(type: markupTool, x: x, y: y, w: w, h: h,
                                                     points: [], text: "", color: markupColor,
                                                     strokeWidth: markupStroke, filled: false)
                    }
                }
                .onEnded { _ in
                    defer { markupDragStart = nil }
                    guard var draft = markupDraft else { return }
                    // Skip tiny accidental drags.
                    if draft.type != .freehand && draft.type != .text && draft.w < 0.01 && draft.h < 0.01 { markupDraft = nil; return }
                    if draft.type == .text {
                        // Prompt for text content (Preview: double-click text to edit).
                        let panel = NSAlert()
                        panel.messageText = "Markup text"
                        panel.informativeText = "Type the text to place on the photo."
                        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
                        tf.stringValue = "Text"
                        panel.accessoryView = tf
                        panel.addButton(withTitle: "Add")
                        panel.addButton(withTitle: "Cancel")
                        if panel.runModal() == .alertFirstButtonReturn {
                            draft.text = tf.stringValue.isEmpty ? "Text" : tf.stringValue
                            recipe.markups.append(draft)
                            commit()
                        }
                    } else {
                        recipe.markups.append(draft)
                        commit()
                    }
                    markupDraft = nil
                }
        )
    }

    private func markupShape(_ m: MarkupElement, fitted: CGSize, live: Bool) -> some View {
        // Single Canvas view (no ViewBuilder branching) — keeps the 26 SDK type-checker fast.
        Canvas { ctx, size in
            let color = colorFromHex(m.color)
            let w = CGFloat(m.w) * fitted.width
            let h = CGFloat(m.h) * fitted.height
            let x = CGFloat(m.x) * fitted.width
            let y = CGFloat(m.y) * fitted.height
            let lineW = CGFloat(m.strokeWidth)
            if m.type == .rect {
                let r = CGRect(x: x, y: y, width: w, height: h)
                ctx.stroke(Path(roundedRect: r, cornerSize: CGSize(width: lineW, height: lineW)), with: .color(color), lineWidth: lineW)
            } else if m.type == .oval {
                ctx.stroke(Ellipse().path(in: CGRect(x: x, y: y, width: w, height: h)), with: .color(color), lineWidth: lineW)
            } else if m.type == .line || m.type == .arrow {
                var p = Path()
                p.move(to: CGPoint(x: x, y: y + h))
                p.addLine(to: CGPoint(x: x + w, y: y))
                ctx.stroke(p, with: .color(color), lineWidth: lineW)
            } else if m.type == .text {
                let t = Text(m.text.isEmpty ? "Text" : m.text).font(.system(size: CGFloat(m.strokeWidth * 6), weight: .bold)).foregroundColor(color)
                ctx.draw(t, at: CGPoint(x: x, y: y), anchor: .topLeading)
            } else {
                var p = Path()
                if let first = m.points.first {
                    p.move(to: CGPoint(x: first.x * fitted.width, y: first.y * fitted.height))
                    for pt in m.points.dropFirst() {
                        p.addLine(to: CGPoint(x: pt.x * fitted.width, y: pt.y * fitted.height))
                    }
                    ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .frame(width: fitted.width, height: fitted.height)
        .allowsHitTesting(false)
        .opacity(live ? 0.8 : 1.0)
    }

    private func colorFromHex(_ hex: String) -> Color {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        return Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    // MARK: - Context menu

    /// Right-click menu for the whole viewer. Every hidden control can be
    /// brought back from here, so hiding the top bar (or all chrome) is never a
    /// dead end.
    @ViewBuilder
    private var viewerContextMenu: some View {
        Toggle("Show All Controls", isOn: $chromeVisible)
        Divider()
        Toggle("Top Bar", isOn: $showTopBar)
        Toggle("Filmstrip", isOn: $showFilmstrip)
        Toggle("Info Panel", isOn: $showInfo)
        Toggle("Adjustments", isOn: $showEdit)
        Divider()
        Button(isFullScreen ? "Exit Full Screen" : "Enter Full Screen") { toggleFullScreen() }
        Button("Viewer Settings…") { showViewerSettings = true }
        Divider()
        Button("Make Collage…") {
            NotificationCenter.default.post(name: .galleriaMakeCollage, object: nil)
        }
        Button("Minimize") { targetWindow?.miniaturize(nil) }
        Button("Close Viewer") { onClose() }
    }

    // MARK: - Floating chrome

    /// Chrome is anchored to the *window*, never to the photo: the top bar is
    /// pinned to the window top and the filmstrip to the window bottom with a
    /// fixed height, so changing photos (different aspect ratios) never moves
    /// the strip. Mouse scroll stays over the same pixels — over the strip it
    /// steps photos, over the photo it zooms.
    private var chrome: some View {
        ZStack {
            VStack(spacing: 0) {
                if chromeVisible && showTopBar {
                    topBar
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(chromeVisible && showTopBar)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                // The strip is pinned on via the right-click menu (or T).
                if showFilmstrip {
                    filmstrip
                        .onHover { hovering in
                            filmstripHovering = hovering
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                compactStatusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(true)

            if showEdit {
                HStack(alignment: .top, spacing: 0) {
                    editPanel
                    Spacer(minLength: 0)
                }
                .padding(.leading, 16)
                .padding(.top, 84)
                .padding(.bottom, filmstripInset + 4)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }

            if showInfo {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 0)
                    infoPanel
                }
                .padding(.trailing, 16)
                .padding(.top, 84)
                .padding(.bottom, filmstripInset + 4)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Top bar

    /// ONE bar for every mode. The compact glass bar is always shown; the
    /// rating, zoom, filmstrip, Finder and slideshow controls only append on
    /// the right while the viewer is full screen (a photo-sized window is too
    /// narrow for them). Toggling full screen no longer swaps in a different
    /// looking bar — the "second menu" is gone.
    private var topBar: some View {
        HStack(spacing: 4) {
            // The single glass bar carries the same close/minimize/maximize
            // buttons; no native title bar is stacked above it.
            windowControls
                .padding(.horizontal, 2)

            iconButton("chevron.left", help: "Previous photo (←)") { step(-1) }
                .disabled(index <= 0)
            iconButton("chevron.right", help: "Next photo (→)") { step(1) }
                .disabled(index >= photos.count - 1)

            if let p = photo {
                Button {
                    library.setFavorite([p.id], favorite: !p.favorite)
                } label: {
                    Image(systemName: p.favorite ? "heart.fill" : "heart")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(p.favorite ? Color.red : Color.primary)
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(ViewerIconButtonStyle(active: false))
                .help(p.favorite ? "Remove from Favorites (.)" : "Add to Favorites (.)")
                .accessibilityLabel(p.favorite ? "Remove from Favorites" : "Add to Favorites")

                if !isCompactWindow {
                    starPicker(for: p)
                }
            }

            if !isCompactWindow {
                zoomControls

                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1, height: 18)
                    .padding(.horizontal, 3)

                iconButton("rectangle.bottomthird.inset.filled",
                           help: "Show or hide filmstrip (T)",
                           active: showFilmstrip) {
                    showFilmstrip.toggle()
                    hoverFilmstripIndex = nil
                }
                iconButton("folder", help: "Show in Finder") { revealInFinder() }
                iconButton(slideshow ? "pause.fill" : "play.fill",
                           help: slideshow ? "Pause slideshow (S)" : "Start slideshow (S)") {
                    toggleSlideshow()
                }
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 1, height: 18)
                    .padding(.horizontal, 3)
            }

            Spacer(minLength: 4)

            iconButton("info.circle", help: "Info panel (I)", active: showInfo) {
                showInfo.toggle()
            }
            iconButton("slider.horizontal.3", help: "Adjustments (E)", active: showEdit) {
                showEdit.toggle()
            }
            iconButton("arrow.up.left.and.arrow.down.right", help: "Full screen (F)") {
                toggleFullScreen()
            }
            iconButton("gearshape", help: "Viewer settings", active: showViewerSettings) {
                showViewerSettings = true
            }
            .popover(isPresented: $showViewerSettings, arrowEdge: .bottom) {
                viewerSettings
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassSurface(cornerRadius: isCompactWindow ? 18 : 20)
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.top, 8)
    }

    /// macOS Finder-style status bar for the compact window, pinned to the
    /// window's bottom edge: filename and position on the left, photo facts
    /// (dimensions, file size, type) on the right.
    private var compactStatusBar: some View {
        HStack(spacing: 10) {
            Text(photo?.filename ?? "—")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel(photo?.filename ?? "No photo")
            Text("·")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(index + 1) of \(photos.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 16)
            Text(statusDimensionText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(statusFileSizeText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Text(statusTypeText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: statusBarInset)
        .glassSurface(cornerRadius: 0)
    }

    private var statusDimensionText: String {
        guard let p = photo else { return "" }
        if p.width > 1 && p.height > 1 { return "\(p.width) × \(p.height) px" }
        guard let size = image?.size,
              size.width > 1, size.height > 1 else { return "" }
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        return "\(w) × \(h) px"
    }

    private var statusFileSizeText: String {
        guard let p = photo else { return "" }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: p.path))?[.size] as? Int64 ?? 0
        guard bytes > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var statusTypeText: String {
        photo.flatMap { p in
            p.path.split(separator: ".").last.map { $0.uppercased() }
        } ?? ""
    }


    /// Close / minimize / maximize, drawn like the macOS traffic lights so the
    /// compact window still behaves like a normal window.
    private var windowControls: some View {
        HStack(spacing: 8) {
            trafficLight(Color(red: 1.00, green: 0.37, blue: 0.34),
                         symbol: "xmark",
                         help: "Close viewer (Esc)") { onClose() }
            trafficLight(Color(red: 1.00, green: 0.74, blue: 0.18),
                         symbol: "minus",
                         help: "Minimize") { targetWindow?.miniaturize(nil) }
            trafficLight(Color(red: 0.15, green: 0.79, blue: 0.25),
                         symbol: "arrow.up.left.and.arrow.down.right",
                         help: isFullScreen ? "Exit full screen (F)" : "Enter full screen (F)") {
                toggleFullScreen()
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }

    private func trafficLight(_ color: Color,
                              symbol: String,
                              help: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color)
                Image(systemName: symbol)
                    .font(.system(size: 6.5, weight: .black))
                    .foregroundStyle(.black.opacity(0.55))
            }
            .frame(width: 13, height: 13)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func iconButton(_ symbol: String,
                            help: String,
                            active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(ViewerIconButtonStyle(active: active))
        .help(help)
        .accessibilityLabel(help)
    }

    private func starPicker(for p: Photo) -> some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { s in
                Button {
                    library.setRating([p.id], rating: p.rating == s ? 0 : s)
                } label: {
                    Image(systemName: s <= p.rating ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(s <= p.rating ? .yellow : .secondary)
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(p.rating == s ? "Clear rating" : "Rate \(s) star\(s == 1 ? "" : "s")")
                .accessibilityLabel(p.rating == s ? "Clear rating" : "Rate \(s) star\(s == 1 ? "" : "s")")
            }
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            iconButton("minus.magnifyingglass", help: "Zoom out (−)") { zoomBy(1 / 1.25) }
                .disabled(zoom <= 1.001)
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { fitToWindow() }
            } label: {
                Text(zoom > 1.001 ? "\(Int((zoom * 100).rounded()))%" : "Fit")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .frame(minWidth: 42, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fit to window (0)")
            .accessibilityLabel("Fit to window")

            iconButton("plus.magnifyingglass", help: "Zoom in (+)") { zoomBy(1.25) }
        }
    }

    // MARK: - Viewer settings

    private var viewerSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Viewer Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Filmstrip size", systemImage: "rectangle.bottomthird.inset.filled")
                        .font(.callout)
                    Spacer()
                    Text("\(Int(filmstripThumbSize)) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $filmstripThumbSize, in: 48...140, step: 4)
            }

            Toggle("Show top bar", isOn: $showTopBar)
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle("Show filmstrip", isOn: $showFilmstrip)
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            Toggle("Start with controls hidden", isOn: $startHidden)
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Label("Slideshow interval", systemImage: "play.rectangle")
                    .font(.callout)
                Picker("Slideshow interval", selection: $slideshowInterval) {
                    Text("2 s").tag(2.0)
                    Text("3 s").tag(3.0)
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            Button {
                showViewerSettings = false
                showShortcuts = true
            } label: {
                Label("Keyboard Shortcuts…", systemImage: "keyboard")
                    .font(.callout)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: - Filmstrip

    private var filmstrip: some View {
        HStack(spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { i, p in
                            // Identify each cell by its photo, never its position:
                            // an index-based identity reuses a cell for a different
                            // file when the folder is rescanned, which used to leave
                            // the old image (and its tooltip) under the new filename.
                            // Dock-style magnification: the hovered thumb grows,
                            // its neighbours swell a little, like the macOS Dock.
                            let distance = hoverFilmstripIndex.map { abs($0 - i) } ?? 99
                            let magnify: CGFloat = distance == 0 ? 1.7
                                : distance == 1 ? 1.32
                                : distance == 2 ? 1.12 : 1.0
                            FilmstripCell(photo: p,
                                          selected: p.id == currentPhotoID,
                                          size: filmstripThumb,
                                          onHover: { hovering in
                                              if hovering {
                                                  hoverFilmstripIndex = i
                                              } else if hoverFilmstripIndex == i {
                                                  hoverFilmstripIndex = nil
                                              }
                                          })
                                .scaleEffect(magnify, anchor: .bottom)
                                .zIndex(magnify > 1 ? 10 : 0)
                                .animation(.spring(response: 0.3, dampingFraction: 0.8),
                                           value: hoverFilmstripIndex)
                                .id(p.id)
                                .onTapGesture { goTo(i) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(height: filmstripBarHeight)
                // Dock magnification grows the hovered thumb above the strip:
                // without this the scroll view clips it and nothing is visible.
                .scrollClipDisabled(true)
                .onChange(of: currentPhotoID) { _, newValue in
                    // Mouse-wheel stepping must not shift the strip under the
                    // pointer; keep its position and just move the highlight.
                    guard Date() >= ScrollZoom.suppressAutoCenterUntil else { return }
                    guard let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .onChange(of: photos.map(\.id)) { _, _ in
                    if let id = currentPhotoID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onAppear {
                    if let id = currentPhotoID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

        }
        .frame(maxWidth: .infinity)
        .glassSurface(cornerRadius: 18)
        .padding(.horizontal, isCompactWindow ? 8 : 16)
        .padding(.bottom, isCompactWindow ? 8 : 14)
    }


    // MARK: - Info panel

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Info", systemImage: "info.circle")
                    .font(.headline)
                Spacer()
                iconButton("xmark", help: "Hide info (I)") { showInfo = false }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    if exif.isEmpty {
                        Text("No metadata")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(exif.enumerated()), id: \.offset) { _, pair in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pair.0)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(pair.1)
                                .font(.caption)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // One accessibility element per row, otherwise VoiceOver reads the
                        // value twice (textSelection wraps it in a second element).
                        .accessibilityElement(children: .ignore)
                        .accessibilityRepresentation {
                            Text(verbatim: "\(pair.0): \(pair.1)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }

            Divider().opacity(0.4)

            Button {
                revealInFinder()
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(.caption.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reveal this photo in Finder")
        }
        .frame(width: 252)
        .frame(maxHeight: 520)
        .glassSurface(cornerRadius: 18)
    }

    // MARK: - Edit panel

    private func editSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String = "%+.2f") -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // No `step:` — macOS 26 draws tick marks below the track, and tight
            // steps fuse into a solid white line (seen under Straighten).
            Slider(value: value, in: range)
                .controlSize(.small)
                .onChange(of: value.wrappedValue) { _, _ in commit() }
        }
    }

    // Compact Preview-style adjustments: small like Preview's panel (248), not 280.
    private var editPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Adjust", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                iconButton("xmark", help: "Close adjustments (E)") { showEdit = false }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        previewMarkupsRepair()
                    } label: {
                        Label(isMarkup ? "Hide markup" : "Markup (Preview)", systemImage: "pencil.and.scribble")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(isMarkup ? Color.accentColor : Color.clear)

                    if isMarkup {
                        HStack(spacing: 6) {
                            Picker("Tool", selection: $markupTool) {
                                ForEach(MarkupType.allCases, id: \.rawValue) { t in
                                    Image(systemName: markupToolIcon(t)).tag(t)
                                }
                            }
                            .pickerStyle(.menu).labelsHidden()
                            ColorPicker("", selection: Binding(
                                get: { colorFromHex(markupColor) },
                                set: { c in markupColor = hexFrom(c) }
                            ))
                            .frame(width: 28, height: 28)
                            Slider(value: $markupStroke, in: 1...10, step: 0.5)
                                .frame(width: 80)
                            Button {
                                recipe.markups.removeLast()
                                commit()
                            } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.plain)
                            .disabled(recipe.markups.isEmpty)
                            .help("Undo last markup")
                        }
                        .font(.caption)
                        Picker("Tool", selection: $markupTool) {
                            ForEach(MarkupType.allCases, id: \.rawValue) { t in
                                Text(t.displayName).tag(t)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        Text("Drag on the photo to draw. Text asks for content on drop.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Button("Clear all markup", role: .destructive) {
                            recipe.markups.removeAll()
                            commit()
                        }
                        .buttonStyle(.plain).font(.caption)
                    }

                    Divider()

                    Toggle("I'm Feeling Lucky", isOn: Binding(
                        get: { recipe.autoEnhance },
                        set: { recipe.autoEnhance = $0; commit() }
                    ))
                    .font(.callout)
                    .help("One-click auto enhance")

                    Divider()

                    Text("Light")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    editSlider("Exposure", value: Binding(get: { recipe.exposure }, set: { recipe.exposure = $0 }), range: -2...2)
                    editSlider("Fill light", value: Binding(get: { recipe.fillLight }, set: { recipe.fillLight = $0 }), range: -1...1)
                    editSlider("Highlights", value: Binding(get: { recipe.highlights }, set: { recipe.highlights = $0 }), range: -1...1)
                    editSlider("Shadows", value: Binding(get: { recipe.shadows }, set: { recipe.shadows = $0 }), range: -1...1)
                    editSlider("Brightness", value: Binding(get: { recipe.brightness }, set: { recipe.brightness = $0 }), range: -1...1)
                    editSlider("Contrast", value: Binding(get: { recipe.contrast }, set: { recipe.contrast = $0 }), range: -1...1)
                    editSlider("Straighten", value: Binding(
                        get: { recipe.straighten },
                        set: { recipe.straighten = ($0 * 10).rounded() / 10 }), range: -8...8, format: "%+.1f°")

                    Divider()

                    Text("Color")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    editSlider("Warmth", value: Binding(get: { recipe.warmth }, set: { recipe.warmth = $0 }), range: -1...1)
                    editSlider("Saturation", value: Binding(get: { recipe.saturation }, set: { recipe.saturation = $0 }), range: -1...1)

                    Divider()

                    Text("Detail")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    editSlider("Sharpen", value: Binding(get: { recipe.sharpen }, set: { recipe.sharpen = $0 }), range: 0...1)
                    editSlider("Vignette", value: Binding(get: { recipe.vignette }, set: { recipe.vignette = $0 }), range: 0...1)

                    Divider()

                    Text("Filters")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(PhotoFilter.allCases, id: \.rawValue) { f in
                                Button(f.displayName) {
                                    recipe.filter = f
                                    commit()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(recipe.filter == f ? .accentColor : Color.clear)
                            }
                        }
                    }

                    Divider()

                    Text("Preview tools")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    HStack(spacing: 6) {
                        Button { showResize = true } label: {
                            Label("Resize…", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        Button { showInstantAlpha = true } label: {
                            Label("Alpha", systemImage: "wand.and.stars")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    HStack(spacing: 6) {
                        Button {
                            copiedStyle = recipe.encoded
                            UserDefaults.standard.set(copiedStyle, forKey: "galleria.copiedStyle")
                            library.flash("Style copied", seconds: 3)
                        } label: {
                            Label("Copy style", systemImage: "doc.on.doc")
                        }
                        Button {
                            if let s = UserDefaults.standard.string(forKey: "galleria.copiedStyle"),
                               !s.isEmpty {
                                recipe = EditRecipe.decode(s)
                                commit()
                            }
                        } label: {
                            Label("Paste", systemImage: "doc.on.clipboard")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(copiedStyle.isEmpty && UserDefaults.standard.string(forKey: "galleria.copiedStyle") == nil)

                    Divider()

                    Text("Smart tools")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                    Button {
                        guard let p = photo else { return }
                        let path = p.path
                        DispatchQueue.global(qos: .userInitiated).async {
                            if let cg = Imaging.baseCGImage(path: path, maxPixel: 1200) {
                                let eyes = FaceDetector.eyeRects(in: cg)
                                let msg = eyes.isEmpty ? "No eyes detected" : "Detected \(eyes.count) eye(s) — applied eye-friendly warmth + slight desaturation"
                                DispatchQueue.main.async {
                                    if !eyes.isEmpty {
                                        recipe.saturation = min(recipe.saturation, -0.05)
                                        recipe.warmth = min(recipe.warmth, 0.05)
                                        commit()
                                    }
                                    library.flash(msg, seconds: 5)
                                }
                            }
                        }
                    } label: {
                        Label("Red-eye assist", systemImage: "eye")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        NotificationCenter.default.post(name: .galleriaCompare, object: nil)
                    } label: {
                        Label("Compare…", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Divider()

                    HStack(spacing: 8) {
                        Button { rotate(90) } label: {
                            Label("Left", systemImage: "rotate.left")
                        }
                        Button { rotate(270) } label: {
                            Label("Right", systemImage: "rotate.right")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Toggle("Flip horizontally", isOn: Binding(
                        get: { recipe.flipH },
                        set: { recipe.flipH = $0; commit() }
                    ))

                    Divider()

                    Text("Crop")
                        .font(.subheadline.weight(.semibold))
                    Button(isCropping ? "Cancel crop" : "Start crop") {
                        isCropping.toggle()
                        cropRect = .zero
                        zoom = 1
                        offset = .zero
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Apply crop") {
                        if cropRect.width > 0.01 && cropRect.height > 0.01 {
                            recipe.crop = EditRecipe.CropRect(x: cropRect.minX, y: cropRect.minY,
                                                              w: cropRect.width, h: cropRect.height)
                            commit()
                        }
                        isCropping = false
                        cropRect = .zero
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!isCropping || cropRect.width < 0.01)

                    Divider()

                    Button("Make Collage from folder…") {
                        NotificationCenter.default.post(name: .galleriaMakeCollage, object: nil)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Open Collage Maker")

                    Button("Reset all edits", role: .destructive) {
                        recipe = .identity
                        commit()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Text("Edits are non-destructive — your original file is never modified. Use ⌘E to export with edits baked in.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
            }
        }
        .frame(width: 248)
        .frame(maxHeight: 560)
        .glassSurface(cornerRadius: 18)
    }

    private func previewMarkupsRepair() {
        isMarkup.toggle()
        if isMarkup {
            chromeVisible = true
            showEdit = true
        }
    }

    private func markupToolIcon(_ t: MarkupType) -> String {
        switch t {
        case .rect: return "rectangle"
        case .oval: return "circle"
        case .line: return "line.3.horizontal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .freehand: return "scribble"
        }
    }

    private func hexFrom(_ c: Color) -> String {
        // Best-effort: convert via NSColor. NSColor components.
        let ns = NSColor(c)
        let rgb = ns.usingColorSpace(.deviceRGB) ?? ns
        let r = Int(clamp(rgb.redComponent, 0, 1) * 255)
        let g = Int(clamp(rgb.greenComponent, 0, 1) * 255)
        let b = Int(clamp(rgb.blueComponent, 0, 1) * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { max(lo, min(hi, v)) }

    // MARK: - Behaviour

    /// Fetch every indexed photo in the folder straight from the catalogue so an
    /// active grid filter (search, rating, Favorites) never narrows the viewer.
    /// Re-anchors on the photo being viewed without reloading it unnecessarily.
    private func refreshFolderScope(anchorID: Int64, folder: String) {
        library.loadPhotos(inFolder: folder) { rows in
            guard !rows.isEmpty else { return }
            if rows.map(\.id) != folderPhotos.map(\.id) {
                folderPhotos = rows
            }
            if let i = rows.firstIndex(where: { $0.id == anchorID }) {
                if i != index { index = i }
            } else {
                // The anchor disappeared (file deleted or moved) between opening
                // and this refresh. Move to the nearest surviving photo and make
                // the identity follow it, so the image, filename and tooltip can
                // never disagree with the highlighted thumbnail.
                let fallback = min(max(index, 0), rows.count - 1)
                index = fallback
                let id = rows[fallback].id
                if currentPhotoID != id { currentPhotoID = id }
            }
        }
    }

    /// Change the shown photo, keeping identity and index in sync in one place.
    private func goTo(_ i: Int) {
        guard photos.indices.contains(i) else { return }
        currentPhotoID = photos[i].id
        index = i
    }

    private func step(_ delta: Int) {
        goTo(index + delta)
    }

    private func zoomBy(_ factor: CGFloat) {
        zoom = min(max(zoom * factor, 1), 12)
        if zoom <= 1 { offset = .zero }
    }

    /// Zoom while keeping the point under the pointer fixed (Google Photos-style
    /// wheel zoom). `windowPoint` is in AppKit window coordinates.
    private func zoomAnchored(to newZoom: CGFloat, at windowPoint: CGPoint) {
        let clamped = min(max(newZoom, 1), 12)
        guard let content = targetWindow?.contentView else {
            zoom = clamped
            if clamped <= 1 { offset = .zero }
            return
        }
        if clamped <= 1.001 {
            zoom = 1
            offset = .zero
            return
        }
        let bounds = content.bounds
        let d = CGSize(width: windowPoint.x - bounds.midX,
                       height: -(windowPoint.y - bounds.midY))
        let factor = clamped / max(zoom, 0.001)
        offset = CGSize(
            width: offset.width * factor + d.width * (1 - factor),
            height: offset.height * factor + d.height * (1 - factor)
        )
        zoom = clamped
    }

    private func toggleSlideshow() {
        slideshow.toggle()
        slideshowTask?.cancel()
        slideshowTask = nil
        if slideshow { startSlideshow() }
    }

    private func startSlideshow() {
        slideshowTask = Task { @MainActor in
            while !Task.isCancelled {
                let interval = max(1, slideshowInterval)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                guard !photos.isEmpty else { break }
                if index >= photos.count - 1 {
                    goTo(0)
                } else {
                    step(1)
                }
            }
        }
    }

    private func fitToWindow() {
        zoom = 1
        offset = .zero
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if zoom > 1 {
                zoom = 1
                offset = .zero
            } else {
                zoom = 2.5
            }
        }
    }

    private func toggleFullScreen() {
        targetWindow?.toggleFullScreen(nil)
    }

    // MARK: - Window presentation

    /// Hide the native toolbar and then enter the requested presentation. The
    /// toolbar is managed through AppKit: toggling it through SwiftUI's toolbar
    /// modifier makes macOS drop out of full screen when the catalogue refreshes.
    private func applyPresentationOnOpen() {
        if let w = targetWindow {
            // Remember the grid's toolbar state across viewer re-creations, and
            // refresh it only when the window is back to a normal grid window.
            if ViewerWindowMemory.toolbarVisible == nil || w.styleMask.contains(.resizable) {
                ViewerWindowMemory.toolbarVisible = w.toolbar?.isVisible
            }
            savedToolbarVisible = ViewerWindowMemory.toolbarVisible
            w.toolbar?.isVisible = false
        }
        // A long photo (at least twice as tall as wide — scrolling screenshots,
        // tall panoramas) never fits a compact photo-shaped window without
        // becoming an unreadable sliver, so it opens full screen by default.
        if isCompactPresentation && !photoIsLong {
            // Let the viewer's insertion animation settle before resizing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                applyCompactWindow()
            }
        } else {
            enterFullScreenOnOpen()
        }
    }

    /// "Long" photo: at least twice as tall as wide. These open full screen
    /// instead of the compact photo-shaped window.
    private var photoIsLong: Bool {
        let p = photo ?? photo(at: index)
        guard let p, p.width > 0, p.height > 0 else { return false }
        return CGFloat(p.height) / CGFloat(p.width) >= 2.0
    }

    /// Full screen on open: used when the viewer opens in the immersive
    /// presentation, or when a long photo needs the whole screen (it never
    /// fits a compact photo-shaped window). A single request is enough;
    /// retrying during the full-screen animation can wedge AppKit's transition.
    private func enterFullScreenOnOpen() {
        guard !isFullScreen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard !isFullScreen else { return }
            guard let w = targetWindow else { return }
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.toggleFullScreen(nil)
        }
    }

    /// Retry compacting after a full-screen transition settles. One timer runs
    /// at a time so rapid re-entry cannot stack dozens of toggles.
    @State private var compactRetryScheduled = false
    private func scheduleCompactRetry() {
        guard !compactRetryScheduled else { return }
        compactRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            compactRetryScheduled = false
            guard isCompactPresentation else { return }
            applyCompactWindow()
        }
    }

    /// Size the window to the photo and remove every non-photo pixel from the
    /// window: transparent title bar, no toolbar, optional floating corner
    /// buttons. The result is the photo at its own aspect ratio, edge to edge.
    private func applyCompactWindow() {
        guard isCompactPresentation else { return }
        guard let w = targetWindow else { return }

        // AppKit aborts if the style mask is touched while a window is moving
        // into or out of a native full-screen state (e.g. the grid relaunched
        // into full screen). Wait until the transition itself is over, then
        // retry — a single retry chain, never a full-screen re-toggle loop.
        if ViewerWindowMemory.fullScreenTransitioning {
            scheduleCompactRetry()
            return
        }
        if w.styleMask.contains(.fullScreen) {
            w.toggleFullScreen(nil)
            scheduleCompactRetry()
            return
        }

        let firstApply = !compactApplied
        if firstApply {
            compactApplied = true
            // Reuse the grid's window chrome across photo switches. Only a
            // normal, resizable grid window is worth re-capturing.
            if ViewerWindowMemory.frame == nil || w.styleMask.contains(.resizable) {
                ViewerWindowMemory.frame = w.frame
                ViewerWindowMemory.styleMask = w.styleMask
                ViewerWindowMemory.titleVisibility = w.titleVisibility
                ViewerWindowMemory.titlebarTransparent = w.titlebarAppearsTransparent
                ViewerWindowMemory.contentMinSize = w.contentMinSize
            }
            savedWindowFrame = ViewerWindowMemory.frame
            savedStyleMask = ViewerWindowMemory.styleMask
            savedTitleVisibility = ViewerWindowMemory.titleVisibility
            savedTitlebarTransparent = ViewerWindowMemory.titlebarTransparent
            savedContentMinSize = ViewerWindowMemory.contentMinSize
            savedToolbarVisible = ViewerWindowMemory.toolbarVisible
        }

        w.toolbar?.isVisible = false
        w.titleVisibility = .hidden
        w.backgroundColor = .black
        // Let the window shrink to a small photo; the grid's minimum must not
        // leak into the compact presentation.
        w.contentMinSize = NSSize(width: 120, height: 120)

        // The compact window always uses floating glass chrome: the photo runs
        // edge to edge and ONE top bar carries the photo controls plus the
        // traffic lights. A native title bar stacked above the glass bar gave
        // two overlapping bars — that mode is gone.
        w.styleMask.insert(.fullSizeContentView)
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = zoom <= 1.001

        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true

        // The compact window is the photo. Lock its shape so a stray resize can
        // never letterbox or distort the image.
        if !w.styleMask.contains(.fullScreen) {
            w.styleMask.remove(.resizable)
        }

        resizeCompactWindow(animated: !firstApply)
    }

    /// Resize the window so its content is exactly the photo's shape. The window
    /// is anchored to the bottom centre of the visible frame (not the centre),
    /// so the filmstrip — pinned to the window bottom — stays at the same screen
    /// Y when photos of different aspect ratios change the window height.
    private func resizeCompactWindow(animated: Bool = true) {
        // Only size the window after the compact presentation has captured the
        // grid's frame and chrome. Otherwise a fast image load would resize the
        // window first, and closing the viewer would "restore" the compact size.
        guard isCompactWindow, compactApplied, let w = targetWindow else { return }
        guard let contentSize = compactContentSize(for: photo) else { return }

        let screen = w.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1470, height: 900)

        // With a transparent full-size content view the frame is the photo; with
        // the native title bar the content area must be the photo's size. Add the
        // fixed chrome strips so the photo itself stays photo-sized inside a
        // window that also contains its filmstrip/top bar.
        let titlebar: CGFloat = 0
        let chromeH: CGFloat = (showFilmstrip ? filmstripBarHeight + 26 : 0)
            + (chromeVisible && showTopBar ? 64 : 0)
            + statusBarInset

        // Shrink the content until the whole frame (photo + chrome strips) fits
        // the visible screen: a tall photo used to push its filmstrip and caption
        // below the screen edge.
        var size = NSSize(width: contentSize.width, height: contentSize.height)
        let availH = max(300, visible.height * 0.96 - titlebar - chromeH)
        if size.height > availH {
            let factor = availH / size.height
            size = NSSize(width: (size.width * factor).rounded(),
                          height: (size.height * factor).rounded())
        }

        let frameSize = NSSize(width: size.width,
                               height: size.height + titlebar + chromeH)
        // Bottom-anchored: filmstrip stays at a fixed screen Y while photo grows/shrinks above it.
        let origin = NSPoint(x: visible.midX - frameSize.width / 2,
                             y: visible.minY + 24)
        let frame = NSRect(origin: origin, size: frameSize)

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                w.animator().setFrame(frame, display: true)
            }
        } else {
            w.setFrame(frame, display: true)
        }

    }

    /// The photo's own pixel size, scaled down only when it would not fit on the
    /// screen. Small photos are shown at 1:1 rather than blown up.
    private func compactContentSize(for photo: Photo?) -> NSSize? {
        guard let photo else { return nil }
        var pixel = CGSize(width: photo.width, height: photo.height)
        if pixel.width <= 0 || pixel.height <= 0,
           let size = Imaging.pixelSize(path: photo.path) {
            pixel = size
        }
        if pixel.width <= 0 || pixel.height <= 0,
           let img = image {
            pixel = img.size
        }
        guard pixel.width > 1, pixel.height > 1 else { return nil }

        let screen = targetWindow?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1470, height: 900)
        let maxW = visible.width * 0.9
        let maxH = visible.height * 0.9
        let scale = min(1, maxW / pixel.width, maxH / pixel.height)
        var size = NSSize(width: (pixel.width * scale).rounded(),
                          height: (pixel.height * scale).rounded())

        // Never open a postage stamp — but never grow past the screen either.
        let minSide: CGFloat = 360
        if size.width < minSide || size.height < minSide {
            let grow = max(minSide / max(size.width, 1), minSide / max(size.height, 1))
            size = NSSize(width: (size.width * grow).rounded(),
                          height: (size.height * grow).rounded())
            let clamp = min(1, maxW / max(size.width, 1), maxH / max(size.height, 1))
            if clamp < 1 {
                size = NSSize(width: (size.width * clamp).rounded(),
                              height: (size.height * clamp).rounded())
            }
        }
        return size
    }

    /// Undo everything `applyCompactWindow` changed, so the grid gets its normal
    /// window (frame, title bar, traffic lights, toolbar) back.
    private func restoreWindowChrome() {
        guard let w = targetWindow else { return }
        if ViewerWindowMemory.fullScreenTransitioning {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { restoreWindowChrome() }
            return
        }
        if compactApplied && w.styleMask.contains(.fullScreen) {
            // Leave full screen first, then put the grid's window back the way it was.
            w.toggleFullScreen(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                restoreCompactState(on: w)
            }
        } else {
            restoreCompactState(on: w)
        }
    }

    private func restoreCompactState(on w: NSWindow) {
        if compactApplied {
            if let mask = savedStyleMask { w.styleMask = mask }
            w.titleVisibility = savedTitleVisibility
            w.titlebarAppearsTransparent = savedTitlebarTransparent
            w.isMovableByWindowBackground = false
            w.standardWindowButton(.closeButton)?.isHidden = false
            w.standardWindowButton(.miniaturizeButton)?.isHidden = false
            w.standardWindowButton(.zoomButton)?.isHidden = false
            w.contentMinSize = savedContentMinSize ?? NSSize(width: 0, height: 0)
            if let frame = savedWindowFrame {
                w.setFrame(frame, display: true)
            }
            compactApplied = false
        }
        if let visible = savedToolbarVisible {
            w.toolbar?.isVisible = visible
            savedToolbarVisible = nil
        }
    }

    private func revealInFinder() {
        guard let p = photo else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)])
    }

    private func rotate(_ deg: Int) {
        recipe.rotation = (recipe.rotation + deg) % 360
        commit()
    }

    private func commit() {
        guard let p = photo else { return }
        library.saveEdit(recipe, for: p.id)
        reloadImage()
    }

    private func resetView() {
        zoom = 1
        offset = .zero
        panStart = nil
        isCropping = false
        cropRect = .zero
        exif = []
    }

    private func load() {
        guard let p = photo else { image = nil; backdrop = nil; return }
        isLoading = true

        let path = p.path
        let mtime = p.mtime

        // Blurred backdrop: a small thumbnail is plenty once it is blurred.
        // Load it synchronously so the backdrop (and its blur) is present on
        // the very first frame — otherwise fullscreen shows black bars until
        // the async thumbnail finishes (or forever if it fails).
        if let cached = ThumbnailService.shared.cachedThumbnail(path: path, mtime: mtime) {
            backdrop = cached
        } else if let cg = Imaging.baseCGImage(path: path, maxPixel: 420) {
            backdrop = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        } else {
            backdrop = nil
        }
        Task {
            let thumb = await ThumbnailService.shared.thumbnail(path: path, mtime: mtime, size: 420)
            await MainActor.run {
                if photo?.id == p.id { backdrop = thumb }
            }
        }

        Task {
            // Never block the main thread on the catalogue queue: a folder scan
            // may be using it.
            let r = await library.loadEditAsync(for: p.id)
            await MainActor.run {
                guard photo?.id == p.id else { return }
                recipe = r
                DispatchQueue.global(qos: .userInitiated).async {
                    let img = Editor.render(path: path, recipe: r, maxPixel: 3000)
                    let meta = Imaging.exif(path: path)
                    let size = Imaging.pixelSize(path: path)
                    DispatchQueue.main.async {
                        guard photo?.id == p.id else { return }
                        image = img
                        exif = meta
                        isLoading = false
                        if let s = size, p.width == 0 {
                            library.setDimensions(photoID: p.id, width: Int(s.width), height: Int(s.height))
                        }
                        // The compact window is the photo: keep its shape in sync.
                        if isCompactWindow { resizeCompactWindow() }
                    }
                }
            }
        }
    }

    private func reloadImage() {
        guard let p = photo else { return }
        let path = p.path
        let r = recipe
        DispatchQueue.global(qos: .userInitiated).async {
            let img = Editor.render(path: path, recipe: r, maxPixel: 3000)
            DispatchQueue.main.async {
                guard photo?.id == p.id else { return }
                image = img
            }
        }
    }

    private func installKeyMonitor() {
        scrollMonitor = ScrollZoom.install { ctx in
            guard !isCropping else { return false }

            // Over the filmstrip: vertical wheel steps through photos, while a
            // horizontal swipe keeps the strip's own scrolling.
            if ctx.overFilmstrip {
                guard abs(ctx.deltaY) > abs(ctx.deltaX) else { return false }
                let now = Date()
                if now.timeIntervalSince(ScrollZoom.lastFilmstripStep) < 0.22 { return true }
                ScrollZoom.filmstripAccum += ctx.deltaY
                if abs(ScrollZoom.filmstripAccum) >= 8 {
                    let direction = ScrollZoom.filmstripAccum > 0 ? 1 : -1
                    ScrollZoom.filmstripAccum = 0
                    ScrollZoom.lastFilmstripStep = now
                    // Keep the strip exactly where it is while the wheel steps
                    // through photos; only the selected highlight moves.
                    ScrollZoom.suppressAutoCenterUntil = now.addingTimeInterval(0.7)
                    step(direction)
                }
                return true
            }

            // Over the info panel (or any other scroll view): native scrolling.
            if ctx.overScrollView { return false }

            // Over the photo: scrolling zooms toward the pointer, fit or zoomed
            // alike. Arrows (and the filmstrip wheel) step through photos.
            let factor = min(max(pow(1.0025, Double(ctx.deltaY)), 0.75), 1.33)
            zoomAnchored(to: zoom * CGFloat(factor), at: ctx.location)
            return true
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 123: step(-1); return nil                     // ←
            case 124: step(1); return nil                      // →
            case 53:                                           // esc
                if isFullScreen {
                    targetWindow?.toggleFullScreen(nil)
                } else if isCropping {
                    isCropping = false
                    cropRect = .zero
                } else {
                    onClose()
                }
                return nil
            case 49: toggleZoom(); return nil                  // space
            case 24, 69: zoomBy(1.25); return nil              // + / =
            case 27, 78:                                       // − / _
                zoomBy(1 / 1.25)
                return nil
            case 29, 18: fitToWindow(); return nil             // 0 / 1
            case 48, 4:                                        // tab / h — hide/show all chrome
                chromeVisible.toggle()
                return nil
            case 3: toggleFullScreen(); return nil             // f
            case 17: showFilmstrip.toggle(); hoverFilmstripIndex = nil; return nil        // t
            case 11: showTopBar.toggle(); return nil           // b
            case 34: showInfo.toggle(); return nil             // i
            case 14: showEdit.toggle(); return nil             // e
            case 1: toggleSlideshow(); return nil              // s
            case 47:                                           // . — favorite
                if let p = photo {
                    library.setFavorite([p.id], favorite: !p.favorite)
                }
                return nil
            case 44:                                           // ? (shift-/)
                if event.modifierFlags.contains(.shift) {
                    showShortcuts = true
                    return nil
                }
                return event
            default: return event
            }
        }
    }
}

// MARK: - Glass surface

extension View {
    /// Apple's Liquid Glass on macOS 26+, with a material fallback for older systems.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

// MARK: - Icon button style

private struct ViewerIconButtonStyle: ButtonStyle {
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Color.white : Color.primary)
            .background(
                Circle().fill(
                    active
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.7 : 0.9)
                    : Color.primary.opacity(configuration.isPressed ? 0.20 : 0.08)
                )
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Scroll wheel behaviour

/// Scroll-wheel / two-finger scrolling over the photo zooms toward the pointer;
/// over the filmstrip it steps previous/next; over the info panel it keeps its
/// normal behaviour. We hit-test before deciding.
private enum ScrollZoom {
    struct Context {
        let deltaX: CGFloat
        let deltaY: CGFloat
        let modifiers: NSEvent.ModifierFlags
        let location: CGPoint
        let overFilmstrip: Bool
        let overScrollView: Bool
    }

    /// Accumulates trackpad deltas so one gentle swipe moves one photo, while a
    /// mouse-wheel notch steps immediately.
    static var filmstripAccum: CGFloat = 0
    static var lastFilmstripStep = Date.distantPast
    /// While the wheel is stepping photos, the strip keeps its scroll offset
    /// instead of animating back to the selected thumbnail.
    static var suppressAutoCenterUntil = Date.distantPast

    static func install(_ handler: @escaping (Context) -> Bool) -> Any {
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Synthetic events sometimes carry no window, so hit-test against the key window.
            guard let window = event.window ?? NSApp.keyWindow else { return event }
            let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let hit = window.contentView?.hitTest(point)
            let scroll = hit.flatMap(enclosingScrollView)
            let context = Context(
                deltaX: event.scrollingDeltaX,
                deltaY: event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 12,
                modifiers: event.modifierFlags,
                location: point,
                overFilmstrip: scroll.map(isFilmstrip) ?? false,
                overScrollView: scroll != nil
            )
            guard context.deltaX != 0 || context.deltaY != 0 else { return event }
            return handler(context) ? nil : event
        }
    }

    private static func enclosingScrollView(_ view: NSView) -> NSScrollView? {
        var v: NSView? = view
        while let current = v {
            if let scroll = current as? NSScrollView { return scroll }
            v = current.superview
        }
        return nil
    }

    private static func isFilmstrip(_ scroll: NSScrollView) -> Bool {
        // The filmstrip is a short, wide horizontal strip; the info panel is tall.
        guard let parent = scroll.superview else { return false }
        let frame = scroll.convert(scroll.bounds, to: parent)
        return frame.height <= 180 && frame.width > frame.height * 1.4
    }
}

// MARK: - Filmstrip cell

private struct FilmstripCell: View {
    let photo: Photo
    let selected: Bool
    let size: CGFloat
    var onHover: ((Bool) -> Void)? = nil
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.14),
                              lineWidth: selected ? 2.5 : 1)
        }
        .opacity(selected ? 1 : 0.72)
        .scaleEffect(selected ? 1 : 0.96)
        .animation(.easeInOut(duration: 0.18), value: selected)
        .onHover { hovering in onHover?(hovering) }
        .task(id: "\(photo.id)-\(Int(size))") {
            image = await ThumbnailService.shared.thumbnail(
                path: photo.path, mtime: photo.mtime, size: size * 2
            )
        }
    }
}

// MARK: - Filmstrip hover preview


// MARK: - Keyboard shortcuts sheet

struct ViewerShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("Navigation", [
            ("← / →", "Previous / next photo"),
            ("Scroll on filmstrip", "Previous / next photo"),
            ("Click a thumbnail", "Jump to that photo"),
        ]),
        ("Zoom", [
            ("Scroll on photo", "Zoom in / out at the pointer"),
            ("Pinch", "Zoom in / out"),
            ("+ / −", "Zoom in / out"),
            ("Space", "Toggle fit / 250%"),
            ("0 or 1", "Fit to window"),
            ("Drag", "Pan while zoomed"),
        ]),
        ("View", [
            ("Tab / H", "Hide or show all controls"),
            ("F", "Toggle full screen"),
            ("Double-click", "Toggle full screen"),
            ("T", "Show or hide filmstrip"),
            ("B", "Show or hide top bar"),
            ("I", "Show or hide info"),
            ("E", "Show or hide adjustments"),
            ("S", "Start or pause slideshow"),
            (".", "Add or remove from Favorites"),
        ]),
        ("General", [
            ("Esc", "Exit full screen / close viewer"),
            ("?", "Show this shortcuts sheet"),
        ]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.0)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            ForEach(Array(group.1.enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.0)
                                        .font(.system(.callout, design: .monospaced))
                                        .frame(width: 150, alignment: .leading)
                                    Text(row.1)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 460, height: 520)
    }
}

