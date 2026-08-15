import Foundation

/// The user-facing recording timer and its pause/resume/countdown state machine — a port
/// of Recordly's `useScreenRecorder` clock (`accumulatedPausedDurationMs` /
/// `pauseStartedAtMs`). The elapsed time excludes any paused spans:
///
///     elapsed = now − startedAt − accumulatedPaused − currentPause
///
/// This is the capture-control logic that does *not* depend on the OS screen-recording
/// permission, so it is unit-tested here; the actual SCStream start/stop is wired
/// separately in ScreenRecorder. All times are in milliseconds.
struct RecordingClock: Equatable {
    private(set) var startedAtMs: Double?
    private(set) var accumulatedPausedMs = 0.0
    private(set) var pauseStartedAtMs: Double?

    var isRunning: Bool { startedAtMs != nil }
    var isPaused: Bool { pauseStartedAtMs != nil }

    mutating func start(at now: Double) {
        startedAtMs = now
        accumulatedPausedMs = 0
        pauseStartedAtMs = nil
    }

    /// Begins a pause span. No-op if not running or already paused.
    mutating func pause(at now: Double) {
        guard startedAtMs != nil, pauseStartedAtMs == nil else { return }
        pauseStartedAtMs = now
    }

    /// Ends the current pause span, folding its duration into the paused accumulator.
    mutating func resume(at now: Double) {
        guard let pausedAt = pauseStartedAtMs else { return }
        accumulatedPausedMs += max(0, now - pausedAt)
        pauseStartedAtMs = nil
    }

    /// Elapsed recording time, excluding all paused spans (including one in progress).
    func elapsedMs(at now: Double) -> Double {
        guard let started = startedAtMs else { return 0 }
        let currentPause = pauseStartedAtMs.map { max(0, now - $0) } ?? 0
        return max(0, now - started - accumulatedPausedMs - currentPause)
    }

    mutating func reset() {
        startedAtMs = nil
        accumulatedPausedMs = 0
        pauseStartedAtMs = nil
    }
}

/// The recorder's high-level phase. Mirrors Recordly's boolean flags
/// (`starting` / `countdownActive` / `recording` / `paused` / `finalizing`) as one enum.
enum RecordingPhase: String, Equatable {
    case idle, countdown, recording, paused, finalizing
}

/// A pre-roll countdown (Recordly's `countdownDelay`, default 3s). `remainingSeconds`
/// counts down from the delay to 0; `isFinished` flips when the delay has elapsed.
struct Countdown: Equatable {
    var delaySeconds: Int = 3
    private(set) var startedAtMs: Double?

    mutating func begin(at now: Double) { startedAtMs = now }
    mutating func cancel() { startedAtMs = nil }

    func remainingSeconds(at now: Double) -> Int {
        guard let started = startedAtMs else { return delaySeconds }
        let elapsed = max(0, now - started) / 1000.0
        return max(0, delaySeconds - Int(elapsed.rounded(.down)))
    }

    func isFinished(at now: Double) -> Bool {
        guard let started = startedAtMs else { return false }
        return (now - started) / 1000.0 >= Double(delaySeconds)
    }
}
