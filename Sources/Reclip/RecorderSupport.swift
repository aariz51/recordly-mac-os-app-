import SwiftUI
import AVFoundation

// MARK: - Persisted recording preferences
//
// Where recordings go and how long the countdown runs are decisions a user makes once, not
// once per take, so they outlive the window.

@MainActor
final class RecordingPreferences: ObservableObject {
    private enum Key {
        static let folder = "reclip.recordingsFolder"
        static let countdown = "reclip.countdownSeconds"
    }

    @Published var countdownSeconds: Int {
        didSet { UserDefaults.standard.set(countdownSeconds, forKey: Key.countdown) }
    }

    /// Security-scoped bookmark isn't needed for a non-sandboxed debug build, but storing
    /// the path keeps the choice across launches either way.
    @Published var folderPath: String? {
        didSet { UserDefaults.standard.set(folderPath, forKey: Key.folder) }
    }

    init() {
        let d = UserDefaults.standard
        countdownSeconds = d.object(forKey: Key.countdown) as? Int ?? 3
        folderPath = d.string(forKey: Key.folder)
    }

    var folder: URL {
        if let folderPath { return URL(fileURLWithPath: folderPath) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var folderLabel: String { folder.lastPathComponent }

    func outputURL() -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent("Reclip-\(stamp).mp4")
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder
        if panel.runModal() == .OK, let url = panel.url { folderPath = url.path }
    }
}

// MARK: - Microphone level
//
// A meter answers the question a device picker can't: "is this the input that's actually
// hearing me?" It runs only while idle — during a take the mic belongs to the recorder.

@MainActor
final class MicLevelMonitor: ObservableObject {
    /// 0…100, as `AudioLevelMeter.normalize` produces.
    @Published private(set) var level: Double = 0
    @Published private(set) var running = false

    private let engine = AVAudioEngine()
    private var meter = AudioLevelMeter()

    func start() {
        guard !running else { return }
        // Asking for the mic here would prompt mid-setup; only meter once it's already
        // granted, and stay silent otherwise.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            let rms = AudioLevelMeter.rms(samples)
            let value = AudioLevelMeter.normalize(rms: rms)
            Task { @MainActor [weak self] in self?.apply(value) }
        }
        do {
            try engine.start()
            running = true
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    private func apply(_ value: Double) {
        // Smooth toward the new reading so the meter doesn't strobe on transients.
        let a = meter.smoothingFactor
        level = level * a + value * (1 - a)
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
        level = 0
    }
}

// MARK: - Countdown
//
// Between "Record" and the first frame there has to be a moment to get out of the way —
// switch windows, put the pointer somewhere sane. A full-screen count is the only readout
// that's legible from across the desk.

struct CountdownOverlay: View {
    let remaining: Int
    var onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: Space.l) {
                Text("\(remaining)")
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(Motion.enter(reduce), value: remaining)
                Text("Recording starts in a moment")
                    .captionType()
                    .foregroundStyle(.white.opacity(0.75))
                Button("Cancel", action: onCancel)
                    .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recording starts in \(remaining) seconds")
    }
}

// MARK: - Permission summary
//
// Three permissions gate a full-featured take, and each fails differently. Naming which one
// is missing — and linking straight to its pane — is the difference between a fixable
// problem and a mysterious one.

struct PermissionRow: View {
    let title: String
    let detail: String
    let status: CapturePermission
    let settingsURL: String

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).controlLabelType()
                Text(detail)
                    .captionType()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.s)
            if status != .authorized {
                Button("Open") {
                    if let url = URL(string: settingsURL) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(status == .authorized ? "granted" : "not granted")")
    }

    private var symbol: String {
        status == .authorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
    private var color: Color {
        status == .authorized ? Palette.success : Palette.warning
    }
}
