import Foundation

/// Cursor click feedback — a port of the click-bounce and click-ripple timing from
/// Recordly's `cursorRenderer.ts`. On a click the cursor "dips" (a sine scale pulse) and,
/// after a short delay, a ripple fades out. The scale/timing math is pure and unit-tested;
/// drawing the ripple sprite (color/opacity/style) is the visual layer.
enum CursorClickEffect {
    static let minBounceDurationMs = 60.0
    static let maxBounceDurationMs = 500.0
    static let bounceScaleFloor = 0.72
    static let bounceDip = 0.08                 // max fractional shrink per unit clickBounce

    static func clampBounceDuration(_ d: Double) -> Double {
        min(maxBounceDurationMs, max(minBounceDurationMs, d))
    }

    /// Bounce progress: 1 at the moment of click, decaying linearly to 0 over the bounce
    /// duration; 0 outside the window.
    static func bounceProgress(ageMs: Double, bounceDurationMs: Double) -> Double {
        guard ageMs >= 0, ageMs <= bounceDurationMs, bounceDurationMs > 0 else { return 0 }
        return 1 - ageMs / bounceDurationMs
    }

    /// Cursor scale during the bounce — a sine dip that returns to 1, floored at 0.72.
    static func bounceScale(progress: Double, clickBounce: Double) -> Double {
        max(bounceScaleFloor, 1 - sin(progress * .pi) * (bounceDip * max(0, clickBounce)))
    }

    /// Ripple progress: the effect starts after a delay of half the bounce duration, then
    /// fades from 1 to 0 over its own duration; 0 before the delay or after it ends.
    static func rippleProgress(ageMs: Double, bounceDurationMs: Double, effectDurationMs: Double) -> Double {
        let delay = bounceDurationMs * 0.5
        let effectAge = ageMs - delay
        guard effectAge >= 0, effectAge <= effectDurationMs, effectDurationMs > 0 else { return 0 }
        return 1 - effectAge / effectDurationMs
    }
}
