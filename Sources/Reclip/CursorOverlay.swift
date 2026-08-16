import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import AppKit

/// Extracts the real macOS system cursor image (Recordly captures the OS cursor for
/// authenticity, rather than always drawing a stylized one).
enum SystemCursor {
    static func arrowSprite(size: CGFloat) -> CIImage? {
        let img = NSCursor.arrow.image
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage, cg.height > 0 else { return nil }
        let ci = CIImage(cgImage: cg)
        let scale = (size * 1.5) / CGFloat(cg.height)   // match the drawn-arrow footprint
        return ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

/// A stylized cursor rendered from the recorded cursor track (used when the OS cursor
/// was hidden during capture). Recordly-style cursor polish.
struct CursorStyle: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case arrow
        case dot
        case system   // the real macOS cursor image
        var id: String { rawValue }
    }
    var enabled = false
    var kind: Kind = .arrow
    var size: Double = 1.0    // multiplier over the base cursor size
    var spotlight = false          // dim everything except a soft circle around the cursor
    var spotlightRadius = 0.18     // circle radius as a fraction of the frame's short side
    var spotlightDim = 0.55        // how much to darken outside the circle (0…1)
    var showClicks = true          // draw an expanding ripple at each recorded click
}

enum CursorRenderer {

    /// Dims the frame except a soft circle around the cursor (a spotlight that draws the
    /// eye to the pointer). Applied in source space so crop/zoom carry it, like the cursor.
    static func applySpotlight(on image: CIImage, track: CursorTrack?, time: Double, style: CursorStyle) -> CIImage {
        guard style.spotlight, let pos = track?.interpolated(at: time) else { return image }
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }
        let px = ext.minX + CGFloat(min(max(pos.x, 0), 1)) * ext.width
        let py = ext.minY + (1 - CGFloat(min(max(pos.y, 0), 1))) * ext.height
        let r = min(ext.width, ext.height) * CGFloat(max(0.03, min(style.spotlightRadius, 0.9)))

        let grad = CIFilter.radialGradient()
        grad.center = CGPoint(x: px, y: py)
        grad.radius0 = Float(r)
        grad.radius1 = Float(r * 1.8)
        grad.color0 = CIColor.white
        grad.color1 = CIColor.black
        let mask = (grad.outputImage ?? CIImage(color: .white)).cropped(to: ext)

        let dim = CIFilter.colorControls()
        dim.inputImage = image
        dim.brightness = -Float(max(0, min(style.spotlightDim, 1)))
        let dark = (dim.outputImage ?? image).cropped(to: ext)

