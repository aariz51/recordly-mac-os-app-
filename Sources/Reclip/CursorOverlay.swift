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

/// The graphic drawn at each click (Recordly's `CursorClickEffectStyle`).
enum CursorClickEffectStyle: String, CaseIterable, Identifiable, Codable {
    case none, ripple, spotlight, echo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Off"
        case .ripple: return "Ripple"
        case .spotlight: return "Spotlight"
        case .echo: return "Echo"
        }
    }
    var summary: String {
        switch self {
        case .none: return "No click graphic — only the cursor motion changes."
        case .ripple: return "Expanding rings radiate from each click."
        case .spotlight: return "A soft halo flashes around the pointer."
        case .echo: return "A pair of rings that spread outward in sequence."
        }
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
    var showClicks = true          // draw the click graphic at each recorded click

    // Motion pipeline (Recordly's CursorVisualSettings). These drive `SmoothedCursorTrack`,
    // which is precomputed once and indexed per frame.
    var smoothing: Double = 0.67           // 0 = snap to the raw path, 2 = floaty
    var sway: Double = 0.4                 // rotation in the direction of travel
    var clickBounce: Double = 2.5          // how far the cursor dips on a click
    var clickBounceDuration: Double = 350  // ms

    // Click graphic.
    var clickEffect: CursorClickEffectStyle = .ripple
    var clickEffectRGB: [Double] = [1, 1, 1]      // effect colour
    var clickEffectScale: Double = 1.0
    var clickEffectOpacity: Double = 1.0
    var clickEffectDurationMs: Double = 600
}

enum CursorRenderer {

    /// The drawn cursor position at `time`. Prefers the precomputed smoothed track (spring
    /// + sway + bounce); falls back to the raw interpolated path when no motion has been
    /// built, so the renderer still works for callers that don't smooth.
    static func resolve(track: CursorTrack?, motion: SmoothedCursorTrack?,
                        time: Double) -> CursorMotionSample? {
        if let m = motion?.sample(at: time) { return m }
        guard let p = track?.interpolated(at: time) else { return nil }
        return CursorMotionSample(t: time, x: p.x, y: p.y, rotation: 0, scale: 1)
    }

    /// Dims the frame except a soft circle around the cursor (a spotlight that draws the
    /// eye to the pointer). Applied in source space so crop/zoom carry it, like the cursor.
    static func applySpotlight(on image: CIImage, track: CursorTrack?, time: Double, style: CursorStyle,
                               motion: SmoothedCursorTrack? = nil) -> CIImage {
        guard style.spotlight, let pos = resolve(track: track, motion: motion, time: time) else { return image }
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

    /// Draws the click graphic at each recent click, in the style the user picked, using the
    /// unit-tested CursorClickEffect timing. Positioned at the cursor location of the click.
    ///
    /// `echo` is a ripple plus a second ring a third of a cycle behind it; `spotlight` is a
    /// filled halo rather than a ring. All three share the same age→progress curve, so the
    /// duration/scale/opacity controls mean the same thing whichever is selected.
    static func drawClicks(on image: CIImage, track: CursorTrack?, time: Double, style: CursorStyle,
                           motion: SmoothedCursorTrack? = nil) -> CIImage {
        guard style.enabled, style.showClicks, style.clickEffect != .none,
              let track, !track.clicks.isEmpty else { return image }
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }
        let bounceDur = CursorClickEffect.clampBounceDuration(style.clickBounceDuration)
        let effectDur = max(80, style.clickEffectDurationMs)
        let scaleFactor = CGFloat(max(0.2, min(style.clickEffectScale, 4)))
        let maxR = min(ext.width, ext.height) * 0.06
            * CGFloat(max(0.2, min(style.size, 6))) * scaleFactor
        let alpha = max(0, min(style.clickEffectOpacity, 1))
        let rgb = style.clickEffectRGB.count >= 3 ? style.clickEffectRGB : [1, 1, 1]

        // Phase offsets: one graphic for ripple/spotlight, two staggered for echo.
        let phases: [Double] = style.clickEffect == .echo ? [0, 0.33] : [0]

        var result = image
        for clickT in track.clicks {
            guard let pos = resolve(track: track, motion: motion, time: clickT) else { continue }
            let px = ext.minX + CGFloat(min(max(pos.x, 0), 1)) * ext.width
            let py = ext.minY + (1 - CGFloat(min(max(pos.y, 0), 1))) * ext.height
            for phase in phases {
                let ageMs = (time - clickT) * 1000 - phase * effectDur
                guard ageMs >= 0 else { continue }
                let rp = CursorClickEffect.rippleProgress(ageMs: ageMs,
                                                          bounceDurationMs: bounceDur,
                                                          effectDurationMs: effectDur)
                guard rp > 0.01 else { continue }
                let radius = maxR * CGFloat(2 - rp)          // expands as it fades
                guard let graphic = makeClickGraphic(style: style.clickEffect, radius: radius,
                                                     opacity: rp * alpha, rgb: rgb) else { continue }
                let s = graphic.extent
                result = graphic.transformed(by: CGAffineTransform(translationX: px - s.width / 2,
                                                                   y: py - s.height / 2))
                    .composited(over: result)
            }
        }
        return result
    }

