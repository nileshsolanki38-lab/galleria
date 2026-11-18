import Foundation
import SwiftUI

// MARK: - Adjustment presets

/// A named collection of adjustment values. Presets carry only the "look"
/// (exposure, color, detail, filter) — never geometry (rotation, crop,
/// straighten) or markups — so applying one on any photo keeps its framing.
struct PhotoPreset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var recipe: EditRecipe
    var isBuiltin: Bool

    init(id: UUID = UUID(), name: String, recipe: EditRecipe, isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.recipe = recipe
        self.isBuiltin = isBuiltin
    }

    enum CodingKeys: String, CodingKey { case id, name, recipe }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        recipe = try c.decode(EditRecipe.self, forKey: .recipe)
        isBuiltin = false   // anything loaded from disk is user-made
    }
}

enum PresetLibrary {
    /// Curated "premium" looks, tuned to hold up across very different photos
    /// (portraits, products, landscapes, artwork). Values are conservative
    /// enough that nothing clips or turns radioactive.
    static let builtins: [PhotoPreset] = [
        PhotoPreset(name: "Punchy", recipe: EditRecipe(
            exposure: 0.15, contrast: 0.25, saturation: 0.3, sharpen: 0.3)),
        PhotoPreset(name: "Portrait Glow", recipe: EditRecipe(
            fillLight: 0.25, highlights: -0.15, shadows: 0.2, warmth: 0.08, saturation: 0.08)),
        PhotoPreset(name: "Golden Hour", recipe: EditRecipe(
            exposure: 0.15, highlights: -0.1, shadows: 0.1, warmth: 0.45, saturation: 0.15)),
        PhotoPreset(name: "Moody Film", recipe: EditRecipe(
            exposure: -0.1, contrast: 0.15, warmth: -0.1, saturation: -0.2, vignette: 0.3)),
        PhotoPreset(name: "Crisp Product", recipe: EditRecipe(
            exposure: 0.2, brightness: 0.1, contrast: 0.2, saturation: 0.1, sharpen: 0.5)),
        PhotoPreset(name: "Dramatic B&W", recipe: EditRecipe(
            contrast: 0.35, sharpen: 0.3, vignette: 0.25, filter: .monochrome)),
        PhotoPreset(name: "Vintage Fade", recipe: EditRecipe(
            exposure: 0.05, contrast: -0.05, warmth: 0.15, filter: .fade)),
        PhotoPreset(name: "Silver Chrome", recipe: EditRecipe(
            contrast: 0.2, sharpen: 0.25, filter: .silver)),
        PhotoPreset(name: "Shadow Lift", recipe: EditRecipe(
            brightness: 0.1, fillLight: 0.2, shadows: 0.4)),
        PhotoPreset(name: "Night Bright", recipe: EditRecipe(
            exposure: 0.4, contrast: 0.05, fillLight: 0.3, shadows: 0.35)),
        PhotoPreset(name: "Sepia Timeless", recipe: EditRecipe(
            warmth: 0.2, vignette: 0.2, filter: .sepia)),
        PhotoPreset(name: "Cool Winter", recipe: EditRecipe(
            exposure: 0.1, warmth: -0.4, saturation: -0.05)),
    ]

    /// The user's saved presets, stored as JSON in Application Support.
    static func loadUserPresets() -> [PhotoPreset] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PhotoPreset].self, from: data)) ?? []
    }

    static func saveUserPresets(_ presets: [PhotoPreset]) {
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Galleria/user-presets.json")
    }
}
