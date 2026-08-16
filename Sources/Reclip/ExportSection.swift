import SwiftUI
import AppKit

// MARK: - Export settings

struct ExportSection: View {
    @ObservedObject var model: EditorModel
    let commit: () -> Void
    let report: (FeedbackKind, String) -> Void
    /// Source pixel size, so the section can state the actual output dimensions.
    let sourceSize: CGSize

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            formatGroup
            if model.format == .mp4 { mp4Group } else { gifGroup }
            captionGroup
            projectGroup
        }
        .animation(Motion.move(reduce), value: model.format)
    }

    private var formatGroup: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Format", trailing: outputLabel)
            SegmentedRow(title: "Output", selection: $model.format,
                         options: ExportFormat.allCases, label: \.rawValue)
            Text(model.format == .mp4
                 ? "H.264 video — the right choice for anything with sound or longer than a few seconds."
                 : "An animated image: no audio, larger files, but it plays anywhere inline.")
                .captionType()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The canvas the current settings actually produce, mirroring the export path's own
    /// sizing so the number shown is the number written.
    private var outputLabel: String {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return "" }
        var canvas = ExportDimensions.canvas(sourceWidth: sourceSize.width,
                                             sourceHeight: sourceSize.height,
                                             ratio: model.style.aspect.ratio.map(Double.init))
        if let cap = model.style.maxOutputHeight, canvas.height > CGFloat(cap) {
            let s = CGFloat(cap) / canvas.height
            canvas = CGSize(width: (canvas.width * s / 2).rounded() * 2,
                            height: (canvas.height * s / 2).rounded() * 2)
        }
        if model.format == .gif, canvas.width > model.gifSize.maxWidth {
            let s = model.gifSize.maxWidth / canvas.width
            canvas = CGSize(width: (canvas.width * s).rounded(), height: (canvas.height * s).rounded())
        }
        return "\(Int(canvas.width))×\(Int(canvas.height))"
    }

    private var mp4Group: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Video")
            MenuRow(title: "Quality", selection: $model.quality,
                    options: ExportQuality.allCases, label: \.rawValue)
            MenuRow(title: "Frame rate", selection: $model.frameRate,
                    options: MP4FrameRate.allCases, label: \.label)
            MenuRow(title: "Encoding", selection: $model.encoding,
                    options: EncodingMode.allCases, label: { $0.rawValue.capitalized })
            Text(bitrateLabel)
                .captionType()
                .foregroundStyle(.secondary)

            ValueSlider(title: "Motion blur", value: $model.motionBlurAmount, range: 0...MotionBlur.maxAmount,
                        format: { $0 < 0.01 ? "Off" : String(format: "%.2f", $0) }, onCommit: {})
            Text("Blends neighbouring frames as they are written, so fast pans read as motion rather than judder. Costs render time.")
                .captionType()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bitrateLabel: String {
        guard sourceSize.width > 0 else { return "" }
        let canvas = ExportDimensions.canvas(sourceWidth: sourceSize.width,
                                             sourceHeight: sourceSize.height,
                                             ratio: model.style.aspect.ratio.map(Double.init))
        let bps = ExportBitrate.mp4(width: Int(canvas.width), height: Int(canvas.height),
                                    quality: model.quality, encoding: model.encoding)
        return "Target bitrate ≈ \(bps / 1_000_000) Mbps."
    }

    private var gifGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "GIF")
            ValueSlider(title: "Frame rate", value: $model.gifFPS, range: 5...30,
                        format: { String(format: "%.0f fps", $0) }, onCommit: {})
            MenuRow(title: "Size", selection: $model.gifSize,
                    options: GifSize.allCases, label: \.rawValue)
            ToggleRow(title: "Loop forever", isOn: $model.gifLoop, emphasis: .control)
            ToggleRow(title: "Ping-pong",
                      subtitle: "Plays forward, then backward, so the loop has no seam.",
                      isOn: $model.gifBounce, emphasis: .control)
        }
    }

    private var captionGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Sidecars")
            ToggleRow(title: "Write .srt and .vtt",
                      subtitle: model.captionCues.isEmpty
                        ? "No caption cues to write yet."
                        : "Saves the \(model.captionCues.count) cues next to the export as subtitle files.",
                      isOn: $model.writeCaptionSidecars,
                      enabled: !model.captionCues.isEmpty,
                      emphasis: .control)
        }
    }

    private var projectGroup: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionHeader(title: "Project", trailing: model.isDirty ? "Unsaved" : nil)
            Text("A .reclip file stores every setting on this page, so the edit can be reopened later.")
                .captionType()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Space.s) {
                Button {
                    save()
                } label: { Label("Save", systemImage: "square.and.arrow.down") }
                    .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                    .keyboardShortcut("s", modifiers: .command)

                Button {
                    load()
                } label: { Label("Load", systemImage: "folder") }
                    .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                    .disabled(!model.hasProjectOnDisk)
                Spacer(minLength: 0)
            }
        }
    }

    private func save() {
        do {
            try model.saveProject()
            report(.success, "Saved \(model.projectURL.lastPathComponent).")
        } catch {
            report(.error, "Could not save the project: \(error.localizedDescription)")
        }
    }

    private func load() {
        do {
            try model.loadProject()
            commit()
            report(.success, "Loaded \(model.projectURL.lastPathComponent).")
        } catch {
            report(.error, "Could not load the project: \(error.localizedDescription)")
        }
    }
}

