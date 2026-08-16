import SwiftUI
import AppKit

// MARK: - Colour bridging
//
// The renderers store colours as `[Double]` RGBA because they cross into Core Image and
// into the `.reclip` file, neither of which wants an NSColor. The UI needs a `Color`
// binding, so the conversion lives here rather than being re-spelled at every call site.

extension Color {
    init(rgba: [Double]) {
        let c = rgba.count >= 3 ? rgba : [1, 1, 1, 1]
        self.init(.sRGB, red: c[0], green: c[1], blue: c[2],
                  opacity: c.count > 3 ? c[3] : 1)
    }

    /// RGBA components in the sRGB space. Falls back to opaque white when a colour can't
    /// be converted (a system/dynamic colour, for instance).
    var rgbaComponents: [Double] {
        guard let converted = NSColor(self).usingColorSpace(.sRGB) else { return [1, 1, 1, 1] }
        return [Double(converted.redComponent), Double(converted.greenComponent),
                Double(converted.blueComponent), Double(converted.alphaComponent)]
    }
}

/// A colour well that reads and writes the renderers' `[Double]` RGBA arrays.
struct ColorRow: View {
    let title: String
    @Binding var rgba: [Double]
    var supportsOpacity = true
    var onCommit: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .controlLabelType()
            Spacer(minLength: Space.s)
            ColorPicker("", selection: Binding(
                get: { Color(rgba: rgba) },
                set: { rgba = $0.rgbaComponents; onCommit() }
            ), supportsOpacity: supportsOpacity)
            .labelsHidden()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

// MARK: - Pickers
//
// Two shapes for the same job. A segmented control shows every option at once, which is
// right up to about four; past that it shrinks each label past legibility, so the same
// choice becomes a menu. Picking per control rather than per screen keeps the inspector
// scannable without making long lists unusable.

struct SegmentedRow<T: Hashable & Identifiable>: View {
    let title: String
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            ControlLabel(title: title)
            Picker("", selection: Binding(get: { selection },
                                          set: { selection = $0; onCommit() })) {
                ForEach(options) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

struct MenuRow<T: Hashable & Identifiable>: View {
    let title: String
    @Binding var selection: T
    let options: [T]
    let label: (T) -> String
    var onCommit: () -> Void = {}

    var body: some View {
        HStack {
            Text(title).controlLabelType()
            Spacer(minLength: Space.s)
            Picker("", selection: Binding(get: { selection },
                                          set: { selection = $0; onCommit() })) {
                ForEach(options) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 150)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

// MARK: - Position grid
//
// A 3×3 of the actual corners, because the overlay's position is a spatial fact and a
// spatial control answers it without translation. The existing four-corner `CornerPicker`
// stays for the places that only offer corners.

struct PositionGrid: View {
    @Binding var corner: WebcamSettings.Corner
    var onChange: () -> Void

    private let layout: [[WebcamSettings.Corner]] = [
        [.topLeading, .topCenter, .topTrailing],
        [.centerLeading, .center, .centerTrailing],
        [.bottomLeading, .bottomCenter, .bottomTrailing],
    ]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(layout.indices, id: \.self) { r in
                HStack(spacing: 3) {
                    ForEach(layout[r], id: \.self) { c in
                        Button {
                            corner = c
                            onChange()
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(corner == c ? Palette.accent : Color.primary.opacity(0.10))
                                .frame(width: 20, height: 14)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                        }
                        .buttonStyle(PressableStyle())
                        .help(c.rawValue)
                        .accessibilityLabel(c.rawValue)
                        .accessibilityAddTraits(corner == c ? [.isSelected] : [])
                    }
                }
            }
        }
        .padding(5)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
    }
}

// MARK: - Focus pad
//
// Zoom focus is a point on the frame. Two number fields describe that point; a pad *is*
// that point, so the control matches the thing it sets.

struct FocusPad: View {
    @Binding var focus: CGPoint
    var aspect: CGFloat = 16.0 / 9.0
    var onCommit: () -> Void

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))

                // Rule-of-thirds guides, so a focus point can be placed deliberately.
                Path { p in
                    for f in [1.0 / 3, 2.0 / 3] {
                        p.move(to: CGPoint(x: size.width * f, y: 0))
                        p.addLine(to: CGPoint(x: size.width * f, y: size.height))
                        p.move(to: CGPoint(x: 0, y: size.height * f))
                        p.addLine(to: CGPoint(x: size.width, y: size.height * f))
                    }
                }
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)

                Circle()
                    .fill(Palette.accent)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .position(x: CGFloat(focus.x) * size.width,
                              y: CGFloat(focus.y) * size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        focus = CGPoint(x: min(max(v.location.x / size.width, 0), 1),
                                        y: min(max(v.location.y / size.height, 0), 1))
                    }
                    .onEnded { _ in onCommit() }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        .accessibilityLabel("Zoom focus point")
        .accessibilityValue("\(Int(focus.x * 100)) percent across, \(Int(focus.y * 100)) percent down")
    }
}

// MARK: - Crop pad
//
// Four sliders can express a crop, but they can't show one. The pad draws the surviving
// region against the whole frame, so the numbers stop being the only readout.

struct CropPad: View {
    @Binding var crop: StyleOptions.CropInsets
    var aspect: CGFloat = 16.0 / 9.0
    var onCommit: () -> Void

