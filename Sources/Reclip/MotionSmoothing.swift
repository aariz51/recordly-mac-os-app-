import Foundation

/// Spring-physics smoothing for cursor and zoom motion — a port of Recordly's
/// `motionSmoothing.ts`. `stepSpring` advances a damped-harmonic-oscillator toward a
/// target using the closed-form analytical solution (under/critically/over-damped), with
/// an overshoot clamp for ζ ≥ 1 so a moving target doesn't cause wobble. The tuning
/// (`cursorSpringConfig` / `zoomSpringConfig`) matches Recordly's curves exactly; the
/// *feel* is a visual judgement, but the math — converges to target, settles, stays
/// bounded — is unit-tested.
struct SpringConfig: Equatable {
    var stiffness: Double
    var damping: Double
    var mass: Double
    var restDelta: Double = 0.0005
    var restSpeed: Double = 0.02
}

struct SpringState: Equatable {
    var value: Double
    var velocity: Double = 0
    var initialized: Bool = false
    init(initialValue: Double = 0) { value = initialValue }
}

enum MotionSmoothing {
    /// Clamps a frame delta to [1, 80]ms; non-finite/≤0 falls back to one 60fps frame.
    static func clampDeltaMs(_ deltaMs: Double, fallbackMs: Double = 1000.0 / 60.0) -> Double {
        guard deltaMs.isFinite, deltaMs > 0 else { return fallbackMs }
        return min(80, max(1, deltaMs))
    }

    private static func resolveSpringPosition(t: Double, target: Double, initialDelta: Double,
                                              initialVelocity: Double, dampingRatio: Double,
                                              w0: Double) -> Double {
        if dampingRatio < 1 {                          // underdamped — oscillatory envelope
            let dampedFreq = w0 * (1 - dampingRatio * dampingRatio).squareRoot()
            let envelope = exp(-dampingRatio * w0 * t)
            return target - envelope *
                (((initialVelocity + dampingRatio * w0 * initialDelta) / dampedFreq) * sin(dampedFreq * t)
                    + initialDelta * cos(dampedFreq * t))
        }
        if dampingRatio == 1 {                         // critically damped
            return target - exp(-w0 * t) * (initialDelta + (initialVelocity + w0 * initialDelta) * t)
        }
        let dampedFreq = w0 * (dampingRatio * dampingRatio - 1).squareRoot()   // overdamped
        let envelope = exp(-dampingRatio * w0 * t)
        let freqT = min(dampedFreq * t, 300)           // cap to avoid Inf in sinh/cosh
        return target - (envelope *
            ((initialVelocity + dampingRatio * w0 * initialDelta) * sinh(freqT)
                + dampedFreq * initialDelta * cosh(freqT))) / dampedFreq
    }

    /// Advances `state` one frame toward `target`. First call snaps to the target.
    @discardableResult
    static func stepSpring(_ state: inout SpringState, target: Double,
                           deltaMs: Double, config: SpringConfig) -> Double {
        let safeDeltaMs = clampDeltaMs(deltaMs)
        if !state.initialized || !state.value.isFinite {
            state.value = target; state.velocity = 0; state.initialized = true
            return state.value
        }
        if abs(target - state.value) <= config.restDelta && abs(state.velocity) <= config.restSpeed {
            state.value = target; state.velocity = 0; return state.value
        }
        let w0 = (config.stiffness / config.mass).squareRoot()
        let dampingRatio = config.damping / (2 * (config.stiffness * config.mass).squareRoot())
        let initialDelta = target - state.value
        let initialVelocity = -state.velocity
        let tSec = safeDeltaMs / 1000

        let current = resolveSpringPosition(t: tSec, target: target, initialDelta: initialDelta,
                                            initialVelocity: initialVelocity,
                                            dampingRatio: dampingRatio, w0: w0)
        if dampingRatio >= 1 {                          // overshoot guard for ζ ≥ 1
            let crossed = (state.value <= target && current > target)
                       || (state.value >= target && current < target)
            if crossed { state.value = target; state.velocity = 0; return state.value }
        }
        let epsilon = 0.0001
        let ahead = resolveSpringPosition(t: tSec + epsilon, target: target, initialDelta: initialDelta,
                                          initialVelocity: initialVelocity,
                                          dampingRatio: dampingRatio, w0: w0)
        let analyticalVelocity = (ahead - current) / epsilon
        let isDone = abs(analyticalVelocity) <= config.restSpeed && abs(target - current) <= config.restDelta
        if isDone { state.value = target; state.velocity = 0 }
        else { state.value = current; state.velocity = analyticalVelocity }
        return state.value
    }

    private static let cursorStiffnessBoost = 1.12

    /// Cursor smoothing config for a 0…2 smoothing factor (0 = snappy, 2 = floaty).
    static func cursorSpringConfig(smoothing: Double) -> SpringConfig {
        let clamped = min(2, max(0, smoothing))
        if clamped <= 0 {
            return SpringConfig(stiffness: 1000, damping: 100, mass: 1, restDelta: 0.0001, restSpeed: 0.001)
        }
        if clamped <= 0.5 {                             // legacy 0…0.5 range
            let n = min(1, max(0, clamped / 0.5))
            return SpringConfig(stiffness: (760 - n * 420) * cursorStiffnessBoost,
                                damping: 34 + n * 24, mass: 0.85 + n * 0.55,
                                restDelta: 0.0002, restSpeed: 0.01)
        }
        let n = min(1, max(0, (clamped - 0.5) / (2 - 0.5)))   // extended 0.5…2 range
        return SpringConfig(stiffness: (340 - n * 180) * cursorStiffnessBoost,
                            damping: 58 + n * 22, mass: 1.35 + n * 0.45,
                            restDelta: 0.0002, restSpeed: 0.01)
    }

    /// Zoom smoothing config for a 0…1 smoothness factor (barely overdamped, ζ ≈ 1.05).
    static func zoomSpringConfig(smoothness: Double = 0.5) -> SpringConfig {
        let clamped = max(0, min(1, smoothness))
        if clamped <= 0 {
            return SpringConfig(stiffness: 1000, damping: 100, mass: 1, restDelta: 0.0001, restSpeed: 0.001)
        }
        let scaled = clamped * 2
        return SpringConfig(stiffness: 100 / scaled, damping: 21, mass: 1.0 * scaled,
                            restDelta: 0.0005, restSpeed: 0.02)
    }
}

/// Cursor "sway" — a subtle rotation of the cursor sprite in its direction of motion,
/// scaled by speed. Port of Recordly's `cursorSway.ts`.
enum CursorSway {
    static let maxRotation = Double.pi / 18            // 10°
    static let speedReference = 1400.0                 // px/s at which speedFactor saturates
    static let verticalWeight = 0.65
    static let intensityScale = 3.0
    static let sliderScale = 2.0

    static func rotation(dx: Double, dy: Double, deltaMs: Double, sway: Double) -> Double {
        if sway <= 0 { return 0 }
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance.isFinite, distance >= 0.01 else { return 0 }
        let speed = distance / (MotionSmoothing.clampDeltaMs(deltaMs) / 1000)
        let speedFactor = min(1, max(0, speed / speedReference))
        if speedFactor <= 0 { return 0 }
        let directionalBias = min(1, max(-1, (dx + dy * verticalWeight) / distance))
        return directionalBias * speedFactor * maxRotation * sway * intensityScale
    }

    static func toSliderValue(_ sway: Double) -> Double { sway / sliderScale }
    static func fromSliderValue(_ slider: Double) -> Double { slider * sliderScale }
}
