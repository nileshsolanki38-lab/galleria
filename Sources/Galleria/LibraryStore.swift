import Foundation
import SQLite3
import UniformTypeIdentifiers
import Darwin

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed photo catalogue. Folder-based: nothing is ever copied or moved.
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var photos: [Photo] = []
    @Published var folders: [String] = []
    @Published var albums: [Album] = []
    @Published var isScanning = false
    @Published var isWatching = false
    @Published var status: String = ""
    @Published var totalCount: Int = 0

    private var statusClearWork: DispatchWorkItem?

    /// Shows a transient message in the status bar, then fades it out.
    func flash(_ message: String, seconds: Double = 6) {
        DispatchQueue.main.async {
            self.status = message
            self.statusClearWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.status = "" }
            self.statusClearWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.galleria.db")
    /// Filesystem enumeration, permission checks and EXIF reads happen here so
    /// the catalogue queue is never blocked for long. Only short SQLite bursts
    /// hop back onto `queue`.
    private let scanQueue = DispatchQueue(label: "com.galleria.scan", qos: .utility)
    private let watcher = FolderWatcher()
    private let watchQueue = DispatchQueue(label: "com.galleria.watcher-setup", qos: .utility)

    // MARK: - Paths

    private var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Galleria", isDirectory: true)
    }

    private var dbURL: URL { supportDir.appendingPathComponent("library.sqlite") }

    static var thumbnailCacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("Galleria/Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: - Lifecycle

    private init() {
        openDatabase()
        migrate()
        configureWatcher()
        loadFolders()
        loadAlbums()
        loadSmartAlbums()
        refresh()

        // Catch anything that changed while the app was closed. This is incremental,
        // so unchanged files cost nothing more than a directory walk. Throttle to
        // once per hour so a quick relaunch doesn't re-walk every folder (which
        // looked like "scanning again" on every launch).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            let last = UserDefaults.standard.double(forKey: "Galleria.lastFullScan")
            let now = Date().timeIntervalSince1970
            if last == 0 || (now - last) > 3600 {
                UserDefaults.standard.set(now, forKey: "Galleria.lastFullScan")
                self.rescanAll(announce: false)
            } else {
                self.refresh()
            }
        }
    }

    private func openDatabase() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            NSLog("Galleria: failed to open database at \(dbURL.path)")
            return
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS photos(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE,
            filename TEXT NOT NULL,
            folder TEXT NOT NULL,
            mtime REAL NOT NULL,
            date REAL NOT NULL DEFAULT 0,
            rating INTEGER NOT NULL DEFAULT 0,
            favorite INTEGER NOT NULL DEFAULT 0,
            caption TEXT NOT NULL DEFAULT '',
            tags TEXT NOT NULL DEFAULT '',
            width INTEGER NOT NULL DEFAULT 0,
            height INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_photos_folder ON photos(folder);
        CREATE INDEX IF NOT EXISTS idx_photos_mtime ON photos(mtime);
        CREATE INDEX IF NOT EXISTS idx_photos_date ON photos(date);
        CREATE TABLE IF NOT EXISTS folders(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL UNIQUE
        );
        CREATE TABLE IF NOT EXISTS albums(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS album_photos(
            album_id INTEGER NOT NULL,
            photo_id INTEGER NOT NULL,
            PRIMARY KEY(album_id, photo_id)
        );
        CREATE TABLE IF NOT EXISTS edits(
            photo_id INTEGER PRIMARY KEY,
            recipe TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS smart_albums(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            search TEXT NOT NULL DEFAULT '',
            min_rating INTEGER NOT NULL DEFAULT 0,
            favorites_only INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS face_counts(
            photo_id INTEGER PRIMARY KEY,
            faces INTEGER NOT NULL DEFAULT 0
        );
        """)

        // Older catalogues predate the capture-date column.
        if !columnExists(table: "photos", column: "date") {
            exec("ALTER TABLE photos ADD COLUMN date REAL NOT NULL DEFAULT 0;")
            exec("CREATE INDEX IF NOT EXISTS idx_photos_date ON photos(date);")
        }
        // …and the favourites flag.
        if !columnExists(table: "photos", column: "favorite") {
            exec("ALTER TABLE photos ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;")
        }
        if !columnExists(table: "photos", column: "latitude") {
            exec("ALTER TABLE photos ADD COLUMN latitude REAL;")
            exec("ALTER TABLE photos ADD COLUMN longitude REAL;")
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        var found = false
        if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column {
                    found = true
                    break
                }
            }
        }
        sqlite3_finalize(stmt)
        return found
    }

    // MARK: - Watching

    private func configureWatcher() {
        watcher.onChange = { [weak self] in
            guard let self else { return }
            self.flash("Library changed — updating…", seconds: 4)
            self.rescanAll()
        }
    }

    /// Keeps FSEvents in sync with the current set of roots. Call on the main queue.
    private func updateWatcher() {
        // FSEventStreamCreate can block in open() while macOS shows a privacy
        // prompt for a protected folder (e.g. Documents). Never do that on the
        // main thread or the whole app freezes before its window appears.
        let paths = folders
        watchQueue.async {
            self.watcher.start(paths: paths)
            let running = self.watcher.isRunning
            DispatchQueue.main.async { self.isWatching = running }
        }
    }

    // MARK: - Folders

    func loadFolders() {
        queue.async {
            var result: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "SELECT path FROM folders ORDER BY path", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) { result.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async {
                self.folders = result
                self.updateWatcher()
            }
        }
    }

    /// True when we are allowed to enumerate the folder. macOS privacy protection makes the
    /// directory unreadable (EPERM) instead of prompting once the user has declined, so this
    /// is the difference between "empty folder" and "no permission".
    static func isReadable(folder: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: folder.path) else { return false }
        // Opening the directory is enough to distinguish "permission denied" from
        // an empty folder. Listing every entry here would duplicate the scan walk
        // and can block for a long time on very large or cloud-backed folders.
        guard let dir = opendir(folder.path) else { return false }
        closedir(dir)
        return true
    }

    /// Canonical form of a URL, so `/var/...` and `/private/var/...` never become
    /// two different catalogue entries for the same file. Foundation normalises
    /// `/private/var` back to `/var`, which is the opposite of what we need, so
    /// use the POSIX `realpath` instead.
    static func canonical(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else {
            return url.standardizedFileURL
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    func addFolder(_ url: URL) {
        let url = Self.canonical(url)
        let path = url.path
        guard Self.isReadable(folder: url) else {
            isScanning = false
            flash("Can’t read “\(url.lastPathComponent)” — allow access in System Settings › Privacy & Security › Files and Folders", seconds: 12)
            return
        }
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO folders(path) VALUES(?)", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { self.loadFolders() }
            self.scanQueue.async { self.scan(folder: url) }
        }
    }

    /// Index one file immediately so an "Open With" request can show it without
    /// waiting for the whole folder, then index the rest of the folder so the
    /// surrounding photos appear in the grid and filmstrip.
    func openPhoto(at url: URL) {
        let url = Self.canonical(url)
        let folder = url.deletingLastPathComponent()
        guard Self.isReadable(folder: folder) else {
            flash("Can’t read “\(folder.lastPathComponent)” — allow access in System Settings › Privacy & Security › Files and Folders", seconds: 12)
            return
        }

        let path = url.path
        let filename = url.lastPathComponent

        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO folders(path) VALUES(?)", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, folder.path, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
               let modified = attrs[.modificationDate] as? Date {
                let mtime = modified.timeIntervalSince1970
                let date = Imaging.captureDate(path: path) ?? mtime
                self.upsertPhoto(path: path, filename: filename, folder: folder.path,
                                 mtime: mtime, date: date)
            }
        }

        DispatchQueue.main.async {
            self.loadFolders()
            self.refresh()
        }

        // The viewer can open from the single row above; fill in the rest of the
        // folder a moment later so the first paint stays instant.
        scanQueue.asyncAfter(deadline: .now() + 0.8) {
            self.scan(folder: folder, announce: false)
            DispatchQueue.main.async {
                self.loadFolders()
                self.refresh()
            }
        }
    }

    /// Single-row upsert, used for the fast path above. Must run on `queue`.
    private func upsertPhoto(path: String, filename: String, folder: String,
                             mtime: Double, date: Double) {
        let sql = """
        INSERT INTO photos(path,filename,folder,mtime,date,rating,caption,tags,width,height)
        VALUES(?,?,?,?,?,0,'','',0,0)
        ON CONFLICT(path) DO UPDATE SET
            mtime=excluded.mtime,
            filename=excluded.filename,
            folder=excluded.folder,
            date=excluded.date
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, filename, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, folder, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, mtime)
        sqlite3_bind_double(stmt, 5, date)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func removeFolder(_ path: String) {
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "DELETE FROM folders WHERE path = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            stmt = nil
            if sqlite3_prepare_v2(self.db, "DELETE FROM photos WHERE folder = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            self.exec("DELETE FROM edits WHERE photo_id NOT IN (SELECT id FROM photos);")
            DispatchQueue.main.async {
                self.loadFolders()
                self.refresh()
            }
        }
    }

    func rescanAll(announce: Bool = true) {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "Galleria.lastFullScan")
        queue.async {
            var roots: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "SELECT path FROM folders", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let c = sqlite3_column_text(stmt, 0) { roots.append(String(cString: c)) }
                }
            }
            sqlite3_finalize(stmt)
            guard !roots.isEmpty else {
                DispatchQueue.main.async { self.refresh() }
                return
            }
            // Enumerate off the catalogue queue: a big or slow folder must not
            // block edits, favourites or the viewer's first paint.
            self.scanQueue.async {
                for r in roots {
                    self.scan(folder: URL(fileURLWithPath: r), announce: announce && r == roots.first)
                }
                DispatchQueue.main.async {
                    self.isScanning = false
                    self.status = ""
                    self.refresh()
                }
            }
        }
    }

    // MARK: - Scanning

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "png", "heic", "heif", "heics", "heifs",
        "tiff", "tif", "gif", "webp", "avif", "avifs", "bmp", "svg", "jxl",
        "psd", "exr", "hdr", "raw", "dng", "cr2", "cr3", "nef", "arw", "raf",
        "orf", "rw2", "pef", "srw", "3fr", "kra", "ora", "xcf", "ico", "icns", "tga", "pcx"
    ]

    /// Incremental scan: unchanged files are skipped entirely (no metadata read, no write),
    /// new/changed files get their EXIF capture date, and rows for deleted files are dropped.
    /// Runs on `scanQueue`, never on the catalogue queue: enumerating a folder
    /// (and reading EXIF) can take seconds, and the catalogue queue must stay
    /// free so the viewer and the grid never block on a scan.
    private func scan(folder url: URL, announce: Bool = true) {
        let folder = Self.canonical(url)
        if announce {
            DispatchQueue.main.async {
                self.isScanning = true
                self.status = "Scanning \(folder.lastPathComponent)…"
            }
        }

        // Never treat "permission denied" as "every file was deleted".
        guard Self.isReadable(folder: folder) else {
            if announce {
                DispatchQueue.main.async {
                    self.isScanning = false
                    self.flash("Can’t read “\(folder.lastPathComponent)” — check Privacy & Security › Files and Folders", seconds: 12)
                }
            }
            return
        }

        // Known rows for this root: path -> (mtime, date). Short DB hop.
        var known: [String: (mtime: Double, date: Double)] = [:]
        queue.sync {
            var lookup: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT path, mtime, date FROM photos WHERE folder = ?", -1, &lookup, nil) == SQLITE_OK {
                sqlite3_bind_text(lookup, 1, folder.path, -1, SQLITE_TRANSIENT)
                while sqlite3_step(lookup) == SQLITE_ROW {
                    if let c = sqlite3_column_text(lookup, 0) {
                        known[String(cString: c)] = (sqlite3_column_double(lookup, 1), sqlite3_column_double(lookup, 2))
                    }
                }
            }
            sqlite3_finalize(lookup)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: folder,
                                                     includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            if announce { DispatchQueue.main.async { self.isScanning = false } }
            return
        }

        // Walk the folder on this queue, collecting only what changed. No SQLite
        // work happens until the walk is finished.
        var entries: [(path: String, filename: String, mtime: Double, date: Double)] = []
        var present = Set<String>()
        present.reserveCapacity(known.count)
        var seen = 0

        for case let fileURL as URL in en {
            autoreleasepool {
                guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { return }
                let ext = fileURL.pathExtension.lowercased()
                guard Self.imageExtensions.contains(ext) else { return }

                let path = fileURL.path
                present.insert(path)
                seen += 1
                let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0

                // Already indexed, file untouched, and we have a real capture date → nothing to do.
                if let old = known[path], abs(old.mtime - mtime) < 1, old.date > 0 { return }

                let date = Imaging.captureDate(path: path) ?? mtime
                entries.append((path, fileURL.lastPathComponent, mtime, date))

                if seen % 100 == 0 {
                    DispatchQueue.main.async { self.status = "Scanning… \(seen) files" }
                }
            }
        }

        // Commit the changes in one short transaction.
        var changed = 0
        var removed = 0
        queue.sync {
            let upsertSQL = """
            INSERT INTO photos(path,filename,folder,mtime,date,rating,caption,tags,width,height)
            VALUES(?,?,?,?,?,0,'','',0,0)
            ON CONFLICT(path) DO UPDATE SET
                mtime=excluded.mtime,
                filename=excluded.filename,
                folder=excluded.folder,
                date=excluded.date
            """
            var upsert: OpaquePointer?
            guard sqlite3_prepare_v2(db, upsertSQL, -1, &upsert, nil) == SQLITE_OK else { return }
            sqlite3_exec(db, "BEGIN TRANSACTION", nil, nil, nil)
            for entry in entries {
                sqlite3_reset(upsert)
                sqlite3_clear_bindings(upsert)
                sqlite3_bind_text(upsert, 1, entry.path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(upsert, 2, entry.filename, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(upsert, 3, folder.path, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(upsert, 4, entry.mtime)
                sqlite3_bind_double(upsert, 5, entry.date)
                if sqlite3_step(upsert) == SQLITE_DONE { changed += 1 }
            }
            sqlite3_finalize(upsert)

            // Drop rows whose files vanished from this root.
            var del: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM photos WHERE path = ?", -1, &del, nil) == SQLITE_OK {
                for path in known.keys where !present.contains(path) {
                    sqlite3_reset(del)
                    sqlite3_clear_bindings(del)
                    sqlite3_bind_text(del, 1, path, -1, SQLITE_TRANSIENT)
                    if sqlite3_step(del) == SQLITE_DONE { removed += 1 }
                }
            }
            sqlite3_finalize(del)

            if removed > 0 {
                exec("DELETE FROM edits WHERE photo_id NOT IN (SELECT id FROM photos);")
            }

            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }

        if announce {
            DispatchQueue.main.async {
                self.isScanning = false
                var parts: [String] = []
                if changed > 0 { parts.append("\(changed) added or updated") }
                if removed > 0 { parts.append("\(removed) removed") }
                if parts.isEmpty { self.status = "" } else { self.flash(parts.joined(separator: " · ")) }
                self.refresh()
            }
        }
    }

    // MARK: - Albums

    func loadAlbums() {
        queue.async {
            var result: [Album] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "SELECT id,name FROM albums ORDER BY name", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_int64(stmt, 0)
                    let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    result.append(Album(id: id, name: name))
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { self.albums = result }
        }
    }

    func createAlbum(name: String, photoIDs: [Int64]) {
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "INSERT INTO albums(name) VALUES(?)", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            let albumID = sqlite3_last_insert_rowid(self.db)

            var link: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO album_photos(album_id,photo_id) VALUES(?,?)", -1, &link, nil) == SQLITE_OK {
                for pid in photoIDs {
                    sqlite3_reset(link)
                    sqlite3_clear_bindings(link)
                    sqlite3_bind_int64(link, 1, albumID)
                    sqlite3_bind_int64(link, 2, pid)
                    sqlite3_step(link)
                }
            }
            sqlite3_finalize(link)
            DispatchQueue.main.async { self.loadAlbums() }
        }
    }

    func deleteAlbum(_ id: Int64) {
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "DELETE FROM albums WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            stmt = nil
            if sqlite3_prepare_v2(self.db, "DELETE FROM album_photos WHERE album_id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async {
                self.loadAlbums()
                self.refresh()
            }
        }
    }

    func addToAlbum(_ albumID: Int64, photoIDs: [Int64]) {
        queue.async {
            var link: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "INSERT OR IGNORE INTO album_photos(album_id,photo_id) VALUES(?,?)", -1, &link, nil) == SQLITE_OK {
                for pid in photoIDs {
                    sqlite3_reset(link)
                    sqlite3_clear_bindings(link)
                    sqlite3_bind_int64(link, 1, albumID)
                    sqlite3_bind_int64(link, 2, pid)
                    sqlite3_step(link)
                }
            }
            sqlite3_finalize(link)
        }
    }

    // MARK: - Query

    func refresh(folder: String? = nil, album: Int64? = nil, search: String = "",
                 minRating: Int = 0, favoritesOnly: Bool = false) {
        queue.async {
            var sql = """
            SELECT p.id,p.path,p.filename,p.folder,p.mtime,p.date,p.rating,p.favorite,p.caption,p.tags,p.width,p.height
            FROM photos p
            """
            var binds: [Any] = []
            if let album {
                sql += " JOIN album_photos ap ON ap.photo_id = p.id AND ap.album_id = ?"
                binds.append(album)
            }
            sql += " WHERE 1=1"
            if let folder { sql += " AND p.folder = ?"; binds.append(folder) }
            if favoritesOnly { sql += " AND p.favorite = 1" }
            if minRating > 0 { sql += " AND p.rating >= ?"; binds.append(minRating) }
            let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                sql += " AND (p.filename LIKE ? OR p.tags LIKE ? OR p.caption LIKE ?)"
                binds.append("%\(q)%"); binds.append("%\(q)%"); binds.append("%\(q)%")
            }
            sql += " ORDER BY p.date DESC, p.mtime DESC LIMIT 50000"

            let rows = self.query(sql, binds)
            DispatchQueue.main.async {
                self.photos = rows
                self.totalCount = rows.count
            }
        }
    }

    /// Every indexed photo in `folder`, independent of the grid's current
    /// filters (search, rating, album). Used by the viewer to browse a whole
    /// folder. Runs on the catalogue queue and calls back on the main thread.
    func loadPhotos(inFolder folder: String, completion: @escaping ([Photo]) -> Void) {
        queue.async {
            let rows = self.query("""
            SELECT p.id,p.path,p.filename,p.folder,p.mtime,p.date,p.rating,p.favorite,p.caption,p.tags,p.width,p.height
            FROM photos p WHERE p.folder = ? ORDER BY p.date DESC, p.mtime DESC
            """, [folder])
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Synchronous lookup of photos by ID, independent of the current grid
    /// filters. Used by Collage/Compare/Batch views so a selection survives
    /// even when the grid is filtered or not yet refreshed.
    func photos(withIDs ids: [Int64]) -> [Photo] {
        guard !ids.isEmpty else { return [] }
        var out: [Photo] = []
        queue.sync {
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let sql = """
            SELECT p.id,p.path,p.filename,p.folder,p.mtime,p.date,p.rating,p.favorite,p.caption,p.tags,p.width,p.height
            FROM photos p WHERE p.id IN (\(placeholders)) ORDER BY p.date DESC, p.mtime DESC
            """
            out = self.query(sql, ids.map { $0 })
        }
        return out
    }

    private func query(_ sql: String, _ binds: [Any]) -> [Photo] {
        var out: [Photo] = []
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let n as Int64: sqlite3_bind_int64(stmt, idx, n)
            default: break
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let path = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let filename = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let folder = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let mtime = sqlite3_column_double(stmt, 4)
            let date = sqlite3_column_double(stmt, 5)
            let rating = Int(sqlite3_column_int(stmt, 6))
            let favorite = sqlite3_column_int(stmt, 7) != 0
            let caption = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
            let tags = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? ""
            let w = Int(sqlite3_column_int(stmt, 10))
            let h = Int(sqlite3_column_int(stmt, 11))
            out.append(Photo(id: id, path: path, filename: filename, folder: folder,
                             mtime: mtime, date: date, rating: rating, favorite: favorite,
                             caption: caption, tags: tags,
                             width: w, height: h))
        }
        sqlite3_finalize(stmt)
        return out
    }

    // MARK: - Mutations

    func setRating(_ ids: [Int64], rating: Int) {
        guard !ids.isEmpty else { return }
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "UPDATE photos SET rating = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                for id in ids {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int(stmt, 1, Int32(rating))
                    sqlite3_bind_int64(stmt, 2, id)
                    sqlite3_step(stmt)
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async {
                for i in self.photos.indices where ids.contains(self.photos[i].id) {
                    self.photos[i].rating = rating
                }
            }
        }
    }

    func setFavorite(_ ids: [Int64], favorite: Bool) {
        guard !ids.isEmpty else { return }
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "UPDATE photos SET favorite = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                for id in ids {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    sqlite3_bind_int(stmt, 1, favorite ? 1 : 0)
                    sqlite3_bind_int64(stmt, 2, id)
                    sqlite3_step(stmt)
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async {
                for i in self.photos.indices where ids.contains(self.photos[i].id) {
                    self.photos[i].favorite = favorite
                }
            }
        }
    }

    func setTags(_ ids: [Int64], tags: String) {
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "UPDATE photos SET tags = ? WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                for id in ids {
                    sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                    sqlite3_bind_text(stmt, 1, tags, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 2, id)
                    sqlite3_step(stmt)
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async {
                for i in self.photos.indices where ids.contains(self.photos[i].id) {
                    self.photos[i].tags = tags
                }
            }
        }
    }

    func setDimensions(photoID: Int64, width: Int, height: Int) {
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "UPDATE photos SET width=?, height=? WHERE id=?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(width))
                sqlite3_bind_int(stmt, 2, Int32(height))
                sqlite3_bind_int64(stmt, 3, photoID)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Edits

    func saveEdit(_ recipe: EditRecipe, for photoID: Int64) {
        queue.async {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO edits(photo_id,recipe) VALUES(?,?) ON CONFLICT(photo_id) DO UPDATE SET recipe=excluded.recipe"
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, photoID)
                sqlite3_bind_text(stmt, 2, recipe.encoded, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Must run on `queue`.
    private func readEdit(for photoID: Int64) -> EditRecipe {
        var recipe = EditRecipe.identity
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT recipe FROM edits WHERE photo_id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, photoID)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let c = sqlite3_column_text(stmt, 0) {
                recipe = EditRecipe.decode(String(cString: c))
            }
        }
        sqlite3_finalize(stmt)
        return recipe
    }

    /// Blocking read for background work such as export.
    func loadEdit(for photoID: Int64) -> EditRecipe {
        queue.sync { readEdit(for: photoID) }
    }

    /// Non-blocking read for the main thread: never waits behind a folder scan
    /// or a catalogue write, so opening the viewer stays instant.
    func loadEditAsync(for photoID: Int64) async -> EditRecipe {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.readEdit(for: photoID))
            }
        }
    }

    func editedPhotoIDs() -> Set<Int64> {
        var out = Set<Int64>()
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT photo_id FROM edits", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW { out.insert(sqlite3_column_int64(stmt, 0)) }
            }
            sqlite3_finalize(stmt)
        }
        return out
    }

    // MARK: - Smart albums (C6)

    @Published var smartAlbums: [SmartAlbum] = []

    func loadSmartAlbums() {
        queue.async {
            var result: [SmartAlbum] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "SELECT id,name,search,min_rating,favorites_only FROM smart_albums ORDER BY name", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = sqlite3_column_int64(stmt, 0)
                    let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                    let search = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let rating = Int(sqlite3_column_int(stmt, 3))
                    let fav = sqlite3_column_int(stmt, 4) != 0
                    result.append(SmartAlbum(id: id, name: name, search: search, minRating: rating, favoritesOnly: fav))
                }
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { self.smartAlbums = result }
        }
    }

    func createSmartAlbum(name: String, search: String, minRating: Int, favoritesOnly: Bool) {
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "INSERT INTO smart_albums(name,search,min_rating,favorites_only) VALUES(?,?,?,?)", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, name, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, search, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(stmt, 3, Int32(minRating))
                sqlite3_bind_int(stmt, 4, favoritesOnly ? 1 : 0)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { self.loadSmartAlbums() }
        }
    }

    func deleteSmartAlbum(_ id: Int64) {
        queue.async {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "DELETE FROM smart_albums WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, id)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { self.loadSmartAlbums() }
        }
    }

    // MARK: - Faces (C4) cache

    func setFaceCount(photoID: Int64, faces: Int) {
        queue.async {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO face_counts(photo_id,faces) VALUES(?,?) ON CONFLICT(photo_id) DO UPDATE SET faces=excluded.faces"
            if sqlite3_prepare_v2(self.db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, photoID)
                sqlite3_bind_int(stmt, 2, Int32(faces))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    func faceCount(photoID: Int64) -> Int {
        var out = 0
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT faces FROM face_counts WHERE photo_id = ?", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int64(stmt, 1, photoID)
                if sqlite3_step(stmt) == SQLITE_ROW { out = Int(sqlite3_column_int(stmt, 0)) }
            }
            sqlite3_finalize(stmt)
        }
        return out
    }
}

struct SmartAlbum: Identifiable, Hashable {
    let id: Int64
    var name: String
    var search: String
    var minRating: Int
    var favoritesOnly: Bool
}