    private static func makeClickGraphic(style: CursorClickEffectStyle, radius: CGFloat,
                                         opacity: Double, rgb: [Double]) -> CIImage? {
        let d = Int(ceil(radius * 2)) + 4
        guard d > 4,
              let ctx = CGContext(data: nil, width: d, height: d, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        let a = max(0, min(opacity, 1))
        let color = CGColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: a)
        switch style {
        case .none:
            return nil
        case .ripple, .echo:
            let lw = max(1, radius * 0.12)
            ctx.setStrokeColor(color)
            ctx.setLineWidth(lw)
            ctx.strokeEllipse(in: CGRect(x: lw, y: lw, width: CGFloat(d) - lw * 2, height: CGFloat(d) - lw * 2))
        case .spotlight:
            // A filled halo: soft in the middle, transparent at the rim, so it reads as a
            // flash of light rather than a disc pasted over the frame.
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            let comps: [CGFloat] = [
                CGFloat(rgb[0]), CGFloat(rgb[1]), CGFloat(rgb[2]), CGFloat(a * 0.55),
                CGFloat(rgb[0]), CGFloat(rgb[1]), CGFloat(rgb[2]), 0,
            ]
            guard let gradient = CGGradient(colorSpace: space, colorComponents: comps,
                                            locations: [0, 1], count: 2) else { return nil }
            let c = CGPoint(x: CGFloat(d) / 2, y: CGFloat(d) / 2)
            ctx.drawRadialGradient(gradient, startCenter: c, startRadius: 0,
                                   endCenter: c, endRadius: CGFloat(d) / 2, options: [])
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// Composites the stylized cursor onto the (uncropped, unzoomed) source frame so it
    /// inherits the same crop/zoom/placement transforms as the footage.
    static func draw(on image: CIImage, track: CursorTrack?, time: Double, style: CursorStyle,
                     motion: SmoothedCursorTrack? = nil) -> CIImage {
        guard style.enabled, let pos = resolve(track: track, motion: motion, time: time) else { return image }
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }

        // The click bounce scales the sprite about its hotspot, so the pointer dips into
        // the click rather than drifting off the point it is indicating.
        let bounce = CGFloat(max(0.1, min(pos.scale, 2)))
        let base = min(ext.width, ext.height) * 0.05 * CGFloat(max(0.2, min(style.size, 6))) * bounce
        guard let sprite = makeSprite(kind: style.kind, size: base) else { return image }

        // Normalized (top-left origin) → CI pixel (bottom-left origin).
        let px = ext.minX + CGFloat(min(max(pos.x, 0), 1)) * ext.width
        let py = ext.minY + (1 - CGFloat(min(max(pos.y, 0), 1))) * ext.height

        // Sway rotates the sprite about its hotspot — the tip for an arrow, the middle for
        // a dot — so the point it indicates stays put while the body leans into the motion.
        var placed = sprite
        let s = sprite.extent
        let hotspot: CGPoint
        switch style.kind {
        case .arrow, .system: hotspot = CGPoint(x: s.minX, y: s.maxY)          // tip at top-left
        case .dot:            hotspot = CGPoint(x: s.midX, y: s.midY)
        }
        if abs(pos.rotation) > 0.0005 {
            placed = placed
                .transformed(by: CGAffineTransform(translationX: -hotspot.x, y: -hotspot.y))
                // CI's y axis runs opposite the screen's, so a clockwise on-screen lean is
                // a negative rotation here.
                .transformed(by: CGAffineTransform(rotationAngle: -CGFloat(pos.rotation)))
                .transformed(by: CGAffineTransform(translationX: hotspot.x, y: hotspot.y))
        }
        return placed.transformed(by: CGAffineTransform(translationX: px - hotspot.x,
                                                        y: py - hotspot.y))
            .composited(over: image)
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
