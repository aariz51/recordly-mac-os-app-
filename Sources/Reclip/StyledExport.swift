import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Visual polish applied to a raw recording: the footage is inset with padding,
/// given rounded corners and a drop shadow, and composited onto a styled background.
struct StyleOptions: Equatable {
    enum Background: Equatable {
        case solid(red: Double, green: Double, blue: Double)
        case gradient(topRGB: (Double, Double, Double), bottomRGB: (Double, Double, Double))

        static func == (lhs: Background, rhs: Background) -> Bool {
            switch (lhs, rhs) {
            case let (.solid(r1, g1, b1), .solid(r2, g2, b2)):
                return r1 == r2 && g1 == g2 && b1 == b2
            case let (.gradient(t1, b1), .gradient(t2, b2)):
                return t1 == t2 && b1 == b2
            default: return false
            }
        }
    }

    var background: Background = .gradient(topRGB: (0.39, 0.36, 1.0), bottomRGB: (0.66, 0.33, 0.97))
    var paddingFraction: Double = 0.06     // fraction of the shorter side
    var cornerRadiusFraction: Double = 0.03
    var shadowOpacity: Double = 0.35
    var shadowRadius: Double = 24
}

enum StyledExportError: LocalizedError {
    case noVideoTrack
    case exportSessionFailed(String)
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The recording has no video track."
        case .exportSessionFailed(let m): return "Export failed: \(m)"
        }
    }
}

/// Renders a styled MP4 from a source recording using a per-frame Core Image pipeline.
enum StyledExport {

    /// Builds a styled Core Image composition for both live preview and export.
    static func makeComposition(for asset: AVAsset, style: StyleOptions) async throws -> AVMutableVideoComposition {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StyledExportError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let renderSize = naturalSize.applying(transform)
        let size = CGSize(width: abs(renderSize.width), height: abs(renderSize.height))

        let shortSide = min(size.width, size.height)
        let padding = shortSide * style.paddingFraction
        let corner = shortSide * style.cornerRadiusFraction
        let ciContext = CIContext()
        let background = makeBackground(style.background, size: size)

        let composition = AVMutableVideoComposition(asset: asset) { request in
            let composed = compose(source: request.sourceImage,
                                   background: background,
                                   canvas: size,
                                   padding: padding,
                                   corner: corner,
                                   shadowOpacity: style.shadowOpacity,
                                   shadowRadius: style.shadowRadius,
                                   context: ciContext)
            request.finish(with: composed, context: nil)
        }
        composition.renderSize = size
        return composition
    }

    static func export(source: URL,
                       to output: URL,
                       style: StyleOptions) async throws {
        let asset = AVURLAsset(url: source)
        let composition = try await makeComposition(for: asset, style: style)

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw StyledExportError.exportSessionFailed("could not create export session")
        }
        export.videoComposition = composition
        export.outputURL = output
        export.outputFileType = .mp4
        try? FileManager.default.removeItem(at: output)

        try await export.export(to: output, as: .mp4)
    }

    // MARK: - Compositing

    private static func compose(source: CIImage,
                                background: CIImage,
                                canvas: CGSize,
                                padding: CGFloat,
                                corner: CGFloat,
                                shadowOpacity: Double,
                                shadowRadius: Double,
                                context: CIContext) -> CIImage {
        let targetWidth = canvas.width - padding * 2
        let targetHeight = canvas.height - padding * 2
        let srcExtent = source.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return background }

        let scale = min(targetWidth / srcExtent.width, targetHeight / srcExtent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent

        let originX = (canvas.width - scaledExtent.width) / 2 - scaledExtent.minX
        let originY = (canvas.height - scaledExtent.height) / 2 - scaledExtent.minY
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: originX, y: originY))

        // Rounded-corner mask over the positioned footage.
        let rounded = roundCorners(positioned, radius: corner)

        // Soft drop shadow behind the footage card.
        var result = background
        if shadowOpacity > 0.001 {
            if let shadow = makeShadow(for: rounded,
                                       opacity: shadowOpacity,
                                       radius: shadowRadius) {
                result = shadow.composited(over: result)
            }
        }
        return rounded.composited(over: result)
    }

    private static func roundCorners(_ image: CIImage, radius: CGFloat) -> CIImage {
        let extent = image.extent
        let mask = CIFilter.roundedRectangleGenerator()
        mask.color = CIColor.white
        mask.extent = extent
        mask.radius = Float(radius)
        guard let maskImage = mask.outputImage else { return image }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = maskImage.cropped(to: extent)
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    private static func makeShadow(for image: CIImage, opacity: Double, radius: Double) -> CIImage? {
        // Black silhouette from the footage alpha, blurred and offset slightly down.
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = image
        colorMatrix.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        guard let silhouette = colorMatrix.outputImage else { return nil }

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = silhouette
        blur.radius = Float(radius)
        return blur.outputImage?.transformed(by: CGAffineTransform(translationX: 0, y: -radius * 0.4))
    }

    private static func makeBackground(_ background: StyleOptions.Background, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        switch background {
        case .solid(let r, let g, let b):
            return CIImage(color: CIColor(red: r, green: g, blue: b)).cropped(to: rect)
        case .gradient(let top, let bottom):
            let g = CIFilter.linearGradient()
            g.point0 = CGPoint(x: 0, y: size.height)
            g.point1 = CGPoint(x: 0, y: 0)
            g.color0 = CIColor(red: top.0, green: top.1, blue: top.2)
            g.color1 = CIColor(red: bottom.0, green: bottom.1, blue: bottom.2)
            return (g.outputImage ?? CIImage(color: .gray)).cropped(to: rect)
        }
    }
}
