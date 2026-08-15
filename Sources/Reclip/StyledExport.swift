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

    enum Aspect: String, CaseIterable, Identifiable {
        case source = "Source"
        case widescreen = "16:9"
        case vertical = "9:16"
        case square = "1:1"
        case classic = "4:3"
        var id: String { rawValue }
        var ratio: CGFloat? {
            switch self {
            case .source: return nil
            case .widescreen: return 16.0 / 9.0
            case .vertical: return 9.0 / 16.0
            case .square: return 1.0
            case .classic: return 4.0 / 3.0
            }
        }
    }

    var background: Background = .gradient(topRGB: (0.39, 0.36, 1.0), bottomRGB: (0.66, 0.33, 0.97))
    var paddingFraction: Double = 0.06     // fraction of the shorter side
    var cornerRadiusFraction: Double = 0.03
    var shadowOpacity: Double = 0.35
    var shadowRadius: Double = 24
    var backgroundBlur: Double = 0         // 0 = off; blurs the source behind as the backdrop
    var aspect: Aspect = .source

    /// Fraction of each edge trimmed from the recorded frame (0…0.5 each).
    struct CropInsets: Equatable {
        var top: Double = 0
        var bottom: Double = 0
        var left: Double = 0
        var right: Double = 0
        static let zero = CropInsets()
        var hasCrop: Bool { top + bottom + left + right > 0.001 }
    }
    var crop: CropInsets = .zero
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
enum ExportQuality: String, CaseIterable, Identifiable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"
    var id: String { rawValue }
    var preset: String {
        switch self {
        case .high: return AVAssetExportPresetHighestQuality
        case .medium: return AVAssetExportPresetMediumQuality
        case .low: return AVAssetExportPresetLowQuality
        }
    }
}

enum StyledExport {

    /// A playable timeline (trim + speed applied) plus its styled video composition.
    struct StyledTimeline {
        let asset: AVAsset
        let video: AVMutableVideoComposition
        let duration: Double
    }

    /// Builds a trimmed + speed-adjusted composition and its styled Core Image video
    /// composition. Output time maps back to source time via `trimStart + outT * speed`,
    /// so zoom, webcam and captions (all keyed to source time) stay in sync.
    static func makeTimeline(source: URL,
                             style: StyleOptions,
                             zoom: ZoomTimeline = ZoomTimeline(),
                             webcam: WebcamFrames = WebcamFrames(),
                             webcamSettings: WebcamSettings = WebcamSettings(),
                             annotations: [Annotation] = [],
                             trim: CMTimeRange? = nil,
                             speed: Double = 1.0,
                             cursor: CursorTrack? = nil,
                             cursorStyle: CursorStyle = CursorStyle()) async throws -> StyledTimeline {
        let srcAsset = AVURLAsset(url: source)
        guard let vTrack = try await srcAsset.loadTracks(withMediaType: .video).first else {
            throw StyledExportError.noVideoTrack
        }
        let naturalSize = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let renderSize = naturalSize.applying(transform)
        let sourceSize = CGSize(width: abs(renderSize.width), height: abs(renderSize.height))
        // The output canvas may differ from the source (aspect-ratio presets);
        // the footage is then fit inside it and the background fills the rest.
        let canvas: CGSize = {
            guard let ratio = style.aspect.ratio else { return sourceSize }
            let base = max(sourceSize.width, sourceSize.height)
            let raw = ratio >= 1 ? CGSize(width: base, height: base / ratio)
                                 : CGSize(width: base * ratio, height: base)
            return CGSize(width: (raw.width / 2).rounded() * 2, height: (raw.height / 2).rounded() * 2)
        }()
        let fullDuration = try await srcAsset.load(.duration)
        let srcRange = trim ?? CMTimeRange(start: .zero, duration: fullDuration)

        let comp = AVMutableComposition()
        guard let compV = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StyledExportError.exportSessionFailed("could not create composition track")
        }
        try compV.insertTimeRange(srcRange, of: vTrack, at: .zero)
        compV.preferredTransform = transform
        for aTrack in try await srcAsset.loadTracks(withMediaType: .audio) {
            if let compA = comp.addMutableTrack(withMediaType: .audio,
                                                preferredTrackID: kCMPersistentTrackID_Invalid) {
                try? compA.insertTimeRange(srcRange, of: aTrack, at: .zero)
            }
        }

