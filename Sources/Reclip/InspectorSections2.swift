import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Captions

struct CaptionsSection: View {
    @ObservedObject var model: EditorModel
    let commit: () -> Void
    let report: (FeedbackKind, String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var language: WhisperLanguage = .auto
    @State private var whisperModel: WhisperModel = .base
    @State private var downloading = false
    @State private var transcribing = false
    @State private var editingCue: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            enableGroup
            transcribeGroup
            if !model.captionCues.isEmpty { cueListGroup }
            if model.captionSettings.enabled { styleGroup }
        }
        .animation(Motion.move(reduce), value: model.captionSettings.enabled)
    }

    private var enableGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Captions",
                          trailing: model.captionCues.isEmpty ? nil : "\(model.captionCues.count) cues")
            ToggleRow(title: "Burn captions in",
                      subtitle: "Draws the cues onto the exported video.",
                      isOn: $model.captionSettings.enabled,
                      enabled: !model.captionCues.isEmpty,
                      emphasis: .control, onChange: commit)
        }
    }

    private var transcribeGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Transcribe")

            MenuRow(title: "Language", selection: $language,
                    options: WhisperLanguage.allCases, label: \.displayName)
            MenuRow(title: "Model", selection: $whisperModel,
                    options: WhisperModel.allCases,
                    label: { $0.rawValue.capitalized + ($0.isDownloaded ? " ✓" : "") })

            if !whisperModel.isDownloaded {
                ActionRow(title: "Speech model",
                          subtitle: "The \(whisperModel.rawValue) model isn't on this Mac yet.",
                          actionTitle: "Download", symbol: "arrow.down.circle",
                          busy: downloading) { download() }
            }

            ActionRow(title: model.captionCues.isEmpty ? "Generate captions" : "Regenerate captions",
                      subtitle: "Transcribes the clip's audio on-device.",
                      actionTitle: "Generate", symbol: "waveform.and.mic",
                      enabled: whisperModel.isDownloaded,
                      busy: transcribing) { transcribe() }

            if !model.captionCues.isEmpty {
                Button(role: .destructive) {
                    model.captionCues = []
                    model.captionSettings.enabled = false
                    commit()
                } label: {
                    Label("Clear captions", systemImage: "trash")
                }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
            }
        }
    }

    private var cueListGroup: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Cues")
            VStack(spacing: Space.xs) {
                ForEach(model.captionCues.indices, id: \.self) { i in
                    HStack(spacing: Space.s) {
                        Text(TrimBar.timeLabel(model.captionCues[i].start))
                            .captionType()
                            .monospacedDigit()
                            .foregroundStyle(Palette.accent)
                        if editingCue == i {
                            TextField("", text: Binding(
                                get: { model.captionCues[i].text },
                                set: { model.captionCues[i].text = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    model.captionCues[i].text =
                                        CaptionEditing.normalizeText(model.captionCues[i].text)
                                    editingCue = nil
                                    commit()
                                }
                        } else {
                            Text(model.captionCues[i].text)
                                .captionType()
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button {
                                editingCue = i
                            } label: {
                                Image(systemName: "pencil").font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                            .accessibilityLabel("Edit cue")
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, Space.s)
                    .background(Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                }
            }
        }
    }

    private var styleGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Style")
            ValueSlider(title: "Font size", value: $model.captionSettings.fontFraction, range: 0.02...0.12,
                        format: { String(format: "%.1f%%", $0 * 100) }, onCommit: commit)
            FontRow(fontName: $model.captionSettings.fontName, onCommit: commit)
            ColorRow(title: "Text colour", rgba: $model.captionSettings.textRGBA, onCommit: commit)
            ValueSlider(title: "Bottom offset", value: $model.captionSettings.bottomOffsetFraction,
                        range: 0...0.4, format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
            ValueSlider(title: "Max width", value: $model.captionSettings.maxWidthFraction,
                        range: 0.3...1, format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
            ValueSlider(title: "Box opacity", value: $model.captionSettings.backgroundOpacity,
                        range: 0...1, format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
            ValueSlider(title: "Box radius", value: $model.captionSettings.cornerRadiusFraction,
                        range: 0...0.06, format: { String(format: "%.1f%%", $0 * 100) }, onCommit: commit)
            SegmentedRow(title: "Animation",
                         selection: Binding(get: { model.captionSettings.animation },
                                            set: { model.captionSettings.animation = $0 }),
                         options: CaptionAnimation.allCases,
                         label: { $0.label }, onCommit: commit)
            if model.captionSettings.animation != .off {
                ValueSlider(title: "Animation time", value: $model.captionSettings.animationDuration,
                            range: 0.05...0.8, format: { String(format: "%.2fs", $0) }, onCommit: commit)
            }
        }
    }

    private func download() {
        downloading = true
        let m = whisperModel
        Task {
            do {
                _ = try await WhisperTranscriber.downloadModel(m)
                report(.success, "Downloaded the \(m.rawValue) speech model.")
            } catch {
                report(.error, "Model download failed: \(error.localizedDescription)")
            }
            downloading = false
        }
    }

    private func transcribe() {
        // whisper-cli ships alongside the app; when it isn't there, say so plainly rather
        // than failing with a path error.
        guard let binary = Self.whisperBinary() else {
            report(.warning, "The whisper-cli binary isn't bundled with this build, so captions can't be generated here.")
            return
        }
        transcribing = true
        let src = model.sourceURL
        let modelURL = whisperModel.localURL
        let lang = language.rawValue
        Task {
            do {
                let cues = try await WhisperTranscriber.transcribe(video: src, binary: binary,
                                                                   model: modelURL, language: lang)
                model.captionCues = cues
                model.captionSettings.enabled = !cues.isEmpty
                commit()
                report(cues.isEmpty ? .warning : .success,
                       cues.isEmpty ? "No speech was found in this clip." : "Generated \(cues.count) caption cues.")
            } catch {
                report(.error, "Transcription failed: \(error.localizedDescription)")
            }
            transcribing = false
        }
    }

    /// Looks for whisper-cli next to the app bundle, then on PATH.
    static func whisperBinary() -> URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "whisper-cli"),
           FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        for candidate in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}

/// Font family picker sourced from the installed families, with a "Default" entry.
struct FontRow: View {
    @Binding var fontName: String
    var onCommit: () -> Void

    private var families: [String] { NSFontManager.shared.availableFontFamilies.sorted() }

    var body: some View {
        HStack {
            Text("Font").controlLabelType()
            Spacer(minLength: Space.s)
            Picker("", selection: Binding(get: { fontName },
                                          set: { fontName = $0; onCommit() })) {
                Text("Default").tag("")
                Divider()
                ForEach(families, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Font")
    }
}

// MARK: - Annotations

struct AnnotationsSection: View {
    @ObservedObject var model: EditorModel
    let commit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            listGroup
            if model.selectedAnnotation != nil { editorGroup }
        }
        .animation(Motion.move(reduce), value: model.selectedAnnotationID)
    }

    private var listGroup: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Annotations",
                          trailing: model.annotations.isEmpty ? nil : "\(model.annotations.count)")

            // One button per kind: the kinds are few and visual, so a row of icons beats a
            // menu plus an "Add" button.
            HStack(spacing: Space.xs) {
                ForEach(AnnotationKindOption.all, id: \.kind) { opt in
                    Button {
                        model.addAnnotation(kind: opt.kind, at: model.playhead)
                        if opt.kind == .image { pickImage() }
                        commit()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: opt.symbol).font(.system(size: 13, weight: .medium))
                            Text(opt.label).font(.system(size: 9, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .help("Add a \(opt.label.lowercased()) annotation at the playhead")
                }
            }

            if model.annotations.isEmpty {
                EmptyHint(symbol: "textformat",
                          message: "Nothing annotated yet. Add text, an image, an arrow, a censor box, or a blur — each is placed at the playhead.")
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(model.annotations) { a in
                        RegionRow(title: "\(TrimBar.timeLabel(a.start))  \(a.kind.rawValue.capitalized)",
                                  detail: a.kind == .text ? a.text : "",
                                  isSelected: model.selectedAnnotationID == a.id,
                                  select: { model.selectedAnnotationID = a.id },
                                  delete: {
                                      model.annotations.removeAll { $0.id == a.id }
                                      if model.selectedAnnotationID == a.id { model.selectedAnnotationID = nil }
                                      commit()
                                  })
                    }
                }
                Text("Tab cycles through annotations under the playhead.")
                    .captionType()
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var editorGroup: some View {
        if let a = model.selectedAnnotation {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader(title: "Selected \(a.kind.rawValue)")

                timingControls(a)

                switch a.kind {
                case .text:  textControls(a)
                case .image: imageControls(a)
                case .arrow: arrowControls(a)
                case .box:   boxControls(a)
                case .blur:  blurControls(a)
                }

                positionControls(a)

                Button(role: .destructive) {
                    model.deleteSelectedAnnotation()
                    commit()
                } label: {
                    Label("Delete annotation", systemImage: "trash")
                }
                .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
            }
            .transition(.rise(reduce, distance: 6))
        }
    }

    private func timingControls(_ a: Annotation) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ValueSlider(title: "Start", value: bind(a, \.start), range: 0...max(model.duration, 1),
                        format: { TrimBar.timeLabel($0) }, onCommit: commit)
            ValueSlider(title: "End", value: bind(a, \.end), range: 0...max(model.duration, 1),
                        format: { TrimBar.timeLabel($0) }, onCommit: commit)
            ValueSlider(title: "Fade", value: bind(a, \.fadeDuration), range: 0...2,
                        format: { $0 < 0.02 ? "Hard cut" : String(format: "%.2fs", $0) }, onCommit: commit)
        }
    }

    private func textControls(_ a: Annotation) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                ControlLabel(title: "Text")
                TextField("Caption text", text: bindText(a))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
            }
            ValueSlider(title: "Size", value: bind(a, \.fontFraction), range: 0.02...0.16,
                        format: { String(format: "%.1f%%", $0 * 100) }, onCommit: commit)
            FontRow(fontName: bindString(a, \.fontName), onCommit: commit)
            Toggle(isOn: bindBool(a, \.bold)) { Text("Bold").controlLabelType() }
                .toggleStyle(.switch).controlSize(.small).tint(Palette.accent)
            ColorRow(title: "Text colour", rgba: bindRGBA(a, \.textColorRGBA), onCommit: commit)
            Toggle(isOn: bindBool(a, \.showBackground)) { Text("Background pill").controlLabelType() }
                .toggleStyle(.switch).controlSize(.small).tint(Palette.accent)
            if a.showBackground {
                ColorRow(title: "Pill colour", rgba: bindRGBA(a, \.bgColorRGBA), onCommit: commit)
            }
        }
    }

    private func imageControls(_ a: Annotation) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ActionRow(title: "Image",
                      subtitle: a.imageData == nil ? "No image chosen yet." : "Image attached.",
                      actionTitle: a.imageData == nil ? "Choose…" : "Replace…",
                      symbol: "photo") { pickImage() }
        }
    }

    private func arrowControls(_ a: Annotation) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ColorRow(title: "Arrow colour", rgba: bindRGBA(a, \.colorRGBA), onCommit: commit)
            ValueSlider(title: "Direction", value: bind(a, \.arrowAngle), range: 0...360,
                        format: { String(format: "%.0f°", $0) }, onCommit: commit)
        }
    }

    private func boxControls(_ a: Annotation) -> some View {
        ColorRow(title: "Fill colour", rgba: bindRGBA(a, \.colorRGBA), onCommit: commit)
    }

    private func blurControls(_ a: Annotation) -> some View {
        ValueSlider(title: "Blur strength", value: bind(a, \.blurRadius), range: 2...80,
                    format: { String(format: "%.0f", $0) }, onCommit: commit)
    }

    private func positionControls(_ a: Annotation) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xs) {
                ControlLabel(title: "Position")
                FocusPad(focus: Binding(get: { a.position },
                                        set: { p in model.updateSelectedAnnotation { $0.position = p } }),
                         onCommit: commit)
            }
            if a.kind != .text {
                ValueSlider(title: "Width", value: Binding(
                                get: { a.regionSize.width },
                                set: { v in model.updateSelectedAnnotation { $0.regionSize.width = v } }),
                            range: 0.03...1, format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
                ValueSlider(title: "Height", value: Binding(
                                get: { a.regionSize.height },
                                set: { v in model.updateSelectedAnnotation { $0.regionSize.height = v } }),
                            range: 0.03...1, format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
            }
        }
    }

    // Binding helpers: each writes through `updateSelectedAnnotation` so the array element
    // is mutated in place rather than replaced.
    private func bind(_ a: Annotation, _ key: WritableKeyPath<Annotation, Double>) -> Binding<Double> {
        Binding(get: { a[keyPath: key] },
                set: { v in model.updateSelectedAnnotation { $0[keyPath: key] = v } })
    }
    private func bindBool(_ a: Annotation, _ key: WritableKeyPath<Annotation, Bool>) -> Binding<Bool> {
        Binding(get: { a[keyPath: key] },
                set: { v in model.updateSelectedAnnotation { $0[keyPath: key] = v }; commit() })
    }
    private func bindString(_ a: Annotation, _ key: WritableKeyPath<Annotation, String>) -> Binding<String> {
        Binding(get: { a[keyPath: key] },
                set: { v in model.updateSelectedAnnotation { $0[keyPath: key] = v } })
    }
    private func bindRGBA(_ a: Annotation, _ key: WritableKeyPath<Annotation, [Double]>) -> Binding<[Double]> {
        Binding(get: { a[keyPath: key] },
                set: { v in model.updateSelectedAnnotation { $0[keyPath: key] = v } })
    }
    private func bindText(_ a: Annotation) -> Binding<String> {
        Binding(get: { a.text },
                set: { v in model.updateSelectedAnnotation { $0.text = v } })
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        model.updateSelectedAnnotation { $0.imageData = data }
        commit()
    }

    struct AnnotationKindOption {
        let kind: Annotation.Kind
        let label: String
        let symbol: String
        static let all: [AnnotationKindOption] = [
            .init(kind: .text, label: "Text", symbol: "textformat"),
            .init(kind: .image, label: "Image", symbol: "photo"),
            .init(kind: .arrow, label: "Arrow", symbol: "arrow.right"),
            .init(kind: .box, label: "Censor", symbol: "rectangle.fill"),
            .init(kind: .blur, label: "Blur", symbol: "drop.fill"),
        ]
    }
}

