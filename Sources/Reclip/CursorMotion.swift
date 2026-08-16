import Foundation
import CoreGraphics

/// One frame of resolved cursor motion: the spring-smoothed position, the sway rotation
/// for that instant, and the click-bounce scale. Precomputed for the whole clip so the
/// per-frame compositor only has to index it (the spring is stateful and therefore cannot
/// be evaluated at a random time).
struct CursorMotionSample: Equatable {
    var t: Double
    var x: Double          // normalized, top-left origin
    var y: Double
    var rotation: Double   // radians, sway
    var scale: Double      // click-bounce multiplier (1 = at rest)
}

/// The cursor path after Recordly's motion pipeline — spring smoothing, directional sway,
/// and click bounce — sampled at a fixed cadence.
///
/// Recordly runs this per animation frame in the renderer, carrying spring state forward.
/// A `AVMutableVideoComposition` handler is called with arbitrary (and on the re-encode
/// path, repeated) times, so the same state cannot be carried there. Precomputing the whole
/// track once at build time gives the identical result and makes the compositor stateless.
struct SmoothedCursorTrack: Equatable {
    var samples: [CursorMotionSample] = []
    var isEmpty: Bool { samples.isEmpty }

    /// Nominal pixel size the sway speed calculation is done against. Sway is defined in
    /// px/s (Recordly's `speedReference` is 1400 px/s), but the track is normalized, so
    /// normalized deltas are scaled into a reference frame before measuring speed.
    static let referenceSize = CGSize(width: 1920, height: 1080)

    /// Builds the smoothed track by stepping the spring at `fps` over `[0, duration]`.
    static func build(track: CursorTrack,
                      style: CursorStyle,
                      duration: Double,
                      fps: Double = 60) -> SmoothedCursorTrack {
        guard duration > 0, !track.samples.isEmpty else { return SmoothedCursorTrack() }
        let step = 1.0 / max(fps, 1)
        let deltaMs = step * 1000
        let config = MotionSmoothing.cursorSpringConfig(smoothing: style.smoothing)

        var sx = SpringState()
        var sy = SpringState()
        var rotationState = SpringState()   // sway is itself eased, or it strobes frame to frame
        let rotationConfig = SpringConfig(stiffness: 220, damping: 26, mass: 1)

        let clicks = track.clicks.sorted()
        let bounceDur = CursorClickEffect.clampBounceDuration(style.clickBounceDuration)

        var out: [CursorMotionSample] = []
        out.reserveCapacity(Int(duration / step) + 2)
        var prevX = 0.0, prevY = 0.0
        var t = 0.0
        while t <= duration + 1e-9 {
            guard let target = track.interpolated(at: t) else { break }
            let x = MotionSmoothing.stepSpring(&sx, target: target.x, deltaMs: deltaMs, config: config)
            let y = MotionSmoothing.stepSpring(&sy, target: target.y, deltaMs: deltaMs, config: config)

            // Sway is driven by the *smoothed* motion, so it follows what is drawn rather
            // than the raw jitter of the sampler.
            let dx = (x - prevX) * referenceSize.width
            let dy = (y - prevY) * referenceSize.height
            let rawRotation = CursorSway.rotation(dx: dx, dy: dy, deltaMs: deltaMs, sway: style.sway)
            let rotation = MotionSmoothing.stepSpring(&rotationState, target: rawRotation,
                                                      deltaMs: deltaMs, config: rotationConfig)
            prevX = x; prevY = y

            // Click bounce: the most recent click still inside its bounce window wins.
            var scale = 1.0
            if style.clickBounce > 0 {
                for c in clicks where c <= t {
                    let ageMs = (t - c) * 1000
                    guard ageMs <= bounceDur else { continue }
                    let p = CursorClickEffect.bounceProgress(ageMs: ageMs, bounceDurationMs: bounceDur)
                    scale = CursorClickEffect.bounceScale(progress: p, clickBounce: style.clickBounce)
                }
            }

            out.append(CursorMotionSample(t: t, x: x, y: y, rotation: rotation, scale: scale))
            t += step
        }
        return SmoothedCursorTrack(samples: out)
    }

    /// The sample covering time `t` (nearest at or before, clamped to the ends).
    func sample(at t: Double) -> CursorMotionSample? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return first }
        if t >= last.t { return last }
        // Uniform cadence, so the index is a direct computation rather than a search.
        let step = samples.count > 1 ? (last.t - first.t) / Double(samples.count - 1) : 0
        guard step > 0 else { return first }
        let idx = Int(((t - first.t) / step).rounded(.down))
        return samples[min(max(idx, 0), samples.count - 1)]
    }
}
