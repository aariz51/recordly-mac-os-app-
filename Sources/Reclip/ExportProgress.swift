import Foundation

/// Export progress reported to the UI — a port of Recordly's `ExportProgress` /
/// `exportProgressState.ts`. Carries the frame counters, a 0…100 percentage, an ETA, and
/// the current `phase`. `saving(previous:)` collapses to a finished 100% saving state,
/// preserving the earlier frame totals (Recordly's `resolveSavingExportProgress`).
struct ExportProgress: Equatable {
    enum Phase: String, Equatable { case preparing, extracting, rendering, finalizing, saving }

    var currentFrame: Int
    var totalFrames: Int
    var percentage: Double
    var estimatedTimeRemaining: Double     // seconds
    var phase: Phase

    /// Builds a progress value with the percentage derived from the frame counters.
    static func make(currentFrame: Int, totalFrames: Int, phase: Phase,
                     estimatedTimeRemaining: Double = 0) -> ExportProgress {
        let pct = totalFrames > 0
            ? min(100, max(0, Double(currentFrame) / Double(totalFrames) * 100))
            : 0
        return ExportProgress(currentFrame: currentFrame, totalFrames: totalFrames,
                              percentage: pct, estimatedTimeRemaining: estimatedTimeRemaining,
                              phase: phase)
    }

    /// The terminal "saving" state: 100%, no ETA, frame totals carried from `previous`.
    static func saving(previous: ExportProgress?) -> ExportProgress {
        let frames = previous.map { max($0.totalFrames, $0.currentFrame, 1) } ?? 1
        return ExportProgress(currentFrame: frames, totalFrames: frames,
                              percentage: 100, estimatedTimeRemaining: 0, phase: .saving)
    }
}
