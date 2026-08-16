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
    var normalizeAudio: Bool = false
    var audioVolumeRegions: [AudioVolumeRegion] = []
    var micProfile: String = MicProfile.raw.rawValue
    var audioRouting: AudioRouting? = nil
    var maxOutputHeight: Int? = nil
    var crop: Crop
    var padInsets: Pad? = nil

    var zoomRegions: [Zoom]
    var zoomEasing: String = ZoomEasing.smooth.rawValue
    var zoomRamp: Double = 0.5
    // Split in/out timing + connected-zoom glide (nil = fall back to zoomRamp/zoomEasing).
    var zoomInDuration: Double? = nil
    var zoomOutDuration: Double? = nil
    var zoomInEasing: String? = nil
    var zoomOutEasing: String? = nil
    var connectZooms: Bool = false
    var connectedGap: Double = 1.5
    var connectedDuration: Double = 1.0
    var connectedEasing: String = ZoomEasing.glide.rawValue
    var webcam: Cam
    var captions: [Cap]

    var cursor: CursorDTO = CursorDTO()
    var captionCues: [CueDTO] = []
    var captionsEnabled: Bool = false
    var captionStyle: CaptionStyleDTO = CaptionStyleDTO()

    var trimStart: Double
    var trimEnd: Double
    var speed: Double
    var speedRegions: [SpeedSegment] = []
    var keepRanges: [[Double]] = []

    // MARK: Nested codable DTOs

    struct CursorDTO: Codable, Equatable {
        var enabled = false
        var kind = CursorStyle.Kind.arrow.rawValue
        var size = 1.0
        var spotlight = false
        var spotlightRadius = 0.18
        var spotlightDim = 0.55
        var showClicks = true
        // Motion + click-effect settings (defaulted, so older .reclip files still decode).
        var smoothing = 0.67
        var sway = 0.4
        var clickBounce = 2.5
        var clickBounceDuration = 350.0
        var clickEffect = CursorClickEffectStyle.ripple.rawValue
        var clickEffectRGB: [Double] = [1, 1, 1]
        var clickEffectScale = 1.0
        var clickEffectOpacity = 1.0
        var clickEffectDurationMs = 600.0
    }
    struct CueDTO: Codable, Equatable { var text: String; var start: Double; var end: Double }

    /// Burned-in caption styling.
    struct CaptionStyleDTO: Codable, Equatable {
        var fontFraction = 0.05
        var fontName = ""
        var textRGBA: [Double] = [1, 1, 1, 1]
        var bottomOffsetFraction = 0.06
        var maxWidthFraction = 0.72
        var backgroundOpacity = 0.75
        var cornerRadiusFraction = 0.02
        var animation = CaptionAnimation.fade.rawValue
        var animationDuration = 0.22
    }

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
        /// User-attached webcam footage, when the clip isn't using its recorded sidecar.
        var sourcePath: String? = nil
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
        var fontName: String = ""
        var textColor: [Double] = [1, 1, 1, 1]
        var showBg: Bool = true
        var bgColor: [Double] = [0, 0, 0, 0.55]
        var arrowAngle: Double = 0
        var fadeDuration: Double = 0
    }

    // MARK: Capture / restore

    static func capture(source: URL, style: StyleOptions, zoom: ZoomTimeline,
                        webcam: WebcamSettings, annotations: [Annotation],
                        trimStart: Double, trimEnd: Double, speed: Double,
                        speedRegions: [SpeedSegment] = [],
                        keepRanges: [ClosedRange<Double>] = [],
                        cursorStyle: CursorStyle = CursorStyle(),
                        captionCues: [CaptionCue] = [],
                        captionsEnabled: Bool = false,
                        captionSettings: CaptionSettings = CaptionSettings()) -> ReclipProject {
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
            normalizeAudio: style.normalizeAudio,
            audioVolumeRegions: style.audioVolumeRegions,
            micProfile: style.micProfile.rawValue,
            audioRouting: style.audioRouting,
            maxOutputHeight: style.maxOutputHeight,
            crop: Crop(top: style.crop.top, bottom: style.crop.bottom, left: style.crop.left, right: style.crop.right),
            padInsets: style.paddingInsets.map { Pad(top: $0.top, bottom: $0.bottom, left: $0.left, right: $0.right) },
            zoomRegions: zoom.regions.map { Zoom(start: $0.start, end: $0.end, scale: Double($0.scale), fx: $0.focus.x, fy: $0.focus.y) },
            zoomEasing: zoom.easing.rawValue,
            zoomRamp: zoom.ramp,
            zoomInDuration: zoom.inDuration,
            zoomOutDuration: zoom.outDuration,
            zoomInEasing: zoom.inEasing?.rawValue,
            zoomOutEasing: zoom.outEasing?.rawValue,
            connectZooms: zoom.connectZooms,
            connectedGap: zoom.connectedGap,
            connectedDuration: zoom.connectedDuration,
            connectedEasing: zoom.connectedEasing.rawValue,
            webcam: Cam(enabled: webcam.enabled, corner: webcam.corner.rawValue, size: webcam.sizeFraction,
                        margin: webcam.marginFraction, roundness: webcam.roundness, mirror: webcam.mirror,
                        shadow: webcam.shadow, aspectRatio: webcam.aspectRatio, cropZoom: webcam.cropZoom,
                        cropOffsetX: webcam.cropOffsetX, cropOffsetY: webcam.cropOffsetY,
                        timeOffset: webcam.timeOffset, reactToZoom: webcam.reactToZoom,
                        sourcePath: webcam.sourcePath),
            captions: annotations.map {
                Cap(text: $0.text, start: $0.start, end: $0.end, x: $0.position.x, y: $0.position.y,
                    fontFraction: $0.fontFraction, kind: $0.kind.rawValue,
                    rw: $0.regionSize.width, rh: $0.regionSize.height, blurRadius: $0.blurRadius,
                    color: $0.colorRGBA, imageB64: $0.imageData?.base64EncodedString(),
                    bold: $0.bold, fontName: $0.fontName, textColor: $0.textColorRGBA, showBg: $0.showBackground, bgColor: $0.bgColorRGBA,
                    arrowAngle: $0.arrowAngle, fadeDuration: $0.fadeDuration)
            },
            cursor: CursorDTO(enabled: cursorStyle.enabled, kind: cursorStyle.kind.rawValue, size: cursorStyle.size,
                              spotlight: cursorStyle.spotlight, spotlightRadius: cursorStyle.spotlightRadius,
                              spotlightDim: cursorStyle.spotlightDim, showClicks: cursorStyle.showClicks,
                              smoothing: cursorStyle.smoothing, sway: cursorStyle.sway,
                              clickBounce: cursorStyle.clickBounce,
                              clickBounceDuration: cursorStyle.clickBounceDuration,
                              clickEffect: cursorStyle.clickEffect.rawValue,
                              clickEffectRGB: cursorStyle.clickEffectRGB,
                              clickEffectScale: cursorStyle.clickEffectScale,
                              clickEffectOpacity: cursorStyle.clickEffectOpacity,
                              clickEffectDurationMs: cursorStyle.clickEffectDurationMs),
            captionCues: captionCues.map { CueDTO(text: $0.text, start: $0.start, end: $0.end) },
            captionsEnabled: captionsEnabled,
            captionStyle: CaptionStyleDTO(fontFraction: captionSettings.fontFraction,
                                          fontName: captionSettings.fontName,
                                          textRGBA: captionSettings.textRGBA,
                                          bottomOffsetFraction: captionSettings.bottomOffsetFraction,
                                          maxWidthFraction: captionSettings.maxWidthFraction,
                                          backgroundOpacity: captionSettings.backgroundOpacity,
                                          cornerRadiusFraction: captionSettings.cornerRadiusFraction,
                                          animation: captionSettings.animation.rawValue,
                                          animationDuration: captionSettings.animationDuration),
            trimStart: trimStart, trimEnd: trimEnd, speed: speed, speedRegions: speedRegions,
            keepRanges: keepRanges.map { [$0.lowerBound, $0.upperBound] })
    }

    func keepRangeList() -> [ClosedRange<Double>] {
        keepRanges.compactMap { $0.count == 2 && $0[1] > $0[0] ? $0[0]...$0[1] : nil }
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
        s.normalizeAudio = normalizeAudio
        s.audioVolumeRegions = audioVolumeRegions
        s.micProfile = MicProfile(rawValue: micProfile) ?? .raw
        s.audioRouting = audioRouting
        s.maxOutputHeight = maxOutputHeight
        s.crop = StyleOptions.CropInsets(top: crop.top, bottom: crop.bottom, left: crop.left, right: crop.right)
        s.paddingInsets = padInsets.map { StyleOptions.PaddingInsets(top: $0.top, bottom: $0.bottom, left: $0.left, right: $0.right) }
        return s
    }

    func zoomTimeline() -> ZoomTimeline {
        var tl = ZoomTimeline(regions: zoomRegions.map {
            ZoomRegion(start: $0.start, end: $0.end, scale: CGFloat($0.scale), focus: CGPoint(x: $0.fx, y: $0.fy))
        }, ramp: zoomRamp, easing: ZoomEasing(rawValue: zoomEasing) ?? .smooth)
        tl.inDuration = zoomInDuration
        tl.outDuration = zoomOutDuration
        tl.inEasing = zoomInEasing.flatMap(ZoomEasing.init(rawValue:))
        tl.outEasing = zoomOutEasing.flatMap(ZoomEasing.init(rawValue:))
        tl.connectZooms = connectZooms
        tl.connectedGap = connectedGap
        tl.connectedDuration = connectedDuration
        tl.connectedEasing = ZoomEasing(rawValue: connectedEasing) ?? .glide
        return tl
    }

    func captionSettingsValue() -> CaptionSettings {
        var s = CaptionSettings()
        s.enabled = captionsEnabled
        s.fontFraction = captionStyle.fontFraction
        s.fontName = captionStyle.fontName
        s.textRGBA = captionStyle.textRGBA
        s.bottomOffsetFraction = captionStyle.bottomOffsetFraction
        s.maxWidthFraction = captionStyle.maxWidthFraction
        s.backgroundOpacity = captionStyle.backgroundOpacity
        s.cornerRadiusFraction = captionStyle.cornerRadiusFraction
        s.animation = CaptionAnimation(rawValue: captionStyle.animation) ?? .fade
        s.animationDuration = captionStyle.animationDuration
        return s
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
        w.sourcePath = webcam.sourcePath
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
            a.fontName = c.fontName
            a.textColorRGBA = c.textColor
            a.showBackground = c.showBg
            a.bgColorRGBA = c.bgColor
            a.arrowAngle = c.arrowAngle
            a.fadeDuration = c.fadeDuration
            return a
        }
    }

    func cursorStyleValue() -> CursorStyle {
        var cs = CursorStyle()
        cs.enabled = cursor.enabled
        cs.kind = CursorStyle.Kind(rawValue: cursor.kind) ?? .arrow
        cs.size = cursor.size
        cs.spotlight = cursor.spotlight
        cs.spotlightRadius = cursor.spotlightRadius
        cs.spotlightDim = cursor.spotlightDim
        cs.showClicks = cursor.showClicks
        cs.smoothing = cursor.smoothing
        cs.sway = cursor.sway
        cs.clickBounce = cursor.clickBounce
        cs.clickBounceDuration = cursor.clickBounceDuration
        cs.clickEffect = CursorClickEffectStyle(rawValue: cursor.clickEffect) ?? .ripple
        cs.clickEffectRGB = cursor.clickEffectRGB
        cs.clickEffectScale = cursor.clickEffectScale
        cs.clickEffectOpacity = cursor.clickEffectOpacity
        cs.clickEffectDurationMs = cursor.clickEffectDurationMs
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

// MARK: - Tolerant decoding
//
// Swift's synthesized `init(from:)` ignores a property's default value: a key missing from
// the JSON is a decoding *error*, not a fallback. That makes the synthesized decoder unusable
// for a document format — every field added in a later version would render every
// previously-saved project unreadable, which is exactly what happened as this struct grew.
//
// So reading is spelled out with `decodeIfPresent` plus the same defaults the declarations
// carry. Only the decoders live here; encoding stays synthesized, and these sit in extensions
// so the memberwise initialisers survive.

/// Reads `key` if present, else returns the declared default.
private func fallback<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>,
                                                  _ key: K, _ value: T) throws -> T {
    try c.decodeIfPresent(T.self, forKey: key) ?? value
}

