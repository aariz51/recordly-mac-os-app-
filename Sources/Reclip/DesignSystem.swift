import SwiftUI

// MARK: - Motion
//
// Every curve and duration here is a deliberate value, not a guess.
// Curves are the strong custom variants (the built-in SwiftUI easings are too
// weak to read as intentional); springs use Apple's damping/response pairs from
// *Designing Fluid Interfaces* (damping 1.0 to settle, ~0.8 only after a gesture
// carried momentum). Reduced motion returns a gentler cross-fade — never nothing.

enum Motion {
    /// Press feedback. Fires on pointer-*down*, so it must be short.
    static let press = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.16)

    /// Hover and colour changes. These aren't entrances, so they take the
    /// symmetric `ease` curve rather than the punchy ease-out — a highlight that
    /// snaps in and crawls out reads as twitchy.
    static let hover = Animation.easeInOut(duration: 0.14)

    /// Something entering or leaving the screen.
    static func enter(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    }

    /// The mirror of `enter`, run shorter. Two rules point in what looks like
    /// opposite directions: a thing should leave along the path it arrived on
    /// (spatial consistency), and the system's response should be quicker than
    /// the user's decision (asymmetric timing). They only conflict if you read
    /// "faster exit" as "different exit" — the resolution is the same path in
    /// less time, not a path deleted.
    static func exit(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.12) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.16)
    }

    /// Something already on screen moving or morphing in place.
    static func move(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .timingCurve(0.77, 0, 0.175, 1, duration: 0.24)
    }

    /// Apple's reposition spring: damping 1.0, response 0.4. No overshoot.
    static func settle(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0)
    }

    /// The return after a gesture let go past a boundary. This is the one place
    /// a little overshoot is earned — the drag carried momentum into the wall.
    static func recoil(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.2)
    }

    /// Determinate progress. Constant motion takes a linear curve; easing a
    /// progress bar makes it lie about the rate of work.
    static let progress = Animation.linear(duration: 0.2)
}

/// Rubber-banding: past a boundary the surface still follows, just less and less.
/// Apple's constant, from *Designing Fluid Interfaces*.
func rubberband(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
    guard dimension > 0 else { return 0 }
    let magnitude = abs(overshoot)
    return (overshoot * dimension * constant) / (dimension + constant * magnitude)
}

extension AnyTransition {
    /// Rises into place, and leaves back down the way it came.
    ///
    /// Nothing scales from zero; real things never appear out of nothing. And
    /// nothing leaves by a different door than it entered — if a card slid up
    /// into view and then dissolves in place, the eye is told the thing was
    /// destroyed rather than put back, which is the wrong story for a panel
    /// that will return. Same path both ways; `Motion.exit` supplies the speed
    /// difference instead of the geometry doing it.
    static func rise(_ reduce: Bool, distance: CGFloat = 10) -> AnyTransition {
        guard !reduce else { return .opacity }
        let path = AnyTransition.opacity
            .combined(with: .offset(y: distance))
            .combined(with: .scale(scale: 0.98))
        return .asymmetric(insertion: path.animation(Motion.enter(false)),
                           removal: path.animation(Motion.exit(false)))
    }

    /// For list rows that are added and removed rapidly.
    static func row(_ reduce: Bool) -> AnyTransition {
        guard !reduce else { return .opacity }
        let path = AnyTransition.opacity.combined(with: .offset(y: -6))
        return .asymmetric(insertion: path.animation(Motion.enter(false)),
                           removal: path.animation(Motion.exit(false)))
    }
}

// MARK: - Palette

enum Palette {
    /// One accent, used for the record affordance and the primary action so the
    /// two read as the same thread of intent.
    static let accent = Color(red: 0.96, green: 0.27, blue: 0.42)
    static let warning = Color(red: 0.98, green: 0.68, blue: 0.20)
    static let success = Color(red: 0.24, green: 0.78, blue: 0.52)

    static let canvasTop = Color(nsColor: .windowBackgroundColor)
    static let canvasBottom = Color(nsColor: .underPageBackgroundColor)

    /// A dark, neutral stage for video so the styled background is judged
    /// against nothing but itself.
    static let stage = Color(red: 0.07, green: 0.07, blue: 0.08)
}

// MARK: - Geometry tokens

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 22
    static let xxl: CGFloat = 30
}