// MARK: - Audio

struct AudioSection: View {
    @ObservedObject var model: EditorModel
    let commit: () -> Void
    /// How many audio tracks the source actually has — routing only means something with two.
    let audioTrackCount: Int

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            levelGroup
            if !model.style.muteAudio {
                processingGroup
                regionsGroup
                if audioTrackCount > 1 { routingGroup }
            }
        }
        .animation(Motion.move(reduce), value: model.style.muteAudio)
    }

    private var levelGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Audio",
                          trailing: audioTrackCount == 0 ? "No audio" : "\(audioTrackCount) track\(audioTrackCount == 1 ? "" : "s")")
            if audioTrackCount == 0 {
                EmptyHint(symbol: "speaker.slash",
                          message: "This recording has no audio track, so there is nothing to mix.")
            }
            ToggleRow(title: "Mute", subtitle: "Drops the audio from the export entirely.",
                      isOn: $model.style.muteAudio, enabled: audioTrackCount > 0,
                      emphasis: .control, onChange: commit)
            if !model.style.muteAudio {
                ValueSlider(title: "Volume", value: $model.style.audioVolume, range: 0...2,
                            format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
            }
        }
        .disabled(audioTrackCount == 0)
    }

    private var processingGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Processing")
            ToggleRow(title: "Normalize",
                      subtitle: "Lifts the loudest peak toward full scale, so a quiet take isn't quiet.",
                      isOn: $model.style.normalizeAudio, emphasis: .control, onChange: commit)
            MenuRow(title: "Mic profile", selection: $model.style.micProfile,
                    options: MicProfile.allCases,
                    label: { $0.rawValue.capitalized }, onCommit: commit)
            Text(micProfileHint)
                .captionType()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var micProfileHint: String {
        switch model.style.micProfile {
        case .raw: return "No processing — the mic track is exported as recorded."
        case .voice: return "Removes low rumble and gates room noise between phrases."
        case .music: return "A light high-pass only, so dynamics survive."
        }
    }

    /// Per-stretch volume overrides — for ducking a noisy passage without touching the rest.
    /// Between regions the level returns to the overall volume.
    private var regionsGroup: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Volume regions",
                          trailing: model.style.audioVolumeRegions.isEmpty
                            ? nil : "\(model.style.audioVolumeRegions.count)")
            Button {
                addRegion()
            } label: { Label("Add at playhead", systemImage: "plus") }
                .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                .disabled(audioTrackCount == 0)

            if model.style.audioVolumeRegions.isEmpty {
                EmptyHint(symbol: "speaker.wave.1",
                          message: "No overrides. Add one to duck or lift a stretch of audio; the rest keeps the overall volume.")
            } else {
                VStack(spacing: Space.s) {
                    ForEach(model.style.audioVolumeRegions.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            HStack {
                                Text("\(TrimBar.timeLabel(model.style.audioVolumeRegions[i].start)) – \(TrimBar.timeLabel(model.style.audioVolumeRegions[i].end))")
                                    .captionType()
                                    .monospacedDigit()
                                Spacer(minLength: Space.s)
                                Button {
                                    model.style.audioVolumeRegions.remove(at: i)
                                    commit()
                                } label: {
                                    Image(systemName: "trash").font(.system(size: 10, weight: .semibold))
                                }
                                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                                .accessibilityLabel("Delete volume region")
                            }
                            ValueSlider(title: "Level", value: Binding(
                                            get: { model.style.audioVolumeRegions[i].volume },
                                            set: { model.style.audioVolumeRegions[i].volume = $0 }),
                                        range: 0...2,
                                        format: { $0 < 0.01 ? "Silent" : String(format: "%.0f%%", $0 * 100) },
                                        onCommit: commit)
                            ValueSlider(title: "Start", value: Binding(
                                            get: { model.style.audioVolumeRegions[i].start },
                                            set: { model.style.audioVolumeRegions[i].start =
                                                    min($0, model.style.audioVolumeRegions[i].end - 0.1) }),
                                        range: 0...max(model.duration, 1),
                                        format: { TrimBar.timeLabel($0) }, onCommit: commit)
                            ValueSlider(title: "End", value: Binding(
                                            get: { model.style.audioVolumeRegions[i].end },
                                            set: { model.style.audioVolumeRegions[i].end =
                                                    max($0, model.style.audioVolumeRegions[i].start + 0.1) }),
                                        range: 0...max(model.duration, 1),
                                        format: { TrimBar.timeLabel($0) }, onCommit: commit)
                        }
                        .padding(Space.s)
                        .background(Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                    }
                }
            }
        }
    }

    private func addRegion() {
        let start = max(0, min(model.playhead, max(model.duration - 0.5, 0)))
        let end = min(model.duration, start + 3)
        guard end - start > 0.2 else { return }
        // Volume regions are applied in order and gap-filled by the mixer, so overlapping
        // ones would fight; refuse rather than produce a mix that depends on ordering.
        let span = TimelineModel.Span(start: start, end: end)
        let clash = model.style.audioVolumeRegions.contains {
            TimelineModel.spansOverlap(span, TimelineModel.Span(start: $0.start, end: $0.end))
        }
        guard !clash else { return }
        model.style.audioVolumeRegions.append(AudioVolumeRegion(start: start, end: end, volume: 0.4))
        commit()
    }

    private var routingGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Routing")
            Text("This clip has separate system and microphone tracks, so each can be mixed on its own.")
                .captionType()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let routing = Binding<AudioRouting>(
                get: { model.style.audioRouting ?? AudioRouting() },
                set: { model.style.audioRouting = $0 })

            ToggleRow(title: "System audio", isOn: routing.systemEnabled,
                      emphasis: .control, onChange: commit)
            if routing.wrappedValue.systemEnabled {
                ValueSlider(title: "System gain", value: routing.systemGain, range: 0...2,
                            format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
            }
            ToggleRow(title: "Microphone", isOn: routing.micEnabled,
                      emphasis: .control, onChange: commit)
            if routing.wrappedValue.micEnabled {
                ValueSlider(title: "Mic gain", value: routing.micGain, range: 0...2,
                            format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)
            }
            ValueSlider(title: "Master", value: routing.masterGain, range: 0...1,
                        format: { String(format: "%.0f%%", $0 * 100) }, onCommit: commit)

            if model.style.audioRouting != nil {
                Button("Reset routing") {
                    model.style.audioRouting = nil
                    commit()
                }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
            }
        }
    }
}

