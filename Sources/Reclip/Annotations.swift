import Foundation
import CoreImage
import CoreText
import CoreGraphics
import AppKit

/// A text caption shown over the video for a time range at a normalized position.
struct Annotation: Identifiable, Equatable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
    var position: CGPoint = CGPoint(x: 0.5, y: 0.12)   // normalized, top-left origin
    var fontFraction: Double = 0.05                     // of canvas height
}

/// An annotation with its text pre-rendered to an image (built once per composition).
struct RenderedAnnotation {
    let annotation: Annotation
    let image: CIImage
    let pixelSize: CGSize
}

enum Annotations {

    /// Render caption text to a detached CIImage using Core Text (thread-safe, no AppKit context).
    static func render(_ text: String, fontSize: CGFloat) -> (CIImage, CGSize)? {
        guard !text.isEmpty else { return nil }
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.cgColor
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let padX: CGFloat = fontSize * 0.5
        let padY: CGFloat = fontSize * 0.35
        let w = Int(ceil(bounds.width + padX * 2))
        let h = Int(ceil(bounds.height + padY * 2))
        guard w > 0, h > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // rounded translucent pill behind the text
        let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
        let path = CGPath(roundedRect: rect, cornerWidth: CGFloat(h) * 0.28,
                          cornerHeight: CGFloat(h) * 0.28, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
        ctx.fillPath()

        ctx.textPosition = CGPoint(x: padX, y: padY - bounds.minY)
        CTLineDraw(line, ctx)

        guard let cg = ctx.makeImage() else { return nil }
        return (CIImage(cgImage: cg), CGSize(width: w, height: h))
    }

    static func prerender(_ annotations: [Annotation], canvas: CGSize) -> [RenderedAnnotation] {
        annotations.compactMap { a in
            let fontSize = canvas.height * a.fontFraction
            guard let (image, size) = render(a.text, fontSize: fontSize) else { return nil }
            return RenderedAnnotation(annotation: a, image: image, pixelSize: size)
        }
    }

    static func composite(base: CIImage, canvas: CGSize,
                          rendered: [RenderedAnnotation], time: Double) -> CIImage {
        var result = base
        for r in rendered where time >= r.annotation.start && time <= r.annotation.end {
            let px = r.annotation.position.x * canvas.width - r.pixelSize.width / 2
            // normalized top-left -> CI bottom-left origin
            let py = (1 - r.annotation.position.y) * canvas.height - r.pixelSize.height / 2
            let placed = r.image.transformed(by: CGAffineTransform(translationX: px, y: py))
            result = placed.composited(over: result)
        }
        return result
    }
}
