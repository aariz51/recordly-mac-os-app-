import SwiftUI
import AVKit
import AVFoundation

struct EditorView: View {
    let sourceURL: URL
    var onClose: () -> Void

    @State private var style = StyleOptions()
    @State private var zoom = ZoomTimeline()
    @State private var autoZoom = false
    @State private var cursorTrack: CursorTrack?
    @State private var duration: Double = 0
    @State private var trimStart: Double = 0
    @State private var trimEnd: Double = 0
    @State private var webcamFrames = WebcamFrames()
    @State private var webcamLoaded = false
    @State private var webcam = WebcamSettings()
    @State private var player = AVPlayer()
    @State private var playerItem: AVPlayerItem?
    @State private var isExporting = false
    @State private var status = ""
    @State private var exportedURL: URL?

    private let presets: [(String, StyleOptions.Background)] = [
        ("Indigo", .gradient(topRGB: (0.39, 0.36, 1.0), bottomRGB: (0.66, 0.33, 0.97))),
        ("Sunset", .gradient(topRGB: (1.0, 0.42, 0.42), bottomRGB: (0.99, 0.79, 0.34))),
        ("Ocean", .gradient(topRGB: (0.15, 0.55, 0.95), bottomRGB: (0.10, 0.20, 0.45))),
        ("Charcoal", .solid(red: 0.11, green: 0.12, blue: 0.14)),
        ("White", .solid(red: 0.96, green: 0.96, blue: 0.97))
    ]
    @State private var presetIndex = 0

    var body: some View {
        HSplitView {
            VideoPlayer(player: player)
                .frame(minWidth: 420, minHeight: 320)
                .background(Color.black)

            controls
                .frame(width: 280)
                .padding(18)
        }
        .frame(minWidth: 760, minHeight: 460)
        .task { await rebuild() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Polish").font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("Background").font(.headline)
                Picker("", selection: $presetIndex) {
                    ForEach(presets.indices, id: \.self) { Text(presets[$0].0).tag($0) }
                }
                .labelsHidden()
                .onChange(of: presetIndex) {
                    style.background = presets[presetIndex].1
                    Task { await rebuild() }
                }
            }

            slider("Padding", value: $style.paddingFraction, range: 0...0.16)
            slider("Corner radius", value: $style.cornerRadiusFraction, range: 0...0.06)
            slider("Shadow", value: $style.shadowOpacity, range: 0...0.7)

            Toggle("Auto-zoom (follow cursor)", isOn: $autoZoom)
                .disabled(cursorTrack == nil)
                .onChange(of: autoZoom) { updateZoom(); Task { await rebuild() } }
            if cursorTrack == nil {
                Text("No cursor data for this clip (record in Reclip to enable auto-zoom).")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            if duration > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trim  \(timeLabel(trimStart)) – \(timeLabel(trimEnd))").font(.headline)
                    Slider(value: $trimStart, in: 0...max(trimEnd - 0.2, 0.2))
                    Slider(value: $trimEnd, in: min(trimStart + 0.2, duration)...duration)
                }
            }

            Toggle("Webcam bubble", isOn: $webcam.enabled)
                .disabled(webcamFrames.isEmpty)
                .onChange(of: webcam.enabled) { Task { await rebuild() } }
            if !webcamFrames.isEmpty && webcam.enabled {
                Picker("Position", selection: $webcam.corner) {
                    ForEach(WebcamSettings.Corner.allCases) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: webcam.corner) { Task { await rebuild() } }
                slider("Webcam size", value: $webcam.sizeFraction, range: 0.12...0.35)
            } else if webcamFrames.isEmpty {
                Text("No webcam footage for this clip.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Divider()

            Button {
                Task { await export() }
            } label: {
                Label(isExporting ? "Exporting…" : "Export styled MP4", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.pink)
            .disabled(isExporting)

            Button {
                Task { await export(asGif: true) }
            } label: {
                Label("Export GIF", systemImage: "photo.stack")
                    .frame(maxWidth: .infinity)
            }
            .disabled(isExporting)

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let exportedURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([exportedURL])
                } label: { Label("Reveal in Finder", systemImage: "folder") }
                .buttonStyle(.link)
            }

            Spacer()
            Button("Close", action: onClose)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Slider(value: value, in: range) { editing in
                if !editing { Task { await rebuild() } }
            }
        }
    }

    // MARK: - Composition

    private func updateZoom() {
        guard autoZoom, let track = cursorTrack, duration > 0 else {
            zoom = ZoomTimeline()
            return
        }
        zoom = ZoomTimeline.autoZoom(from: track, duration: duration)
    }

    private func rebuild() async {
        let asset = AVURLAsset(url: sourceURL)
        do {
            if cursorTrack == nil { cursorTrack = CursorTrack.load(besides: sourceURL) }
            if !webcamLoaded {
                webcamFrames = await WebcamOverlay.load(for: sourceURL)
                webcamLoaded = true
            }
            if duration == 0 {
                duration = (try? await asset.load(.duration))?.seconds ?? 0
                if trimEnd == 0 { trimEnd = duration }
            }
            updateZoom()
            let composition = try await StyledExport.makeComposition(
                for: asset, style: style, zoom: zoom, webcam: webcamFrames, webcamSettings: webcam)
            let item = AVPlayerItem(asset: asset)
            item.videoComposition = composition
            playerItem = item
            player.replaceCurrentItem(with: item)
            _ = await player.seek(to: .zero)
            player.play()
            status = ""
        } catch {
            status = "Preview error: \(error.localizedDescription)"
        }
    }

    private func timeLabel(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func export(asGif: Bool = false) async {
        isExporting = true
        status = asGif ? "Rendering GIF…" : "Rendering MP4…"
        let out = sourceURL.deletingPathExtension()
            .appendingPathExtension(asGif ? "styled.gif" : "styled.mp4")
        var trim: CMTimeRange? = nil
        if duration > 0, (trimStart > 0.05 || trimEnd < duration - 0.05) {
            trim = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                               duration: CMTime(seconds: trimEnd - trimStart, preferredTimescale: 600))
        }
        do {
            if asGif {
                try await GifExport.export(source: sourceURL, to: out, style: style, zoom: zoom,
                                           trim: trim, webcam: webcamFrames, webcamSettings: webcam)
            } else {
                try await StyledExport.export(source: sourceURL, to: out, style: style, zoom: zoom,
                                              trim: trim, webcam: webcamFrames, webcamSettings: webcam)
            }
            exportedURL = out
            status = "Saved \(out.lastPathComponent)"
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
        isExporting = false
    }
}