extension ReclipProject {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Only the source file name is genuinely required — a project without it names nothing.
        sourceFileName = try c.decode(String.self, forKey: .sourceFileName)
        version = try fallback(c, .version, 1)

        background = try fallback(c, .background, BG(kind: "gradient", top: [0.39, 0.36, 1.0],
                                                     bottom: [0.66, 0.33, 0.97]))
        backgroundImageB64 = try c.decodeIfPresent(String.self, forKey: .backgroundImageB64)
        paddingFraction = try fallback(c, .paddingFraction, 0.06)
        cornerRadiusFraction = try fallback(c, .cornerRadiusFraction, 0.03)
        squircleCorners = try fallback(c, .squircleCorners, false)
        shadowOpacity = try fallback(c, .shadowOpacity, 0.35)
        shadowRadius = try fallback(c, .shadowRadius, 24)
        backgroundBlur = try fallback(c, .backgroundBlur, 0)
        aspect = try fallback(c, .aspect, StyleOptions.Aspect.source.rawValue)
        deviceFrame = try fallback(c, .deviceFrame, DeviceFrame.none.rawValue)
        muteAudio = try fallback(c, .muteAudio, false)
        audioVolume = try fallback(c, .audioVolume, 1.0)
        normalizeAudio = try fallback(c, .normalizeAudio, false)
        audioVolumeRegions = try fallback(c, .audioVolumeRegions, [])
        micProfile = try fallback(c, .micProfile, MicProfile.raw.rawValue)
        audioRouting = try c.decodeIfPresent(AudioRouting.self, forKey: .audioRouting)
        maxOutputHeight = try c.decodeIfPresent(Int.self, forKey: .maxOutputHeight)
        crop = try fallback(c, .crop, Crop())
        padInsets = try c.decodeIfPresent(Pad.self, forKey: .padInsets)

