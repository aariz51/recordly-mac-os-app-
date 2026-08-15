import Foundation

/// Playback / trim / duration timing helpers — a port of the applicable pure functions in
/// Recordly's `mediaTiming.ts`. (The preview-player sync-rate and pitch-preservation
/// helpers are AVPlayer/AVAudioMix concerns and live in the player layer, not here.)
enum MediaTiming {
    /// Clamps a seek/trim time into [0, duration]. A nil/non-finite duration leaves the
    /// (non-negative) target unchanged.
    static func clampMediaTime(_ target: Double, duration: Double?) -> Double {
        let safeTarget = max(0, target)
        guard let d = duration, d.isFinite else { return safeTarget }
        return max(0, min(safeTarget, max(0, d)))
    }

    /// Reconciles a container duration with a decoded stream duration: prefers the stream
    /// duration, but falls back to the container's when they differ by more than
    /// max(2s, 10%) — a stream that decoded short shouldn't truncate the timeline.
    static func effectiveStreamDurationSeconds(duration: Double?, streamDuration: Double?) -> Double {
        let safeDuration = (duration?.isFinite == true && (duration ?? 0) > 0) ? max(0, duration!) : 0
        let safeStream = (streamDuration?.isFinite == true && (streamDuration ?? 0) > 0) ? max(0, streamDuration!) : 0
        if safeDuration > 0 && safeStream > 0 {
            let gap = safeDuration - safeStream
            let threshold = max(2, safeDuration * 0.1)
            return gap > threshold ? safeDuration : safeStream
        }
        if safeStream > 0 { return safeStream }
        if safeDuration > 0 { return safeDuration }
        return 0
    }

    /// Recording duration excluding paused spans — Recordly's `getEffectiveRecordingDurationMs`.
    /// Equivalent to `RecordingClock.elapsedMs`, exposed in Recordly's parameter form for
    /// duration finalization at stop time.
    static func effectiveRecordingDurationMs(startTimeMs: Double, endTimeMs: Double,
                                             accumulatedPausedDurationMs: Double = 0,
                                             pauseStartedAtMs: Double? = nil) -> Double {
        guard startTimeMs.isFinite, endTimeMs.isFinite else { return 0 }
        let safeStart = max(0, startTimeMs)
        let safeEnd = max(safeStart, endTimeMs)
        let activePause = pauseStartedAtMs.map { max(0, safeEnd - $0) } ?? 0
        return max(0, safeEnd - safeStart - max(0, accumulatedPausedDurationMs) - activePause)
    }
}
