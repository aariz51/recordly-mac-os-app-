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
    case recordly // Recordly's signature curve: a soft lead-in with a long settle
    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear: return "Linear"
        case .smooth: return "Smooth"
        case .glide: return "Glide"
        case .snappy: return "Snappy"
        case .recordly: return "Signature"
        }
    }

    func apply(_ x: Double) -> CGFloat {
        let c = min(max(x, 0), 1)
        switch self {
        case .linear: return CGFloat(c)
        case .smooth: return CGFloat(c * c * (3 - 2 * c))
        case .glide:  return CGFloat(c * c * c * (c * (c * 6 - 15) + 10))
        case .snappy: return CGFloat(1 - pow(1 - c, 3))
        case .recordly:
            // A cubic-bezier(0.22, 1, 0.36, 1)-shaped ease-out: leaves fast, settles long.
            return CGFloat(1 - pow(1 - c, 4))
        }
    }
}

/// The two motion presets Recordly ships, which set every zoom timing at once.
enum ZoomMotionPreset: String, CaseIterable, Identifiable {
    case focused, smooth
    var id: String { rawValue }
    var label: String { self == .focused ? "Focused" : "Smooth" }
    var summary: String {
        switch self {
        case .focused: return "Snappier motion for demos and walkthroughs."
        case .smooth:  return "Gentler motion for presentations and polished reveals."
        }
    }
    /// (inDuration, outDuration, inEasing, outEasing)
    var timing: (Double, Double, ZoomEasing, ZoomEasing) {
        switch self {
        case .focused: return (0.85, 0.6, .snappy, .snappy)
        case .smooth:  return (1.52, 1.02, .recordly, .recordly)
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
    var ramp: Double = 0.5   // seconds to ease in and out (legacy; used when in/out are nil)
    var easing: ZoomEasing = .smooth

    // Recordly splits the single ramp into a separate entrance and exit, each with its own
    // duration and curve. Both default to `ramp`/`easing` so existing projects are unchanged.
    var inDuration: Double? = nil
    var outDuration: Double? = nil
    var inEasing: ZoomEasing? = nil
    var outEasing: ZoomEasing? = nil

    /// When on, two regions closer than `connectedGap` glide from one focus to the next at
    /// full zoom instead of pulling out and pushing back in.
    var connectZooms: Bool = false
    var connectedGap: Double = 1.5
    var connectedDuration: Double = 1.0
    var connectedEasing: ZoomEasing = .glide

    var effectiveInDuration: Double { max(0.001, inDuration ?? ramp) }
    var effectiveOutDuration: Double { max(0.001, outDuration ?? ramp) }
    var effectiveInEasing: ZoomEasing { inEasing ?? easing }
    var effectiveOutEasing: ZoomEasing { outEasing ?? easing }

    /// Applies a motion preset to the in/out timings.
    mutating func apply(preset: ZoomMotionPreset) {
        let (i, o, ie, oe) = preset.timing
        inDuration = i; outDuration = o; inEasing = ie; outEasing = oe
    }

    /// Add a manual zoom region at a chosen depth and focus point.
    @discardableResult
    mutating func addRegion(start: Double, end: Double,
                            depth: ZoomDepth = .strong,
                            focus: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> ZoomRegion {
        let region = ZoomRegion(start: start, end: end, scale: depth.scale, focus: focus)
        regions.append(region)
        return region
    }

    /// Merges regions separated by a gap ≤ `maxGap` into one continuous region, so the
    /// camera stays zoomed across quick successions instead of popping out and back in
    /// (Recordly's "connect neighbors"). The merged region keeps the deeper scale.
    mutating func connectNeighbors(maxGap: Double = 0.5) {
        guard regions.count > 1 else { return }
        let sorted = regions.sorted { $0.start < $1.start }
        var merged: [ZoomRegion] = [sorted[0]]
        for r in sorted.dropFirst() {
            var last = merged[merged.count - 1]
            if r.start - last.end <= maxGap {
                last.end = Swift.max(last.end, r.end)
                if r.scale > last.scale { last.scale = r.scale; last.focus = r.focus }
                merged[merged.count - 1] = last
            } else {
                merged.append(r)
            }
        }
        regions = merged
    }

    /// Returns scale (1 = no zoom) and focus point at time `t`.
    func value(at t: Double) -> (scale: CGFloat, focus: CGPoint) {
        let sorted = regions.sorted { $0.start < $1.start }

        // Inside a region: ramp in from its start, out toward its end. When the region is
        // connected to a neighbour on either side, that edge's ramp is suppressed — the
        // camera is already at depth coming in, and stays at depth going out.
        if let idx = sorted.firstIndex(where: { t >= $0.start && t <= $0.end }) {
            let r = sorted[idx]
            let prev = idx > 0 ? sorted[idx - 1] : nil
            let next = idx + 1 < sorted.count ? sorted[idx + 1] : nil
            let joinedBefore = connectZooms && prev.map { r.start - $0.end <= connectedGap } == true
            let joinedAfter = connectZooms && next.map { $0.start - r.end <= connectedGap } == true

            let inEnv = joinedBefore ? 1
                : effectiveInEasing.apply(min(1.0, (t - r.start) / effectiveInDuration))
            let outEnv = joinedAfter ? 1
                : effectiveOutEasing.apply(min(1.0, (r.end - t) / effectiveOutDuration))
            let env = min(inEnv, outEnv)
            return (1.0 + (r.scale - 1.0) * env, r.focus)
        }

        // Between two connected regions: hold the zoom and pan the focus across the gap.
        if connectZooms {
            for (a, b) in zip(sorted, sorted.dropFirst())
            where t > a.end && t < b.start && b.start - a.end <= connectedGap {
                let gap = b.start - a.end
                let span = max(0.001, min(connectedDuration, gap))
                // Centre the glide in the gap so the pan reads as deliberate rather than
                // rushing at one edge.
                let lead = (gap - span) / 2
                let p = min(1, max(0, (t - a.end - lead) / span))
                let e = Double(connectedEasing.apply(p))
                let scale = a.scale + (b.scale - a.scale) * CGFloat(e)
                let focus = CGPoint(x: a.focus.x + (b.focus.x - a.focus.x) * e,
                                    y: a.focus.y + (b.focus.y - a.focus.y) * e)
                return (scale, focus)
            }
        }
        return (1.0, CGPoint(x: 0.5, y: 0.5))
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
