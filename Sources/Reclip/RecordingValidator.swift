import Foundation
import AVFoundation

/// Validates finished recordings and prunes incomplete/orphaned files — Recordly cleans up
/// after crashes so a half-written capture never shows up as a usable clip.
enum RecordingValidator {
    enum Status: Equatable {
        case valid(duration: Double)
        case empty          // zero-byte (writer never flushed)
        case unreadable     // present but not a decodable movie
        case noVideo        // decodable but has no video track

        var isValid: Bool { if case .valid = self { return true }; return false }
    }

    /// Checks a single recording file.
    static func validate(_ url: URL) async -> Status {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .unreadable }
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if (size ?? 0) == 0 { return .empty }
        let asset = AVURLAsset(url: url)
        guard let dur = try? await asset.load(.duration), dur.seconds > 0.05 else { return .unreadable }
        guard let vTracks = try? await asset.loadTracks(withMediaType: .video), !vTracks.isEmpty else {
            return .noVideo
        }
        return .valid(duration: dur.seconds)
    }

    /// Removes incomplete recordings (empty/unreadable/no-video) and orphaned sidecars
    /// (`.cursor` / `.reclip` with no surviving movie). Returns the URLs removed.
    @discardableResult
    static func prune(in directory: URL) async -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        var removed: [URL] = []
        let movies = items.filter { $0.pathExtension.lowercased() == "mp4" }
        var survivingBases = Set<String>()
        for movie in movies {
            if await validate(movie).isValid {
                survivingBases.insert(movie.deletingPathExtension().lastPathComponent)
            } else {
                try? fm.removeItem(at: movie); removed.append(movie)
            }
        }
        for item in items where ["cursor", "reclip"].contains(item.pathExtension.lowercased()) {
            if !survivingBases.contains(item.deletingPathExtension().lastPathComponent) {
                try? fm.removeItem(at: item); removed.append(item)
            }
        }
        return removed
    }
}
