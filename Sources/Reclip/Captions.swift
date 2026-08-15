import Foundation
import CoreImage
import CoreText
import CoreGraphics

/// A caption cue with its time range. (Transcription that produces cues — e.g. Whisper —
/// is a separate concern; this is the styled rendering half of the captions subsystem.)
struct CaptionCue: Equatable {
    var text: String
    var start: Double
    var end: Double
}

/// Styling for burned-in captions (Recordly parity: color, size, offset, width, box).
struct CaptionSettings: Equatable {
    var enabled = false
    var fontFraction: Double = 0.05        // of canvas height
    var textRGBA: [Double] = [1, 1, 1, 1]
    var bottomOffsetFraction: Double = 0.06
    var maxWidthFraction: Double = 0.72
    var backgroundOpacity: Double = 0.75
    var cornerRadiusFraction: Double = 0.02 // of canvas height
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

        let x = (canvas.width - size.width) / 2
        let y = canvas.height * settings.bottomOffsetFraction     // CI bottom-origin
        return pill.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: base)
    }

    /// Renders a single centered caption line inside a rounded translucent pill.
    private static func renderPill(_ text: String, fontSize: CGFloat, maxWidth: CGFloat,
                                   radius: CGFloat, settings: CaptionSettings) -> (CIImage, CGSize)? {
        let color = settings.textRGBA
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, fontSize, nil)
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