        let clampedSpeed = max(0.25, min(speed, 4.0))
        if abs(clampedSpeed - 1.0) > 0.01 {
            let scaled = CMTimeMultiplyByFloat64(srcRange.duration, multiplier: 1.0 / clampedSpeed)
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: srcRange.duration), toDuration: scaled)
        }

        let shortSide = min(canvas.width, canvas.height)
        let padding = shortSide * style.paddingFraction
        let corner = shortSide * style.cornerRadiusFraction
        let ciContext = CIContext()
        let staticBackground = makeBackground(style.background, size: canvas)
        let renderedAnnotations = Annotations.prerender(annotations, canvas: canvas)
        let trimStart = srcRange.start.seconds
        let blur = style.backgroundBlur
        let crop = style.crop

        let video = AVMutableVideoComposition(asset: comp) { request in
            let srcT = trimStart + request.compositionTime.seconds * clampedSpeed
            // Draw the stylized cursor in source space first, so crop/zoom carry it.
            let withCursor = CursorRenderer.draw(on: request.sourceImage, track: cursor,
                                                 time: srcT, style: cursorStyle)
            let frame = applyCrop(withCursor, crop)
            // Background is either the static solid/gradient, or a blurred fill of the frame.
            let background = blur > 0.01
                ? blurredFill(frame, canvas: canvas, intensity: CGFloat(blur))
                : staticBackground
            let z = zoom.value(at: srcT)
            let zoomed = applyZoom(frame, scale: z.scale, focus: z.focus, canvas: canvas)
            let composed = compose(source: zoomed,
                                   background: background,
                                   canvas: canvas,
                                   padding: padding,
                                   corner: corner,
                                   shadowOpacity: style.shadowOpacity,
                                   shadowRadius: style.shadowRadius,
                                   context: ciContext)
            let withCam = WebcamOverlay.composite(base: composed, canvas: canvas,
                                                  webcam: webcam, time: srcT, settings: webcamSettings)
            let withText = Annotations.composite(base: withCam, canvas: canvas,
                                                 rendered: renderedAnnotations, time: srcT)
            request.finish(with: withText, context: nil)
        }
        video.renderSize = canvas
        return StyledTimeline(asset: comp, video: video, duration: comp.duration.seconds)
    }

    /// Aspect-fills the frame across the whole canvas, blurred and darkened, as a backdrop.
    private static func blurredFill(_ image: CIImage, canvas: CGSize, intensity: CGFloat) -> CIImage {
        let rect = CGRect(origin: .zero, size: canvas)
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return CIImage(color: .black).cropped(to: rect) }
        let scale = max(canvas.width / ext.width, canvas.height / ext.height)
        var img = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let e = img.extent
        img = img.transformed(by: CGAffineTransform(translationX: (canvas.width - e.width) / 2 - e.minX,
                                                    y: (canvas.height - e.height) / 2 - e.minY))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = img.clampedToExtent()
        blur.radius = Float(intensity * min(canvas.width, canvas.height) * 0.03)
        let blurred = (blur.outputImage ?? img).cropped(to: rect)
        let darken = CIFilter.colorControls()
        darken.inputImage = blurred
        darken.brightness = -0.15
        return (darken.outputImage ?? blurred).cropped(to: rect)
    }

    /// Trims the recorded frame by the given edge fractions and re-origins it at zero.
    private static func applyCrop(_ image: CIImage, _ crop: StyleOptions.CropInsets) -> CIImage {
        guard crop.hasCrop else { return image }
        let e = image.extent
        let left = CGFloat(min(max(crop.left, 0), 0.49))
        let right = CGFloat(min(max(crop.right, 0), 0.49))
        let top = CGFloat(min(max(crop.top, 0), 0.49))
        let bottom = CGFloat(min(max(crop.bottom, 0), 0.49))
        // CI is bottom-origin: raise the origin by the bottom inset, shrink height by top+bottom.
        let rect = CGRect(x: e.minX + left * e.width,
                          y: e.minY + bottom * e.height,
                          width: max(e.width * (1 - left - right), 1),
                          height: max(e.height * (1 - top - bottom), 1))
        return image.cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Scales the frame around a normalized (top-left origin) focus point, keeping the original extent.
    private static func applyZoom(_ image: CIImage, scale: CGFloat, focus: CGPoint, canvas: CGSize) -> CIImage {
        guard scale > 1.0001 else { return image }
        let extent = image.extent
        let fx = extent.minX + focus.x * extent.width
        let fy = extent.minY + (1.0 - focus.y) * extent.height   // top-left -> CI bottom-left
        let t = CGAffineTransform(translationX: fx, y: fy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -fx, y: -fy)
        return image.transformed(by: t).cropped(to: extent)
    }

    static func export(source: URL,
                       to output: URL,
                       style: StyleOptions,
                       zoom: ZoomTimeline = ZoomTimeline(),
                       trim: CMTimeRange? = nil,
                       webcam: WebcamFrames = WebcamFrames(),
                       webcamSettings: WebcamSettings = WebcamSettings(),
                       annotations: [Annotation] = [],
                       speed: Double = 1.0,
                       quality: ExportQuality = .high,
                       cursor: CursorTrack? = nil,
                       cursorStyle: CursorStyle = CursorStyle(),
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let tl = try await makeTimeline(source: source, style: style, zoom: zoom,
                                        webcam: webcam, webcamSettings: webcamSettings,
                                        annotations: annotations, trim: trim, speed: speed,
                                        cursor: cursor, cursorStyle: cursorStyle)
        guard let export = AVAssetExportSession(asset: tl.asset, presetName: quality.preset) else {
            throw StyledExportError.exportSessionFailed("could not create export session")
        }
        export.videoComposition = tl.video
        export.outputURL = output
        export.outputFileType = .mp4
        try? FileManager.default.removeItem(at: output)

        guard let progress else {
            try await export.export(to: output, as: .mp4)
            return
        }

        // Report a real fraction while the render runs, so the UI can say how
        // much is left rather than only that something is happening.
        async let running: Void = export.export(to: output, as: .mp4)
        for await state in export.states(updateInterval: 0.25) {
            if case .exporting(let p) = state { progress(p.fractionCompleted) }
        }
        try await running
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