// MARK: - Keyboard shortcut reference
//
// The editor has enough single-key actions that they need to be discoverable somewhere
// other than tooltips. `Shortcuts` already models the bindings and formats them, so this
// sheet renders that model rather than a second hand-written list that could drift from it.

struct ShortcutsHelp: View {
    /// The user's bindings, so the reference shows what is actually bound rather than the
    /// defaults it shipped with.
    var config: [ShortcutAction: ShortcutBinding] = [:]
    var onCustomize: () -> Void = {}
    var onClose: () -> Void

    private var configurable: [(ShortcutAction, ShortcutBinding)] {
        let merged = Shortcuts.mergeWithDefaults(config)
        return ShortcutAction.allCases.compactMap { a in merged[a].map { (a, $0) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keyboard shortcuts").displayType()
                    Text("Timeline and editor controls")
                        .captionType()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Space.s)
                Button("Customize", action: onCustomize)
                    .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                    .help("Rebind the editing shortcuts")
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Close")
            }

            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader(title: "Editing")
                ForEach(configurable, id: \.0) { action, binding in
                    row(label(action), Shortcuts.formatBinding(binding, isMac: true))
                }
            }

            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader(title: "Fixed")
                ForEach(Shortcuts.fixed, id: \.label) { f in
                    row(f.label, f.bindings.map { Shortcuts.formatBinding($0, isMac: true) }
                        .joined(separator: "  /  "))
                }
                row("Undo", "⌘ + Z")
                row("Redo", "⇧ + ⌘ + Z")
                row("Save project", "⌘ + S")
                row("Export", "⌘ + E")
                row("Close editor", "⌘ + W")
            }
        }
        .padding(Space.xl)
        .frame(width: 380)
    }

    private func row(_ name: String, _ keys: String) -> some View {
        HStack {
            Text(name).captionType()
            Spacer(minLength: Space.m)
            Text(keys)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func label(_ a: ShortcutAction) -> String {
        switch a {
        case .addZoom: return "Add zoom"
        case .splitClip: return "Split clip"
        case .addAnnotation: return "Add annotation"
        case .addKeyframe: return "Add speed region"
        case .deleteSelected: return "Delete selected"
        case .playPause: return "Play / pause"
        }
    }
}

// MARK: - Shortcut rebinding
//
// `Shortcuts` already models bindings, conflicts against both configurable and fixed
// actions, and display formatting — everything a rebinding UI needs. This is that UI: click
// a row, press a combination, and the model says whether it collides before it is accepted.

struct ShortcutsConfig: View {
    @Binding var config: [ShortcutAction: ShortcutBinding]
    var onSave: ([ShortcutAction: ShortcutBinding]) -> Void
    var onClose: () -> Void

    @State private var draft: [ShortcutAction: ShortcutBinding] = [:]
    @State private var capturing: ShortcutAction?
    @State private var conflict: String?
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            header

            Text("Click a shortcut, then press the new combination. Esc cancels.")
                .captionType()
                .foregroundStyle(.secondary)

            VStack(spacing: Space.xs) {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    row(action)
                }
            }

            if let conflict {
                FeedbackLine(kind: .warning, message: conflict)
                    .transition(.rise(reduce, distance: 4))
            }

            VStack(alignment: .leading, spacing: Space.s) {
                SectionHeader(title: "Fixed")
                ForEach(Shortcuts.fixed, id: \.label) { f in
                    HStack {
                        Text(f.label).captionType().foregroundStyle(.secondary)
                        Spacer(minLength: Space.m)
                        Text(f.bindings.map { Shortcuts.formatBinding($0, isMac: true) }
                                .joined(separator: "  /  "))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack(spacing: Space.s) {
                Button("Reset to defaults") {
                    draft = Shortcuts.defaults
                    conflict = nil
                }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                Spacer(minLength: 0)
                Button("Cancel", action: onClose)
                    .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
                Button("Save") {
                    onSave(draft)
                    onClose()
                }
                .buttonStyle(ActionButtonStyle(variant: .prominent, fullWidth: false))
            }
        }
        .padding(Space.xl)
        .frame(width: 420)
        .onAppear { draft = Shortcuts.mergeWithDefaults(config) }
        .animation(Motion.enter(reduce), value: conflict)
        .background { captureHost }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Keyboard shortcuts").displayType()
                Text("Rebind the editing actions")
                    .captionType()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.s)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
            .accessibilityLabel("Close")
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        let binding = draft[action] ?? Shortcuts.defaults[action]!
        let isCapturing = capturing == action
        return Button {
            capturing = isCapturing ? nil : action
            conflict = nil
        } label: {
            HStack {
                Text(label(action)).captionType()
                Spacer(minLength: Space.m)
                Text(isCapturing ? "Press a key…" : Shortcuts.formatBinding(binding, isMac: true))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isCapturing ? Palette.accent : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, Space.s)
            .background(isCapturing ? Palette.accent.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .accessibilityLabel("\(label(action)): \(Shortcuts.formatBinding(binding, isMac: true))")
    }

    /// Captures the next key press while a row is armed. A local monitor is the only way to
    /// see a raw combination — SwiftUI's own shortcut plumbing consumes it before a view
    /// could observe which keys were pressed.
    private var captureHost: some View {
        KeyCaptureView(enabled: capturing != nil) { chord in
            guard let action = capturing else { return }
            let proposed = ShortcutBinding(key: chord.key, ctrl: chord.primaryModifier,
                                           shift: chord.shift, alt: chord.alt)
            if let clash = Shortcuts.findConflict(proposed, forAction: action, config: draft) {
                switch clash {
                case .fixed(let name):
                    conflict = "That combination is reserved for “\(name)” and can't be reassigned."
                case .configurable(let other):
                    conflict = "Already used by “\(label(other))”. Pick another, or rebind that one first."
                }
                return
            }
            draft[action] = proposed
            capturing = nil
            conflict = nil
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func label(_ a: ShortcutAction) -> String {
        switch a {
        case .addZoom: return "Add zoom"
        case .splitClip: return "Split clip"
        case .addAnnotation: return "Add annotation"
        case .addKeyframe: return "Add speed region"
        case .deleteSelected: return "Delete selected"
        case .playPause: return "Play / pause"
        }
    }
}

/// Bridges an AppKit local key monitor into SwiftUI, reporting each press as a `KeyChord`.
struct KeyCaptureView: NSViewRepresentable {
    var enabled: Bool
    var onKey: (KeyChord) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onKey = onKey
        context.coordinator.setEnabled(enabled)
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onKey = onKey
        context.coordinator.setEnabled(enabled)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onKey: ((KeyChord) -> Void)?
        private var monitor: Any?

        func setEnabled(_ on: Bool) {
            if on, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let chars = event.charactersIgnoringModifiers, !chars.isEmpty else {
                        return event
                    }
                    // Esc falls through so the sheet's own cancel shortcut still works.
                    if event.keyCode == 53 { return event }
                    let flags = event.modifierFlags
                    self.onKey?(KeyChord(key: chars.lowercased(),
                                         primaryModifier: flags.contains(.command),
                                         shift: flags.contains(.shift),
                                         alt: flags.contains(.option)))
                    return nil   // swallow, so the key doesn't also trigger an editor action
                }
            } else if !on, let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
