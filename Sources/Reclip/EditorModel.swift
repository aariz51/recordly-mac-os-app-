import SwiftUI
import AVFoundation
import Combine

/// Which inspector section is showing. Recordly puts these in a left rail; the same
/// grouping, so a user of either app finds the same control in the same place.
enum InspectorSection: String, CaseIterable, Identifiable {
    case scene, clip, zoom, cursor, webcam, captions, annotations, audio, export
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scene: return "Scene"
        case .clip: return "Clip"
        case .zoom: return "Zoom"
        case .cursor: return "Cursor"
        case .webcam: return "Webcam"
        case .captions: return "Captions"
        case .annotations: return "Annotate"
        case .audio: return "Audio"
        case .export: return "Export"
        }
    }

    var symbol: String {
        switch self {
        case .scene: return "photo.on.rectangle.angled"
        case .clip: return "scissors"
        case .zoom: return "plus.magnifyingglass"
        case .cursor: return "cursorarrow"
        case .webcam: return "person.crop.circle"
        case .captions: return "captions.bubble"
        case .annotations: return "textformat"
        case .audio: return "waveform"
        case .export: return "square.and.arrow.up"
        }
    }
}

/// Which output the export bar produces.
enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4 = "MP4"
    case gif = "GIF"
    var id: String { rawValue }
    var symbol: String { self == .mp4 ? "film" : "photo.stack" }
}

/// Everything the editor is editing, in one observable place.
///
/// This exists because the settings are no longer a handful of `@State` values: they are a
/// document. Undo/redo, dirty tracking and `.reclip` save/load all need to see the whole
/// document at once, and `ReclipProject` is already an Equatable, Codable snapshot of
/// exactly that — so it doubles as the history entry and the file format.
@MainActor
final class EditorModel: ObservableObject {

    let sourceURL: URL

    // MARK: Document state

    @Published var style = StyleOptions()
    @Published var zoom = ZoomTimeline()
    @Published var cursorStyle = CursorStyle()
    @Published var captionSettings = CaptionSettings()
    @Published var captionCues: [CaptionCue] = []
    @Published var webcam = WebcamSettings()
    @Published var annotations: [Annotation] = []
    @Published var trimStart: Double = 0
    @Published var trimEnd: Double = 0
    @Published var speed: Double = 1.0
    @Published var speedRegions: [SpeedSegment] = []

    // MARK: Export settings (not part of the document — they describe the render, not the edit)

    @Published var format: ExportFormat = .mp4
    @Published var quality: ExportQuality = .high
    @Published var frameRate: MP4FrameRate = .fps30
    @Published var encoding: EncodingMode = .quality
    @Published var motionBlurAmount: Double = 0
    @Published var gifFPS: Double = 12
    @Published var gifSize: GifSize = .medium
    @Published var gifLoop = true
    @Published var gifBounce = false
    @Published var writeCaptionSidecars = false

    // MARK: Session state

    @Published var section: InspectorSection = .scene
    @Published var duration: Double = 0
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var selectedZoomID: UUID?
    @Published var selectedAnnotationID: UUID?
    /// Index into `speedRegions`; kept as an index because SpeedSegment has no identity.
    @Published var selectedSpeedIndex: Int?
    @Published var cursorTrack: CursorTrack?
    @Published var webcamFrames = WebcamFrames()
    @Published var isDirty = false
    @Published var canUndo = false
    @Published var canRedo = false

    private var history = EditorHistory<ReclipProject>()
    private var document = DocumentState()
    /// Suppresses history recording while an undo/redo is being applied.
    private var applyingHistory = false

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    // MARK: - Snapshot / restore

    func snapshot() -> ReclipProject {
        ReclipProject.capture(source: sourceURL, style: style, zoom: zoom, webcam: webcam,
                              annotations: annotations, trimStart: trimStart, trimEnd: trimEnd,
                              speed: speed, speedRegions: speedRegions, keepRanges: [],
                              cursorStyle: cursorStyle, captionCues: captionCues,
                              captionsEnabled: captionSettings.enabled,
                              captionSettings: captionSettings)
    }

    func restore(_ p: ReclipProject) {
        style = p.style()
        zoom = p.zoomTimeline()
        webcam = p.webcamSettings()
        annotations = p.annotationList()
        cursorStyle = p.cursorStyleValue()
        captionCues = p.captionCueList()
        captionSettings = p.captionSettingsValue()
        trimStart = p.trimStart
        trimEnd = p.trimEnd
        speed = p.speed
        speedRegions = p.speedRegions
    }

    /// Call after any committed edit. Pushes a history entry and refreshes the dirty flag.
    func record() {
        let snap = snapshot()
        history.record(snap, applyingHistory: applyingHistory)
        refreshFlags(snap)
    }

    /// Seeds the history with the opening state so the first edit has something to undo to.
    ///
    /// The opening state also becomes the clean baseline. Without that, `isDirty` compares
    /// against a nil baseline — which reads as "never saved" and lights the unsaved dot on a
    /// clip nobody has touched yet. Dirty should mean "changed since you opened it".
    func beginHistory() {
        let opening = snapshot()
        history.reset()
        history.record(opening)
        document.markSaved(opening)
        refreshFlags(opening)
    }

    private func refreshFlags(_ snap: ReclipProject) {
        canUndo = history.canUndo
        canRedo = history.canRedo
        isDirty = document.isDirty(snap)
    }

    @discardableResult
    func undo() -> Bool {
        guard let previous = history.undo(fallbackCurrent: snapshot()) else { return false }
        applyingHistory = true
        restore(previous)
        applyingHistory = false
        refreshFlags(previous)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let next = history.redo(fallbackCurrent: snapshot()) else { return false }
        applyingHistory = true
        restore(next)
        applyingHistory = false
        refreshFlags(next)
        return true
    }

