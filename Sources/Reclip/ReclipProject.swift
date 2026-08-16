import Foundation
import CoreGraphics

/// A saved editing session: the source recording plus every polish setting, so work can
/// be reopened later. Persisted as a `.reclip` JSON file (Recordly's `.recordia` analogue).
struct ReclipProject: Codable, Equatable {
    var version = 1
    var sourceFileName: String

    var background: BG
    var backgroundImageB64: String? = nil
    var paddingFraction: Double
    var cornerRadiusFraction: Double
    var squircleCorners: Bool = false
    var shadowOpacity: Double
    var shadowRadius: Double
    var backgroundBlur: Double
    var aspect: String
    var deviceFrame: String = DeviceFrame.none.rawValue
    var muteAudio: Bool = false
    var audioVolume: Double = 1.0
    var maxOutputHeight: Int? = nil
    var crop: Crop
    var padInsets: Pad? = nil

    var zoomRegions: [Zoom]
    var zoomEasing: String = ZoomEasing.smooth.rawValue
    var zoomRamp: Double = 0.5
    var webcam: Cam
    var captions: [Cap]

    var cursor: CursorDTO = CursorDTO()
    var captionCues: [CueDTO] = []
    var captionsEnabled: Bool = false

    var trimStart: Double
    var trimEnd: Double
    var speed: Double
    var speedRegions: [SpeedSegment] = []

    // MARK: Nested codable DTOs

    struct CursorDTO: Codable, Equatable {
        var enabled = false
        var kind = CursorStyle.Kind.arrow.rawValue
        var size = 1.0
    }
    struct CueDTO: Codable, Equatable { var text: String; var start: Double; var end: Double }

    struct BG: Codable, Equatable {
        var kind: String            // "solid" | "gradient"
        var solid: [Double]?
        var top: [Double]?
        var bottom: [Double]?

        static func from(_ b: StyleOptions.Background) -> BG {
            switch b {
            case .solid(let r, let g, let bl): return BG(kind: "solid", solid: [r, g, bl])
            case .gradient(let t, let bo): return BG(kind: "gradient", top: [t.0, t.1, t.2], bottom: [bo.0, bo.1, bo.2])
            }
        }
        func toBackground() -> StyleOptions.Background {
            if kind == "solid", let s = solid, s.count == 3 {
                return .solid(red: s[0], green: s[1], blue: s[2])
            }
            if let t = top, let b = bottom, t.count == 3, b.count == 3 {
                return .gradient(topRGB: (t[0], t[1], t[2]), bottomRGB: (b[0], b[1], b[2]))
            }
            return .gradient(topRGB: (0.39, 0.36, 1.0), bottomRGB: (0.66, 0.33, 0.97))
        }
    }
    struct Crop: Codable, Equatable { var top = 0.0; var bottom = 0.0; var left = 0.0; var right = 0.0 }
    struct Pad: Codable, Equatable { var top = 0.06; var bottom = 0.06; var left = 0.06; var right = 0.06 }
    struct Zoom: Codable, Equatable { var start: Double; var end: Double; var scale: Double; var fx: Double; var fy: Double }
    struct Cam: Codable, Equatable {
        var enabled: Bool; var corner: String; var size: Double; var margin: Double
        var roundness: Double; var mirror: Bool; var shadow: Bool
        var aspectRatio: Double = 1.0
        var cropZoom: Double = 1.0
        var cropOffsetX: Double = 0
        var cropOffsetY: Double = 0
        var timeOffset: Double = 0
        var reactToZoom: Bool = false
    }
    struct Cap: Codable, Equatable {
        var text: String; var start: Double; var end: Double
        var x: Double; var y: Double; var fontFraction: Double
        var kind: String = Annotation.Kind.text.rawValue
        var rw: Double = 0.3; var rh: Double = 0.2
        var blurRadius: Double = 24
        var color: [Double] = [0, 0, 0, 0.85]
        var imageB64: String? = nil
        var bold: Bool = true
        var textColor: [Double] = [1, 1, 1, 1]
        var showBg: Bool = true
        var bgColor: [Double] = [0, 0, 0, 0.55]
        var arrowAngle: Double = 0
    }

