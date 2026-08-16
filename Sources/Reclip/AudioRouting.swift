import Foundation

/// Which captured source a track came from (Recordly routes mic/system/mixed separately).
enum SourceTrackId: String, CaseIterable, Codable { case mic, system, mixed }

/// Per-track + master gain resolution — a faithful port of Recordly's `audioRoutingEngine`.
/// Lets mic and system audio be gained or muted independently under a master gain. The
/// resolution math is pure and unit-tested; applying it needs mic/system captured to
/// separate tracks (a capture-side follow-up).
struct AudioRouting: Equatable, Codable {
    static let normalizeGain = 1.35     // SOURCE_AUDIO_NORMALIZE_GAIN

    var micGain: Double = 1
    var systemGain: Double = 1
    var masterGain: Double = 1
    var micEnabled = true
    var systemEnabled = true

    /// Clamp to [0, max]; non-finite → 1 (Recordly's clampGain).
    static func clampGain(_ v: Double, max: Double) -> Double {
        guard v.isFinite else { return 1 }
        return Swift.max(0, Swift.min(max, v))
    }

    /// Effective gain for a track: clamp(trackGain, 2) × clamp(masterGain, 1); 0 if disabled.
    func effectiveGain(for track: SourceTrackId) -> Double {
        let enabled: Bool, g: Double
        switch track {
        case .mic:    enabled = micEnabled;    g = micGain
        case .system: enabled = systemEnabled; g = systemGain
        case .mixed:  enabled = true;          g = 1
        }
        guard enabled else { return 0 }
        return Self.clampGain(g, max: 2) * Self.clampGain(masterGain, max: 1)
    }

    /// Region gain (Recordly): clamp(volume × (normalize ? 1.35 : 1), 1).
    static func regionGain(volume: Double, normalize: Bool) -> Double {
        clampGain(volume * (normalize ? normalizeGain : 1), max: 1)
    }
}
