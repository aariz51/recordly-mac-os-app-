import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import CoreGraphics
import AppKit

/// An overlay shown over the video for a time range at a normalized position. Text by
/// default; also image, arrow, box (censor), and blur region types (Recordly parity).
struct Annotation: Identifiable, Equatable {
    enum Kind: String, Equatable { case text, image, arrow, box, blur }

    var id = UUID()
    var text: String
    var start: Double
    var end: Double
    var position: CGPoint = CGPoint(x: 0.5, y: 0.12)   // normalized center, top-left origin
    var fontFraction: Double = 0.05                     // of canvas height (text)
    // Extra fields (defaulted so text captions stay source-compatible):
    var kind: Kind = .text
    var regionSize: CGSize = CGSize(width: 0.3, height: 0.2) // normalized, for region kinds
    var blurRadius: Double = 24                          // for .blur
    var colorRGBA: [Double] = [0, 0, 0, 0.85]            // for .box fill / .arrow stroke
    var imageData: Data? = nil                           // for .image
    // Text typography (defaulted to the previous fixed style for compatibility):
    var bold: Bool = true
    var textColorRGBA: [Double] = [1, 1, 1, 1]           // text fill (default white)
    var showBackground: Bool = true                      // the rounded pill behind the text
    var bgColorRGBA: [Double] = [0, 0, 0, 0.55]          // pill colour
    var arrowAngle: Double = 0                           // degrees, 0 = pointing right (for .arrow)
    var fadeDuration: Double = 0                          // seconds to fade in/out (0 = hard cut)
}

/// An annotation with any pre-rendered image (text/image kinds); region kinds render live.
struct RenderedAnnotation {
    let annotation: Annotation
    let image: CIImage?
    let pixelSize: CGSize
}

enum Annotations {

    /// Render caption text to a detached CIImage using Core Text (thread-safe, no AppKit context).
    static func render(_ text: String, fontSize: CGFloat,
                       bold: Bool = true,
                       textColor: [Double] = [1, 1, 1, 1],
                       showBackground: Bool = true,
                       bgColor: [Double] = [0, 0, 0, 0.55]) -> (CIImage, CGSize)? {
        guard !text.isEmpty else { return nil }
        let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, fontSize, nil)
        func color(_ c: [Double]) -> CGColor {
            CGColor(red: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color(textColor)
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
        // rounded pill behind the text (optional)
        if showBackground {
            let rect = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h))
            let path = CGPath(roundedRect: rect, cornerWidth: CGFloat(h) * 0.28,
                              cornerHeight: CGFloat(h) * 0.28, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(color(bgColor))
            ctx.fillPath()
        }

        ctx.textPosition = CGPoint(x: padX, y: padY - bounds.minY)
        CTLineDraw(line, ctx)

        guard let cg = ctx.makeImage() else { return nil }
        return (CIImage(cgImage: cg), CGSize(width: w, height: h))
    }

    static func prerender(_ annotations: [Annotation], canvas: CGSize) -> [RenderedAnnotation] {
        annotations.compactMap { a in
            switch a.kind {
            case .text:
                let fontSize = canvas.height * a.fontFraction
                guard let (image, size) = render(a.text, fontSize: fontSize, bold: a.bold,
                                                 textColor: a.textColorRGBA, showBackground: a.showBackground,
                                                 bgColor: a.bgColorRGBA) else { return nil }
                return RenderedAnnotation(annotation: a, image: image, pixelSize: size)
            case .image:
                guard let data = a.imageData, let ci = CIImage(data: data) else { return nil }
                return RenderedAnnotation(annotation: a, image: ci, pixelSize: ci.extent.size)
            case .arrow, .box, .blur:
                // Rendered live in composite() against the base frame.
                return RenderedAnnotation(annotation: a, image: nil, pixelSize: .zero)
            }
        }
    }

    /// Opacity envelope for fade in/out: ramps 0→1 over `fade` seconds after `start` and
    /// 1→0 over `fade` seconds before `end` (1 throughout when `fade` is 0).
    static func fadeFactor(time t: Double, start: Double, end: Double, fade f: Double) -> Double {
        guard f > 0.001 else { return 1 }
        let fadeIn = min(1, max(0, (t - start) / f))
        let fadeOut = min(1, max(0, (end - t) / f))
        return min(fadeIn, fadeOut)
    }

