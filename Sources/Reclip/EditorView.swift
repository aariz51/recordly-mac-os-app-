import SwiftUI
import AVKit
import AVFoundation
import Combine

struct EditorView: View {
    let sourceURL: URL
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

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
    @State private var annotations: [Annotation] = []
    @State private var newCaption = ""
    @State private var speed: Double = 1.0
    @State private var player = AVPlayer()
    @State private var isExporting = false
    @State private var exportProgress: Double?
    @State private var status: Status?
    @State private var exportedURL: URL?
    @State private var playhead: Double = 0
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var didLoad = false
    @State private var appeared = false
    /// Space is the scrub key everywhere else in video; it must still type a
    /// space when the caption field has focus.
    @FocusState private var captionFocused: Bool
    /// Aspect of the rendered composition, so the preview card hugs the video
    /// instead of framing it in black letterbox bars.
    @State private var previewAspect: CGFloat = 16.0 / 9.0

    struct Status: Equatable {
        let kind: FeedbackKind
        let message: String
        init(_ kind: FeedbackKind, _ message: String) { self.kind = kind; self.message = message }
    }

    private let presets: [(String, StyleOptions.Background)] = [
        ("Indigo", .gradient(topRGB: (0.39, 0.36, 1.0), bottomRGB: (0.66, 0.33, 0.97))),
        ("Sunset", .gradient(topRGB: (1.0, 0.42, 0.42), bottomRGB: (0.99, 0.79, 0.34))),
        ("Ocean", .gradient(topRGB: (0.15, 0.55, 0.95), bottomRGB: (0.10, 0.20, 0.45))),
        ("Charcoal", .solid(red: 0.11, green: 0.12, blue: 0.14)),
        ("White", .solid(red: 0.96, green: 0.96, blue: 0.97))
    ]
    @State private var presetIndex = 0

