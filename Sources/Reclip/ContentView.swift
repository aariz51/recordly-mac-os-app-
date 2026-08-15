import SwiftUI
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var recorder = ScreenRecorder()
    @Environment(\.accessibilityReduceMotion) private var reduce

    enum SourceKind: String, CaseIterable, Identifiable {
        case display = "Display"
        case window = "Window"
        var id: String { rawValue }
        var symbol: String { self == .display ? "display" : "macwindow" }
    }

    @State private var sourceKind: SourceKind = .display
    @State private var displays: [SCDisplay] = []
    @State private var windows: [SCWindow] = []
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var selectedWindowID: CGWindowID?
    @State private var feedback = Feedback(.status, "Pick what to capture, then press ⌘R.")
    @State private var lastSavedURL: URL?
    @State private var appeared = false

    struct Feedback: Equatable {
        let kind: FeedbackKind
        let message: String
        init(_ kind: FeedbackKind, _ message: String) { self.kind = kind; self.message = message }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Space.l) {
                header
                    .stagger(0, appeared: appeared, reduce: reduce)

                sourceCard
                    .stagger(1, appeared: appeared, reduce: reduce)

                captureCard
                    .stagger(2, appeared: appeared, reduce: reduce)

                recordControls
                    .stagger(3, appeared: appeared, reduce: reduce)

                FeedbackLine(kind: feedback.kind, message: feedback.message)
                    .padding(.horizontal, Space.xs)
                    .animation(Motion.enter(reduce), value: feedback)

                if let url = lastSavedURL, !recorder.isRecording {
                    resultCard(url)
                        .transition(.rise(reduce))
                }

                openButton
                    .padding(.top, Space.xs)
            }
            .padding(Space.xl)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(
            LinearGradient(colors: [Palette.canvasTop, Palette.canvasBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .task {
            await refreshSources()
            withAnimation(Motion.enter(reduce)) { appeared = true }
        }
        .onChange(of: sourceKind) { Task { await refreshSources() } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Palette.accent, Palette.accent.opacity(0.72)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 38, height: 38)
                    .shadow(color: Palette.accent.opacity(0.35), radius: 10, y: 4)
                Image(systemName: "record.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Reclip").displayType()
                Text("Record, polish, export")
                    .captionType()
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: Space.s)

            statusPill
        }
    }

    /// Answers "what is the app doing right now?" without reading the log line.
    private var statusPill: some View {
        HStack(spacing: 6) {
            if recorder.isRecording {
                RecordPulse(size: 7)
                Text("Recording")
            } else {
                Circle()
                    .fill(hasSelection ? Palette.success : Palette.warning)
                    .frame(width: 7, height: 7)
                Text(hasSelection ? "Ready" : "No source")
            }
        }
        .captionType()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        .animation(Motion.move(reduce), value: recorder.isRecording)
    }

    // MARK: - Source

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Source")

            Picker("", selection: $sourceKind) {
                ForEach(SourceKind.allCases) { kind in
                    Label(kind.rawValue, systemImage: kind.symbol).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(recorder.isRecording)

            sourcePicker

            if needsPermission {
                permissionHint
                    .transition(.rise(reduce, distance: 6))
            }
        }
        .card()
        .animation(Motion.move(reduce), value: needsPermission)
    }

    private var needsPermission: Bool {
        sourceKind == .display && displays.isEmpty
    }

    private var permissionHint: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            FeedbackLine(kind: .warning,
                         message: "Reclip needs Screen Recording permission before it can see your displays.")
            Button("Open Privacy Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
        }
        .padding(Space.m)
        .background(Palette.warning.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    @ViewBuilder
    private var sourcePicker: some View {
        switch sourceKind {
        case .display where displays.isEmpty, .window where windows.isEmpty:
            // An empty picker is a dead control; say what's missing instead.
            HStack(spacing: 6) {
                Image(systemName: "rectangle.dashed")
                Text(sourceKind == .display ? "No displays available yet" : "No windows open to record")
            }
            .captionType()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
        case .display:
            Picker("", selection: $selectedDisplayID) {
                ForEach(displays, id: \.displayID) { d in
                    Text("Display \(d.displayID)  ·  \(d.width)×\(d.height)").tag(Optional(d.displayID))
                }
            }
            .labelsHidden()
            .disabled(recorder.isRecording || displays.isEmpty)
        case .window:
            Picker("", selection: $selectedWindowID) {
                ForEach(windows, id: \.windowID) { w in
                    Text(windowLabel(w)).tag(Optional(w.windowID))
                }
            }
            .labelsHidden()
            .disabled(recorder.isRecording || windows.isEmpty)
        }
    }

    // MARK: - Capture options

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Capture")

            toggleRow(icon: "speaker.wave.2.fill",
                      title: "System audio",
                      subtitle: "Everything you hear on this Mac",
                      isOn: $recorder.captureSystemAudio,
                      enabled: !recorder.isRecording)

            toggleRow(icon: "mic.fill",
                      title: "Microphone",
                      subtitle: "Your voice, on its own track",
                      isOn: $recorder.captureMicrophone,
                      enabled: !recorder.isRecording)

            toggleRow(icon: "person.crop.circle.fill",
                      title: "Webcam",
                      subtitle: WebcamRecorder.hasCamera
                          ? "Recorded alongside, placed later in the editor"
                          : "No camera detected",
                      isOn: $recorder.captureWebcam,
                      enabled: !recorder.isRecording && WebcamRecorder.hasCamera)
        }
        .card(padding: Space.m)
    }

    private func toggleRow(icon: String,
                           title: String,
                           subtitle: String,
                           isOn: Binding<Bool>,
                           enabled: Bool) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue && enabled ? Palette.accent : .secondary)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .animation(Motion.press, value: isOn.wrappedValue)

            VStack(alignment: .leading, spacing: 1) {
                Text(title).titleType()
                Text(subtitle).captionType().foregroundStyle(.secondary)
            }

            Spacer(minLength: Space.s)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Palette.accent)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, Space.xs)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }

    // MARK: - Record

    @ViewBuilder
    private var recordControls: some View {
        VStack(spacing: Space.m) {
            if recorder.isRecording {
                HStack(spacing: Space.s) {
                    RecordPulse()
                    Text(timeString(recorder.elapsed))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .tracking(-0.5)
                        .contentTransition(.numericText())
                        .animation(Motion.enter(reduce), value: Int(recorder.elapsed))
                }
                .foregroundStyle(Palette.accent)

                Button { Task { await stop() } } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                }
                .buttonStyle(ActionButtonStyle(variant: .prominent, tint: Palette.accent))
                .keyboardShortcut("r", modifiers: .command)
            } else {
                Button { Task { await start() } } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                }
                .buttonStyle(ActionButtonStyle(variant: .prominent, tint: Palette.accent))
                .disabled(!hasSelection)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .animation(Motion.move(reduce), value: recorder.isRecording)
    }

    // MARK: - Result

    private func resultCard(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.success)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recording saved").titleType()
                    Text(url.lastPathComponent)
                        .captionType()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Space.s) {
                Button { EditorWindow.show(for: url) } label: {
                    Label("Polish & Export", systemImage: "wand.and.stars")
                }
                .buttonStyle(ActionButtonStyle(variant: .prominent))

                Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
            }
        }
        .card()
    }

    private var openButton: some View {
        Button { openRecording() } label: {
            Label("Open a recording to polish…", systemImage: "folder.badge.plus")
        }
        .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
        .disabled(recorder.isRecording)
        .keyboardShortcut("o", modifiers: .command)
    }

    private var hasSelection: Bool {
        switch sourceKind {
        case .display: return selectedDisplayID != nil
        case .window: return selectedWindowID != nil
        }
    }

    // MARK: - Actions

    private func openRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            EditorWindow.show(for: url)
        }
    }

    private func refreshSources() async {
        do {
            switch sourceKind {
            case .display:
                let list = try await recorder.availableDisplays()
                displays = list
                if selectedDisplayID == nil || !list.contains(where: { $0.displayID == selectedDisplayID }) {
                    selectedDisplayID = list.first?.displayID
                }
                feedback = list.isEmpty
                    ? Feedback(.warning, "No displays visible yet — grant Screen Recording access to continue.")
                    : Feedback(.status, "Pick what to capture, then press ⌘R.")
            case .window:
                let list = try await recorder.availableWindows()
                windows = list
                if selectedWindowID == nil || !list.contains(where: { $0.windowID == selectedWindowID }) {
                    selectedWindowID = list.first?.windowID
                }
                feedback = list.isEmpty
                    ? Feedback(.warning, "No open windows to record right now.")
                    : Feedback(.status, "Recording a single window keeps the rest of your desktop private.")
            }
        } catch {
            feedback = Feedback(.error, "Could not list sources: \(error.localizedDescription)")
        }
    }

    private func start() async {
        let source: CaptureSource?
        switch sourceKind {
        case .display: source = selectedDisplayID.map { .display($0) }
        case .window: source = selectedWindowID.map { .window($0) }
        }
        guard let source else { return }
        withAnimation(Motion.enter(reduce)) { lastSavedURL = nil }
        do {
            try await recorder.start(source: source, to: defaultOutputURL())
            feedback = Feedback(.status, "Recording. Press ⌘R again to stop.")
        } catch {
            feedback = Feedback(.error, "Failed to start: \(error.localizedDescription)")
        }
    }

    private func stop() async {
        do {
            try await recorder.stop()
            let url = recorder.outputURL
            withAnimation(Motion.settle(reduce)) { lastSavedURL = url }
            feedback = Feedback(.success, "Saved to \(url?.deletingLastPathComponent().lastPathComponent ?? "Movies").")
        } catch {
            feedback = Feedback(.error, "Failed to stop: \(error.localizedDescription)")
        }
    }

    private func windowLabel(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "App"
        let title = w.title ?? ""
        return title.isEmpty ? app : "\(app)  ·  \(title)"
    }

    private func defaultOutputURL() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return movies.appendingPathComponent("Reclip-\(stamp).mp4")
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Launch stagger
//
// The launch cascade is a once-per-session moment, so it can spend a little of
// the delight budget. 55ms between cards — long enough to read as a cascade,
// short enough that nothing feels withheld. It never blocks interaction.

private extension View {
    func stagger(_ index: Int, appeared: Bool, reduce: Bool) -> some View {
        let delay = reduce ? 0 : Double(index) * 0.055
        return opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduce ? 0 : 8)
            .animation(Motion.enter(reduce).delay(delay), value: appeared)
    }
}
