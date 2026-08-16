import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Scene
//
// Background, framing, and the shape of the output. These are the settings that change
// what the composition *is*, so they lead.

struct SceneSection: View {
    @ObservedObject var model: EditorModel
    let commit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var presetID: String? = "aurora"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            backgroundGroup
            framingGroup
            outputGroup
            cropGroup
        }
    }

    private var backgroundGroup: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Background")

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s), count: 4),
                      spacing: Space.s) {
                ForEach(BackgroundPresets.all) { p in
                    BackgroundSwatch(name: p.name,
                                     background: p.background,
                                     isSelected: presetID == p.id && model.style.backgroundImage == nil) {
                        presetID = p.id
                        model.style.backgroundImage = nil
                        model.style.background = p.background
                        commit()
                    }
                }
            }

            HStack(spacing: Space.s) {
                Button {
                    chooseWallpaper()
                } label: {
                    Label("Image…", systemImage: "photo")
                }
                .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))

                if model.style.backgroundImage != nil {
                    Button {
                        model.style.backgroundImage = nil
                        commit()
                    } label: {
                        Label("Remove", systemImage: "xmark")
                    }
                    .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                    .transition(.rise(reduce, distance: 4))
                }
                Spacer(minLength: 0)
            }
            .animation(Motion.enter(reduce), value: model.style.backgroundImage != nil)

            ValueSlider(title: "Background blur", value: $model.style.backgroundBlur, range: 0...1,
                        format: { $0 < 0.01 ? "Off" : String(format: "%.0f%%", $0 * 100) },
                        onCommit: commit)
            Text("Blurs the footage itself into the backdrop, instead of using a colour.")
                .captionType()
                .foregroundStyle(.secondary)
        }
    }

    private var framingGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Frame")

            Toggle(isOn: Binding(get: { model.style.paddingInsets != nil },
                                 set: { on in
                                     model.style.paddingInsets = on
                                        ? StyleOptions.PaddingInsets(
                                            top: model.style.paddingFraction, bottom: model.style.paddingFraction,
                                            left: model.style.paddingFraction, right: model.style.paddingFraction)
                                        : nil
                                     commit()
                                 })) {
                Text("Independent padding").controlLabelType()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Palette.accent)

            if let insets = model.style.paddingInsets {
                // Per-side padding, for footage that shouldn't sit dead centre.
                let bind = { (key: WritableKeyPath<StyleOptions.PaddingInsets, Double>) in
                    Binding<Double>(get: { model.style.paddingInsets?[keyPath: key] ?? 0 },
                                    set: { model.style.paddingInsets?[keyPath: key] = $0 })
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    ValueSlider(title: "Top", value: bind(\.top), range: 0...0.3,
                                format: pct, onCommit: commit)
                    ValueSlider(title: "Bottom", value: bind(\.bottom), range: 0...0.3,
                                format: pct, onCommit: commit)
                    ValueSlider(title: "Left", value: bind(\.left), range: 0...0.3,
                                format: pct, onCommit: commit)
                    ValueSlider(title: "Right", value: bind(\.right), range: 0...0.3,
                                format: pct, onCommit: commit)
                }
                .transition(.rise(reduce, distance: 6))
                .onAppear { _ = insets }
            } else {
                ValueSlider(title: "Padding", value: $model.style.paddingFraction, range: 0...0.16,
                            format: pct, onCommit: commit)
            }

            ValueSlider(title: "Corner radius", value: $model.style.cornerRadiusFraction, range: 0...0.06,
                        format: { String(format: "%.1f%%", $0 * 100) }, onCommit: commit)

            Toggle(isOn: Binding(get: { model.style.squircleCorners },
                                 set: { model.style.squircleCorners = $0; commit() })) {
                Text("Continuous corners").controlLabelType()
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Palette.accent)

            ValueSlider(title: "Shadow", value: $model.style.shadowOpacity, range: 0...0.7,
                        format: { String(format: "%.0f%%", $0 / 0.7 * 100) }, onCommit: commit)
            ValueSlider(title: "Shadow spread", value: $model.style.shadowRadius, range: 4...80,
                        format: { String(format: "%.0f", $0) }, onCommit: commit)

            MenuRow(title: "Device frame", selection: $model.style.deviceFrame,
                    options: DeviceFrame.allCases, label: \.rawValue, onCommit: commit)
        }
        .animation(Motion.move(reduce), value: model.style.paddingInsets != nil)
    }

    private var outputGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Output")
            MenuRow(title: "Aspect ratio", selection: $model.style.aspect,
                    options: StyleOptions.Aspect.allCases, label: \.rawValue, onCommit: commit)
            MenuRow(title: "Max height",
                    selection: Binding(get: { HeightCap(model.style.maxOutputHeight) },
                                       set: { model.style.maxOutputHeight = $0.value }),
                    options: HeightCap.allCases, label: \.label, onCommit: commit)
        }
    }

    private var cropGroup: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Crop",
                          trailing: model.style.crop.hasCrop ? "Trimmed" : nil)
            CropPad(crop: $model.style.crop, onCommit: commit)
            HStack {
                Text("Drag an edge to trim the recorded frame.")
                    .captionType()
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.s)
                Button("Reset") {
                    model.style.crop = .zero
                    commit()
                }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                .disabled(!model.style.crop.hasCrop)
            }
        }
    }

    private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    private func chooseWallpaper() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        model.style.backgroundImage = data
        commit()
    }

    /// Output-height cap as a pickable value (the engine stores an optional Int).
    enum HeightCap: String, CaseIterable, Identifiable {
        case source, h1080, h720, h480
        init(_ v: Int?) {
            switch v {
            case 1080: self = .h1080
            case 720: self = .h720
            case 480: self = .h480
            default: self = .source
            }
        }
        var id: String { rawValue }
        var value: Int? {
            switch self {
            case .source: return nil
            case .h1080: return 1080
            case .h720: return 720
            case .h480: return 480
            }
        }
        var label: String {
            switch self {
            case .source: return "Source"
            case .h1080: return "1080p"
            case .h720: return "720p"
            case .h480: return "480p"
            }
        }
    }
}