        zoomRegions = try fallback(c, .zoomRegions, [])
        zoomEasing = try fallback(c, .zoomEasing, ZoomEasing.smooth.rawValue)
        zoomRamp = try fallback(c, .zoomRamp, 0.5)
        zoomInDuration = try c.decodeIfPresent(Double.self, forKey: .zoomInDuration)
        zoomOutDuration = try c.decodeIfPresent(Double.self, forKey: .zoomOutDuration)
        zoomInEasing = try c.decodeIfPresent(String.self, forKey: .zoomInEasing)
        zoomOutEasing = try c.decodeIfPresent(String.self, forKey: .zoomOutEasing)
        connectZooms = try fallback(c, .connectZooms, false)
        connectedGap = try fallback(c, .connectedGap, 1.5)
        connectedDuration = try fallback(c, .connectedDuration, 1.0)
        connectedEasing = try fallback(c, .connectedEasing, ZoomEasing.glide.rawValue)

        webcam = try fallback(c, .webcam,
                              Cam(enabled: false, corner: WebcamSettings.Corner.bottomTrailing.rawValue,
                                  size: 0.22, margin: 0.04, roundness: 1, mirror: true, shadow: true))
        captions = try fallback(c, .captions, [])
        cursor = try fallback(c, .cursor, CursorDTO())
        captionCues = try fallback(c, .captionCues, [])
        captionsEnabled = try fallback(c, .captionsEnabled, false)
        captionStyle = try fallback(c, .captionStyle, CaptionStyleDTO())

