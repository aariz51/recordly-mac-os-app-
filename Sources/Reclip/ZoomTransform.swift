import Foundation

/// Zoom-camera geometry — a port of the pure functions in Recordly's `zoomTransform.ts`
/// (the Pixi.js container/filter plumbing is the renderer's concern and lives elsewhere).
/// `compute` maps a normalized focus point + zoom scale + ramp progress to a scale and a
/// stage translation that keeps the focus centred; `focusFromTransform` is its inverse.
struct ZoomTransform: Equatable {
    var scale: Double
    var x: Double
    var y: Double

    struct Size: Equatable { var width: Double; var height: Double }
    struct Rect: Equatable { var x: Double; var y: Double; var width: Double; var height: Double }

    static func compute(stage: Size, baseMask: Rect, zoomScale: Double,
                        progress: Double = 1, focusX: Double, focusY: Double) -> ZoomTransform {
        guard stage.width > 0, stage.height > 0, baseMask.width > 0, baseMask.height > 0 else {
            return ZoomTransform(scale: 1, x: 0, y: 0)
        }
        let p = min(1, max(0, progress))
        let focusPxX = baseMask.x + focusX * baseMask.width
        let focusPxY = baseMask.y + focusY * baseMask.height
        let scale = 1 + (zoomScale - 1) * p
        let finalX = stage.width / 2 - focusPxX * zoomScale
        let finalY = stage.height / 2 - focusPxY * zoomScale
        return ZoomTransform(scale: scale, x: finalX * p, y: finalY * p)
    }

    /// Recovers the normalized focus (cx, cy) from a fully-applied transform (progress 1).
    static func focusFromTransform(stage: Size, baseMask: Rect, zoomScale: Double,
                                   x: Double, y: Double) -> (cx: Double, cy: Double) {
        guard stage.width > 0, stage.height > 0, baseMask.width > 0, baseMask.height > 0, zoomScale > 0 else {
            return (0.5, 0.5)
        }
        let focusPxX = (stage.width / 2 - x) / zoomScale
        let focusPxY = (stage.height / 2 - y) / zoomScale
        return ((focusPxX - baseMask.x) / baseMask.width, (focusPxY - baseMask.y) / baseMask.height)
    }
}
