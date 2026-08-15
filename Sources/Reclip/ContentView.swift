import SwiftUI
import ScreenCaptureKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var recorder = ScreenRecorder()

    enum SourceKind: String, CaseIterable, Identifiable {
        case display = "Display"
        case window = "Window"
        var id: String { rawValue }
    }

    @State private var sourceKind: SourceKind = .display
    @State private var displays: [SCDisplay] = []
    @State private var windows: [SCWindow] = []
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var selectedWindowID: CGWindowID?
    @State private var statusMessage = "Ready to record."
    @State private var lastSavedURL: URL?
    @State private var editing: EditItem?

    struct EditItem: Identifiable { let url: URL; var id: String { url.path } }

    var body: some View {
        VStack(spacing: 18) {
            header

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("", selection: $sourceKind) {
                        ForEach(SourceKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(recorder.isRecording)

                    sourcePicker

                    Divider()

                    Toggle("System audio", isOn: $recorder.captureSystemAudio)
                        .disabled(recorder.isRecording)
                    Toggle("Microphone", isOn: $recorder.captureMicrophone)
                        .disabled(recorder.isRecording)
                }
                .padding(8)
            }

            recordControls

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let url = lastSavedURL {
                HStack(spacing: 16) {
                    Button {
                        editing = EditItem(url: url)
                    } label: { Label("Polish & Export", systemImage: "wand.and.stars") }
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: { Label("Reveal in Finder", systemImage: "folder") }
                }
                .buttonStyle(.link)
            }

            Button {
                openRecording()
            } label: { Label("Open a recording to polish…", systemImage: "folder.badge.plus") }
                .buttonStyle(.link)
                .disabled(recorder.isRecording)

            Spacer()
        }
        .padding(24)
        .task { await refreshSources() }
        .onChange(of: sourceKind) { Task { await refreshSources() } }
        .sheet(item: $editing) { item in
            EditorView(sourceURL: item.url) { editing = nil }
        }
    }

    private func openRecording() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            editing = EditItem(url: url)
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: "record.circle")
                .font(.system(size: 38))
                .foregroundStyle(.pink)
            Text("Reclip").font(.title.bold())
            Text("Screen recorder").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sourcePicker: some View {
        switch sourceKind {
        case .display:
            Picker("Display", selection: $selectedDisplayID) {
                ForEach(displays, id: \.displayID) { d in
                    Text("Display \(d.displayID) — \(d.width)×\(d.height)").tag(Optional(d.displayID))
                }
            }
            .disabled(recorder.isRecording)
        case .window:
            Picker("Window", selection: $selectedWindowID) {
                ForEach(windows, id: \.windowID) { w in
                    Text(windowLabel(w)).tag(Optional(w.windowID))
                }
            }
            .disabled(recorder.isRecording)
        }
    }

    @ViewBuilder
    private var recordControls: some View {
        if recorder.isRecording {
            VStack(spacing: 10) {
                Text(timeString(recorder.elapsed))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.pink)
                Button(role: .destructive) { Task { await stop() } } label: {
                    Label("Stop Recording", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        } else {
            Button { Task { await start() } } label: {
                Label("Start Recording", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .disabled(!hasSelection)
        }
    }

    private var hasSelection: Bool {
        switch sourceKind {
        case .display: return selectedDisplayID != nil
        case .window: return selectedWindowID != nil
        }
    }

    // MARK: - Actions

    private func refreshSources() async {
        do {
            switch sourceKind {
            case .display:
                let list = try await recorder.availableDisplays()
                displays = list
                if selectedDisplayID == nil || !list.contains(where: { $0.displayID == selectedDisplayID }) {
                    selectedDisplayID = list.first?.displayID
                }
                statusMessage = list.isEmpty
                    ? "No displays found. Grant Screen Recording permission in System Settings."
                    : "Ready to record."
            case .window:
                let list = try await recorder.availableWindows()
                windows = list
                if selectedWindowID == nil || !list.contains(where: { $0.windowID == selectedWindowID }) {
                    selectedWindowID = list.first?.windowID
                }
                statusMessage = list.isEmpty ? "No windows available." : "Ready to record."
            }
        } catch {
            statusMessage = "Could not list sources: \(error.localizedDescription)"
        }
    }

    private func start() async {
        let source: CaptureSource?
        switch sourceKind {
        case .display: source = selectedDisplayID.map { .display($0) }
        case .window: source = selectedWindowID.map { .window($0) }
        }
        guard let source else { return }
        do {
            try await recorder.start(source: source, to: defaultOutputURL())
            statusMessage = "Recording…"
        } catch {
            statusMessage = "Failed to start: \(error.localizedDescription)"
        }
    }

    private func stop() async {
        do {
            try await recorder.stop()
            lastSavedURL = recorder.outputURL
            statusMessage = "Saved to \(recorder.outputURL?.lastPathComponent ?? "Movies")."
        } catch {
            statusMessage = "Failed to stop: \(error.localizedDescription)"
        }
    }

    private func windowLabel(_ w: SCWindow) -> String {
        let app = w.owningApplication?.applicationName ?? "App"
        let title = w.title ?? ""
        return title.isEmpty ? app : "\(app) — \(title)"
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
