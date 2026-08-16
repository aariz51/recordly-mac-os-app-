import SwiftUI
import AVKit
import AVFoundation
import Combine

struct EditorView: View {
    let sourceURL: URL
    var onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    @StateObject private var model: EditorModel
    @State private var player = AVPlayer()
    @State private var isExporting = false
    @State private var exportProgress: Double?
    @State private var status: Status?
    @State private var exportedURL: URL?
    @State private var timeObserver: Any?
    @State private var didLoad = false
    @State private var appeared = false
    @State private var showShortcuts = false
    @State private var showShortcutConfig = false
    @State private var shortcutConfig: [ShortcutAction: ShortcutBinding] = ShortcutStore.load()
    @State private var sourceSize: CGSize = .zero
    @State private var audioTrackCount = 0
    /// Aspect of the rendered composition, so the preview card hugs the video
    /// instead of framing it in black letterbox bars.
    @State private var previewAspect: CGFloat = 16.0 / 9.0
    /// Rebuilds are expensive; a slider drag fires dozens of commits, so they coalesce.
    @State private var rebuildTask: Task<Void, Never>?

    init(sourceURL: URL, onClose: @escaping () -> Void) {
        self.sourceURL = sourceURL
        self.onClose = onClose
        _model = StateObject(wrappedValue: EditorModel(sourceURL: sourceURL))
    }

    struct Status: Equatable {
        let kind: FeedbackKind
        let message: String
        init(_ kind: FeedbackKind, _ message: String) { self.kind = kind; self.message = message }
    }

