import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// Temporal motion blur — a faithful port of Recordly's `temporalMotionBlur.ts`.
///
/// `config` turns a 0…2 "amount" into a sample count + shutter fraction + weight-curve
/// power; `samplePlanUs` expands that into symmetric, cosine-tapered per-sample weights
/// that sum to 1. `blend` averages several composed frames by those weights. The math is
/// unit-tested against the original constants; the render wiring lives in the re-encode
/// path (it blends the N most recent composed frames as temporal neighbours).
enum MotionBlur {
    // Constants mirror the exported values in temporalMotionBlur.ts.
    static let minShutter = 0.18
    static let maxShutter = 3.0
    static let minSamples = 3
    static let maxSamples = 61
    static let defaultSamples = 13
    static let defaultShutter = 0.94
    static let autoMinShutter = 0.24
    static let autoMaxShutter = 0.62
    static let autoMaxSamples = 5
    static let weightFloor = 0.22
    static let maxAmount = 2.0
    static let minAmount = 0.001

    struct Config: Equatable {
        let sampleCount: Int
        let shutterFraction: Double
        let weightCurvePower: Double
    }
    struct Sample: Equatable {
        let offsetUs: Double
        let weight: Double
    }

    /// Rounds a sample-count override to the nearest odd value within [min, max].
    static func normalizeSampleCount(_ value: Double?) -> Int? {
        guard let value, value.isFinite else { return nil }
        let rounded = Int(value.rounded())
        let clamped = min(maxSamples, max(minSamples, rounded))
        if clamped % 2 == 1 { return clamped }
        return clamped >= maxSamples ? clamped - 1 : clamped + 1
    }

    /// Nil below the minimum blur amount (blur off); otherwise the resolved config.
    static func config(amount: Double?,
                       sampleCountOverride: Double? = nil,
                       shutterFractionOverride: Double? = nil) -> Config? {
        let resolved = (amount?.isFinite == true) ? max(0, amount ?? 0) : 0
        if resolved < minAmount { return nil }
        let normalized = min(1, resolved / maxAmount)
        let sampleStep = Int((normalized * (Double(autoMaxSamples - minSamples) / 2)).rounded())
        let defaultSampleCount = minSamples + sampleStep * 2
        let sampleCount = normalizeSampleCount(sampleCountOverride) ?? defaultSampleCount
        let shutterFraction: Double
        if let o = shutterFractionOverride, o.isFinite {
            shutterFraction = min(maxShutter, max(minShutter, o))
        } else {
            shutterFraction = autoMinShutter + normalized * (autoMaxShutter - autoMinShutter)
        }
        return Config(sampleCount: sampleCount,
                      shutterFraction: shutterFraction,
                      weightCurvePower: 1.2 + normalized * 0.9)
    }

    /// Evenly spaced sample offsets (µs) across the shutter window, centred on 0.
    static func sampleOffsetsUs(frameDurationUs: Double, config: Config) -> [Double] {
        let safeFrame = max(1, frameDurationUs)
        let n = max(1, config.sampleCount)
        if n == 1 { return [0] }
        let window = safeFrame * max(0, min(maxShutter, config.shutterFraction))
        let start = -window / 2
        let step = window / Double(n - 1)
        return (0..<n).map { start + step * Double($0) }
    }

    /// The offsets paired with cosine-tapered, floor-lifted weights that sum to 1.
    static func samplePlanUs(frameDurationUs: Double, config: Config) -> [Sample] {
        let offsets = sampleOffsetsUs(frameDurationUs: frameDurationUs, config: config)
        if offsets.count == 1 { return [Sample(offsetUs: 0, weight: 1)] }
        let center = Double(offsets.count - 1) / 2
        let raw = offsets.indices.map { i -> Double in
            let dist = abs(Double(i) - center) / max(1, center)
            let tapered = cos(dist * (.pi / 2))
            return weightFloor + (1 - weightFloor) * pow(max(0, tapered), config.weightCurvePower)
        }
        let sum = raw.reduce(0, +)
        let total = sum == 0 ? 1 : sum
        return offsets.indices.map { Sample(offsetUs: offsets[$0], weight: raw[$0] / total) }
    }

    /// Weighted average of several images (weights need not pre-sum to 1 — they're
    /// renormalized here so a partial window at the start of the clip stays exposed).
    static func blend(_ layers: [(image: CIImage, weight: Double)], extent: CGRect) -> CIImage? {
        guard !layers.isEmpty else { return nil }
        let sum = layers.reduce(0) { $0 + $1.weight }
        let norm = sum == 0 ? 1 : sum
        var acc: CIImage?
        for (img, w) in layers {
            let scale = w / norm
            let m = CIFilter.colorMatrix()
            m.inputImage = img.cropped(to: extent)
            m.rVector = CIVector(x: CGFloat(scale), y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: CGFloat(scale), z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: CGFloat(scale), w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)      // frames are opaque
            guard let scaled = m.outputImage else { continue }
            if let a = acc {
                let add = CIFilter.additionCompositing()
                add.inputImage = scaled
                add.backgroundImage = a
                acc = add.outputImage
            } else {
                acc = scaled
            }
        }
        return acc?.cropped(to: extent)
    }
}
