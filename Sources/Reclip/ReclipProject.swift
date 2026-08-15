import Foundation
import CoreGraphics

/// A saved editing session: the source recording plus every polish setting, so work can
/// be reopened later. Persisted as a `.reclip` JSON file (Recordly's `.recordia` analogue).
struct ReclipProject: Codable, Equatable {
    var version = 1
    var sourceFileName: String

    var background: BG
    var paddingFraction: Double
    var cornerRadiusFraction: Double
    var shadowOpacity: Double
    var shadowRadius: Double
    var backgroundBlur: Double
    var aspect: String
    var crop: Crop

    var zoomRegions: [Zoom]
    var webcam: Cam
    var captions: [Cap]

    var trimStart: Double
    var trimEnd: Double
    var speed: Double

    // MARK: Nested codable DTOs

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
    struct Zoom: Codable, Equatable { var start: Double; var end: Double; var scale: Double; var fx: Double; var fy: Double }
    struct Cam: Codable, Equatable {
        var enabled: Bool; var corner: String; var size: Double; var margin: Double
        var roundness: Double; var mirror: Bool; var shadow: Bool
    }
    struct Cap: Codable, Equatable { var text: String; var start: Double; var end: Double; var x: Double; var y: Double; var fontFraction: Double }

    // MARK: Capture / restore

    static func capture(source: URL, style: StyleOptions, zoom: ZoomTimeline,
                        webcam: WebcamSettings, annotations: [Annotation],
                        trimStart: Double, trimEnd: Double, speed: Double) -> ReclipProject {
        ReclipProject(
            sourceFileName: source.lastPathComponent,
            background: .from(style.background),
            paddingFraction: style.paddingFraction,
            cornerRadiusFraction: style.cornerRadiusFraction,
            shadowOpacity: style.shadowOpacity,
            shadowRadius: style.shadowRadius,
            backgroundBlur: style.backgroundBlur,
            aspect: style.aspect.rawValue,
            crop: Crop(top: style.crop.top, bottom: style.crop.bottom, left: style.crop.left, right: style.crop.right),
            zoomRegions: zoom.regions.map { Zoom(start: $0.start, end: $0.end, scale: Double($0.scale), fx: $0.focus.x, fy: $0.focus.y) },
            webcam: Cam(enabled: webcam.enabled, corner: webcam.corner.rawValue, size: webcam.sizeFraction,
                        margin: webcam.marginFraction, roundness: webcam.roundness, mirror: webcam.mirror, shadow: webcam.shadow),
            captions: annotations.map { Cap(text: $0.text, start: $0.start, end: $0.end, x: $0.position.x, y: $0.position.y, fontFraction: $0.fontFraction) },
            trimStart: trimStart, trimEnd: trimEnd, speed: speed)
    }

    func style() -> StyleOptions {
        var s = StyleOptions()
        s.background = background.toBackground()
        s.paddingFraction = paddingFraction
        s.cornerRadiusFraction = cornerRadiusFraction
        s.shadowOpacity = shadowOpacity
        s.shadowRadius = shadowRadius
        s.backgroundBlur = backgroundBlur
        s.aspect = StyleOptions.Aspect(rawValue: aspect) ?? .source
        s.crop = StyleOptions.CropInsets(top: crop.top, bottom: crop.bottom, left: crop.left, right: crop.right)
        return s
    }

    func zoomTimeline() -> ZoomTimeline {
        ZoomTimeline(regions: zoomRegions.map {
            ZoomRegion(start: $0.start, end: $0.end, scale: CGFloat($0.scale), focus: CGPoint(x: $0.fx, y: $0.fy))
        })
    }

    func webcamSettings() -> WebcamSettings {
        var w = WebcamSettings()
        w.enabled = webcam.enabled
        w.corner = WebcamSettings.Corner(rawValue: webcam.corner) ?? .bottomTrailing
        w.sizeFraction = webcam.size
        w.marginFraction = webcam.margin
        w.roundness = webcam.roundness
        w.mirror = webcam.mirror
        w.shadow = webcam.shadow
        return w
    }

    func annotationList() -> [Annotation] {
        captions.map { Annotation(text: $0.text, start: $0.start, end: $0.end,
                                  position: CGPoint(x: $0.x, y: $0.y), fontFraction: $0.fontFraction) }
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
}
