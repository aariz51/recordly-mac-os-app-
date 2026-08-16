import SwiftUI
import ScreenCaptureKit
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var recorder = ScreenRecorder()
    @StateObject private var prefs = RecordingPreferences()
    @StateObject private var micLevel = MicLevelMonitor()
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
    @State private var countdownRemaining: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var showPermissions = false

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

                destinationCard
                    .stagger(3, appeared: appeared, reduce: reduce)

                recordControls
                    .stagger(4, appeared: appeared, reduce: reduce)

                FeedbackLine(kind: feedback.kind, message: feedback.message)
                    .padding(.horizontal, Space.xs)
                    .animation(Motion.enter(reduce), value: feedback)

                if let url = lastSavedURL, !recorder.isRecording {
                    resultCard(url)
                        .transition(.rise(reduce))
                }

                openButtons
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
        .overlay {
            if let remaining = countdownRemaining {
                CountdownOverlay(remaining: remaining) { cancelCountdown() }
            }
        }
        .animation(Motion.enter(reduce), value: countdownRemaining)
        .task {
            await refreshSources()
            withAnimation(Motion.enter(reduce)) { appeared = true }
        }
        .onChange(of: sourceKind) { Task { await refreshSources() } }
        // The meter is a pre-flight check: it runs while the mic is enabled and idle, and
        // hands the device back the moment a take starts.
        .onChange(of: recorder.captureMicrophone) { _, on in
            if on && !recorder.isRecording { micLevel.start() } else { micLevel.stop() }
        }
        .onChange(of: recorder.isRecording) { _, on in
            if on { micLevel.stop() } else if recorder.captureMicrophone { micLevel.start() }
        }
        .onDisappear { micLevel.stop(); countdownTask?.cancel() }
        .sheet(isPresented: $showPermissions) { permissionSheet }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Space.m) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.badge, style: .continuous)
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
                if recorder.isPaused {
                    Circle().fill(Palette.warning).frame(width: 7, height: 7)
                    Text("Paused")
                } else {
                    RecordPulse(size: 7)
                    Text("Recording")
                }
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
        .animation(Motion.move(reduce), value: recorder.isPaused)
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

            ToggleRow(icon: "speaker.wave.2.fill",
                      title: "System audio",
                      subtitle: "Everything you hear on this Mac",
                      isOn: $recorder.captureSystemAudio,
                      enabled: !recorder.isRecording)

            ToggleRow(icon: "mic.fill",
                      title: "Microphone",
                      subtitle: "Your voice, on its own track",
                      isOn: $recorder.captureMicrophone,
                      enabled: !recorder.isRecording)

            if recorder.captureMicrophone {
                VStack(alignment: .leading, spacing: Space.s) {
                    devicePicker(title: "Input",
                                 devices: recorder.availableMicrophones,
                                 selection: $recorder.microphoneDeviceID)
                    // The meter proves the chosen input is live before a take, not after.
                    LevelMeter(level: micLevel.level)
                }
                .padding(.leading, 38)
                .transition(.rise(reduce, distance: 6))
            }

            ToggleRow(icon: "person.crop.circle.fill",
                      title: "Webcam",
                      subtitle: WebcamRecorder.hasCamera
                          ? "Recorded alongside, placed later in the editor"
                          : "No camera detected",
                      isOn: $recorder.captureWebcam,
                      enabled: !recorder.isRecording && WebcamRecorder.hasCamera)

            if recorder.captureWebcam {
                devicePicker(title: "Camera",
                             devices: recorder.availableCameras,
                             selection: $recorder.webcamDeviceID)
                    .padding(.leading, 38)
                    .transition(.rise(reduce, distance: 6))
            }

            ToggleRow(icon: "cursorarrow",
                      title: "Show cursor",
                      subtitle: "Bakes the live pointer into the capture. Turn it off to draw a clean one in the editor.",
                      isOn: $recorder.showCursor,
                      enabled: !recorder.isRecording)
        }
        .card(padding: Space.m)
        .animation(Motion.move(reduce), value: recorder.captureMicrophone)
        .animation(Motion.move(reduce), value: recorder.captureWebcam)
    }

    private func devicePicker(title: String, devices: [CaptureDeviceInfo],
                              selection: Binding<String?>) -> some View {
        HStack {
            Text(title).captionType().foregroundStyle(.secondary)
            Spacer(minLength: Space.s)
            Picker("", selection: selection) {
                Text("System default").tag(String?.none)
                ForEach(devices) { d in Text(d.name).tag(Optional(d.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
            .disabled(recorder.isRecording)
        }
    }

    // MARK: - Destination and timing

    private var destinationCard: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Before you start")

            HStack {
                Text("Countdown").controlLabelType()
                Spacer(minLength: Space.s)
                Picker("", selection: $prefs.countdownSeconds) {
                    Text("None").tag(0)
                    Text("3s").tag(3)
                    Text("5s").tag(5)
                    Text("10s").tag(10)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                .disabled(recorder.isRecording)
            }

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Save to").controlLabelType()
                    Text(prefs.folder.path)
                        .captionType()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: Space.s)
                Button("Change…") { prefs.chooseFolder() }
                    .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                    .disabled(recorder.isRecording)
            }

            Button {
                showPermissions = true
            } label: {
                Label("Check permissions", systemImage: "lock.shield")
            }
            .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
        }
        .card(padding: Space.m)
    }

    private var permissionSheet: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Permissions").displayType()
                    Text("What Reclip needs, and why")
                        .captionType()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.s)
                Button { showPermissions = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Close")
            }

            PermissionRow(title: "Screen Recording",
                          detail: "Required — without it there is nothing to capture.",
                          status: displays.isEmpty ? .denied : .authorized,
                          settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            PermissionRow(title: "Microphone",
                          detail: "Only needed when you record your voice.",
                          status: CapturePermission.fromAVStatus(
                            AVCaptureDevice.authorizationStatus(for: .audio)),
                          settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
            PermissionRow(title: "Camera",
                          detail: "Only needed for the webcam bubble.",
                          status: CapturePermission.fromAVStatus(
                            AVCaptureDevice.authorizationStatus(for: .video)),
                          settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")

            Text("macOS only re-reads these when an app launches, so quit and reopen Reclip after granting one.")
                .captionType()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.xl)
        .frame(width: 400)
    }

    // MARK: - Record

    @ViewBuilder
    private var recordControls: some View {
        VStack(spacing: Space.m) {
            if recorder.isRecording {
                HStack(spacing: Space.s) {
                    if recorder.isPaused {
                        Circle().fill(Palette.warning).frame(width: 9, height: 9)
                    } else {
                        RecordPulse()
                    }
                    Text(timeString(recorder.elapsed))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .tracking(-0.5)
                        .contentTransition(.numericText())
                        .animation(Motion.enter(reduce), value: Int(recorder.elapsed))
                }
                .foregroundStyle(recorder.isPaused ? Palette.warning : Palette.accent)

                Button { Task { await stop() } } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                }
                .buttonStyle(ActionButtonStyle(variant: .prominent, tint: Palette.accent))
                .keyboardShortcut("r", modifiers: .command)

                HStack(spacing: Space.s) {
                    Button {
                        if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                    } label: {
                        Label(recorder.isPaused ? "Resume" : "Pause",
                              systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(ActionButtonStyle(variant: .secondary))

                    Button(role: .destructive) { Task { await cancelTake() } } label: {
                        Label("Discard", systemImage: "trash")
                    }
                    .buttonStyle(ActionButtonStyle(variant: .secondary))
                }
            } else {
                Button { startWithCountdown() } label: {
                    Label("Start Recording", systemImage: "record.circle.fill")
                }
                .buttonStyle(ActionButtonStyle(variant: .prominent, tint: Palette.accent))
                .disabled(!hasSelection || countdownRemaining != nil)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .animation(Motion.move(reduce), value: recorder.isRecording)
        .animation(Motion.move(reduce), value: recorder.isPaused)
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

    private var openButtons: some View {
        HStack(spacing: Space.s) {
            Button { openRecording() } label: {
                Label("Open a recording…", systemImage: "folder.badge.plus")
            }
            .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
            .disabled(recorder.isRecording)
            .keyboardShortcut("o", modifiers: .command)

            Button { openProject() } label: {
                Label("Open a project…", systemImage: "doc.badge.gearshape")
            }
            .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
            .disabled(recorder.isRecording)
            .help("Opens a .reclip project alongside its recording")
        }
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

    /// Opening a `.reclip` opens the recording it describes — the project is the settings,
    /// the movie is the subject, and the editor needs both.
    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "reclip") ?? .json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let project = try? ReclipProject.load(from: url) else {
            feedback = Feedback(.error, "That project file could not be read.")
            return
        }
        let movie = url.deletingLastPathComponent().appendingPathComponent(project.sourceFileName)
        guard FileManager.default.fileExists(atPath: movie.path) else {
            feedback = Feedback(.error, "The recording this project points at (\(project.sourceFileName)) isn't next to it.")
            return
        }
        EditorWindow.show(for: movie)
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

    /// Runs the countdown (if any), then starts. Escape during the count aborts without
    /// having touched the capture stack.
    private func startWithCountdown() {
        guard prefs.countdownSeconds > 0 else {
            Task { await start() }
            return
        }
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            var remaining = prefs.countdownSeconds
            countdownRemaining = remaining
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { countdownRemaining = nil; return }
                remaining -= 1
                countdownRemaining = remaining > 0 ? remaining : nil
            }
            await start()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdownRemaining = nil
        feedback = Feedback(.status, "Countdown cancelled.")
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
            try await recorder.start(source: source, to: prefs.outputURL())
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
            feedback = Feedback(.success, "Saved to \(prefs.folderLabel).")
        } catch {
            feedback = Feedback(.error, "Failed to stop: \(error.localizedDescription)")
        }
    }

    private func cancelTake() async {
        await recorder.discard()
        withAnimation(Motion.enter(reduce)) { lastSavedURL = nil }
        feedback = Feedback(.status, "Take discarded — nothing was saved.")
    }

    private func windowLabel(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "App"
        let title = w.title ?? ""
        return title.isEmpty ? app : "\(app)  ·  \(title)"
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
