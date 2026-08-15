import Foundation
import CoreGraphics

/// A period of the clip that is zoomed in on a focus point (normalized, top-left origin).
struct ZoomRegion: Identifiable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale: CGFloat
    var focus: CGPoint      // normalized 0...1, top-left origin
}

/// Ramp curves for how a zoom eases in and out.
enum ZoomEasing: String, CaseIterable, Identifiable {
    case linear
    case smooth   // smoothstep
    case glide    // smootherstep (gentler)
    case snappy   // ease-out cubic (fast in, settle)
    var id: String { rawValue }

    func apply(_ x: Double) -> CGFloat {
        let c = min(max(x, 0), 1)
        switch self {
        case .linear: return CGFloat(c)
        case .smooth: return CGFloat(c * c * (3 - 2 * c))
        case .glide:  return CGFloat(c * c * c * (c * (c * 6 - 15) + 10))
        case .snappy: return CGFloat(1 - pow(1 - c, 3))
        }
    }
}

/// The six zoom depth presets (Recordly parity).
enum ZoomDepth: String, CaseIterable, Identifiable {
    case subtle = "1.25×"
    case light = "1.5×"
    case medium = "1.8×"
    case strong = "2.2×"
    case heavy = "3.5×"
    case max = "5×"
    var id: String { rawValue }
    var scale: CGFloat {
        switch self {
        case .subtle: return 1.25
        case .light: return 1.5
        case .medium: return 1.8
        case .strong: return 2.2
        case .heavy: return 3.5
        case .max: return 5.0
        }
    }
}

/// Evaluates the active zoom (scale + focus) at any time, with eased in/out ramps.
struct ZoomTimeline: Equatable {
    var regions: [ZoomRegion] = []
    var ramp: Double = 0.5   // seconds to ease in and out
    var easing: ZoomEasing = .smooth

    /// Add a manual zoom region at a chosen depth and focus point.
    @discardableResult
    mutating func addRegion(start: Double, end: Double,
                            depth: ZoomDepth = .strong,
                            focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> ZoomRegion {
        let region = ZoomRegion(start: start, end: end, scale: depth.scale, focus: focus)
        regions.append(region)
        return region
    }

    /// Returns scale (1 = no zoom) and focus point at time `t`.
    func value(at t: Double) -> (scale: CGFloat, focus: CGPoint) {
        guard let r = regions.first(where: { t >= $0.start && t <= $0.end }) else {
            return (1.0, CGPoint(x: 0.5, y: 0.5))
        }
        let inRamp = min(1.0, (t - r.start) / max(ramp, 0.001))
        let outRamp = min(1.0, (r.end - t) / max(ramp, 0.001))
        let env = easing.apply(min(inRamp, outRamp))
        let scale = 1.0 + (r.scale - 1.0) * env
        return (scale, r.focus)
    }

    /// Build zoom regions automatically from cursor dwell clusters.
    static func autoZoom(from track: CursorTrack, duration: Double,
                         segment: Double = 3.0, scale: CGFloat = 1.7) -> ZoomTimeline {
        guard duration > 0.3, !track.samples.isEmpty else { return ZoomTimeline() }
        var regions: [ZoomRegion] = []
        var t = 0.0
        while t < duration {
            let end = min(t + segment, duration)
            let window = track.samples.filter { $0.t >= t && $0.t < end }
            if !window.isEmpty {
                let cx = window.map(\.x).reduce(0, +) / Double(window.count)
                let cy = window.map(\.y).reduce(0, +) / Double(window.count)
                // movement spread in the window; only zoom where there is some dwell
                let spread = window.map { abs($0.x - cx) + abs($0.y - cy) }.reduce(0, +) / Double(window.count)
                if spread < 0.20 {
                    regions.append(ZoomRegion(start: t + 0.1, end: end - 0.1,
                                              scale: scale, focus: CGPoint(x: cx, y: cy)))
                }
            }
            t += segment
        }
        return ZoomTimeline(regions: mergeAdjacent(regions))
    }

    private static func mergeAdjacent(_ regions: [ZoomRegion]) -> [ZoomRegion] {
        guard !regions.isEmpty else { return [] }
        var merged: [ZoomRegion] = [regions[0]]
        for r in regions.dropFirst() {
            var last = merged[merged.count - 1]
            let close = abs(r.focus.x - last.focus.x) + abs(r.focus.y - last.focus.y) < 0.12
            if close && r.start - last.end < 0.6 {
                last.end = r.end
                last.focus = CGPoint(x: (last.focus.x + r.focus.x) / 2,
                                     y: (last.focus.y + r.focus.y) / 2)
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }
        return merged
    }
}
