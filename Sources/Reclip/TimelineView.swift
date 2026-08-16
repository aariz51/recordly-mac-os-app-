import SwiftUI

/// The editor's timeline: a time axis plus one lane per kind of region.
///
/// Reclip had a single trim bar, which can say "keep this stretch" and nothing else. Zooms,
/// speed changes and annotations are all *time* facts, and a list in the inspector makes the
/// reader rebuild their arrangement in their head. Lanes show the arrangement directly —
/// where a zoom sits relative to a caption is a glance, not a comparison of two timestamps.
struct TimelineView: View {
    @ObservedObject var model: EditorModel
    let commit: () -> Void
    let scrub: (Double) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduce
    /// A drag in progress: which region, and which part of it is being moved.
    @State private var drag: DragTarget?

    private let laneHeight: CGFloat = 22
    private let axisHeight: CGFloat = 16

    enum Handle { case body, start, end }
    struct DragTarget: Equatable {
        enum Kind: Equatable { case zoom(UUID), speed(Int), annotation(UUID), trimStart, trimEnd }
        var kind: Kind
        var handle: Handle
        /// Offset from the grabbed point to the region's start, so the region doesn't jump.
        var grabOffset: Double
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            header
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                VStack(alignment: .leading, spacing: 3) {
                    axis(width: width)
                    lane(title: "Clip", width: width) { clipLane(width: width) }
                    lane(title: "Zoom", width: width) { zoomLane(width: width) }
                    lane(title: "Speed", width: width) { speedLane(width: width) }
                    lane(title: "Notes", width: width) { annotationLane(width: width) }
                }
                .overlay(alignment: .topLeading) { playhead(width: width) }
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: width))
            }
            .frame(height: axisHeight + (laneHeight + 3) * 4 + 6)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.s) {
            Text(TimelineModel.formatPlayheadTime(ms: model.playhead * 1000))
                .captionType()
                .monospacedDigit()
                .foregroundStyle(Palette.accent)
                .frame(width: 54, alignment: .leading)

            Text("\(TrimBar.timeLabel(model.trimEnd - model.trimStart)) kept of \(TrimBar.timeLabel(model.duration))")
                .captionType()
                .foregroundStyle(.secondary)

            Spacer(minLength: Space.s)

            Button {
                _ = model.addZoom(at: model.playhead)
                commit()
            } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                .help("Add a zoom region at the playhead (Z)")

            Button {
                _ = model.addSpeedRegion(at: model.playhead)
                commit()
            } label: { Label("Speed", systemImage: "speedometer") }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                .help("Add a speed region at the playhead (S)")

            Button {
                model.addAnnotation(kind: .text, at: model.playhead)
                commit()
            } label: { Label("Note", systemImage: "textformat") }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                .help("Add a text annotation at the playhead (A)")

            Button {
                model.splitAtPlayhead()
                commit()
            } label: { Label("Split", systemImage: "scissors") }
                .buttonStyle(ActionButtonStyle(variant: .quiet, fullWidth: false))
                .help("Trim to the playhead (C)")
        }
    }

    // MARK: - Lanes

    private func lane<Content: View>(title: String, width: CGFloat,
                                     @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .frame(height: laneHeight)
            content()
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
                .allowsHitTesting(false)
        }
        .frame(height: laneHeight)
    }

    /// The kept range, with draggable trim handles at each end.
    private func clipLane(width: CGFloat) -> some View {
        let x0 = x(model.trimStart, width), x1 = x(model.trimEnd, width)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Palette.success.opacity(0.28))
                .frame(width: max(x1 - x0, 2), height: laneHeight)
                .offset(x: x0)
            handleBar(at: x0, kind: .trimStart, label: "Trim start")
            handleBar(at: x1, kind: .trimEnd, label: "Trim end")
        }
    }

    private func zoomLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(model.zoom.regions) { r in
                regionBlock(start: r.start, end: r.end, width: width,
                            color: Palette.accent,
                            selected: model.selectedZoomID == r.id,
                            label: String(format: "%.2g×", r.scale),
                            kind: .zoom(r.id)) {
                    model.selectedZoomID = r.id
                    model.section = .zoom
                }
            }
        }
    }

    private func speedLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(model.speedRegions.indices, id: \.self) { i in
                let s = model.speedRegions[i]
                regionBlock(start: s.start, end: s.end, width: width,
                            color: Palette.warning,
                            selected: model.selectedSpeedIndex == i,
                            label: String(format: "%.2g×", s.speed),
                            kind: .speed(i)) {
                    model.selectedSpeedIndex = i
                    model.section = .clip
                }
            }
        }
    }

    private func annotationLane(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            ForEach(model.annotations) { a in
                regionBlock(start: a.start, end: a.end, width: width,
                            color: Color(red: 0.36, green: 0.62, blue: 0.98),
                            selected: model.selectedAnnotationID == a.id,
                            label: a.kind == .text ? a.text : a.kind.rawValue,
                            kind: .annotation(a.id)) {
                    model.selectedAnnotationID = a.id
                    model.section = .annotations
                }
            }
        }
    }

    /// One draggable region block: the body moves it, the edges resize it.
    private func regionBlock(start: Double, end: Double, width: CGFloat,
                             color: Color, selected: Bool, label: String,
                             kind: DragTarget.Kind, select: @escaping () -> Void) -> some View {
        let x0 = x(start, width), x1 = x(end, width)
        let w = max(x1 - x0, 6)
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(color.opacity(selected ? 0.85 : 0.55))
            .frame(width: w, height: laneHeight - 4)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.white.opacity(selected ? 0.9 : 0), lineWidth: 1))
            .overlay(
                Text(label)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 3))
            .offset(x: x0)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        if drag == nil {
                            select()
                            // The grabbed third decides whether this is a move or a resize.
                            let local = v.startLocation.x - x0
                            let handle: Handle = local < 8 ? .start : (local > w - 8 ? .end : .body)
                            drag = DragTarget(kind: kind, handle: handle,
                                              grabOffset: time(v.startLocation.x, width) - start)
                        }
                        applyDrag(v.location.x, width: width)
                    }
                    .onEnded { _ in drag = nil; commit() }
            )
            .onTapGesture { select() }
            .help(label)
    }

    private func handleBar(at px: CGFloat, kind: DragTarget.Kind, label: String) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Palette.success)
            .frame(width: 5, height: laneHeight)
            .offset(x: px - 2.5)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if drag == nil { drag = DragTarget(kind: kind, handle: .body, grabOffset: 0) }
                        // Trim handles are dragged in the lane's own coordinate space.
                        applyTrim(kind: kind, px: px + v.translation.width)
                    }
                    .onEnded { _ in drag = nil; commit() }
            )
            .help(label)
            .accessibilityLabel(label)
    }

    // MARK: - Axis and playhead

    private func axis(width: CGFloat) -> some View {
        // Tick spacing is chosen so labels never collide: aim for one every ~70pt.
        let target = Double(width / 70)
        let raw = model.duration / max(target, 1)
        let steps: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let step = steps.first { $0 >= raw } ?? 600
        let count = Int(model.duration / step)
        return ZStack(alignment: .topLeading) {
            ForEach(0...max(count, 0), id: \.self) { i in
                let t = Double(i) * step
                if t <= model.duration {
                    Text(TimelineModel.formatTimeLabel(ms: t * 1000, intervalMs: step * 1000))
                        .font(.system(size: 8.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .offset(x: x(t, width) + 2)
                }
            }
        }
        .frame(height: axisHeight, alignment: .topLeading)
    }

    private func playhead(width: CGFloat) -> some View {
        Rectangle()
            .fill(.white)
            .frame(width: 1.5)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .offset(x: x(model.playhead, width))
            .allowsHitTesting(false)
    }

    // MARK: - Geometry

    private func x(_ t: Double, _ width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(min(max(t / model.duration, 0), 1)) * width
    }

    private func time(_ px: CGFloat, _ width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(px / width), 0), 1) * model.duration
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard drag == nil else { return }
                scrub(time(v.location.x, width))
            }
    }

    // MARK: - Drag application

    private func applyTrim(kind: DragTarget.Kind, px: CGFloat) {
        // The lane's width isn't known here, so trim uses the same mapping via the stored
        // playhead scale — recomputed from the current geometry at call time.
        switch kind {
        case .trimStart:
            model.trimStart = min(max(0, timeFromGlobal(px)), model.trimEnd - 0.1)
        case .trimEnd:
            model.trimEnd = max(min(model.duration, timeFromGlobal(px)), model.trimStart + 0.1)
        default: break
        }
    }

    /// Trim handles are offset in points inside the same lane the regions use, so they share
    /// the lane width captured at layout time.
    @State private var laneWidth: CGFloat = 1
    private func timeFromGlobal(_ px: CGFloat) -> Double { time(px, laneWidth) }

    private func applyDrag(_ px: CGFloat, width: CGFloat) {
        laneWidth = width
        guard let d = drag else { return }
        let t = time(px, width)
        switch d.kind {
        case .zoom(let id):
            guard let i = model.zoom.regions.firstIndex(where: { $0.id == id }) else { return }
            move(&model.zoom.regions[i].start, &model.zoom.regions[i].end, to: t, drag: d)
        case .speed(let i):
            guard model.speedRegions.indices.contains(i) else { return }
            move(&model.speedRegions[i].start, &model.speedRegions[i].end, to: t, drag: d)
        case .annotation(let id):
            guard let i = model.annotations.firstIndex(where: { $0.id == id }) else { return }
            move(&model.annotations[i].start, &model.annotations[i].end, to: t, drag: d)
        case .trimStart, .trimEnd:
            applyTrim(kind: d.kind, px: px)
        }
    }

    /// Moves or resizes a [start, end] pair, keeping it inside the clip and non-degenerate.
    private func move(_ start: inout Double, _ end: inout Double, to t: Double, drag d: DragTarget) {
        let minLen = 0.2
        switch d.handle {
        case .body:
            let length = end - start
            let newStart = min(max(0, t - d.grabOffset), max(0, model.duration - length))
            start = newStart
            end = newStart + length
        case .start:
            start = min(max(0, t), end - minLen)
        case .end:
            end = max(min(model.duration, t), start + minLen)
        }
    }
}
