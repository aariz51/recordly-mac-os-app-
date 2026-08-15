import Foundation

/// Microphone level meter — a port of Recordly's `useAudioLevelMeter` level math. Computes
/// an RMS from a sample buffer, normalizes it to a 0…100 meter reading (with the same 2×
/// gain), and applies exponential smoothing across buffers. The level math is pure and
/// unit-tested; feeding it live samples requires an `AVAudioEngine` mic tap (mic permission).
struct AudioLevelMeter {
    var smoothingFactor: Double = 0.8      // matches the analyser smoothingTimeConstant
    private(set) var level: Double = 0     // 0…100

    /// Root-mean-square of a PCM buffer (samples expected in [-1, 1]).
    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// Maps a full-scale-relative RMS to 0…100 with Recordly's 2× gain, clamped.
    static func normalize(rms: Double) -> Double { min(100, max(0, rms) * 100 * 2) }

    /// Feeds a new sample buffer and returns the smoothed level.
    @discardableResult
    mutating func update(samples: [Float]) -> Double {
        let target = AudioLevelMeter.normalize(rms: AudioLevelMeter.rms(samples))
        level = level * smoothingFactor + target * (1 - smoothingFactor)
        return level
    }

    mutating func reset() { level = 0 }
}