        let blend = CIFilter.blendWithMask()
        blend.inputImage = image          // full-bright inside the circle
        blend.backgroundImage = dark      // dimmed outside
        blend.maskImage = mask
        return (blend.outputImage ?? image).cropped(to: ext)
    }

    /// Draws an expanding, fading ring at each recent click (Recordly's click ripple), using
    /// the unit-tested CursorClickEffect timing. Positioned at the cursor location of the click.
    static func drawClicks(on image: CIImage, track: CursorTrack?, time: Double, style: CursorStyle) -> CIImage {
        guard style.enabled, style.showClicks, let track, !track.clicks.isEmpty else { return image }
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }
        let bounceDur = 200.0, effectDur = 500.0
        let maxR = min(ext.width, ext.height) * 0.06 * CGFloat(max(0.2, min(style.size, 6)))
        var result = image
        for clickT in track.clicks {
            let rp = CursorClickEffect.rippleProgress(ageMs: (time - clickT) * 1000,
                                                      bounceDurationMs: bounceDur, effectDurationMs: effectDur)
            guard rp > 0.01, let pos = track.interpolated(at: clickT) else { continue }
            let px = ext.minX + CGFloat(min(max(pos.x, 0), 1)) * ext.width
            let py = ext.minY + (1 - CGFloat(min(max(pos.y, 0), 1))) * ext.height
            let radius = maxR * CGFloat(2 - rp)          // expands as it fades
            if let ring = makeRipple(radius: radius, opacity: rp) {
                let s = ring.extent
                result = ring.transformed(by: CGAffineTransform(translationX: px - s.width / 2,
                                                                y: py - s.height / 2)).composited(over: result)
            }
        }
        return result
    }

    private static func makeRipple(radius: CGFloat, opacity: Double) -> CIImage? {
        let d = Int(ceil(radius * 2)) + 4
        guard d > 4,
              let ctx = CGContext(data: nil, width: d, height: d, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        let lw = max(1, radius * 0.12)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: max(0, min(opacity, 1))))
        ctx.setLineWidth(lw)
        ctx.strokeEllipse(in: CGRect(x: lw, y: lw, width: CGFloat(d) - lw * 2, height: CGFloat(d) - lw * 2))
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// Composites the stylized cursor onto the (uncropped, unzoomed) source frame so it
    /// inherits the same crop/zoom/placement transforms as the footage.
    static func draw(on image: CIImage, track: CursorTrack?, time: Double, style: CursorStyle) -> CIImage {
        guard style.enabled, let pos = track?.interpolated(at: time) else { return image }
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }

        let base = min(ext.width, ext.height) * 0.05 * CGFloat(max(0.2, min(style.size, 6)))
        guard let sprite = makeSprite(kind: style.kind, size: base) else { return image }

        // Normalized (top-left origin) → CI pixel (bottom-left origin).
        let px = ext.minX + CGFloat(min(max(pos.x, 0), 1)) * ext.width
        let py = ext.minY + (1 - CGFloat(min(max(pos.y, 0), 1))) * ext.height

        // Place the sprite so its hotspot sits at (px, py). Arrow hotspot = top-left;
        // dot hotspot = center.
        let s = sprite.extent
        let tx: CGFloat
        let ty: CGFloat
        switch style.kind {
        case .arrow, .system: tx = px;              ty = py - s.height   // tip at top-left
        case .dot:            tx = px - s.width / 2; ty = py - s.height / 2
        }
        return sprite.transformed(by: CGAffineTransform(translationX: tx, y: ty)).composited(over: image)
    }

    private static func makeSprite(kind: CursorStyle.Kind, size: CGFloat) -> CIImage? {
        if kind == .system { return SystemCursor.arrowSprite(size: size) }
        let w = Int(ceil(size))
        let h = Int(ceil(size * (kind == .arrow ? 1.5 : 1.0)))
        guard w > 1, h > 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        let W = CGFloat(w), H = CGFloat(h)

        switch kind {
        case .system: return nil   // handled by the early return above; unreachable here
        case .dot:
            let inset = max(1, size * 0.06)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
            ctx.fillEllipse(in: CGRect(x: inset, y: inset, width: W - inset * 2, height: H - inset * 2))
            ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
            ctx.setLineWidth(max(1, size * 0.07))
            ctx.strokeEllipse(in: CGRect(x: inset, y: inset, width: W - inset * 2, height: H - inset * 2))

        case .arrow:
            // macOS-style pointer with the tip at the top-left. CGContext is bottom-left
            // origin, so the tip is at (0, H).
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: H))
            p.addLine(to: CGPoint(x: 0, y: H * 0.24))
            p.addLine(to: CGPoint(x: W * 0.30, y: H * 0.50))
            p.addLine(to: CGPoint(x: W * 0.46, y: H * 0.44))
            p.addLine(to: CGPoint(x: W * 0.66, y: 0))
            p.addLine(to: CGPoint(x: W * 0.82, y: H * 0.06))
            p.addLine(to: CGPoint(x: W * 0.62, y: H * 0.50))
            p.addLine(to: CGPoint(x: W * 0.88, y: H * 0.50))
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fillPath()
            ctx.addPath(p)
            ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))
            ctx.setLineWidth(max(1, size * 0.05))
            ctx.strokePath()
        }
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg)
    }
}
