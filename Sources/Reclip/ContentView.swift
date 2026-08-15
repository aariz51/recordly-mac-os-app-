import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @StateObject private var recorder = ScreenRecorder()
    @State private var displays: [SCDisplay] = []
    @State private var selectedDisplayID: CGDirectDisplayID?
    @State private var statusMessage = "Ready to record."
    @State private var lastSavedURL: URL?

    private var selectedDisplay: SCDisplay? {
        displays.first { $0.displayID == selectedDisplayID }
    }

    var body: some View {
        VStack(spacing: 20) {
            header

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("Display", selection: $selectedDisplayID) {
                        ForEach(displays, id: \.displayID) { d in
                            Text("Display \(d.displayID) — \(d.width)×\(d.height)")
                                .tag(Optional(d.displayID))
                        }
                    }
                    Toggle("Capture system audio", isOn: $recorder.captureSystemAudio)
                        .disabled(recorder.isRecording)
                }
                .padding(6)
            }

            recordControls

            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            if let url = lastSavedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal last recording in Finder", systemImage: "folder")
                }
                .buttonStyle(.link)
            }

            Spacer()
        }
        .padding(24)
        .task { await loadDisplays() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Image(systemName: "record.circle")
                .font(.system(size: 40))
                .foregroundStyle(.pink)
            Text("Reclip")
                .font(.title.bold())
            Text("Screen recorder")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recordControls: some View {
        if recorder.isRecording {
            VStack(spacing: 10) {
                Text(timeString(recorder.elapsed))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.pink)
                Button(role: .destructive) {
                    Task { await stop() }
                } label: {
                    Label("Stop Recording", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
        } else {
            Button {
                Task { await start() }
            } label: {
                Label("Start Recording", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .disabled(selectedDisplay == nil)
        }
    }

    // MARK: - Actions

    private func loadDisplays() async {
        do {
            let list = try await recorder.availableDisplays()
            displays = list
            if selectedDisplayID == nil { selectedDisplayID = list.first?.displayID }
            statusMessage = list.isEmpty
                ? "No displays found. Grant Screen Recording permission in System Settings."
                : "Ready to record."
        } catch {
            statusMessage = "Could not list displays: \(error.localizedDescription)"
        }
    }

    private func start() async {
        guard let display = selectedDisplay else { return }
        let url = defaultOutputURL()
        do {
            try await recorder.start(display: display, to: url)
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

    private func defaultOutputURL() -> URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return movies.appendingPathComponent("Reclip-\(stamp).mp4")
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
