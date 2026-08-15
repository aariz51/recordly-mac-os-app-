import Foundation
import CoreImage
import CoreGraphics

/// A stylized cursor rendered from the recorded cursor track (used when the OS cursor
/// was hidden during capture). Recordly-style cursor polish.
struct CursorStyle: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case arrow
        case dot
        var id: String { rawValue }
    }
    var enabled = false
    var kind: Kind = .arrow
    var size: Double = 1.0    // multiplier over the base cursor size
}

enum CursorRenderer {

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
        case .arrow: tx = px;              ty = py - s.height
        case .dot:   tx = px - s.width / 2; ty = py - s.height / 2
        }
        return sprite.transformed(by: CGAffineTransform(translationX: tx, y: ty)).composited(over: image)
    }

    private static func makeSprite(kind: CursorStyle.Kind, size: CGFloat) -> CIImage? {
        let w = Int(ceil(size))
        let h = Int(ceil(size * (kind == .arrow ? 1.5 : 1.0)))
        guard w > 1, h > 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        let W = CGFloat(w), H = CGFloat(h)

        switch kind {
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