        trimStart = try fallback(c, .trimStart, 0)
        trimEnd = try fallback(c, .trimEnd, 0)
        speed = try fallback(c, .speed, 1)
        speedRegions = try fallback(c, .speedRegions, [])
        keepRanges = try fallback(c, .keepRanges, [])
    }
}

extension ReclipProject.CursorDTO {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try fallback(c, .enabled, false)
        kind = try fallback(c, .kind, CursorStyle.Kind.arrow.rawValue)
        size = try fallback(c, .size, 1.0)
        spotlight = try fallback(c, .spotlight, false)
        spotlightRadius = try fallback(c, .spotlightRadius, 0.18)
        spotlightDim = try fallback(c, .spotlightDim, 0.55)
        showClicks = try fallback(c, .showClicks, true)
        smoothing = try fallback(c, .smoothing, 0.67)
        sway = try fallback(c, .sway, 0.4)
        clickBounce = try fallback(c, .clickBounce, 2.5)
        clickBounceDuration = try fallback(c, .clickBounceDuration, 350.0)
        clickEffect = try fallback(c, .clickEffect, CursorClickEffectStyle.ripple.rawValue)
        clickEffectRGB = try fallback(c, .clickEffectRGB, [1, 1, 1])
        clickEffectScale = try fallback(c, .clickEffectScale, 1.0)
        clickEffectOpacity = try fallback(c, .clickEffectOpacity, 1.0)
        clickEffectDurationMs = try fallback(c, .clickEffectDurationMs, 600.0)
    }
}

