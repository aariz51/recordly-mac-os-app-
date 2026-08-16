import Foundation

/// A per-segment playback-speed region (in source time).
struct SpeedSegment: Equatable, Codable {
    var start: Double
    var end: Double
    var speed: Double
}

/// Maps output time ↔ source time when middle segments have been cut out (kept ranges
/// concatenated). Lets the compositor keep overlays (keyed to source time) in sync with a
/// cut timeline. Built from the list of surviving source ranges, in output order.
struct CutMap: Equatable {
    struct Segment: Equatable { var src: Double; var out: Double; var dur: Double }
    let segments: [Segment]

    /// Builds a CutMap from kept source ranges (as (start,end) seconds), concatenated.
    init(keptRanges: [(Double, Double)]) {
        var segs: [Segment] = []
        var acc = 0.0
        for (s, e) in keptRanges where e > s {
            let d = e - s
            segs.append(Segment(src: s, out: acc, dur: d))
            acc += d
        }
        segments = segs
    }

    var outputDuration: Double { segments.reduce(0) { $0 + $1.dur } }

    func sourceTime(forOutput t: Double) -> Double {
        if t <= 0 { return segments.first?.src ?? 0 }
        for s in segments where t <= s.out + s.dur + 1e-9 {
            return s.src + (t - s.out)
        }
        return segments.last.map { $0.src + $0.dur } ?? 0
    }
}

/// Piecewise time mapping for per-segment speed changes. Normalizes a set of speed regions
/// into contiguous segments covering `[0, sourceDuration]` (gaps run at 1×), and maps output
/// time ↔ source time so the compositor's overlays (zoom/cursor/captions, all keyed to source
/// time) stay in sync with a variable-speed timeline.
///
/// This is the tested foundation for speed regions; wiring it into the AVComposition build
/// (per-segment `scaleTimeRange`) is the follow-up, verified against `outputDuration`.
struct SpeedMap: Equatable {
    let segments: [SpeedSegment]     // contiguous, in source time
    let sourceDuration: Double

    init(regions: [SpeedSegment], sourceDuration: Double) {
        var segs: [SpeedSegment] = []
        let clean = regions.filter { $0.end > $0.start && $0.speed > 0 }.sorted { $0.start < $1.start }
        var cursor = 0.0
        for r in clean {
            let s = Swift.max(cursor, Swift.max(0, r.start))
            let e = Swift.min(sourceDuration, r.end)
            if e <= s { continue }
            if s > cursor { segs.append(SpeedSegment(start: cursor, end: s, speed: 1)) }
            segs.append(SpeedSegment(start: s, end: e, speed: Swift.min(Swift.max(r.speed, 0.1), 10)))
            cursor = e
        }
        if cursor < sourceDuration { segs.append(SpeedSegment(start: cursor, end: sourceDuration, speed: 1)) }
        if segs.isEmpty { segs = [SpeedSegment(start: 0, end: sourceDuration, speed: 1)] }
        self.segments = segs
        self.sourceDuration = sourceDuration
    }

    /// Total output (played) duration after the speed changes.
    var outputDuration: Double {
        segments.reduce(0) { $0 + ($1.end - $1.start) / $1.speed }
    }

    /// Whether any segment differs from 1× (else the timeline is a plain passthrough).
    var isIdentity: Bool { segments.allSatisfy { abs($0.speed - 1) < 1e-9 } }

    /// Maps an output-timeline time to the corresponding source time.
    func sourceTime(forOutput tOut: Double) -> Double {
        if tOut <= 0 { return 0 }
        var accOut = 0.0
        for seg in segments {
            let segOut = (seg.end - seg.start) / seg.speed
            if tOut <= accOut + segOut + 1e-12 {
                return seg.start + (tOut - accOut) * seg.speed
            }
            accOut += segOut
        }
        return sourceDuration
    }
}
