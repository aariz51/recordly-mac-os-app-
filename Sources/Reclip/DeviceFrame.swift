import Foundation
import CoreImage
import CoreGraphics
import AppKit

/// A decorative chrome wrapped around the recorded footage — a macOS window title bar
/// (traffic-light buttons) or a browser frame (buttons + address pill). Recordly offers
/// device/window frames; this is the engine-side renderer.
enum DeviceFrame: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case macOS = "macOS Window"
    case browser = "Browser"
    var id: String { rawValue }
}

enum DeviceFrameRenderer {
    /// Returns the footage with a chrome bar added above it (taller combined image), or the
    /// footage unchanged for `.none`. Origin is normalised to (0,0).
    static func apply(_ footage: CIImage, frame: DeviceFrame) -> CIImage {
        guard frame != .none else { return footage }
        let e = footage.extent
        guard e.width > 1, e.height > 1 else { return footage }
        let barH = (e.height * (frame == .browser ? 0.11 : 0.055)).rounded()
        guard let bar = makeBar(width: e.width, height: barH, frame: frame) else { return footage }
        // Footage at origin; bar sits on top (higher y in CI's bottom-origin space).
        let footageAtOrigin = footage.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        let barPlaced = bar.transformed(by: CGAffineTransform(translationX: 0, y: e.height))
        return barPlaced.composited(over: footageAtOrigin)
    }

    private static func makeBar(width: CGFloat, height: CGFloat, frame: DeviceFrame) -> CIImage? {
        let w = Int(width), h = Int(height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Bar background.
        let dark = frame == .macOS
        ctx.setFillColor(red: dark ? 0.16 : 0.93, green: dark ? 0.17 : 0.93, blue: dark ? 0.19 : 0.94, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Traffic-light buttons on the left.
        let r = height * 0.16
        let cy = height / 2
        let colors: [(CGFloat, CGFloat, CGFloat)] = [(0.98, 0.36, 0.34), (0.99, 0.74, 0.25), (0.30, 0.79, 0.32)]
        for (i, c) in colors.enumerated() {
            let cx = height * (0.55 + CGFloat(i) * 0.65)
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        }

        // Browser: a rounded address-bar pill in the middle.
        if frame == .browser {
            let pillH = height * 0.5
            let pillX = height * 3.2
            let pillW = CGFloat(w) - pillX - height * 0.8
            if pillW > 10 {
                let rect = CGRect(x: pillX, y: (height - pillH) / 2, width: pillW, height: pillH)
                let path = CGPath(roundedRect: rect, cornerWidth: pillH / 2, cornerHeight: pillH / 2, transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                ctx.fillPath()
            }
        }
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}