// MARK: - Zoom

struct ZoomSection: View {
    @ObservedObject var model: EditorModel
    let commit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            regionsGroup
            if model.selectedZoom != nil { selectedGroup }
            motionGroup
        }
        .animation(Motion.move(reduce), value: model.selectedZoomID)
    }

    private var regionsGroup: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Zoom regions",
                          trailing: model.zoom.regions.isEmpty ? nil : "\(model.zoom.regions.count)")

            HStack(spacing: Space.s) {
                Button {
                    _ = model.addZoom(at: model.playhead)
                    commit()
                } label: {
                    Label("Add at playhead", systemImage: "plus")
                }
                .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                .keyboardShortcut("z", modifiers: [])

                Button {
                    suggestFromCursor()
                } label: {
                    Label("Suggest", systemImage: "wand.and.stars")
                }
                .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                .disabled(model.cursorTrack == nil)
                .help(model.cursorTrack == nil
                      ? "Needs cursor data — record in Reclip to enable."
                      : "Builds zoom regions from where the cursor dwelled.")
                Spacer(minLength: 0)
            }

            if model.zoom.regions.isEmpty {
                EmptyHint(symbol: "plus.magnifyingglass",
                          message: "No zooms yet. Add one at the playhead, or let Reclip suggest them from the recorded cursor path.")
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(model.zoom.regions.sorted { $0.start < $1.start }) { r in
                        RegionRow(title: "\(TrimBar.timeLabel(r.start)) – \(TrimBar.timeLabel(r.end))",
                                  detail: String(format: "%.2g×", r.scale),
                                  isSelected: model.selectedZoomID == r.id,
                                  select: { model.selectedZoomID = r.id },
                                  delete: {
                                      model.zoom.regions.removeAll { $0.id == r.id }
                                      if model.selectedZoomID == r.id { model.selectedZoomID = nil }
                                      commit()
                                  })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedGroup: some View {
        if let region = model.selectedZoom {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader(title: "Selected zoom")

                MenuRow(title: "Depth",
                        selection: Binding(
                            get: { ZoomDepth.allCases.min {
                                abs($0.scale - region.scale) < abs($1.scale - region.scale) } ?? .strong },
                            set: { d in model.updateSelectedZoom { $0.scale = d.scale } }),
                        options: ZoomDepth.allCases, label: \.rawValue, onCommit: commit)

                VStack(alignment: .leading, spacing: Space.xs) {
                    ControlLabel(title: "Focus")
                    FocusPad(focus: Binding(get: { region.focus },
                                            set: { p in model.updateSelectedZoom { $0.focus = p } }),
                             onCommit: commit)
                }

                Button(role: .destructive) {
                    model.deleteSelectedZoom()
                    commit()
                } label: {
                    Label("Delete zoom", systemImage: "trash")
                }
                .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
            }
            .transition(.rise(reduce, distance: 6))
        }
    }

    private var motionGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Motion")

            HStack(spacing: Space.s) {
                ForEach(ZoomMotionPreset.allCases) { p in
                    Button {
                        model.zoom.apply(preset: p)
                        commit()
                    } label: {
                        Text(p.label)
                    }
                    .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                    .help(p.summary)
                }
                Spacer(minLength: 0)
            }

            ValueSlider(title: "Zoom in", value: Binding(
                            get: { model.zoom.effectiveInDuration },
                            set: { model.zoom.inDuration = $0 }),
                        range: 0.1...3,
                        format: { String(format: "%.2fs", $0) }, onCommit: commit)
            MenuRow(title: "In curve",
                    selection: Binding(get: { model.zoom.effectiveInEasing },
                                       set: { model.zoom.inEasing = $0 }),
                    options: ZoomEasing.allCases, label: \.label, onCommit: commit)

            ValueSlider(title: "Zoom out", value: Binding(
                            get: { model.zoom.effectiveOutDuration },
                            set: { model.zoom.outDuration = $0 }),
                        range: 0.1...3,
                        format: { String(format: "%.2fs", $0) }, onCommit: commit)
            MenuRow(title: "Out curve",
                    selection: Binding(get: { model.zoom.effectiveOutEasing },
                                       set: { model.zoom.outEasing = $0 }),
                    options: ZoomEasing.allCases, label: \.label, onCommit: commit)

            ToggleRow(title: "Connect zooms",
                      subtitle: "Neighbouring zooms glide from one to the next instead of pulling out between them.",
                      isOn: $model.zoom.connectZooms, emphasis: .control, onChange: commit)

            if model.zoom.connectZooms {
                VStack(alignment: .leading, spacing: Space.m) {
                    ValueSlider(title: "Connect within", value: $model.zoom.connectedGap, range: 0.2...5,
                                format: { String(format: "%.1fs", $0) }, onCommit: commit)
                    ValueSlider(title: "Glide time", value: $model.zoom.connectedDuration, range: 0.2...3,
                                format: { String(format: "%.2fs", $0) }, onCommit: commit)
                    MenuRow(title: "Glide curve", selection: $model.zoom.connectedEasing,
                            options: ZoomEasing.allCases, label: \.label, onCommit: commit)
                }
                .transition(.rise(reduce, distance: 6))
            }
        }
        .animation(Motion.move(reduce), value: model.zoom.connectZooms)
    }

    private func suggestFromCursor() {
        guard let track = model.cursorTrack, model.duration > 0 else { return }
        var suggested = ZoomTimeline.autoZoom(from: track, duration: model.duration)
        // Keep everything the user placed by hand; only add where there is room.
        for r in suggested.regions {
            let span = TimelineModel.Span(start: r.start, end: r.end)
            let clash = model.zoom.regions.contains {
                TimelineModel.spansOverlap(span, TimelineModel.Span(start: $0.start, end: $0.end))
            }
            if !clash { model.zoom.regions.append(r) }
        }
        suggested.regions = []
        commit()
    }
}

