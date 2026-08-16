import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import CoreGraphics

/// A caption cue with its time range. (Transcription that produces cues — e.g. Whisper —
/// is a separate concern; this is the styled rendering half of the captions subsystem.)
struct CaptionCue: Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// How a caption cue enters and leaves (Recordly's caption animation setting).
enum CaptionAnimation: String, CaseIterable, Identifiable, Codable {
    case off, fade, rise, pop
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .fade: return "Fade"
        case .rise: return "Rise"
        case .pop: return "Pop"
        }
    }
}

/// Styling for burned-in captions (Recordly parity: color, size, offset, width, box).
struct CaptionSettings: Equatable {
    var enabled = false
    var fontFraction: Double = 0.05        // of canvas height
    var fontName: String = ""              // "" = default (Helvetica Neue Medium)
    var textRGBA: [Double] = [1, 1, 1, 1]
    var bottomOffsetFraction: Double = 0.06
    var maxWidthFraction: Double = 0.72
    var backgroundOpacity: Double = 0.75
    var cornerRadiusFraction: Double = 0.02 // of canvas height
    var animation: CaptionAnimation = .fade
    var animationDuration: Double = 0.22    // seconds for the in/out transition
}

/// The opacity/offset/scale a cue is drawn at, given how far into its range `time` is.
/// Split out from the renderer so the curve is pure and unit-testable.
struct CaptionTransform: Equatable {
    var opacity: Double = 1
    var offsetY: Double = 0     // fraction of the pill height, positive = lower
    var scale: Double = 1

    static func at(time: Double, cue: CaptionCue, settings: CaptionSettings) -> CaptionTransform {
        guard settings.animation != .off else { return CaptionTransform() }
        let d = max(0.01, settings.animationDuration)
        let inP = min(1, max(0, (time - cue.start) / d))
        let outP = min(1, max(0, (cue.end - time) / d))
        let p = min(inP, outP)
        // Smoothstep, so the entrance eases instead of tracking a straight line.
        let e = p * p * (3 - 2 * p)
        switch settings.animation {
        case .off:  return CaptionTransform()
        case .fade: return CaptionTransform(opacity: e)
        case .rise: return CaptionTransform(opacity: e, offsetY: (1 - e) * -0.6)
        case .pop:  return CaptionTransform(opacity: e, scale: 0.86 + 0.14 * e)
        }
    }
}

enum CaptionRenderer {

    static func composite(base: CIImage, canvas: CGSize,
                          cues: [CaptionCue], time: Double, settings: CaptionSettings) -> CIImage {
        guard settings.enabled,
              let cue = cues.first(where: { time >= $0.start && time <= $0.end }),
              !cue.text.isEmpty else { return base }

        let fontSize = canvas.height * settings.fontFraction
        let maxWidth = canvas.width * settings.maxWidthFraction
        let radius = canvas.height * settings.cornerRadiusFraction
        guard let (pill, size) = renderPill(cue.text, fontSize: fontSize, maxWidth: maxWidth,
                                            radius: radius, settings: settings) else { return base }

        let anim = CaptionTransform.at(time: time, cue: cue, settings: settings)
        guard anim.opacity > 0.004 else { return base }

        // Scale about the pill's own centre so "pop" grows from the middle, not the corner.
        var img = pill
        if abs(anim.scale - 1) > 0.001 {
            let s = CGFloat(anim.scale)
            img = img.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2))
                .transformed(by: CGAffineTransform(scaleX: s, y: s))
                .transformed(by: CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
        }
        if anim.opacity < 0.999 {
            let cm = CIFilter.colorMatrix()
            cm.inputImage = img
            cm.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(anim.opacity))
            img = cm.outputImage ?? img
        }

        let x = (canvas.width - size.width) / 2
        // CI is bottom-origin, so a "rise" (entering from below) is a negative y offset.
        let y = canvas.height * settings.bottomOffsetFraction + CGFloat(anim.offsetY) * size.height
        return img.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: base)
    }

    /// Renders a single centered caption line inside a rounded translucent pill.
    private static func renderPill(_ text: String, fontSize: CGFloat, maxWidth: CGFloat,
                                   radius: CGFloat, settings: CaptionSettings) -> (CIImage, CGSize)? {
        let color = settings.textRGBA
        let family = settings.fontName.isEmpty ? "HelveticaNeue-Medium" : settings.fontName
        let font = CTFontCreateWithName(family as CFString, fontSize, nil)
        let cg = CGColor(red: color[0], green: color[1], blue: color[2], alpha: color.count > 3 ? color[3] : 1)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: cg]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        let padX = fontSize * 0.6
        let padY = fontSize * 0.4
        let textW = min(bounds.width, maxWidth)
        let w = Int(ceil(textW + padX * 2))
        let h = Int(ceil(bounds.height + padY * 2))
        guard w > 1, h > 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)

        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let path = CGPath(roundedRect: rect, cornerWidth: min(radius, CGFloat(h) / 2),
                          cornerHeight: min(radius, CGFloat(h) / 2), transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: settings.backgroundOpacity))
        ctx.fillPath()

        ctx.textPosition = CGPoint(x: padX, y: padY - bounds.minY)
        CTLineDraw(line, ctx)

        guard let img = ctx.makeImage() else { return nil }
        return (CIImage(cgImage: img), CGSize(width: w, height: h))
    }
}

/// SRT / VTT caption sidecar generation (Recordly exports both).
enum CaptionExport {
    static func srt(_ cues: [CaptionCue]) -> String {
        cues.enumerated().map { i, c in
            "\(i + 1)\n\(timecode(c.start, sep: ",")) --> \(timecode(c.end, sep: ","))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [CaptionCue]) -> String {
        "WEBVTT\n\n" + cues.map { c in
            "\(timecode(c.start, sep: ".")) --> \(timecode(c.end, sep: "."))\n\(c.text)\n"
        }.joined(separator: "\n")
    }

    static func timecode(_ t: Double, sep: String) -> String {
        let total = max(0, t)
        let whole = Int(total)
        let ms = Int((total - Double(whole)) * 1000)
        return String(format: "%02d:%02d:%02d%@%03d", whole / 3600, (whole % 3600) / 60, whole % 60, sep, ms)
    }
}