    // MARK: Capture / restore

    static func capture(source: URL, style: StyleOptions, zoom: ZoomTimeline,
                        webcam: WebcamSettings, annotations: [Annotation],
                        trimStart: Double, trimEnd: Double, speed: Double,
                        speedRegions: [SpeedSegment] = [],
                        cursorStyle: CursorStyle = CursorStyle(),
                        captionCues: [CaptionCue] = [],
                        captionsEnabled: Bool = false) -> ReclipProject {
        ReclipProject(
            sourceFileName: source.lastPathComponent,
            background: .from(style.background),
            backgroundImageB64: style.backgroundImage?.base64EncodedString(),
            paddingFraction: style.paddingFraction,
            cornerRadiusFraction: style.cornerRadiusFraction,
            squircleCorners: style.squircleCorners,
            shadowOpacity: style.shadowOpacity,
            shadowRadius: style.shadowRadius,
            backgroundBlur: style.backgroundBlur,
            aspect: style.aspect.rawValue,
            deviceFrame: style.deviceFrame.rawValue,
            muteAudio: style.muteAudio,
            audioVolume: style.audioVolume,
            maxOutputHeight: style.maxOutputHeight,
            crop: Crop(top: style.crop.top, bottom: style.crop.bottom, left: style.crop.left, right: style.crop.right),
            padInsets: style.paddingInsets.map { Pad(top: $0.top, bottom: $0.bottom, left: $0.left, right: $0.right) },
            zoomRegions: zoom.regions.map { Zoom(start: $0.start, end: $0.end, scale: Double($0.scale), fx: $0.focus.x, fy: $0.focus.y) },
            zoomEasing: zoom.easing.rawValue,
            zoomRamp: zoom.ramp,
            webcam: Cam(enabled: webcam.enabled, corner: webcam.corner.rawValue, size: webcam.sizeFraction,
                        margin: webcam.marginFraction, roundness: webcam.roundness, mirror: webcam.mirror,
                        shadow: webcam.shadow, aspectRatio: webcam.aspectRatio, cropZoom: webcam.cropZoom,
                        cropOffsetX: webcam.cropOffsetX, cropOffsetY: webcam.cropOffsetY,
                        timeOffset: webcam.timeOffset, reactToZoom: webcam.reactToZoom),
            captions: annotations.map {
                Cap(text: $0.text, start: $0.start, end: $0.end, x: $0.position.x, y: $0.position.y,
                    fontFraction: $0.fontFraction, kind: $0.kind.rawValue,
                    rw: $0.regionSize.width, rh: $0.regionSize.height, blurRadius: $0.blurRadius,
                    color: $0.colorRGBA, imageB64: $0.imageData?.base64EncodedString(),
                    bold: $0.bold, textColor: $0.textColorRGBA, showBg: $0.showBackground, bgColor: $0.bgColorRGBA,
                    arrowAngle: $0.arrowAngle)
            },
            cursor: CursorDTO(enabled: cursorStyle.enabled, kind: cursorStyle.kind.rawValue, size: cursorStyle.size),
            captionCues: captionCues.map { CueDTO(text: $0.text, start: $0.start, end: $0.end) },
            captionsEnabled: captionsEnabled,
            trimStart: trimStart, trimEnd: trimEnd, speed: speed, speedRegions: speedRegions)
    }

    func style() -> StyleOptions {
        var s = StyleOptions()
        s.background = background.toBackground()
        s.backgroundImage = backgroundImageB64.flatMap { Data(base64Encoded: $0) }
        s.paddingFraction = paddingFraction
        s.cornerRadiusFraction = cornerRadiusFraction
        s.squircleCorners = squircleCorners
        s.shadowOpacity = shadowOpacity
        s.shadowRadius = shadowRadius
        s.backgroundBlur = backgroundBlur
        s.aspect = StyleOptions.Aspect(rawValue: aspect) ?? .source
        s.deviceFrame = DeviceFrame(rawValue: deviceFrame) ?? .none
        s.muteAudio = muteAudio
        s.audioVolume = audioVolume
        s.maxOutputHeight = maxOutputHeight
        s.crop = StyleOptions.CropInsets(top: crop.top, bottom: crop.bottom, left: crop.left, right: crop.right)
        s.paddingInsets = padInsets.map { StyleOptions.PaddingInsets(top: $0.top, bottom: $0.bottom, left: $0.left, right: $0.right) }
        return s
    }

