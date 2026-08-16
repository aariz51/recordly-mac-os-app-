import Foundation
import AppKit

/// A timestamped, normalized cursor position (origin top-left, 0...1).
struct CursorSample: Codable {
    var t: Double          // seconds since recording start
    var x: Double
    var y: Double
}

/// Recorded cursor path for a clip, persisted as a sidecar JSON next to the MP4.
struct CursorTrack: Codable {
    var samples: [CursorSample] = []
    var clicks: [Double] = []      // timestamps (seconds) of mouse-down events

    static func sidecarURL(for movie: URL) -> URL {
        movie.deletingPathExtension().appendingPathExtension("cursor.json")
    }

    func save(besides movie: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.sidecarURL(for: movie))
    }

    static func load(besides movie: URL) -> CursorTrack? {
        let url = sidecarURL(for: movie)
        guard let data = try? Data(contentsOf: url),
              let track = try? JSONDecoder().decode(CursorTrack.self, from: data) else { return nil }
        return track
    }

    /// Nearest sample position at time `t` (normalized).
    func position(at t: Double) -> CGPoint? {
        guard !samples.isEmpty else { return nil }
        var best = samples[0]
        for s in samples where s.t <= t { best = s }
        return CGPoint(x: best.x, y: best.y)
    }

    /// Smoothly interpolated position at time `t` (linear between bracketing samples).
    func interpolated(at t: Double) -> CGPoint? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.t { return CGPoint(x: first.x, y: first.y) }
        if t >= last.t { return CGPoint(x: last.x, y: last.y) }
        for i in 1..<samples.count where samples[i].t >= t {
            let a = samples[i - 1], b = samples[i]
            let span = b.t - a.t
            let f = span > 1e-9 ? (t - a.t) / span : 0
            return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        }
        return CGPoint(x: last.x, y: last.y)
    }
}

/// Samples the global cursor position on a timer while a recording is in progress.
@MainActor
final class CursorSampler {
    private var timer: Timer?
    private var startedAt: Date?
    private var clickMonitor: Any?
    private(set) var track = CursorTrack()

    func start() {
        track = CursorTrack()
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        // Record click timestamps globally (for click-ripple rendering).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt else { return }
                self.track.clicks.append(Date().timeIntervalSince(startedAt))
            }
        }
    }

    func stop() -> CursorTrack {
        timer?.invalidate()
        timer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        return track
    }

    private func sample() {
        guard let startedAt else { return }
        guard let screen = NSScreen.main else { return }
        let mouse = NSEvent.mouseLocation                      // bottom-left origin, points
        let frame = screen.frame
        let nx = (mouse.x - frame.minX) / frame.width
        let ny = 1.0 - (mouse.y - frame.minY) / frame.height   // convert to top-left origin
        track.samples.append(CursorSample(t: Date().timeIntervalSince(startedAt),
                                          x: min(max(nx, 0), 1),
                                          y: min(max(ny, 0), 1)))
    }
}