// MARK: - Clip
//
// The timing of the clip itself: what is kept, how fast it runs, and any stretches that run
// at a different rate. Trim and speed regions are dragged on the timeline; this is where
// their values are read and set precisely.

struct ClipSection: View {
    @ObservedObject var model: EditorModel
    let commit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            trimGroup
            speedGroup
            regionsGroup
            if model.selectedSpeedIndex != nil { selectedSpeedGroup }
        }
        .animation(Motion.move(reduce), value: model.selectedSpeedIndex)
    }

    private var trimGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Trim",
                          trailing: "\(TrimBar.timeLabel(model.trimStart)) – \(TrimBar.timeLabel(model.trimEnd))")
            ValueSlider(title: "Start", value: Binding(
                            get: { model.trimStart },
                            set: { model.trimStart = min($0, model.trimEnd - 0.1) }),
                        range: 0...max(model.duration, 1),
                        format: { TrimBar.timeLabel($0) }, onCommit: commit)
            ValueSlider(title: "End", value: Binding(
                            get: { model.trimEnd },
                            set: { model.trimEnd = max($0, model.trimStart + 0.1) }),
                        range: 0...max(model.duration, 1),
                        format: { TrimBar.timeLabel($0) }, onCommit: commit)
            HStack {
                Text("\(TrimBar.timeLabel(model.trimEnd - model.trimStart)) kept of \(TrimBar.timeLabel(model.duration))")
                    .captionType()
                    .foregroundStyle(.secondary)
                Spacer(minLength: Space.s)
                Button("Reset") {
                    model.trimStart = 0
                    model.trimEnd = model.duration
                    commit()
                }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                .disabled(model.trimStart == 0 && model.trimEnd == model.duration)
            }
            Button {
                model.splitAtPlayhead()
                commit()
            } label: { Label("Trim to playhead", systemImage: "scissors") }
                .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
        }
    }

    private var speedGroup: some View {
        // `SpeedControl` carries its own section header, so this group must not add a second.
        VStack(alignment: .leading, spacing: Space.m) {
            SpeedControl(speed: $model.speed, onCommit: commit)
                // Speed regions override the overall rate, so the global control steps back
                // rather than sitting there looking live while having no effect.
                .disabled(!model.speedRegions.isEmpty)
                .opacity(model.speedRegions.isEmpty ? 1 : 0.45)
            if !model.speedRegions.isEmpty {
                Text("Speed regions replace this overall rate while they last.")
                    .captionType()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var regionsGroup: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Speed regions",
                          trailing: model.speedRegions.isEmpty ? nil : "\(model.speedRegions.count)")
            Button {
                _ = model.addSpeedRegion(at: model.playhead)
                commit()
            } label: { Label("Add at playhead", systemImage: "plus") }
                .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))

            if model.speedRegions.isEmpty {
                EmptyHint(symbol: "speedometer",
                          message: "No speed regions. Add one to run a stretch of the clip faster or slower than the rest.")
            } else {
                VStack(spacing: Space.xs) {
                    ForEach(model.speedRegions.indices, id: \.self) { i in
                        let s = model.speedRegions[i]
                        RegionRow(title: "\(TrimBar.timeLabel(s.start)) – \(TrimBar.timeLabel(s.end))",
                                  detail: String(format: "%.2g×", s.speed),
                                  isSelected: model.selectedSpeedIndex == i,
                                  select: { model.selectedSpeedIndex = i },
                                  delete: {
                                      model.speedRegions.remove(at: i)
                                      if model.selectedSpeedIndex == i { model.selectedSpeedIndex = nil }
                                      commit()
                                  })
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var selectedSpeedGroup: some View {
        if let i = model.selectedSpeedIndex, model.speedRegions.indices.contains(i) {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionHeader(title: "Selected region")
                ValueSlider(title: "Rate", value: Binding(
                                get: { model.speedRegions[i].speed },
                                set: { model.speedRegions[i].speed = $0 }),
                            range: 0.25...4,
                            format: { String(format: "%.2g×", $0) }, onCommit: commit)
                ValueSlider(title: "Start", value: Binding(
                                get: { model.speedRegions[i].start },
                                set: { model.speedRegions[i].start = min($0, model.speedRegions[i].end - 0.2) }),
                            range: 0...max(model.duration, 1),
                            format: { TrimBar.timeLabel($0) }, onCommit: commit)
                ValueSlider(title: "End", value: Binding(
                                get: { model.speedRegions[i].end },
                                set: { model.speedRegions[i].end = max($0, model.speedRegions[i].start + 0.2) }),
                            range: 0...max(model.duration, 1),
                            format: { TrimBar.timeLabel($0) }, onCommit: commit)
                Button(role: .destructive) {
                    model.deleteSelectedSpeedRegion()
                    commit()
                } label: { Label("Delete region", systemImage: "trash") }
                    .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
            }
            .transition(.rise(reduce, distance: 6))
        }
    }
}