extension ReclipProject.CaptionStyleDTO {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontFraction = try fallback(c, .fontFraction, 0.05)
        fontName = try fallback(c, .fontName, "")
        textRGBA = try fallback(c, .textRGBA, [1, 1, 1, 1])
        bottomOffsetFraction = try fallback(c, .bottomOffsetFraction, 0.06)
        maxWidthFraction = try fallback(c, .maxWidthFraction, 0.72)
        backgroundOpacity = try fallback(c, .backgroundOpacity, 0.75)
        cornerRadiusFraction = try fallback(c, .cornerRadiusFraction, 0.02)
        animation = try fallback(c, .animation, CaptionAnimation.fade.rawValue)
        animationDuration = try fallback(c, .animationDuration, 0.22)
    }
}

extension ReclipProject.Cam {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try fallback(c, .enabled, false)
        corner = try fallback(c, .corner, WebcamSettings.Corner.bottomTrailing.rawValue)
        size = try fallback(c, .size, 0.22)
        margin = try fallback(c, .margin, 0.04)
        roundness = try fallback(c, .roundness, 1.0)
        mirror = try fallback(c, .mirror, true)
        shadow = try fallback(c, .shadow, true)
        aspectRatio = try fallback(c, .aspectRatio, 1.0)
        cropZoom = try fallback(c, .cropZoom, 1.0)
        cropOffsetX = try fallback(c, .cropOffsetX, 0)
        cropOffsetY = try fallback(c, .cropOffsetY, 0)
        timeOffset = try fallback(c, .timeOffset, 0)
        reactToZoom = try fallback(c, .reactToZoom, false)
        sourcePath = try c.decodeIfPresent(String.self, forKey: .sourcePath)
    }
}

extension ReclipProject.Cap {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try fallback(c, .text, "")
        start = try fallback(c, .start, 0)
        end = try fallback(c, .end, 0)
        x = try fallback(c, .x, 0.5)
        y = try fallback(c, .y, 0.12)
        fontFraction = try fallback(c, .fontFraction, 0.05)
        kind = try fallback(c, .kind, Annotation.Kind.text.rawValue)
        rw = try fallback(c, .rw, 0.3)
        rh = try fallback(c, .rh, 0.2)
        blurRadius = try fallback(c, .blurRadius, 24)
        color = try fallback(c, .color, [0, 0, 0, 0.85])
        imageB64 = try c.decodeIfPresent(String.self, forKey: .imageB64)
        bold = try fallback(c, .bold, true)
        fontName = try fallback(c, .fontName, "")
        textColor = try fallback(c, .textColor, [1, 1, 1, 1])
        showBg = try fallback(c, .showBg, true)
        bgColor = try fallback(c, .bgColor, [0, 0, 0, 0.55])
        arrowAngle = try fallback(c, .arrowAngle, 0)
        fadeDuration = try fallback(c, .fadeDuration, 0)
    }
}

extension ReclipProject.Crop {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        top = try fallback(c, .top, 0)
        bottom = try fallback(c, .bottom, 0)
        left = try fallback(c, .left, 0)
        right = try fallback(c, .right, 0)
    }
}

extension ReclipProject.Pad {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        top = try fallback(c, .top, 0.06)
        bottom = try fallback(c, .bottom, 0.06)
        left = try fallback(c, .left, 0.06)
        right = try fallback(c, .right, 0.06)
    }
}