/// One ladder of corner radii. Hand-typed radii that almost match are the visual
/// equivalent of five almost-identical easing curves — the eye reads the drift
/// even when it can't name it.
enum Radius {
    static let chip: CGFloat = 6      // speed chips
    static let inset: CGFloat = 7     // icon tiles, caption rows, small wells
    static let control: CGFloat = 8   // buttons, swatches
    static let track: CGFloat = 9     // slider / trim tracks
    static let stage: CGFloat = 10    // the video preview
    static let badge: CGFloat = 11    // the app mark
    static let card: CGFloat = 14     // grouped cards
}

// MARK: - Typography
//
// Tracking is size-specific: large text tightens as it grows, body sits near 0,
// small all-caps labels open up so they stay legible.

extension View {
    func displayType() -> some View {
        font(.system(size: 22, weight: .semibold, design: .rounded))
            .tracking(-0.4)
    }

    func titleType() -> some View {
        font(.system(size: 15, weight: .semibold))
            .tracking(-0.1)
    }

    /// Section eyebrow — small, so it gets positive tracking.
    func eyebrowType() -> some View {
        font(.system(size: 10.5, weight: .semibold))
            .tracking(0.7)
            .textCase(.uppercase)
    }

    /// The label on a single control *inside* a section. It has to be visibly a
    /// rung below the eyebrow, or "Padding" reads as a peer of "Frame" and the
    /// grouping stops meaning anything — so it stays sentence case, unspaced.
    func controlLabelType() -> some View {
        font(.system(size: 11.5, weight: .medium))
            .tracking(0)
    }

    func captionType() -> some View {
        font(.system(size: 11))
            .tracking(0.1)
    }
}

// MARK: - Surfaces

/// A grouped card. Sits on the opaque window canvas rather than stacking one
/// translucent surface on another, and carries a bright top edge so it reads as
/// a material catching light.
///
/// The edge is a *gradient* border at rest — light catching a surface, not a
/// drawn outline. Under Increase Contrast that reading is a luxury the user has
/// explicitly declined, so the same edge becomes a flat, defined line: grouping
/// you can see rather than grouping you can sense.
struct CardSurface: ViewModifier {
    var padding: CGFloat = Space.l
    var radius: CGFloat = Radius.card

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let high = contrast == .increased
        return content
            .padding(padding)
            .background(Color.primary.opacity(high ? 0.09 : 0.045),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: high
                                ? [Color.primary.opacity(0.45), Color.primary.opacity(0.45)]
                                : [Color.primary.opacity(0.14), Color.primary.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
    }
}

/// Floating chrome — a translucent layer with content passing beneath it.
///
/// Reduced Transparency is its own accessibility signal, independent of Reduced
/// Motion, and the app was answering neither of the two it uses. The correct
/// answer is not "remove the layer": the layer is doing structural work: it is
/// "make the material frostier" — raise the opacity to solid and drop the blur,
/// then give it the defined edge the blur was previously providing for free.
struct ChromeSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let material: Material
    /// What the layer becomes when translucency is declined. It has to be picked
    /// per site, because a bar on the window canvas and a pill over video are
    /// solid in two very different directions.
    let solid: Color

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency {
                shape.fill(solid)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.22), lineWidth: 1))
            } else {
                shape.fill(material)
            }
        }
    }
}

extension View {
    func chrome<S: InsettableShape>(_ shape: S,
                                    material: Material = .regularMaterial,
                                    solid: Color) -> some View {
        modifier(ChromeSurface(shape: shape, material: material, solid: solid))
    }
}

// MARK: - Entrance cascade
//
// A group of panels arriving together is a once-per-window moment, so it can
// spend a little of the delight budget. 55ms between items — long enough to read
// as a cascade, short enough that nothing feels withheld. It is decorative, so
// it never gates input: everything is hit-testable from the first frame.

extension View {
    func stagger(_ index: Int, appeared: Bool, reduce: Bool) -> some View {
        let delay = reduce ? 0 : Double(index) * 0.055
        return opacity(appeared ? 1 : 0)
            .offset(y: appeared || reduce ? 0 : 8)
            .animation(Motion.enter(reduce).delay(delay), value: appeared)
    }
}

extension View {
    func card(padding: CGFloat = Space.l, radius: CGFloat = Radius.card) -> some View {
        modifier(CardSurface(padding: padding, radius: radius))
    }