    // MARK: - Project file

    var projectURL: URL { ReclipProject.projectURL(for: sourceURL) }

    func saveProject(to url: URL? = nil) throws {
        let snap = snapshot()
        try snap.save(to: url ?? projectURL)
        document.markSaved(snap)
        refreshFlags(snap)
    }

    func loadProject(from url: URL? = nil) throws {
        let p = try ReclipProject.load(from: url ?? projectURL)
        restore(p)
        document.markSaved(p)
        history.reset()
        history.record(p)
        refreshFlags(p)
    }

    var hasProjectOnDisk: Bool { FileManager.default.fileExists(atPath: projectURL.path) }

    // MARK: - Derived

    /// Trim range in SOURCE time, or nil when the whole clip is kept.
    func trimRange() -> CMTimeRange? {
        guard duration > 0, trimStart > 0.05 || trimEnd < duration - 0.05 else { return nil }
        return CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                           duration: CMTime(seconds: trimEnd - trimStart, preferredTimescale: 600))
    }

    var selectedZoom: ZoomRegion? {
        guard let id = selectedZoomID else { return nil }
        return zoom.regions.first { $0.id == id }
    }

    var selectedAnnotation: Annotation? {
        guard let id = selectedAnnotationID else { return nil }
        return annotations.first { $0.id == id }
    }

    /// Mutates the selected zoom region in place.
    func updateSelectedZoom(_ change: (inout ZoomRegion) -> Void) {
        guard let id = selectedZoomID, let idx = zoom.regions.firstIndex(where: { $0.id == id }) else { return }
        change(&zoom.regions[idx])
    }

    /// Mutates the selected annotation in place.
    func updateSelectedAnnotation(_ change: (inout Annotation) -> Void) {
        guard let id = selectedAnnotationID,
              let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&annotations[idx])
    }

    // MARK: - Timeline edits

    /// Adds a zoom region at the playhead, refusing to overlap an existing one.
    @discardableResult
    func addZoom(at time: Double, length: Double = 3, depth: ZoomDepth = .strong) -> Bool {
        let start = max(0, min(time, max(duration - 0.5, 0)))
        let end = min(duration, start + length)
        guard end - start > 0.2 else { return false }
        let span = TimelineModel.Span(start: start, end: end)
        let clash = zoom.regions.contains {
            TimelineModel.spansOverlap(span, TimelineModel.Span(start: $0.start, end: $0.end))
        }
        guard !clash else { return false }
        // Focus defaults to wherever the cursor was, which is nearly always what is meant.
        let focus = cursorTrack?.interpolated(at: (start + end) / 2) ?? CGPoint(x: 0.5, y: 0.5)
        let region = zoom.addRegion(start: start, end: end, depth: depth, focus: focus)
        selectedZoomID = region.id
        return true
    }

    func deleteSelectedZoom() {
        guard let id = selectedZoomID else { return }
        zoom.regions.removeAll { $0.id == id }
        selectedZoomID = nil
    }

    /// Adds a speed region at the playhead, refusing to overlap an existing one.
    @discardableResult
    func addSpeedRegion(at time: Double, length: Double = 3, speed value: Double = 2) -> Bool {
        let start = max(0, min(time, max(duration - 0.5, 0)))
        let end = min(duration, start + length)
        guard end - start > 0.2 else { return false }
        let span = TimelineModel.Span(start: start, end: end)
        let clash = speedRegions.contains {
            TimelineModel.spansOverlap(span, TimelineModel.Span(start: $0.start, end: $0.end))
        }
        guard !clash else { return false }
        speedRegions.append(SpeedSegment(start: start, end: end, speed: value))
        selectedSpeedIndex = speedRegions.count - 1
        return true
    }

    func deleteSelectedSpeedRegion() {
        guard let i = selectedSpeedIndex, speedRegions.indices.contains(i) else { return }
        speedRegions.remove(at: i)
        selectedSpeedIndex = nil
    }

    /// Splits the clip at `time` by trimming to whichever side is longer — the native
    /// analogue of Recordly's split, which cuts the timeline at the playhead.
    func splitAtPlayhead() {
        let t = playhead
        guard t > trimStart + 0.1, t < trimEnd - 0.1 else { return }
        if (t - trimStart) >= (trimEnd - t) { trimEnd = t } else { trimStart = t }
    }

    func addAnnotation(kind: Annotation.Kind, at time: Double) {
        var a = Annotation(text: kind == .text ? "Caption" : "", start: time, end: time + 3)
        a.kind = kind
        annotations.append(a)
        selectedAnnotationID = a.id
    }

    func deleteSelectedAnnotation() {
        guard let id = selectedAnnotationID else { return }
        annotations.removeAll { $0.id == id }
        selectedAnnotationID = nil
    }

    /// Re-decodes the webcam frames after the attached footage changes.
    func reloadWebcamFrames() async {
        let override = webcam.sourcePath.map { URL(fileURLWithPath: $0) }
        webcamFrames = await WebcamOverlay.load(for: sourceURL, override: override)
        if webcamFrames.isEmpty { webcam.enabled = false }
    }

    /// Tab-cycles the selection through annotations that overlap the playhead.
    func cycleAnnotation(forward: Bool) {
        let live = annotations.filter { playhead >= $0.start && playhead <= $0.end }
        guard !live.isEmpty else { return }
        guard let id = selectedAnnotationID, let i = live.firstIndex(where: { $0.id == id }) else {
            selectedAnnotationID = live.first?.id
            return
        }
        let n = live.count
        selectedAnnotationID = live[((i + (forward ? 1 : -1)) % n + n) % n].id
    }
}
