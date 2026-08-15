import Foundation
import CoreGraphics

/// Zoom-focus clamping — a port of Recordly's `focusUtils.clampFocusToScale`. At a given
/// zoom scale the visible viewport has size `1/scale`; the focus point must stay far enough
/// from the edges (`margin = 1/(2·scale)`) that the viewport remains within [0, 1]. This
/// keeps a corner-biased zoom showing a full in-frame region rather than running off the
/// edge, and is a no-op for focuses already near centre.
enum FocusUtils {
    static func focusBounds(scale: CGFloat) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        let s = max(1, scale)
        let margin = 1 / (2 * s)
        return (margin, 1 - margin, margin, 1 - margin)
    }

    static func clampFocusToScale(_ focus: CGPoint, scale: CGFloat) -> CGPoint {
        let b = focusBounds(scale: scale)
        let cx = min(max(focus.x, 0), 1)
        let cy = min(max(focus.y, 0), 1)
        return CGPoint(x: min(max(cx, b.minX), b.maxX),
                       y: min(max(cy, b.minY), b.maxY))
    }
}
