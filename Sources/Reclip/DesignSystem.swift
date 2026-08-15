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

    /// Something entering or leaving the screen.
    static func enter(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
    }

    /// Something already on screen moving or morphing in place.
    static func move(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .timingCurve(0.77, 0, 0.175, 1, duration: 0.24)
    }

    /// Apple's reposition spring: damping 1.0, response 0.4. No overshoot.
    static func settle(_ reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.4, bounce: 0)
    }
}

extension AnyTransition {
    /// Enters by rising into place, leaves by fading — exits are faster than entrances.
    /// Nothing scales from zero; real things never appear out of nothing.
    static func rise(_ reduce: Bool, distance: CGFloat = 10) -> AnyTransition {
        guard !reduce else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: distance)).combined(with: .scale(scale: 0.98)),
            removal: .opacity.combined(with: .scale(scale: 0.98)))
    }

    /// For list rows that are added and removed rapidly.
    static func row(_ reduce: Bool) -> AnyTransition {
        guard !reduce else { return .opacity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity)
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

enum Radius {
    static let control: CGFloat = 8
    static let card: CGFloat = 14
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

    func captionType() -> some View {
        font(.system(size: 11))
            .tracking(0.1)
    }
}

// MARK: - Surfaces

/// A grouped card. Sits on the opaque window canvas rather than stacking one
/// translucent surface on another, and carries a bright top edge so it reads as
/// a material catching light.
struct CardSurface: ViewModifier {
    var padding: CGFloat = Space.l
    var radius: CGFloat = Radius.card

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.primary.opacity(0.14), Color.primary.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
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
                .animation(Motion.press, value: hovering)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kind.color)
            Text(message)
                .captionType()
                .foregroundStyle(kind == .status ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
            .onAppear {
                guard !reduce else { return }
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

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String
    var onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionHeader(title: title, trailing: format(value))
            Slider(value: $value, in: range) { editing in
                if !editing { onCommit() }
            }
            .controlSize(.small)
            .tint(Palette.accent)
        }
    }
}
