import Foundation

/// A one-tap background choice for the editor. Recordly ships a wallpaper gallery; Reclip
/// provides an original curated set of gradients + solids (no copied image assets), plus
/// the engine also accepts a user-supplied image background (see StyleOptions.Background).
struct BackgroundPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let background: StyleOptions.Background
}

enum BackgroundPresets {
    /// Curated, original background presets. Colours are hand-picked (not ported from any
    /// third-party asset), so they ship freely with the App Store build.
    static let all: [BackgroundPreset] = [
        BackgroundPreset(id: "aurora",   name: "Aurora",
                         background: .gradient(topRGB: (0.39, 0.36, 1.00), bottomRGB: (0.66, 0.33, 0.97))),
        BackgroundPreset(id: "sunset",   name: "Sunset",
                         background: .gradient(topRGB: (0.98, 0.45, 0.36), bottomRGB: (0.98, 0.72, 0.36))),
        BackgroundPreset(id: "ocean",    name: "Ocean",
                         background: .gradient(topRGB: (0.13, 0.42, 0.78), bottomRGB: (0.20, 0.72, 0.79))),
        BackgroundPreset(id: "forest",   name: "Forest",
                         background: .gradient(topRGB: (0.11, 0.37, 0.29), bottomRGB: (0.36, 0.62, 0.38))),
        BackgroundPreset(id: "grape",    name: "Grape",
                         background: .gradient(topRGB: (0.42, 0.22, 0.66), bottomRGB: (0.78, 0.36, 0.72))),
        BackgroundPreset(id: "ember",    name: "Ember",
                         background: .gradient(topRGB: (0.60, 0.11, 0.24), bottomRGB: (0.94, 0.42, 0.31))),
        BackgroundPreset(id: "mint",     name: "Mint",
                         background: .gradient(topRGB: (0.16, 0.60, 0.55), bottomRGB: (0.56, 0.85, 0.68))),
        BackgroundPreset(id: "slateblue", name: "Slate Blue",
                         background: .gradient(topRGB: (0.20, 0.24, 0.36), bottomRGB: (0.36, 0.44, 0.62))),
        BackgroundPreset(id: "peach",    name: "Peach",
                         background: .gradient(topRGB: (0.98, 0.62, 0.55), bottomRGB: (0.99, 0.83, 0.71))),
        BackgroundPreset(id: "midnight", name: "Midnight",
                         background: .gradient(topRGB: (0.06, 0.08, 0.16), bottomRGB: (0.16, 0.20, 0.35))),
        BackgroundPreset(id: "rose",     name: "Rosé",
                         background: .gradient(topRGB: (0.85, 0.36, 0.52), bottomRGB: (0.98, 0.66, 0.74))),
        BackgroundPreset(id: "citrus",   name: "Citrus",
                         background: .gradient(topRGB: (0.95, 0.77, 0.20), bottomRGB: (0.62, 0.80, 0.28))),
        // Neutral solids
        BackgroundPreset(id: "graphite", name: "Graphite",  background: .solid(red: 0.12, green: 0.13, blue: 0.15)),
        BackgroundPreset(id: "paper",    name: "Paper",     background: .solid(red: 0.96, green: 0.96, blue: 0.94)),
        BackgroundPreset(id: "cobalt",   name: "Cobalt",    background: .solid(red: 0.11, green: 0.24, blue: 0.51)),
        BackgroundPreset(id: "sand",     name: "Sand",      background: .solid(red: 0.85, green: 0.79, blue: 0.68)),
    ]

    static func preset(id: String) -> BackgroundPreset? { all.first { $0.id == id } }
}
