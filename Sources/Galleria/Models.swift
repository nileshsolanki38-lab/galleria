import Foundation

// MARK: - Photo

struct Photo: Identifiable, Hashable {
    let id: Int64
    var path: String
    var filename: String
    var folder: String
    /// File modification time (epoch seconds).
    var mtime: Double
    /// Capture date from EXIF, falling back to mtime (epoch seconds).
    var date: Double
    var rating: Int
    var favorite: Bool = false
    var caption: String
    var tags: String
    var width: Int
    var height: Int

    var url: URL { URL(fileURLWithPath: path) }

    /// Best available date for timeline grouping.
    var takenAt: Date { Date(timeIntervalSince1970: date > 0 ? date : mtime) }
}

// MARK: - Album

struct Album: Identifiable, Hashable {
    let id: Int64
    var name: String
}

// MARK: - Photo filters (Picasa-style)

enum PhotoFilter: String, Codable, CaseIterable {
    case none, monochrome, sepia, vintage, vivid, fade, silver, warm

    var displayName: String {
        switch self {
        case .none: return "None"
        case .monochrome: return "Mono"
        case .sepia: return "Sepia"
        case .vintage: return "Vintage"
        case .vivid: return "Vivid"
        case .fade: return "Fade"
        case .silver: return "Silver"
        case .warm: return "Warm"
        }
    }
}

// MARK: - Markup (Preview-style)

enum MarkupType: String, Codable, CaseIterable {
    case rect, oval, line, arrow, text, freehand

    var displayName: String {
        switch self {
        case .rect: return "Rectangle"
        case .oval: return "Oval"
        case .line: return "Line"
        case .arrow: return "Arrow"
        case .text: return "Text"
        case .freehand: return "Freehand"
        }
    }
}

struct MarkupElement: Codable, Equatable {
    var type: MarkupType
    /// Normalised 0...1 top-left coordinates.
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    /// Freehand path points (normalised), used only for `.freehand`.
    var points: [CGPoint] = []
    var text: String = ""
    var color: String = "#FF0000" // #RRGGBB
    var strokeWidth: Double = 3   // points
    var filled: Bool = false
}

// MARK: - Non-destructive edit recipe

struct EditRecipe: Codable, Equatable {
    struct CropRect: Codable, Equatable {
        /// Normalised 0...1 coordinates in the oriented image space.
        var x: Double
        var y: Double
        var w: Double
        var h: Double
    }

    var rotation: Int = 0          // 0, 90, 180, 270 (clockwise)
    var flipH: Bool = false
    var autoEnhance: Bool = false
    var crop: CropRect? = nil

    // Picasa-style adjustments (all neutral = 0, so old recipes stay identity).
    var exposure: Double = 0        // -2...2 EV stops
    var brightness: Double = 0      // -1...1
    var contrast: Double = 0        // -1...1
    var fillLight: Double = 0       // -1...1  (lifts shadows)
    var highlights: Double = 0      // -1...1
    var shadows: Double = 0         // -1...1
    var warmth: Double = 0          // -1...1  (temperature)
    var saturation: Double = 0      // -1...1
    var sharpen: Double = 0         //  0...1  luminance sharpen
    var vignette: Double = 0        //  0...1
    var straighten: Double = 0      // -8...8 degrees
    var filter: PhotoFilter = .none
    var markups: [MarkupElement] = [] // Preview-style markup (non-destructive)

    var isIdentity: Bool {
        rotation == 0 && !flipH && !autoEnhance && crop == nil
        && exposure == 0 && brightness == 0 && contrast == 0
        && fillLight == 0 && highlights == 0 && shadows == 0
        && warmth == 0 && saturation == 0 && sharpen == 0
        && vignette == 0 && straighten == 0 && filter == .none
        && markups.isEmpty
    }

    static let identity = EditRecipe()

    var encoded: String {
        guard let data = try? JSONEncoder().encode(self),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    static func decode(_ s: String) -> EditRecipe {
        guard let data = s.data(using: .utf8),
              let r = try? JSONDecoder().decode(EditRecipe.self, from: data) else { return .identity }
        return r
    }
}

// MARK: - Collage

enum CollageLayout: String, Codable, CaseIterable {
    case grid, pictureInPicture, mosaic, freestyle

    var displayName: String {
        switch self {
        case .grid: return "Grid"
        case .pictureInPicture: return "Picture-in-Picture"
        case .mosaic: return "Mosaic"
        case .freestyle: return "Freestyle"
        }
    }
}

struct CollageRecipe: Codable, Equatable {
    var layout: CollageLayout = .grid
    var spacing: Double = 8       // points between tiles, 0...32
    var background: String = "white" // "white" | "black" | hex "#RRGGBB" | "none"
    var cornerRadius: Double = 0  // 0...24
    var canvasAspect: String = "square" // "square" | "4:3" | "16:9" | "free"
    var borderWidth: Double = 0   // 0...12 points, Picasa "Borders"
    var borderColor: String = "black"
    var caption: String = ""      // optional title at bottom
    var pipSize: Double = 0.38    // 0.15...0.6 fraction for Picture-in-Picture
    var pipX: Double = 0.75       // 0...1 position
    var pipY: Double = 0.75

    static let `default` = CollageRecipe()
}

// MARK: - Sidebar selection

enum SidebarItem: Hashable {
    case all
    case favorites
    case folder(String)
    case album(Int64)
    case smartAlbum(Int64)
}
