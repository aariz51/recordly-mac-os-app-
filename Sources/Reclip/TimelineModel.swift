import Foundation

/// Pure timeline-model logic — a port of Recordly's `timeline/core` (`spans`, `time`,
/// `rows`). This is the data layer the timeline UI consumes (span clamping, time-label
/// formatting, track-row addressing); the drag-drop interaction layer is separate.
enum TimelineModel {

    // MARK: - Spans

    struct Span: Equatable { var start: Double; var end: Double }

    static func spansOverlap(_ left: Span, _ right: Span) -> Bool {
        left.end > right.start && left.start < right.end
    }

    /// Clamps a region [start, end] into [0, total] while preserving `minDuration`:
    /// the start can't push the region past the end of the timeline, and the end is
    /// always at least `minDuration` after the (clamped) start.
    static func normalizeRegionSpan(startMs: Double, endMs: Double,
                                    totalMs: Double, minDurationMs: Double) -> Span {
        let safeTotal = max(0, totalMs)
        let safeMin = max(0, min(minDurationMs, safeTotal))
        let clampedStart = max(0, min(startMs, safeTotal))
        let start = max(0, min(clampedStart, safeTotal - safeMin))
        let end = min(safeTotal, max(endMs, start + safeMin))
        return Span(start: start, end: end)
    }

    // MARK: - Time formatting

    /// Playhead label: `"1:05.3"` past a minute, else `"5.3s"`.
    static func formatPlayheadTime(ms: Double) -> String {
        let s = ms / 1000
        let minute = Int((s / 60).rounded(.down))
        let sec = s.truncatingRemainder(dividingBy: 60)
        if minute > 0 {
            let secStr = String(format: "%.1f", sec)
            return "\(minute):\(secStr.count < 4 ? String(repeating: "0", count: 4 - secStr.count) + secStr : secStr)"
        }
        return "\(String(format: "%.1f", sec))s"
    }

    /// Axis tick label; fractional digits depend on the tick interval (finer interval →
    /// more precision). Shows `h:mm:ss` past an hour, `m:ss[.f…]` otherwise.
    static func formatTimeLabel(ms: Double, intervalMs: Double) -> String {
        let totalSeconds = ms / 1000
        let hours = Int((totalSeconds / 3600).rounded(.down))
        let minutes = Int((totalSeconds.truncatingRemainder(dividingBy: 3600) / 60).rounded(.down))
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        let fractionalDigits = intervalMs < 250 ? 2 : (intervalMs < 1000 ? 1 : 0)

        if hours > 0 {
            return "\(hours):\(pad2(minutes)):\(pad2(Int(seconds.rounded(.down))))"
        }
        if fractionalDigits > 0 {
            let secFrac = String(format: "%.\(fractionalDigits)f", seconds)
            let parts = secFrac.split(separator: ".", maxSplits: 1)
            let whole = String(parts[0])
            let frac = parts.count > 1 ? String(parts[1]) : ""
            let wholePadded = whole.count < 2 ? String(repeating: "0", count: 2 - whole.count) + whole : whole
            return "\(minutes):\(wholePadded).\(frac)"
        }
        return "\(minutes):\(pad2(Int(seconds.rounded(.down))))"
    }

    private static func pad2(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }

    // MARK: - Track row IDs

    static let annotationRowId = "row-annotation"
    static let audioRowId = "row-audio"
    private static var annotationPrefix: String { annotationRowId + "-" }
    private static var audioPrefix: String { audioRowId + "-" }

    static func annotationTrackRowId(_ index: Int) -> String { "\(annotationRowId)-\(max(0, index))" }
    static func isAnnotationTrackRowId(_ rowId: String) -> Bool {
        rowId == annotationRowId || rowId.hasPrefix(annotationPrefix)
    }
    static func annotationTrackIndex(_ rowId: String) -> Int {
        if rowId == annotationRowId { return 0 }
        return max(0, Int(rowId.dropFirst(annotationPrefix.count)) ?? 0)
    }

    static func audioTrackRowId(_ index: Int) -> String { "\(audioPrefix)\(max(0, index))" }
    static func isAudioTrackRowId(_ rowId: String) -> Bool {
        rowId == audioRowId || rowId.hasPrefix(audioPrefix)
    }
    static func audioTrackIndex(_ rowId: String) -> Int {
        if rowId == audioRowId { return 0 }
        return max(0, Int(rowId.dropFirst(audioPrefix.count)) ?? 0)
    }
}
