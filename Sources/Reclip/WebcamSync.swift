import Foundation

/// Webcam / timeline synchronization — a port of Recordly's `webcamSync.ts`. The webcam
/// sidecar can start at a different offset than the main recording; `targetTimeSeconds`
/// maps a timeline time to the webcam's own time (shifted by the offset, clamped to the
/// webcam duration). `shouldSeek` decides when the preview needs to re-seek the webcam
/// (on a timeline jump or when drift exceeds a play/pause-dependent threshold).
enum WebcamSync {
    /// The webcam media time to show for a given timeline `currentTime`.
    static func targetTimeSeconds(currentTime: Double, webcamDuration: Double?, timeOffsetMs: Double?) -> Double {
        let offsetMs = (timeOffsetMs?.isFinite == true) ? (timeOffsetMs ?? 0) : 0
        let shifted = currentTime - offsetMs / 1000
        return MediaTiming.clampMediaTime(shifted, duration: webcamDuration)
    }

    static func shouldSeek(desiredTime: Double, isPlaying: Bool, isSeeking: Bool,
                           previousTimelineTime: Double?, timelineTime: Double,
                           webcamCurrentTime: Double) -> Bool {
        if isSeeking { return false }
        let timelineJumped = previousTimelineTime == nil
            || abs(timelineTime - previousTimelineTime!) > 0.25
        let driftThreshold = isPlaying ? 0.35 : 0.01
        return timelineJumped || abs(webcamCurrentTime - desiredTime) > driftThreshold
    }
}