    private static func faded(_ img: CIImage, _ factor: Double) -> CIImage {
        guard factor < 0.999 else { return img }
        let cm = CIFilter.colorMatrix()
        cm.inputImage = img
        cm.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, factor)))
        return cm.outputImage ?? img
    }

    static func composite(base: CIImage, canvas: CGSize,
                          rendered: [RenderedAnnotation], time: Double) -> CIImage {
        var result = base
        for r in rendered where time >= r.annotation.start && time <= r.annotation.end {
            let a = r.annotation
            let fade = fadeFactor(time: time, start: a.start, end: a.end, fade: a.fadeDuration)
            switch a.kind {
            case .text:
                guard let image = r.image else { continue }
                let px = a.position.x * canvas.width - r.pixelSize.width / 2
                let py = (1 - a.position.y) * canvas.height - r.pixelSize.height / 2
                result = faded(image, fade).transformed(by: CGAffineTransform(translationX: px, y: py)).composited(over: result)
            case .image:
                guard let image = r.image else { continue }
                result = faded(placeInRegion(image, annotation: a, canvas: canvas), fade).composited(over: result)
            case .box:
                let rect = regionRect(a, canvas: canvas)
                let c = a.colorRGBA
                let fill = CIImage(color: CIColor(red: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1))
                    .cropped(to: rect)
                result = fill.composited(over: result)
            case .blur:
                let rect = regionRect(a, canvas: canvas)
                let region = result.cropped(to: rect)
                let blur = CIFilter.gaussianBlur()
                blur.inputImage = region.clampedToExtent()
                blur.radius = Float(a.blurRadius)
                if let blurred = blur.outputImage?.cropped(to: rect) {
                    result = blurred.composited(over: result)
                }
            case .arrow:
                if let arrow = makeArrow(a, canvas: canvas) {
                    result = arrow.composited(over: result)
                }
            }
        }
        return result
    }

    /// Region rect in CI (bottom-left origin) canvas pixels.
    private static func regionRect(_ a: Annotation, canvas: CGSize) -> CGRect {
        let w = a.regionSize.width * canvas.width
        let h = a.regionSize.height * canvas.height
        let cx = a.position.x * canvas.width
        let cy = (1 - a.position.y) * canvas.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: max(w, 1), height: max(h, 1))
    }

    private static func placeInRegion(_ image: CIImage, annotation a: Annotation, canvas: CGSize) -> CIImage {
        let rect = regionRect(a, canvas: canvas)
        let e = image.extent
        guard e.width > 0, e.height > 0 else { return image }
        let scale = min(rect.width / e.width, rect.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let se = scaled.extent
        return scaled.transformed(by: CGAffineTransform(translationX: rect.midX - se.midX,
                                                        y: rect.midY - se.midY))
    }

    private static func makeArrow(_ a: Annotation, canvas: CGSize) -> CIImage? {
        let rect = regionRect(a, canvas: canvas)
        let w = Int(ceil(rect.width)), h = Int(ceil(rect.height))
        guard w > 1, h > 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let c = a.colorRGBA
        ctx.setShouldAntialias(true)
        let W = CGFloat(w), H = CGFloat(h)
        // Left→right arrow: shaft + head.
        ctx.setStrokeColor(CGColor(red: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1))
        ctx.setLineWidth(max(2, min(W, H) * 0.12))
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: W * 0.1, y: H * 0.5))
        ctx.addLine(to: CGPoint(x: W * 0.8, y: H * 0.5))
        ctx.strokePath()
        ctx.setFillColor(CGColor(red: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1))
        ctx.move(to: CGPoint(x: W * 0.95, y: H * 0.5))
        ctx.addLine(to: CGPoint(x: W * 0.72, y: H * 0.72))
        ctx.addLine(to: CGPoint(x: W * 0.72, y: H * 0.28))
        ctx.closePath()
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        var img = CIImage(cgImage: cg)   // extent (0,0,W,H), arrow points right
        // Rotate around the arrow's own center so it can point in any direction.
        if abs(a.arrowAngle) > 0.01 {
            let angle = CGFloat(a.arrowAngle) * .pi / 180
            img = img.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2))
                     .transformed(by: CGAffineTransform(rotationAngle: angle))
                     .transformed(by: CGAffineTransform(translationX: W / 2, y: H / 2))
        }
        // Center the (possibly rotated) arrow in the region rect.
        let e = img.extent
        return img.transformed(by: CGAffineTransform(translationX: rect.midX - e.midX,
                                                     y: rect.midY - e.midY))
    }
}