/// A selectable row for a timeline region, with a delete affordance.
struct RegionRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let select: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            Button(action: select) {
                HStack(spacing: Space.s) {
                    Text(title)
                        .captionType()
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    Text(detail)
                        .captionType()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.99))

            Button(action: delete) {
                Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
            .accessibilityLabel("Delete \(title)")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, Space.s)
        .background(isSelected ? Palette.accent.opacity(0.15) : Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .strokeBorder(Palette.accent, lineWidth: isSelected ? 1 : 0))
    }
}

// MARK: - Cursor

struct CursorSection: View {
    @ObservedObject var model: EditorModel
    let commit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            if model.cursorTrack == nil {
                EmptyHint(symbol: "cursorarrow.slash",
                          message: "No cursor track for this clip. Record in Reclip to capture the cursor path, then these controls come alive.")
            }
            appearanceGroup
            motionGroup
            clickGroup
            spotlightGroup
        }
        .disabled(model.cursorTrack == nil)
        .opacity(model.cursorTrack == nil ? 0.5 : 1)
    }

    private var appearanceGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Cursor")
            ToggleRow(title: "Draw cursor",
                      subtitle: "Renders a clean pointer from the recorded path.",
                      isOn: $model.cursorStyle.enabled, emphasis: .control, onChange: commit)

            if model.cursorStyle.enabled {
                VStack(alignment: .leading, spacing: Space.m) {
                    SegmentedRow(title: "Style", selection: $model.cursorStyle.kind,
                                 options: CursorStyle.Kind.allCases,
                                 label: { $0.rawValue.capitalized }, onCommit: commit)
                    ValueSlider(title: "Size", value: $model.cursorStyle.size, range: 0.4...4,
                                format: { String(format: "%.1f×", $0) }, onCommit: commit)
                }
                .transition(.rise(reduce, distance: 6))
            }
        }
        .animation(Motion.move(reduce), value: model.cursorStyle.enabled)
    }

    @ViewBuilder
    private var motionGroup: some View {
        if model.cursorStyle.enabled {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader(title: "Motion")
                ValueSlider(title: "Smoothing", value: $model.cursorStyle.smoothing, range: 0...2,
                            format: { $0 < 0.02 ? "Off" : String(format: "%.2f", $0) }, onCommit: commit)
                Text("Runs the recorded path through a spring, so the pointer glides instead of stepping between samples.")
                    .captionType()
                    .foregroundStyle(.secondary)
                ValueSlider(title: "Sway", value: $model.cursorStyle.sway, range: 0...2,
                            format: { $0 < 0.02 ? "Off" : String(format: "%.2f", $0) }, onCommit: commit)
            }
        }
    }

    @ViewBuilder
    private var clickGroup: some View {
        if model.cursorStyle.enabled {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader(title: "Clicks")
                ToggleRow(title: "Show clicks", isOn: $model.cursorStyle.showClicks,
                          emphasis: .control, onChange: commit)

                if model.cursorStyle.showClicks {
                    VStack(alignment: .leading, spacing: Space.m) {
                        MenuRow(title: "Effect", selection: $model.cursorStyle.clickEffect,
                                options: CursorClickEffectStyle.allCases, label: \.label, onCommit: commit)
                        Text(model.cursorStyle.clickEffect.summary)
                            .captionType()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        ValueSlider(title: "Bounce", value: $model.cursorStyle.clickBounce, range: 0...5,
                                    format: { $0 < 0.02 ? "Off" : String(format: "%.1f", $0) }, onCommit: commit)

                        AdvancedGroup(title: "Advanced") {
                            ColorRow(title: "Effect colour",
                                     rgba: Binding(
                                        get: { model.cursorStyle.clickEffectRGB + [1] },
                                        set: { model.cursorStyle.clickEffectRGB = Array($0.prefix(3)) }),
                                     supportsOpacity: false, onCommit: commit)
                            ValueSlider(title: "Effect size", value: $model.cursorStyle.clickEffectScale,
                                        range: 0.3...3, format: { String(format: "%.1f×", $0) }, onCommit: commit)
                            ValueSlider(title: "Effect opacity", value: $model.cursorStyle.clickEffectOpacity,
                                        range: 0...1, format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
                            ValueSlider(title: "Effect duration", value: $model.cursorStyle.clickEffectDurationMs,
                                        range: 150...1500, format: { String(format: "%.0f ms", $0) }, onCommit: commit)
                            ValueSlider(title: "Bounce speed", value: $model.cursorStyle.clickBounceDuration,
                                        range: CursorClickEffect.minBounceDurationMs...CursorClickEffect.maxBounceDurationMs,
                                        format: { String(format: "%.0f ms", $0) }, onCommit: commit)
                        }
                    }
                    .transition(.rise(reduce, distance: 6))
                }
            }
            .animation(Motion.move(reduce), value: model.cursorStyle.showClicks)
        }
    }

    private var spotlightGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Spotlight")
            ToggleRow(title: "Dim around the cursor",
                      subtitle: "Darkens everything outside a soft circle at the pointer.",
                      isOn: $model.cursorStyle.spotlight, emphasis: .control, onChange: commit)
            if model.cursorStyle.spotlight {
                VStack(alignment: .leading, spacing: Space.m) {
                    ValueSlider(title: "Radius", value: $model.cursorStyle.spotlightRadius, range: 0.05...0.6,
                                format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
                    ValueSlider(title: "Dimming", value: $model.cursorStyle.spotlightDim, range: 0...1,
                                format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
                }
                .transition(.rise(reduce, distance: 6))
            }
        }
        .animation(Motion.move(reduce), value: model.cursorStyle.spotlight)
    }
}