    /// A soft gradient where scrolling content meets floating chrome — a scroll
    /// edge effect instead of a hard 1px divider.
    func scrollEdge(_ edge: VerticalEdge, color: Color, height: CGFloat = 20) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) {
            LinearGradient(colors: edge == .top ? [color, color.opacity(0)] : [color.opacity(0), color],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: height)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Buttons

/// Press feedback lives on pointer-down and is subtle (0.97). Hover is a
/// separate, quieter signal. Every pressable surface in the app uses this.
struct ActionButtonStyle: ButtonStyle {
    enum Variant { case prominent, secondary, quiet }

    var variant: Variant = .prominent
    var tint: Color = Palette.accent
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        ButtonBody(configuration: configuration, variant: variant, tint: tint, fullWidth: fullWidth)
    }

    private struct ButtonBody: View {
        let configuration: ActionButtonStyle.Configuration
        let variant: Variant
        let tint: Color
        let fullWidth: Bool

        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.vertical, variant == .quiet ? 5 : 9)
                .padding(.horizontal, variant == .quiet ? 8 : 14)
                .foregroundStyle(foreground)
                .background(background)
                .overlay(border)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .shadow(color: shadowColor, radius: 10, y: 3)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.4)
                .animation(Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovering)
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            switch variant {
            case .prominent: return .white
            case .secondary: return .primary
            case .quiet: return hovering && isEnabled ? .primary : .secondary
            }
        }

        @ViewBuilder private var background: some View {
            switch variant {
            case .prominent:
                tint.brightness(hovering && isEnabled ? 0.05 : 0)
            case .secondary:
                Color.primary.opacity(hovering && isEnabled ? 0.10 : 0.06)
            case .quiet:
                Color.primary.opacity(hovering && isEnabled ? 0.07 : 0)
            }
        }

        @ViewBuilder private var border: some View {
            if variant == .secondary {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }

        private var shadowColor: Color {
            guard variant == .prominent, isEnabled else { return .clear }
            return tint.opacity(configuration.isPressed ? 0.18 : 0.32)
        }
    }
}

/// For non-button pressable surfaces (swatches, chips, corner targets) that need
/// the same press feedback without inheriting button chrome.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Feedback
//
// Feedback comes in four kinds: status, completion, warning, error. Each gets a
// distinct icon and colour so the kind is legible before the sentence is read.

enum FeedbackKind {
    case status, success, warning, error

    var symbol: String {
        switch self {
        case .status: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .status: return .secondary
        case .success: return Palette.success
        case .warning: return Palette.warning
        case .error: return Palette.accent
        }
    }
}

struct FeedbackLine: View {
    let kind: FeedbackKind
    let message: String

    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind.color)
                // The icon morphs between kinds instead of blinking out and back.
                .contentTransition(.symbolEffect(.replace))

            // One sentence replacing another is a crossfade, and a crossfade
            // shows two legible strings at once — which reads as a glitch, not a
            // change. A touch of blur through the swap fuses them into one.
            ZStack(alignment: .topLeading) {
                Text(message)
                    .captionType()
                    .foregroundStyle(kind == .status ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .id(message)
                    .transition(reduce ? AnyTransition.opacity
                                       : AnyTransition(.blurReplace(.downUp)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

// MARK: - Determinate progress
//
// A spinner answers "is it alive?". A job that can run for a minute also has to
// answer "how much longer?" — so the render reports a real fraction. The fill is
// a transform, not a width, so it stays off the layout path.

struct ProgressTrack: View {
    /// 0...1, or nil while the work has started but has no measurable progress yet.
    let fraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var sweeping = false

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    if let fraction {
                        Capsule()
                            .fill(Palette.accent)
                            .frame(width: geo.size.width)
                            .scaleEffect(x: CGFloat(min(max(fraction, 0.015), 1)),
                                         y: 1,
                                         anchor: .leading)
                            .animation(Motion.progress, value: fraction)
                    } else if reduce {
                        // Reduced motion means gentler, not nothing. A dimmed
                        // full-width fill says "working, amount unknown" without
                        // anything travelling across the screen.
                        Capsule().fill(Palette.accent.opacity(0.4))
                    } else {
                        // Before the encoder reports a first fraction, the old
                        // code drew a 1.5%-wide stub and held it there. A bar
                        // that is present and motionless is the visual signature
                        // of a hung job — it was reporting the opposite of the
                        // truth. An unmeasured job gets constant motion instead,
                        // and constant motion takes a linear curve: easing a
                        // sweep would imply a rate that isn't being measured.
                        let width = geo.size.width * 0.32
                        Capsule()
                            .fill(Palette.accent)
                            .frame(width: width)
                            .offset(x: sweeping ? geo.size.width : -width)
                            .onAppear {
                                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                                    sweeping = true
                                }
                            }
                    }
                }
            }
            .clipShape(Capsule())
            .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "In progress")
    }
}