    var body: some View {
        HStack(spacing: 0) {
            stage
            inspector
                .frame(width: 320)
        }
        .frame(minWidth: 940, idealWidth: 1060, minHeight: 620, idealHeight: 680)
        .background {
            // Space plays and pauses, as it does in every other video tool.
            // Disabled while the caption field is focused so typing still works.
            Button("Play or pause preview") { togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(captionFocused)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task { await firstLoad() }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            player.pause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            // A polish preview is watched over and over; loop it instead of
            // leaving a frozen last frame.
            Task { @MainActor in
                await player.seek(to: .zero)
                player.play()
            }
        }
    }

    // MARK: - Stage

    private var stage: some View {
        ZStack {
            Palette.stage.ignoresSafeArea()

            PlayerStage(player: player)
                .aspectRatio(previewAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.stage, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .padding(Space.xxl)

            if !didLoad {
                VStack(spacing: Space.m) {
                    ProgressView().controlSize(.small)
                    Text("Building preview…")
                        .captionType()
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Top-trailing, because the window's traffic lights sit over the
        // top-leading corner of the stage.
        .overlay(alignment: .topTrailing) {
            // Was a decorative "Live preview" badge. It sat in the one spot the
            // eye already goes and did nothing — so it became the transport:
            // it now says whether the preview is running and clicking it stops it.
            Button(action: togglePlayback) {
                HStack(spacing: 6) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                    Text(isPlaying ? "Playing" : "Paused")
                        .contentTransition(.opacity)
                }
                .captionType()
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .help("Play or pause the preview (Space)")
            .padding(Space.l)
            .animation(Motion.hover, value: isPlaying)
        }
        .animation(Motion.enter(reduce), value: didLoad)
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            inspectorHeader

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    backgroundSection.stagger(0, appeared: appeared, reduce: reduce)
                    frameSection.stagger(1, appeared: appeared, reduce: reduce)
                    motionSection.stagger(2, appeared: appeared, reduce: reduce)
                    if duration > 0 {
                        timingSection.stagger(3, appeared: appeared, reduce: reduce)
                    }
                    webcamSection.stagger(4, appeared: appeared, reduce: reduce)
                    captionSection.stagger(5, appeared: appeared, reduce: reduce)
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.l)
                .padding(.bottom, Space.xl)
            }
            // Content passes under the header and the export bar, so both edges
            // get a soft fade rather than a hard rule.
            .scrollEdge(.top, color: Color(nsColor: .windowBackgroundColor), height: 14)
            .scrollEdge(.bottom, color: Color(nsColor: .windowBackgroundColor).opacity(0.9), height: 16)

            exportBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1)
        }
    }

    private var inspectorHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Polish").displayType()
                Text(sourceURL.lastPathComponent)
                    .captionType()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.s)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
            .keyboardShortcut("w", modifiers: .command)
            .help("Close editor (⌘W)")
            .accessibilityLabel("Close editor")
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.l)
        .padding(.bottom, Space.m)
    }

    // MARK: - Sections

    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Background")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s), count: 3),
                      spacing: Space.s) {
                ForEach(presets.indices, id: \.self) { i in
                    BackgroundSwatch(name: presets[i].0,
                                     background: presets[i].1,
                                     isSelected: presetIndex == i) {
                        presetIndex = i
                        style.background = presets[i].1
                        Task { await rebuild() }
                    }
                }
            }
        }
    }

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Frame")

            ValueSlider(title: "Padding", value: $style.paddingFraction, range: 0...0.16,
                        format: { String(format: "%.0f%%", $0 * 100) },
                        onCommit: { Task { await rebuild() } })

            ValueSlider(title: "Corner radius", value: $style.cornerRadiusFraction, range: 0...0.06,
                        format: { String(format: "%.1f%%", $0 * 100) },
                        onCommit: { Task { await rebuild() } })

            ValueSlider(title: "Shadow", value: $style.shadowOpacity, range: 0...0.7,
                        format: { String(format: "%.0f%%", $0 / 0.7 * 100) },
                        onCommit: { Task { await rebuild() } })
        }
    }

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Motion")
            ToggleRow(title: "Auto-zoom",
                      subtitle: cursorTrack == nil
                          ? "Needs cursor data — record in Reclip to enable."
                          : "Eases into wherever the cursor is working.",
                      isOn: $autoZoom,
                      enabled: cursorTrack != nil,
                      emphasis: .control) {
                updateZoom()
                Task { await rebuild() }
            }
        }
    }

    private var timingSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader(title: "Trim",
                              trailing: "\(timeLabel(trimStart)) – \(timeLabel(trimEnd))")
                TrimBar(duration: duration,
                        start: $trimStart,
                        end: $trimEnd,
                        playhead: playhead,
                        onScrub: { scrub(toSourceTime: $0) }) {
                    Task { await rebuild() }
                }
                Text("\(timeLabel(trimEnd - trimStart)) kept of \(timeLabel(duration))")
                    .captionType()
                    .foregroundStyle(.secondary)
            }

            SpeedControl(speed: $speed) { Task { await rebuild() } }
        }
    }

    private var webcamSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Webcam")
            ToggleRow(title: "Webcam bubble",
                      subtitle: webcamFrames.isEmpty ? "No webcam footage for this clip." : nil,
                      isOn: $webcam.enabled,
                      enabled: !webcamFrames.isEmpty,
                      emphasis: .control) {
                Task { await rebuild() }
            }

            if !webcamFrames.isEmpty && webcam.enabled {
                VStack(alignment: .leading, spacing: Space.m) {
                    HStack(alignment: .center, spacing: Space.m) {
                        CornerPicker(corner: $webcam.corner) { Task { await rebuild() } }
                        Text(webcam.corner.rawValue)
                            .captionType()
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }

                    ValueSlider(title: "Size", value: $webcam.sizeFraction, range: 0.12...0.35,
                                format: { String(format: "%.0f%%", $0 * 100) },
                                onCommit: { Task { await rebuild() } })
                }
                .transition(.rise(reduce, distance: 6))
            }
        }
        .animation(Motion.move(reduce), value: webcam.enabled)
    }

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Captions",
                          trailing: annotations.isEmpty ? nil : "\(annotations.count)")

            HStack(spacing: Space.s) {
                TextField("Caption at \(timeLabel(playhead))", text: $newCaption)
                    .textFieldStyle(.roundedBorder)
                    .focused($captionFocused)
                    .onSubmit(addCaption)
                Button("Add", action: addCaption)
                    .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                    .disabled(newCaption.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            VStack(spacing: Space.xs) {
                ForEach(annotations) { a in
                    HStack(spacing: Space.s) {
                        Text(timeLabel(a.start))
                            .captionType()
                            .monospacedDigit()
                            .foregroundStyle(Palette.accent)
                        Text(a.text)
                            .captionType()
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            withAnimation(Motion.enter(reduce)) {
                                annotations.removeAll { $0.id == a.id }
                            }
                            Task { await rebuild() }
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                        .help("Delete this caption")
                        .accessibilityLabel("Delete caption \(a.text)")
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, Space.s)
                    .background(Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    .transition(.row(reduce))
                }
            }
        }
    }

    // MARK: - Export bar

    private var exportBar: some View {
        VStack(spacing: Space.s) {
            if let status {
                FeedbackLine(kind: status.kind, message: status.message)
                    .transition(.rise(reduce, distance: 4))
            }

            Button { Task { await export() } } label: {
                if isExporting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text(exportProgress.map { "Rendering \(Int($0 * 100))%" } ?? "Rendering…")
                            .contentTransition(.numericText())
                            .monospacedDigit()
                    }
                } else {
                    Label("Export MP4", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(ActionButtonStyle(variant: .prominent))
            .disabled(isExporting)
            .keyboardShortcut("e", modifiers: .command)

            if isExporting {
                ProgressTrack(fraction: exportProgress)
                    .transition(.opacity)
            }

            HStack(spacing: Space.s) {
                Button { Task { await export(asGif: true) } } label: {
                    Label("GIF", systemImage: "photo.stack")
                }
                .buttonStyle(ActionButtonStyle(variant: .secondary))
                .disabled(isExporting)

                if let exportedURL {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .buttonStyle(ActionButtonStyle(variant: .secondary))
                    .transition(.rise(reduce, distance: 4))
                }
            }
        }
        .padding(Space.l)
        .background(.regularMaterial)
        .animation(Motion.enter(reduce), value: isExporting)
        .animation(Motion.enter(reduce), value: status)
        .animation(Motion.enter(reduce), value: exportedURL)
        .animation(Motion.progress, value: exportProgress)
    }

    // MARK: - Composition

    private func updateZoom() {
        guard autoZoom, let track = cursorTrack, duration > 0 else {
            zoom = ZoomTimeline()
            return
        }
        zoom = ZoomTimeline.autoZoom(from: track, duration: duration)
    }

    private func firstLoad() async {
        cursorTrack = CursorTrack.load(besides: sourceURL)
        if !webcamLoaded {
            webcamFrames = await WebcamOverlay.load(for: sourceURL)
            webcamLoaded = true
        }
        if duration == 0 {
            let asset = AVURLAsset(url: sourceURL)
            duration = (try? await asset.load(.duration))?.seconds ?? 0
            if trimEnd == 0 { trimEnd = duration }
        }
        observePlayhead()
        await rebuild()
        didLoad = true
        withAnimation(Motion.enter(reduce)) { appeared = true }
    }

    private func togglePlayback() {
        if player.rate > 0 { player.pause() } else { player.play() }
        isPlaying = player.rate > 0
    }

    /// Drives the preview from a trim handle while it is being dragged. Seeking
    /// is cheap; rebuilding the composition is not — so the frame follows the
    /// grip continuously and the render waits for the release.
    private func scrub(toSourceTime source: Double) {
        player.pause()
        isPlaying = false
        // The composition starts at the trim-in point, so source time has to be
        // mapped back into the output timeline the player is actually running.
        let out = max(source - trimStart, 0) / max(speed, 0.01)
        Task { @MainActor in
            await player.seek(to: CMTime(seconds: out, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Playback position, mapped back into source time so the trim bar's
    /// playhead stays truthful under trim and speed changes.
    private func observePlayhead() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
            queue: .main
        ) { time in
            let out = time.seconds
            guard out.isFinite else { return }
            playhead = trimStart + out * speed
            let running = player.rate > 0
            if running != isPlaying { isPlaying = running }
        }
    }

    private func rebuild() async {
        // Keep the viewer where they were: rebuilding the composition should not
        // throw playback back to the first frame every time a slider is nudged.
        let wasPlaying = player.rate > 0 || !didLoad
        let resumeAt = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0

        do {
            updateZoom()
            let tl = try await StyledExport.makeTimeline(
                source: sourceURL, style: style, zoom: zoom, webcam: webcamFrames, webcamSettings: webcam,
                annotations: annotations, trim: currentTrim(), speed: speed)
            let size = tl.video.renderSize
            if size.width > 0, size.height > 0 { previewAspect = size.width / size.height }
            let item = AVPlayerItem(asset: tl.asset)
            item.videoComposition = tl.video
            player.replaceCurrentItem(with: item)

            let target = min(max(resumeAt, 0), max(tl.duration - 0.05, 0))
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
            if status?.kind == .error { status = nil }
        } catch {
            status = Status(.error, "Preview error: \(error.localizedDescription)")
        }
    }

    /// Trim range in SOURCE time, or nil if the whole clip is used.
    private func currentTrim() -> CMTimeRange? {
        guard duration > 0, (trimStart > 0.05 || trimEnd < duration - 0.05) else { return nil }
        return CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                           duration: CMTime(seconds: trimEnd - trimStart, preferredTimescale: 600))
    }

    private func addCaption() {
        let text = newCaption.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // Player time is OUTPUT time; convert to SOURCE time so captions stay in sync with trim/speed.
        let outNow = player.currentTime().seconds
        let out = outNow.isFinite ? outNow : 0
        let srcStart = trimStart + out * speed
        withAnimation(Motion.enter(reduce)) {
            annotations.append(Annotation(text: text, start: srcStart, end: srcStart + 3))
        }
        newCaption = ""
        Task { await rebuild() }
    }

    private func timeLabel(_ t: Double) -> String {
        let s = Int(max(t, 0).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func export(asGif: Bool = false) async {
        isExporting = true
        exportProgress = nil
        exportedURL = nil
        status = Status(.status, asGif ? "Rendering GIF…" : "Rendering MP4…")
        let out = sourceURL.deletingPathExtension()
            .appendingPathExtension(asGif ? "styled.gif" : "styled.mp4")
        let trim = currentTrim()
        let report: @Sendable (Double) -> Void = { value in
            Task { @MainActor in exportProgress = value }
        }
        do {
            if asGif {
                try await GifExport.export(source: sourceURL, to: out, style: style, zoom: zoom,
                                           trim: trim, webcam: webcamFrames, webcamSettings: webcam,
                                           annotations: annotations, speed: speed, progress: report)
            } else {
                try await StyledExport.export(source: sourceURL, to: out, style: style, zoom: zoom,
                                              trim: trim, webcam: webcamFrames, webcamSettings: webcam,
                                              annotations: annotations, speed: speed, progress: report)
            }
            exportedURL = out
            status = Status(.success, "Saved \(out.lastPathComponent)")
        } catch {
            status = Status(.error, "Export failed: \(error.localizedDescription)")
        }
        isExporting = false
        exportProgress = nil
    }
}