// MARK: - Webcam

struct WebcamSection: View {
    @ObservedObject var model: EditorModel
    let commit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader(title: "Webcam")
                if model.webcamFrames.isEmpty {
                    EmptyHint(symbol: "person.crop.circle.badge.xmark",
                              message: "No webcam footage for this clip. Record with the webcam on, or attach a camera file below.")
                }
                footageRow
                ToggleRow(title: "Webcam bubble", isOn: $model.webcam.enabled,
                          enabled: !model.webcamFrames.isEmpty, emphasis: .control, onChange: commit)
            }

            if model.webcam.enabled && !model.webcamFrames.isEmpty {
                VStack(alignment: .leading, spacing: Space.xl) {
                    placementGroup
                    shapeGroup
                    frameGroup
                }
                .transition(.rise(reduce, distance: 6))
            }
        }
        .animation(Motion.move(reduce), value: model.webcam.enabled)
    }

    /// Attach / replace / detach the camera file. A clip recorded with the webcam on already
    /// has a sidecar; this is for pairing a clip with footage shot separately.
    private var footageRow: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ActionRow(title: "Footage",
                      subtitle: model.webcam.sourcePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                        ?? (model.webcamFrames.isEmpty ? "None attached." : "Using the clip's own recording."),
                      actionTitle: model.webcam.sourcePath == nil ? "Attach…" : "Replace…",
                      symbol: "video.badge.plus") { attachFootage() }

            if model.webcam.sourcePath != nil {
                Button {
                    model.webcam.sourcePath = nil
                    Task { await model.reloadWebcamFrames() }
                    commit()
                } label: { Label("Use the clip's own recording", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
            }
        }
    }

    private func attachFootage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.webcam.sourcePath = url.path
        Task {
            await model.reloadWebcamFrames()
            // Attaching footage is only useful if the bubble is actually shown.
            if !model.webcamFrames.isEmpty { model.webcam.enabled = true }
            commit()
        }
    }

    private var placementGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Placement", trailing: model.webcam.corner.rawValue)
            HStack(alignment: .center, spacing: Space.m) {
                PositionGrid(corner: $model.webcam.corner, onChange: commit)
                Spacer(minLength: 0)
            }
            ValueSlider(title: "Size", value: $model.webcam.sizeFraction, range: 0.08...0.5,
                        format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
            ValueSlider(title: "Margin", value: $model.webcam.marginFraction, range: 0...0.15,
                        format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
            ToggleRow(title: "React to zoom",
                      subtitle: "The bubble grows a little as the screen zooms in.",
                      isOn: $model.webcam.reactToZoom, emphasis: .control, onChange: commit)
        }
    }

    private var shapeGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Shape")
            ValueSlider(title: "Roundness", value: $model.webcam.roundness, range: 0...1,
                        format: { $0 > 0.98 ? "Circle" : String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
            ValueSlider(title: "Aspect", value: $model.webcam.aspectRatio, range: 0.5...2,
                        format: { String(format: "%.2f", $0) }, onCommit: commit)
            ToggleRow(title: "Mirror", subtitle: "Selfie-style horizontal flip.",
                      isOn: $model.webcam.mirror, emphasis: .control, onChange: commit)
            ToggleRow(title: "Shadow", isOn: $model.webcam.shadow, emphasis: .control, onChange: commit)
        }
    }

    private var frameGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Framing")
            ValueSlider(title: "Zoom", value: $model.webcam.cropZoom, range: 1...3,
                        format: { String(format: "%.2f×", $0) }, onCommit: commit)
            ValueSlider(title: "Pan X", value: $model.webcam.cropOffsetX, range: -1...1,
                        format: { String(format: "%+.2f", $0) }, onCommit: commit)
            ValueSlider(title: "Pan Y", value: $model.webcam.cropOffsetY, range: -1...1,
                        format: { String(format: "%+.2f", $0) }, onCommit: commit)
            ValueSlider(title: "Sync offset", value: $model.webcam.timeOffset, range: -2...2,
                        format: { String(format: "%+.2fs", $0) }, onCommit: commit)
            Text("Shifts the webcam track against the screen recording, if they drifted apart.")
                .captionType()
                .foregroundStyle(.secondary)
        }
    }
}
