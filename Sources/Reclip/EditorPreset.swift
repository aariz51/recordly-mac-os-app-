import Foundation

/// A saved, named editor styling snapshot the user can reapply to any recording — port of
/// Recordly's `EditorPreset` (editorPreferences.ts). The snapshot reuses `ReclipProject`
/// (its `sourceFileName` is ignored on apply), so a preset captures every polish setting.
struct EditorPreset: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var createdAt: Double
    var snapshot: ReclipProject
}

/// Persists the user's editor presets to a JSON file in Application Support.
enum EditorPresetStore {
    static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Reclip/presets.json")
    }

    static func all(from url: URL = fileURL()) -> [EditorPreset] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([EditorPreset].self, from: data) else { return [] }
        return list.sorted { $0.createdAt < $1.createdAt }
    }

    /// Inserts or replaces a preset (matched by id) and writes the store.
    @discardableResult
    static func save(_ preset: EditorPreset, to url: URL = fileURL()) -> [EditorPreset] {
        var list = all(from: url).filter { $0.id != preset.id }
        list.append(preset)
        write(list, to: url)
        return list.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    static func delete(id: String, from url: URL = fileURL()) -> [EditorPreset] {
        let list = all(from: url).filter { $0.id != id }
        write(list, to: url)
        return list
    }

    private static func write(_ list: [EditorPreset], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(list) { try? data.write(to: url) }
    }
}