    var body: some View {
        HStack(spacing: 0) {
            stageColumn
            SectionRail(section: $model.section)
            inspector
                .frame(width: 320)
        }
        .frame(minWidth: 1140, idealWidth: 1300, minHeight: 720, idealHeight: 820)
        .background { shortcutHost }
        .task { await firstLoad() }
        .onDisappear {
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            rebuildTask?.cancel()
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
        .sheet(isPresented: $showShortcuts) {
            ShortcutsHelp(config: shortcutConfig,
                          onCustomize: {
                              showShortcuts = false
                              // The sheet has to finish dismissing before the next one opens.
                              Task { @MainActor in
                                  try? await Task.sleep(for: .milliseconds(220))
                                  showShortcutConfig = true
                              }
                          },
                          onClose: { showShortcuts = false })
        }
        .sheet(isPresented: $showShortcutConfig) {
            ShortcutsConfig(config: $shortcutConfig,
                            onSave: { updated in
                                shortcutConfig = updated
                                ShortcutStore.save(updated)
                            },
                            onClose: { showShortcutConfig = false })
        }
    }

    // MARK: - Keyboard
    //
    // Single-key actions live on invisible buttons rather than a key-event monitor, so they
    // inherit SwiftUI's focus rules — they stop firing while a text field has the keyboard,
    // which is exactly the behaviour a monitor would have to reimplement badly.

    private var shortcutHost: some View {
        let bound = Shortcuts.mergeWithDefaults(shortcutConfig)
        return Group {
            action(bound[.playPause], "Play or pause") { togglePlayback() }
            action(bound[.addZoom], "Add zoom") {
                _ = model.addZoom(at: model.playhead); commit()
            }
            action(bound[.addKeyframe], "Add speed region") {
                _ = model.addSpeedRegion(at: model.playhead); commit()
            }
            action(bound[.addAnnotation], "Add annotation") {
                model.addAnnotation(kind: .text, at: model.playhead); commit()
            }
            action(bound[.splitClip], "Split clip") {
                model.splitAtPlayhead(); commit()
            }
            action(bound[.deleteSelected], "Delete selected") { deleteSelection() }

            // Fixed bindings — deliberately not rebindable, and matched by `Shortcuts.fixed`
            // so the config sheet refuses to hand them out.
            hiddenButton("Delete selected (alt)", .delete, []) { deleteSelection() }
            hiddenButton("Cycle annotations", KeyEquivalent("\t"), []) {
                model.cycleAnnotation(forward: true)
            }
            hiddenButton("Undo", KeyEquivalent("z"), .command) {
                if model.undo() { scheduleRebuild() }
            }
            hiddenButton("Redo", KeyEquivalent("z"), [.command, .shift]) {
                if model.redo() { scheduleRebuild() }
            }
            hiddenButton("Shortcuts", KeyEquivalent("/"), .command) { showShortcuts = true }
        }
    }

    /// A hidden button carrying a user-configurable binding.
    @ViewBuilder
    private func action(_ binding: ShortcutBinding?, _ title: String,
                        perform: @escaping () -> Void) -> some View {
        if let binding, let ch = binding.key.first {
            hiddenButton(title, KeyEquivalent(ch), Self.modifiers(for: binding), action: perform)
        }
    }

    /// `ShortcutBinding.ctrl` means "the platform's primary modifier", which on macOS is ⌘.
    private static func modifiers(for binding: ShortcutBinding) -> EventModifiers {
        var m: EventModifiers = []
        if binding.ctrl { m.insert(.command) }
        if binding.shift { m.insert(.shift) }
        if binding.alt { m.insert(.option) }
        return m
    }

    private func hiddenButton(_ title: String, _ key: KeyEquivalent,
                              _ modifiers: EventModifiers,
                              action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private func deleteSelection() {
        if model.selectedAnnotationID != nil { model.deleteSelectedAnnotation() }
        else if model.selectedZoomID != nil { model.deleteSelectedZoom() }
        else { return }
        commit()
    }

    // MARK: - Stage

    private var stageColumn: some View {
        VStack(spacing: 0) {
            stage
            timelineBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stage: some View {
        ZStack {
            Palette.stage.ignoresSafeArea()

            PlayerStage(player: player)
                .aspectRatio(previewAspect, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.stage, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                .padding(Space.xl)

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
        .overlay(alignment: .topTrailing) { transportPill }
        .overlay(alignment: .bottomLeading) { historyControls }
        .animation(Motion.enter(reduce), value: didLoad)
    }

    // Top-trailing, because the window's traffic lights sit over the
    // top-leading corner of the stage.
    private var transportPill: some View {
        // Was a decorative "Live preview" badge. It sat in the one spot the
        // eye already goes and did nothing — so it became the transport:
        // it now says whether the preview is running and clicking it stops it.
        //
        // Nothing here animates on `isPlaying`, deliberately. This label had
        // a symbol-replace and a crossfade on it, which is the single worst
        // place in the app to spend motion: Space toggles playback, the
        // preview loops, and trimming a clip means hitting it over and over
        // for as long as the session lasts. Motion on an action repeated
        // that often stops reading as polish and starts reading as lag
        // between the key and the machine. The press scale stays — that
        // fires on a click, and press feedback is never the thing to cut.
        HStack(spacing: Space.xs) {
            Button { skip(by: -5) } label: {
                Image(systemName: "gobackward.5").frame(width: 14)
            }
            .buttonStyle(PressableStyle())
            .help("Back five seconds")

            Button(action: togglePlayback) {
                HStack(spacing: 6) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 9)
                    Text(model.isPlaying ? "Playing" : "Paused")
                        .fixedSize()
                        .frame(width: 46, alignment: .leading)
                }
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .help("Play or pause the preview (Space)")

            Button { skip(by: 5) } label: {
                Image(systemName: "goforward.5").frame(width: 14)
            }
            .buttonStyle(PressableStyle())
            .help("Forward five seconds")
        }
        .captionType()
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .chrome(Capsule(), material: .ultraThinMaterial,
                solid: Color(red: 0.11, green: 0.11, blue: 0.12))
        .padding(Space.l)
    }

    private var historyControls: some View {
        HStack(spacing: Space.xs) {
            Button { if model.undo() { scheduleRebuild() } } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 14)
            }
            .buttonStyle(PressableStyle())
            .disabled(!model.canUndo)
            .opacity(model.canUndo ? 1 : 0.35)
            .help("Undo (⌘Z)")

            Button { if model.redo() { scheduleRebuild() } } label: {
                Image(systemName: "arrow.uturn.forward").frame(width: 14)
            }
            .buttonStyle(PressableStyle())
            .disabled(!model.canRedo)
            .opacity(model.canRedo ? 1 : 0.35)
            .help("Redo (⇧⌘Z)")
        }
        .captionType()
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .chrome(Capsule(), material: .ultraThinMaterial,
                solid: Color(red: 0.11, green: 0.11, blue: 0.12))
        .padding(Space.l)
    }

    private var timelineBar: some View {
        TimelineView(model: model, commit: commit, scrub: { scrub(toSourceTime: $0) })
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
            }
    }

    // MARK: - Inspector

    private var inspector: some View {
        VStack(spacing: 0) {
            inspectorHeader

            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    sectionBody
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.l)
                .padding(.bottom, Space.xl)
                .stagger(0, appeared: appeared, reduce: reduce)
                // A fresh identity per section means the scroll position resets when the
                // section changes, instead of landing mid-way down unrelated content.
                .id(model.section)
            }
            // Content passes under the header and the export bar, so both edges
            // get a soft fade rather than a hard rule.
            .scrollEdge(.top, color: Color(nsColor: .windowBackgroundColor), height: 14)
            .scrollEdge(.bottom, color: Color(nsColor: .windowBackgroundColor).opacity(0.9), height: 16)

            exportBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch model.section {
        case .scene:       SceneSection(model: model, commit: commit)
        case .clip:        ClipSection(model: model, commit: commit)
        case .zoom:        ZoomSection(model: model, commit: commit)
        case .cursor:      CursorSection(model: model, commit: commit)
        case .webcam:      WebcamSection(model: model, commit: commit)
        case .captions:    CaptionsSection(model: model, commit: commit, report: report)
        case .annotations: AnnotationsSection(model: model, commit: commit)
        case .audio:       AudioSection(model: model, commit: commit, audioTrackCount: audioTrackCount)
        case .export:      ExportSection(model: model, commit: commit, report: report, sourceSize: sourceSize)
        }
    }

    private var inspectorHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(model.section.title).displayType()
                    if model.isDirty {
                        Circle()
                            .fill(Palette.warning)
                            .frame(width: 6, height: 6)
                            .help("Unsaved changes")
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                Text(sourceURL.lastPathComponent)
                    .captionType()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Space.s)

            Button { showShortcuts = true } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
            .help("Keyboard shortcuts (⌘/)")
            .accessibilityLabel("Keyboard shortcuts")

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
                    Label("Export \(model.format.rawValue)", systemImage: model.format.symbol)
                }
            }
            .buttonStyle(ActionButtonStyle(variant: .prominent))
            .disabled(isExporting)
            .keyboardShortcut("e", modifiers: .command)

            if isExporting {
                ProgressTrack(fraction: exportProgress)
                    .transition(.opacity)
            }

            if let exportedURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([exportedURL]) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(ActionButtonStyle(variant: .secondary))
                .transition(.rise(reduce, distance: 4))
            }
        }
        .padding(Space.l)
        .chrome(Rectangle(), solid: Color(nsColor: .windowBackgroundColor))
        .animation(Motion.enter(reduce), value: isExporting)
        .animation(Motion.enter(reduce), value: status)
        .animation(Motion.enter(reduce), value: exportedURL)
        .animation(Motion.progress, value: exportProgress)
    }

    // MARK: - Lifecycle

    private func report(_ kind: FeedbackKind, _ message: String) {
        status = Status(kind, message)
    }

    private func firstLoad() async {
        model.cursorTrack = CursorTrack.load(besides: sourceURL)
        model.webcamFrames = await WebcamOverlay.load(for: sourceURL)

        let asset = AVURLAsset(url: sourceURL)
        model.duration = (try? await asset.load(.duration))?.seconds ?? 0
        if model.trimEnd == 0 { model.trimEnd = model.duration }
        audioTrackCount = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
        if let v = try? await asset.loadTracks(withMediaType: .video).first,
           let natural = try? await v.load(.naturalSize),
           let transform = try? await v.load(.preferredTransform) {
            let r = natural.applying(transform)
            sourceSize = CGSize(width: abs(r.width), height: abs(r.height))
        }

        // Reopening a clip that was edited before should land back on that edit.
        if model.hasProjectOnDisk {
            try? model.loadProject()
            // The project may point at footage other than the clip's own sidecar.
            if model.webcam.sourcePath != nil { await model.reloadWebcamFrames() }
        }
        model.beginHistory()

        observePlayhead()
        await rebuild()
        didLoad = true
        withAnimation(Motion.enter(reduce)) { appeared = true }
    }

    private func togglePlayback() {
        if player.rate > 0 { player.pause() } else { player.play() }
        model.isPlaying = player.rate > 0
    }

    private func skip(by seconds: Double) {
        let target = player.currentTime().seconds + seconds
        Task { @MainActor in
            await player.seek(to: CMTime(seconds: max(0, target), preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Drives the preview from a timeline scrub. Seeking is cheap; rebuilding the
    /// composition is not — so the frame follows the pointer continuously and the render
    /// waits for the release.
    private func scrub(toSourceTime source: Double) {
        player.pause()
        model.isPlaying = false
        model.playhead = source
        // The composition starts at the trim-in point, so source time has to be
        // mapped back into the output timeline the player is actually running.
        let out = max(source - model.trimStart, 0) / max(model.speed, 0.01)
        Task { @MainActor in
            await player.seek(to: CMTime(seconds: out, preferredTimescale: 600),
                              toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    /// Playback position, mapped back into source time so the timeline's
    /// playhead stays truthful under trim and speed changes.
    private func observePlayhead() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.08, preferredTimescale: 600),
            queue: .main
        ) { time in
            let out = time.seconds
            guard out.isFinite else { return }
            model.playhead = model.trimStart + out * model.speed
            let running = player.rate > 0
            if running != model.isPlaying { model.isPlaying = running }
        }
    }

    /// Records the edit for undo, then rebuilds the preview.
    private func commit() {
        model.record()
        scheduleRebuild()
    }

    /// Coalesces rebuild requests: a slider drag commits on release, but colour wells and
    /// steppers can fire in bursts, and each rebuild reconstructs the whole composition.
    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }
            await rebuild()
        }
    }

    private func rebuild() async {
        // Keep the viewer where they were: rebuilding the composition should not
        // throw playback back to the first frame every time a slider is nudged.
        let wasPlaying = player.rate > 0 || !didLoad
        let resumeAt = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0

        do {
            let tl = try await StyledExport.makeTimeline(
                source: sourceURL, style: model.style, zoom: model.zoom,
                webcam: model.webcamFrames, webcamSettings: model.webcam,
                annotations: model.annotations, trim: model.trimRange(), speed: model.speed,
                speedRegions: model.speedRegions,
                cursor: model.cursorTrack, cursorStyle: model.cursorStyle,
                captions: model.captionCues, captionSettings: model.captionSettings)
            let size = tl.video.renderSize
            if size.width > 0, size.height > 0 { previewAspect = size.width / size.height }
            let item = AVPlayerItem(asset: tl.asset)
            item.videoComposition = tl.video
            item.audioMix = tl.audioMix
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

    // MARK: - Export

    private func export() async {
        isExporting = true
        exportProgress = nil
        exportedURL = nil
        let isGif = model.format == .gif
        status = Status(.status, isGif ? "Rendering GIF…" : "Rendering MP4…")
        let out = sourceURL.deletingPathExtension()
            .appendingPathExtension(isGif ? "styled.gif" : "styled.mp4")
        let trim = model.trimRange()
        let report: @Sendable (Double) -> Void = { value in
            Task { @MainActor in exportProgress = value }
        }
        do {
            if isGif {
                try await GifExport.export(source: sourceURL, to: out, style: model.style,
                                           zoom: model.zoom, trim: trim,
                                           webcam: model.webcamFrames, webcamSettings: model.webcam,
                                           annotations: model.annotations, speed: model.speed,
                                           fps: model.gifFPS, maxWidth: model.gifSize.maxWidth,
                                           loop: model.gifLoop, bounce: model.gifBounce,
                                           progress: report)
            } else if model.motionBlurAmount > 0.01 || model.frameRate != .fps30 || model.encoding != .quality {
                // The re-encode path is the only one that can set frame rate, bitrate and
                // motion blur, so it is used whenever any of those is not at its default.
                try await StyledExport.exportReencoded(
                    source: sourceURL, to: out, style: model.style, zoom: model.zoom, trim: trim,
                    webcam: model.webcamFrames, webcamSettings: model.webcam,
                    annotations: model.annotations, speed: model.speed,
                    quality: model.quality, encoding: model.encoding, frameRate: model.frameRate,
                    motionBlur: model.motionBlurAmount,
                    cursor: model.cursorTrack, cursorStyle: model.cursorStyle,
                    captions: model.captionCues, captionSettings: model.captionSettings,
                    progress: report)
            } else {
                try await StyledExport.export(source: sourceURL, to: out, style: model.style,
                                              zoom: model.zoom, trim: trim,
                                              webcam: model.webcamFrames, webcamSettings: model.webcam,
                                              annotations: model.annotations, speed: model.speed,
                                              speedRegions: model.speedRegions,
                                              quality: model.quality,
                                              cursor: model.cursorTrack, cursorStyle: model.cursorStyle,
                                              captions: model.captionCues,
                                              captionSettings: model.captionSettings,
                                              progress: report)
            }
            if model.writeCaptionSidecars, !model.captionCues.isEmpty {
                writeSidecars(besides: out)
            }
            exportedURL = out
            status = Status(.success, "Saved \(out.lastPathComponent)")
        } catch {
            status = Status(.error, "Export failed: \(error.localizedDescription)")
        }
        isExporting = false
        exportProgress = nil
    }

    private func writeSidecars(besides output: URL) {
        let base = output.deletingPathExtension()
        try? CaptionExport.srt(model.captionCues)
            .write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        try? CaptionExport.vtt(model.captionCues)
            .write(to: base.appendingPathExtension("vtt"), atomically: true, encoding: .utf8)
    }
}