// MARK: - Toggle row
//
// The switch is the control, but the label is what the eye reads and the pointer
// aims at. A 28pt switch beside a 280pt row that means exactly the same thing is
// a mapping failure — so the whole row is the target, and it presses like one.

struct ToggleRow: View {
    /// A switch in a list of capture options is a list item; a switch sitting
    /// among inspector sliders is a control. Same component, two densities —
    /// so its label matches whatever it is standing next to.
    enum Emphasis { case list, control }

    var icon: String?
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    var enabled: Bool = true
    var emphasis: Emphasis = .list
    var onChange: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button {
            isOn.toggle()
            onChange()
        } label: {
            HStack(spacing: Space.m) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOn && enabled ? Palette.accent : .secondary)
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
                        .animation(Motion.hover, value: isOn)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Group {
                        if emphasis == .list {
                            Text(title).titleType()
                        } else {
                            Text(title).controlLabelType()
                        }
                    }
                    if let subtitle {
                        Text(subtitle)
                            .captionType()
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.leading)

                Spacer(minLength: Space.s)

                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Palette.accent)
                    // The row owns the gesture; the switch is the readout.
                    .allowsHitTesting(false)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, Space.s)
            .background(
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .fill(Color.primary.opacity(hovering && enabled ? 0.05 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.985))
        .onHover { hovering = $0 && enabled }
        .animation(Motion.hover, value: hovering)
        .opacity(enabled ? 1 : 0.45)
        .disabled(!enabled)
        // VoiceOver should hear a switch, not a button that happens to flip one.
        .accessibilityRepresentation {
            Toggle(isOn: $isOn) {
                Text(subtitle.map { "\(title). \($0)" } ?? title)
            }
        }
    }
}

// MARK: - Recording indicator

/// A slow ripple, not a blink: it says "live" without pulling the eye away from
/// the timer. Static under reduced motion.
struct RecordPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var rippling = false

    var size: CGFloat = 9

    var body: some View {
        Circle()
            .fill(Palette.accent)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(Palette.accent, lineWidth: 2)
                    .scaleEffect(rippling ? 2.6 : 1)
                    .opacity(rippling ? 0 : 0.55)
            )
            .onAppear { arm() }
            // A `repeatForever` started in `onAppear` reads the motion setting
            // exactly once and then never listens again — so switching on Reduce
            // Motion mid-recording left the one looping animation in the app
            // running anyway, which is precisely the case the setting exists to
            // stop. Re-arming on the change makes the loop answer to it.
            .onChange(of: reduce) { _, _ in arm() }
    }

    private func arm() {
        withAnimation(.linear(duration: 0)) { rippling = false }
        guard !reduce else { return }
        // The restart has to land in a later turn of the run loop; collapsing
        // false→true into one update gives SwiftUI no transition to animate.
        Task { @MainActor in
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                rippling = true
            }
        }
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .eyebrowType()
                .foregroundStyle(.secondary)
            Spacer(minLength: Space.s)
            if let trailing {
                Text(trailing)
                    .captionType()
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }
}

// MARK: - Labelled slider
//
// The value is always visible. Showing what a control is set to is context that
// makes the control simpler, not busier.

/// The label/value pair above a single control. One rung below `SectionHeader`.
struct ControlLabel: View {
    let title: String
    var value: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .controlLabelType()
                .foregroundStyle(.primary)
            Spacer(minLength: Space.s)
            if let value {
                Text(value)
                    .captionType()
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }
}

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String
    var onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ControlLabel(title: title, value: format(value))
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit() }
            }
            .controlSize(.small)
            .tint(Palette.accent)
        }
    }
}