    /// Which edge a drag is moving, decided once at gesture start so a fast drag can't
    /// hop to a different edge mid-gesture.
    @State private var activeEdge: Edge?

    enum Edge { case top, bottom, leading, trailing }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let rect = CGRect(x: CGFloat(crop.left) * size.width,
                              y: CGFloat(crop.top) * size.height,
                              width: size.width * CGFloat(1 - crop.left - crop.right),
                              height: size.height * CGFloat(1 - crop.top - crop.bottom))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .fill(Color.primary.opacity(0.07))

                // The kept region, bright against the dimmed remainder.
                Rectangle()
                    .fill(Palette.accent.opacity(0.16))
                    .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                    .overlay(Rectangle().strokeBorder(Palette.accent, lineWidth: 1.5))
                    .offset(x: rect.minX, y: rect.minY)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if activeEdge == nil { activeEdge = nearestEdge(to: v.startLocation, in: size, rect: rect) }
                        apply(v.location, in: size)
                    }
                    .onEnded { _ in activeEdge = nil; onCommit() }
            )
        }
        .aspectRatio(aspect, contentMode: .fit)
        .accessibilityLabel("Crop region")
    }

    private func nearestEdge(to p: CGPoint, in size: CGSize, rect: CGRect) -> Edge {
        let d: [(Edge, CGFloat)] = [
            (.top, abs(p.y - rect.minY)), (.bottom, abs(p.y - rect.maxY)),
            (.leading, abs(p.x - rect.minX)), (.trailing, abs(p.x - rect.maxX)),
        ]
        return d.min { $0.1 < $1.1 }?.0 ?? .top
    }

    private func apply(_ p: CGPoint, in size: CGSize) {
        // Each edge is capped so it can never cross its opposite: a crop that inverts is
        // not a smaller frame, it is an empty one.
        func clamp(_ v: Double, _ opposite: Double) -> Double { min(max(v, 0), max(0, 0.95 - opposite)) }
        switch activeEdge {
        case .top:      crop.top = clamp(Double(p.y / size.height), crop.bottom)
        case .bottom:   crop.bottom = clamp(Double(1 - p.y / size.height), crop.top)
        case .leading:  crop.left = clamp(Double(p.x / size.width), crop.right)
        case .trailing: crop.right = clamp(Double(1 - p.x / size.width), crop.left)
        case .none:     break
        }
    }
}

// MARK: - Level meter

/// Live input level, drawn as a row of segments. A single bar answers "is it loud?";
/// segments also answer "is it clipping?", which is the question that matters before a take.
struct LevelMeter: View {
    /// 0…100, as `AudioLevelMeter.normalize` produces.
    let level: Double
    var segments = 14

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let threshold = Double(i) / Double(segments) * 100
                let lit = level >= threshold
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(lit ? color(for: i) : Color.primary.opacity(0.10))
                    .frame(height: 6)
            }
        }
        .animation(Motion.hover, value: level)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level)) percent")
    }

    private func color(for index: Int) -> Color {
        let f = Double(index) / Double(segments)
        if f > 0.9 { return Palette.accent }
        if f > 0.72 { return Palette.warning }
        return Palette.success
    }
}

// MARK: - Disclosure group
//
// The advanced controls in a section are real, but they are not what the section is for.
// A closed group keeps the common case a short list and the deep case one click away.

struct AdvancedGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withAnimation(Motion.move(reduce)) { open.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title).controlLabelType()
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.99))

            if open {
                VStack(alignment: .leading, spacing: Space.m) {
                    content()
                }
                .padding(.leading, Space.m)
                .transition(.rise(reduce, distance: 6))
            }
        }
    }
}

// MARK: - Section rail
//
// Eight sections is past what a scrolling stack can hold legibly, so the sections become a
// rail. It also makes the set of sections itself visible — you can see there *is* a cursor
// section without scrolling to find out.

struct SectionRail: View {
    @Binding var section: InspectorSection

    var body: some View {
        VStack(spacing: 2) {
            ForEach(InspectorSection.allCases) { s in
                Button {
                    section = s
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: s.symbol)
                            .font(.system(size: 14, weight: .medium))
                        Text(s.title)
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundStyle(section == s ? Palette.accent : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.inset, style: .continuous)
                            .fill(Palette.accent.opacity(section == s ? 0.12 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle(scale: 0.96))
                .help(s.title)
                .accessibilityLabel(s.title)
                .accessibilityAddTraits(section == s ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s)
        .padding(.horizontal, 5)
        .frame(width: 62)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1)
        }
    }
}

// MARK: - Small helpers

/// A one-line row with a trailing button — "Generate captions", "Reset", and friends.
struct ActionRow: View {
    let title: String
    var subtitle: String?
    let actionTitle: String
    var symbol: String?
    var enabled = true
    var busy = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).controlLabelType()
                if let subtitle {
                    Text(subtitle)
                        .captionType()
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s)
            Button(action: action) {
                if busy {
                    ProgressView().controlSize(.small)
                } else if let symbol {
                    Label(actionTitle, systemImage: symbol)
                } else {
                    Text(actionTitle)
                }
            }
            .buttonStyle(ActionButtonStyle(variant: .secondary, fullWidth: false))
            .disabled(!enabled || busy)
        }
    }
}

/// An empty-state line for a section that has nothing to configure yet.
struct EmptyHint: View {
    let symbol: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(message)
                .captionType()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Space.m)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: Radius.inset, style: .continuous))
    }
}