    func zoomTimeline() -> ZoomTimeline {
        ZoomTimeline(regions: zoomRegions.map {
            ZoomRegion(start: $0.start, end: $0.end, scale: CGFloat($0.scale), focus: CGPoint(x: $0.fx, y: $0.fy))
        }, ramp: zoomRamp, easing: ZoomEasing(rawValue: zoomEasing) ?? .smooth)
    }

    func webcamSettings() -> WebcamSettings {
        var w = WebcamSettings()
        w.enabled = webcam.enabled
        w.corner = WebcamSettings.Corner(rawValue: webcam.corner) ?? .bottomTrailing
        w.sizeFraction = webcam.size
        w.aspectRatio = webcam.aspectRatio
        w.cropZoom = webcam.cropZoom
        w.cropOffsetX = webcam.cropOffsetX
        w.cropOffsetY = webcam.cropOffsetY
        w.timeOffset = webcam.timeOffset
        w.reactToZoom = webcam.reactToZoom
        w.marginFraction = webcam.margin
        w.roundness = webcam.roundness
        w.mirror = webcam.mirror
        w.shadow = webcam.shadow
        return w
    }

    func annotationList() -> [Annotation] {
        captions.map { c in
            var a = Annotation(text: c.text, start: c.start, end: c.end,
                               position: CGPoint(x: c.x, y: c.y), fontFraction: c.fontFraction)
            a.kind = Annotation.Kind(rawValue: c.kind) ?? .text
            a.regionSize = CGSize(width: c.rw, height: c.rh)
            a.blurRadius = c.blurRadius
            a.colorRGBA = c.color
            a.imageData = c.imageB64.flatMap { Data(base64Encoded: $0) }
            a.bold = c.bold
            a.textColorRGBA = c.textColor
            a.showBackground = c.showBg
            a.bgColorRGBA = c.bgColor
            a.arrowAngle = c.arrowAngle
            return a
        }
    }

    func cursorStyleValue() -> CursorStyle {
        var cs = CursorStyle()
        cs.enabled = cursor.enabled
        cs.kind = CursorStyle.Kind(rawValue: cursor.kind) ?? .arrow
        cs.size = cursor.size
        return cs
    }

    func captionCueList() -> [CaptionCue] {
        captionCues.map { CaptionCue(text: $0.text, start: $0.start, end: $0.end) }
    }

    // MARK: Persistence

    static func projectURL(for movie: URL) -> URL {
        movie.deletingPathExtension().appendingPathExtension("reclip")
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url)
    }

    static func load(from url: URL) throws -> ReclipProject {
        try JSONDecoder().decode(ReclipProject.self, from: Data(contentsOf: url))
    }

    /// Whether this project differs from a previously-saved baseline (Recordly's
    /// `hasUnsavedProjectChanges`). ReclipProject is Equatable over all persisted state,
    /// so this is an exact structural comparison; a nil baseline means "never saved".
    func hasUnsavedChanges(since saved: ReclipProject?) -> Bool {
        guard let saved else { return true }
        return self != saved
    }
}

/// Tracks the last-saved baseline so the editor can show an "unsaved changes" indicator
/// and prompt before discarding — a port of Recordly's project dirty-state tracking.
struct DocumentState: Equatable {
    private(set) var savedBaseline: ReclipProject?

    var hasEverBeenSaved: Bool { savedBaseline != nil }

    func isDirty(_ current: ReclipProject) -> Bool {
        current.hasUnsavedChanges(since: savedBaseline)
    }

    /// Records the just-persisted project as the clean baseline.
    mutating func markSaved(_ project: ReclipProject) { savedBaseline = project }
}
