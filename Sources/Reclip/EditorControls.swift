import SwiftUI

// MARK: - Background swatches
//
// A colour picked from a menu of names asks you to translate "Ocean" into a
// picture. A swatch *is* the picture — the control looks like what it changes.

extension StyleOptions.Background {
    var preview: LinearGradient {
        switch self {
        case .solid(let r, let g, let b):
            let c = Color(red: r, green: g, blue: b)
            return LinearGradient(colors: [c, c], startPoint: .top, endPoint: .bottom)
        case .gradient(let top, let bottom):
            return LinearGradient(colors: [Color(red: top.0, green: top.1, blue: top.2),
                                           Color(red: bottom.0, green: bottom.1, blue: bottom.2)],
                                  startPoint: .top, endPoint: .bottom)
        }
    }
}

struct BackgroundSwatch: View {
    let name: String
    let background: StyleOptions.Background
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background.preview)
                    .frame(height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.accent, lineWidth: 2)
                            .opacity(isSelected ? 1 : 0))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white, Palette.accent)
                            .padding(3)
                            .opacity(isSelected ? 1 : 0)
                            .scaleEffect(isSelected ? 1 : 0.9)
                    }
                    .animation(Motion.enter(reduce), value: isSelected)

                Text(name)
                    .captionType()
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PressableStyle())
        .help(name)
    }
}

// MARK: - Trim bar
//
// Two sliders described a range in numbers; this shows it. The handles track the
// pointer 1:1 from wherever they were grabbed, the kept region is the bright
// part, and the render only re-runs when the drag ends.

struct TrimBar: View {
    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    /// Current playback position in *source* time, or nil when unknown.
    var playhead: Double?
    var onCommit: () -> Void

    @State private var grabbedStart: Double?
    @State private var grabbedEnd: Double?

    private let handleWidth: CGFloat = 11
    private let minGap: Double = 0.2

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - handleWidth * 2, 1)
            let span = max(duration, 0.001)
            let startX = CGFloat(start / span) * usable
            let endX = CGFloat(end / span) * usable + handleWidth

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.07))

                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Palette.accent.opacity(0.18))
                    .frame(width: max(endX - startX + handleWidth, handleWidth * 2))
                    .offset(x: startX)

                if let playhead, playhead >= start, playhead <= end {
                    Capsule()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: 2)
                        .padding(.vertical, 5)
                        .offset(x: CGFloat(playhead / span) * usable + handleWidth)
                        .allowsHitTesting(false)
                }

                handle
                    .offset(x: startX)
                    .gesture(dragGesture(usable: usable, span: span, isStart: true))

                handle
                    .offset(x: endX)
                    .gesture(dragGesture(usable: usable, span: span, isStart: false))
            }
        }
        .frame(height: 34)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Palette.accent)
            .frame(width: handleWidth)
            .overlay(
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 2, height: 12))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .contentShape(Rectangle().inset(by: -6))   // a little hit padding
    }

    /// `minimumDistance: 0` so the handle answers on pointer-down, and the value
    /// is offset from where it was grabbed rather than snapping under the pointer.
    private func dragGesture(usable: CGFloat, span: Double, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let delta = Double(value.translation.width / usable) * span
                if isStart {
                    let base = grabbedStart ?? start
                    if grabbedStart == nil { grabbedStart = base }
                    start = min(max(0, base + delta), end - minGap)
                } else {
                    let base = grabbedEnd ?? end
                    if grabbedEnd == nil { grabbedEnd = base }
                    end = max(min(duration, base + delta), start + minGap)
                }
            }
            .onEnded { _ in
                grabbedStart = nil
                grabbedEnd = nil
                onCommit()
            }
    }
}

// MARK: - Speed

struct SpeedControl: View {
    @Binding var speed: Double
    var onCommit: () -> Void

    private let presets: [Double] = [0.5, 1, 1.5, 2]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionHeader(title: "Speed", trailing: String(format: "%.2f×", speed))

            HStack(spacing: 5) {
                ForEach(presets, id: \.self) { preset in
                    Chip(label: preset == 1 ? "1×" : String(format: "%g×", preset),
                         isSelected: abs(speed - preset) < 0.01) {
                        speed = preset
                        onCommit()
                    }
                }
            }

            Slider(value: $speed, in: 0.25...4.0) { editing in
                if !editing { onCommit() }
            }
            .controlSize(.small)
            .tint(Palette.accent)
        }
    }
}

struct Chip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .padding(.vertical, 4)
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity)
                .foregroundStyle(isSelected ? .white : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Palette.accent : Color.primary.opacity(hovering ? 0.10 : 0.06)))
                .animation(Motion.enter(reduce), value: isSelected)
                .animation(Motion.press, value: hovering)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Webcam corner picker
//
// The control is a small copy of the frame, and the dots sit where the bubble
// will sit. Nothing has to be read to know what it does.

struct CornerPicker: View {
    @Binding var corner: WebcamSettings.Corner
    var onChange: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))

            dot(.topLeading, alignment: .topLeading)
            dot(.topTrailing, alignment: .topTrailing)
            dot(.bottomLeading, alignment: .bottomLeading)
            dot(.bottomTrailing, alignment: .bottomTrailing)
        }
        .frame(width: 96, height: 58)
    }

    private func dot(_ value: WebcamSettings.Corner, alignment: Alignment) -> some View {
        let selected = corner == value
        return Button {
            corner = value
            onChange()
        } label: {
            Circle()
                .fill(selected ? Palette.accent : Color.primary.opacity(0.22))
                .frame(width: selected ? 15 : 11, height: selected ? 15 : 11)
                .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
                .padding(7)
                .contentShape(Rectangle())
                .animation(Motion.enter(reduce), value: selected)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .help(value.rawValue)
    }
}

// MARK: - Inspector rows

struct InspectorToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var enabled: Bool = true
    var onChange: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).titleType()
                if let subtitle {
                    Text(subtitle)
                        .captionType()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Palette.accent)
                .onChange(of: isOn) { onChange() }
        }
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
    }
}
