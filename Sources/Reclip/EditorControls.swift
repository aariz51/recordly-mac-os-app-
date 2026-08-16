import SwiftUI
import AppKit

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
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .fill(background.preview)
                    .frame(height: 38)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
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
    enum Handle: Hashable { case start, end }

    let duration: Double
    @Binding var start: Double
    @Binding var end: Double
    /// Current playback position in *source* time, or nil when unknown.
    var playhead: Double?
    /// Called continuously while a handle is dragged, with the source time now
    /// under that handle. The preview follows the grip, so you cut on a frame
    /// you can actually see rather than on a number.
    var onScrub: ((Double) -> Void)?
    var onCommit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce

    @State private var grabbed: Handle?
    @State private var grabBase: Double = 0
    /// How far past the boundary the pointer has pushed, in points, already
    /// rubber-banded. Real things resist before they stop.
    @State private var overshoot: CGFloat = 0
    @State private var hovered: Handle?
    /// Which handles have pushed a cursor. `NSCursor` keeps a stack, and an
    /// unbalanced pop leaves the pointer stuck as a resize arrow for the rest of
    /// the session — so a push is only ever popped once.
    @State private var cursorPushed: Set<Handle> = []

    private let handleWidth: CGFloat = 11
    private let minGap: Double = 0.2

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - handleWidth * 2, 1)
            let span = max(duration, 0.001)
            let startX = CGFloat(start / span) * usable + (grabbed == .start ? overshoot : 0)
            let endX = CGFloat(end / span) * usable + handleWidth + (grabbed == .end ? overshoot : 0)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Radius.track, style: .continuous)
                    .fill(Color.primary.opacity(0.09))

                // The kept region is the one thing this control exists to state,
                // so it has to survive being read at a glance. At 0.22 the accent
                // sat close enough to the 0.09 empty track that in light mode the
                // bar read as one flat band — the answer was there and illegible.
                RoundedRectangle(cornerRadius: Radius.track, style: .continuous)
                    .fill(Palette.accent.opacity(grabbed == nil ? 0.28 : 0.38))
                    .frame(width: max(endX - startX + handleWidth, handleWidth * 2))
                    .offset(x: startX)
                    .animation(Motion.hover, value: grabbed)

                if let playhead, playhead >= start, playhead <= end {
                    // Hard-coded white vanished against the light-mode track: the
                    // playhead was drawn, just invisible in half the app's runs.
                    // `.primary` inverts with the scheme, so it stays the darkest
                    // or lightest thing on the track either way.
                    Capsule()
                        .fill(Color.primary.opacity(0.9))
                        .frame(width: 2)
                        .padding(.vertical, 5)
                        .offset(x: CGFloat(playhead / span) * usable + handleWidth)
                        .allowsHitTesting(false)
                }

                handle(.start)
                    .offset(x: startX)
                    .gesture(dragGesture(usable: usable, span: span, handle: .start))

                handle(.end)
                    .offset(x: endX)
                    .gesture(dragGesture(usable: usable, span: span, handle: .end))
            }
            // The handles move as they're dragged, so translation has to be
            // measured against the track — not against the handle's own frame,
            // which would feed its motion back into the gesture.
            .coordinateSpace(.named(Self.track))
        }
        .frame(height: 34)
    }

    private func handle(_ which: Handle) -> some View {
        let active = grabbed == which
        let lit = active || hovered == which
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Palette.accent)
            .frame(width: handleWidth)
            .overlay(
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 2, height: 12))
            .shadow(color: .black.opacity(active ? 0.4 : 0.25), radius: active ? 6 : 3, y: 1)
            .brightness(lit ? 0.06 : 0)
            // Feedback on pointer-*down*: the grip thickens the instant it is
            // taken, before a single pixel of movement has happened.
            .scaleEffect(x: active ? 1.35 : 1, y: active ? 1.1 : 1)
            .animation(Motion.press, value: active)
            .animation(Motion.hover, value: lit)
            .contentShape(Rectangle().inset(by: -8))   // a little hit padding
            .onHover { inside in
                hovered = inside ? which : (hovered == which ? nil : hovered)
                if inside, !cursorPushed.contains(which) {
                    cursorPushed.insert(which)
                    NSCursor.resizeLeftRight.push()
                } else if !inside, cursorPushed.remove(which) != nil {
                    NSCursor.pop()
                }
            }
            .accessibilityElement()
            .accessibilityLabel(which == .start ? "Trim start" : "Trim end")
            .accessibilityValue(Self.timeLabel(which == .start ? start : end))
            .accessibilityAdjustableAction { direction in
                let step = max(duration / 100, 0.1)
                let delta = direction == .increment ? step : -step
                switch which {
                case .start: start = min(max(0, start + delta), end - minGap)
                case .end:   end = max(min(duration, end + delta), start + minGap)
                }
                onScrub?(which == .start ? start : end)
                onCommit()
            }
    }

    /// `minimumDistance: 0` so the handle answers on pointer-down, and the value
    /// is offset from where it was grabbed rather than snapping under the pointer.
    private static let track = "reclip.trim.track"

    private func dragGesture(usable: CGFloat, span: Double, handle which: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.track))
            .onChanged { value in
                if grabbed != which {
                    grabbed = which
                    grabBase = which == .start ? start : end
                }
                let desired = grabBase + Double(value.translation.width / usable) * span
                let lower = which == .start ? 0 : start + minGap
                let upper = which == .start ? end - minGap : duration
                let clamped = min(max(desired, lower), upper)

                if which == .start { start = clamped } else { end = clamped }

                // Past the boundary the handle keeps following the pointer, just
                // less and less — a wall you can lean on rather than one you hit.
                let excessPoints = CGFloat((desired - clamped) / span) * usable
                overshoot = reduce ? 0 : rubberband(excessPoints, dimension: usable * 0.5)

                onScrub?(clamped)
            }
            .onEnded { _ in
                grabbed = nil
                grabBase = 0
                withAnimation(Motion.recoil(reduce)) { overshoot = 0 }
                onCommit()
            }
    }

    static func timeLabel(_ t: Double) -> String {
        let s = Int(max(t, 0).rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
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
                    RoundedRectangle(cornerRadius: Radius.chip, style: .continuous)
                        .fill(isSelected ? Palette.accent : Color.primary.opacity(hovering ? 0.10 : 0.06)))
                // Selecting a chip is a colour swap, not an entrance — nothing
                // arrives, nothing leaves. The punchy ease-out belongs to things
                // that travel; on a fill it just makes the colour land late.
                // Same curve as hover, because it's the same kind of change.
                .animation(Motion.hover, value: isSelected)
                .animation(Motion.hover, value: hovering)
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
            RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))

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
            // The dot grows by transform, not by frame. Animating `width`/`height`
            // pushes every change through layout and paint; a scale is composited
            // and, unlike the frame swap, doesn't shove the neighbouring dots a
            // couple of points sideways each time the selection moves.
            Circle()
                .fill(selected ? Palette.accent : Color.primary.opacity(0.22))
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.6 : 0), lineWidth: 1.5))
                .scaleEffect(selected ? 1.36 : 1)
                .padding(7)
                .contentShape(Rectangle())
                .animation(Motion.enter(reduce), value: selected)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .help(value.rawValue)
    }
}

