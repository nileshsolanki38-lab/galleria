import SwiftUI
import AppKit

/// Files handed to the app by Finder ("Open With"), the command line, or a drag
/// onto the Dock icon. They are queued until the main window is ready to show them.
enum OpenQueue {
    private(set) static var pending: [URL] = []

    static func enqueue(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if Thread.isMainThread {
            pending.append(contentsOf: urls)
            NotificationCenter.default.post(name: .galleriaOpenPhoto, object: nil)
        } else {
            DispatchQueue.main.async { enqueue(urls) }
        }
    }

    static func drain() -> [URL] {
        let urls = pending
        pending.removeAll()
        return urls
    }
}

final class GalleriaAppDelegate: NSObject, NSApplicationDelegate {
    /// Finder "Open With" / double-click in Finder. macOS prefers this over openFile.
    func application(_ application: NSApplication, open urls: [URL]) {
        OpenQueue.enqueue(urls)
    }

    /// Older code paths and some drag-and-drop sources still use openFile.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        OpenQueue.enqueue([URL(fileURLWithPath: filename)])
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

@main
struct GalleriaApp: App {
    @NSApplicationDelegateAdaptor(GalleriaAppDelegate.self) private var appDelegate
    @StateObject private var library = LibraryStore.shared

    init() {
        let args = CommandLine.arguments

        // Headless helper: `Galleria --scan <folder> [more folders…]` indexes on launch.
        if let idx = args.firstIndex(of: "--scan"), idx + 1 < args.count {
            let paths = args[(idx + 1)...].prefix { !$0.hasPrefix("-") }
            if !paths.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    for raw in paths {
                        let path = (raw as NSString).expandingTildeInPath
                        LibraryStore.shared.addFolder(URL(fileURLWithPath: path))
                    }
                }
            }
        } else {
            // `open -a Galleria photo.jpg` / dragging a file onto the app icon: the
            // file arrives as a command-line argument before the window exists.
            let files = args.dropFirst().compactMap { raw -> URL? in
                guard !raw.hasPrefix("-") else { return nil }
                let path = (raw as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { return nil }
                return URL(fileURLWithPath: path)
            }
            OpenQueue.enqueue(files)
        }
    }

    var body: some Scene {
        // A single library window. `WindowGroup` would spawn a second window
        // every time Finder sends us an "Open With" file.
        Window("Galleria", id: "main") {
            ContentView()
                .environmentObject(library)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .toolbar) {
                Button("Keyboard Shortcuts…") {
                    NotificationCenter.default.post(name: .galleriaShowShortcuts, object: nil)
                }
                .keyboardShortcut("/", modifiers: [.command])
            }
            CommandMenu("Library") {
                Button("Open Photo…") {
                    NotificationCenter.default.post(name: .galleriaOpenPhotoPicker, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Add Folder…") {
                    NotificationCenter.default.post(name: .galleriaAddFolder, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Rescan Library") {
                    LibraryStore.shared.rescanAll()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Button("Make Collage…") {
                    NotificationCenter.default.post(name: .galleriaMakeCollage, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button("Compare Selection…") {
                    NotificationCenter.default.post(name: .galleriaCompare, object: nil)
                }
                .keyboardShortcut("c", modifiers: [.command])

                Button("People (Faces)…") {
                    NotificationCenter.default.post(name: .galleriaFaces, object: nil)
                }
                Button("Places (Map)…") {
                    NotificationCenter.default.post(name: .galleriaPlaces, object: nil)
                }
                Button("Duplicate Finder…") {
                    NotificationCenter.default.post(name: .galleriaDuplicates, object: nil)
                }
                Button("Batch Resize / Convert…") {
                    NotificationCenter.default.post(name: .galleriaBatch, object: nil)
                }

                Divider()

                Button("Export Selected…") {
                    NotificationCenter.default.post(name: .galleriaExport, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command])
            }
        }
    }
}

extension Notification.Name {
    static let galleriaAddFolder = Notification.Name("galleria.addFolder")
    static let galleriaExport = Notification.Name("galleria.export")
    static let galleriaOpenPhoto = Notification.Name("galleria.openPhoto")
    static let galleriaOpenPhotoPicker = Notification.Name("galleria.openPhotoPicker")
    static let galleriaShowShortcuts = Notification.Name("galleria.showShortcuts")
    static let galleriaMakeCollage = Notification.Name("galleria.makeCollage")
    static let galleriaCompare = Notification.Name("galleria.compare")
    static let galleriaFaces = Notification.Name("galleria.faces")
    static let galleriaPlaces = Notification.Name("galleria.places")
    static let galleriaDuplicates = Notification.Name("galleria.duplicates")
    static let galleriaBatch = Notification.Name("galleria.batch")
}
