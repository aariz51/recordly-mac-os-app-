import Foundation

/// Microphone processing profiles (Recordly offers raw/voice/music-style processing).
enum MicProfile: String, CaseIterable, Identifiable, Codable {
    case raw        // no processing
    case voice      // high-pass rumble removal + gentle noise gate
    case music      // light high-pass only, preserves dynamics
    var id: String { rawValue }
}

/// Real audio DSP for the mic track: a biquad high-pass (RBJ cookbook) and a noise gate.
/// Pure sample math — unit-tested — so the processing is verifiable independent of muxing.
enum MicProcessor {
    /// Second-order Butterworth-ish high-pass. Removes low-frequency rumble below `cutoff`.
    static func highPass(_ x: [Float], cutoff: Double, sampleRate: Double, q: Double = 0.707) -> [Float] {
        guard cutoff > 0, sampleRate > 0, !x.isEmpty else { return x }
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosw = cos(w0), alpha = sin(w0) / (2 * q)
        let b0 = (1 + cosw) / 2, b1 = -(1 + cosw), b2 = (1 + cosw) / 2
        let a0 = 1 + alpha, a1 = -2 * cosw, a2 = 1 - alpha
        let nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0, na1 = a1 / a0, na2 = a2 / a0
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let xn = Double(x[i])
            let yn = nb0 * xn + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2
            y[i] = Float(yn)
            x2 = x1; x1 = xn; y2 = y1; y1 = yn
        }
        return y
    }

    /// Silences samples quieter than `threshold` (a simple downward gate).
    static func noiseGate(_ x: [Float], threshold: Float) -> [Float] {
        x.map { abs($0) < threshold ? 0 : $0 }
    }

    /// Applies a profile's chain to a mono float buffer.
    static func apply(_ profile: MicProfile, to x: [Float], sampleRate: Double) -> [Float] {
        switch profile {
        case .raw:   return x
        case .voice: return noiseGate(highPass(x, cutoff: 90, sampleRate: sampleRate), threshold: 0.012)
        case .music: return highPass(x, cutoff: 35, sampleRate: sampleRate)
        }
    }

    /// Processes 16-bit little-endian mono PCM through a profile, returning new PCM bytes.
    static func processPCM16(_ pcm: Data, profile: MicProfile, sampleRate: Double) -> Data {
        guard profile != .raw, !pcm.isEmpty else { return pcm }
        let count = pcm.count / 2
        var floats = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count { floats[i] = Float(p[i]) / Float(Int16.max) }
        }
        let out = apply(profile, to: floats, sampleRate: sampleRate)
        var result = Data(count: count * 2)
        result.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                let v = max(-1, min(1, out[i]))
                p[i] = Int16(v * Float(Int16.max))
            }
        }
        return result
    }
}
