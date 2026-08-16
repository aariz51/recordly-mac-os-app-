import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// GIF output size presets (Recordly parity).
enum GifSize: String, CaseIterable, Identifiable {
    case medium = "720p"
    case large = "1080p"
    case original = "Original"
    var id: String { rawValue }
    var maxWidth: CGFloat {
        switch self {
        case .medium: return 720
        case .large: return 1080
        case .original: return 100_000
        }
    }
}

/// Renders the styled composition to an animated GIF using AVAssetImageGenerator + ImageIO.
enum GifExport {

    static func export(source: URL,
                       to output: URL,
                       style: StyleOptions,
                       zoom: ZoomTimeline = ZoomTimeline(),
                       trim: CMTimeRange? = nil,
                       webcam: WebcamFrames = WebcamFrames(),
                       webcamSettings: WebcamSettings = WebcamSettings(),
                       annotations: [Annotation] = [],
                       speed: Double = 1.0,
                       fps: Double = 12,
                       maxWidth: CGFloat = 720,
                       loop: Bool = true,
                       bounce: Bool = false,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let tl = try await StyledExport.makeTimeline(source: source, style: style, zoom: zoom,
                                                     webcam: webcam, webcamSettings: webcamSettings,
                                                     annotations: annotations, trim: trim, speed: speed)

        let generator = AVAssetImageGenerator(asset: tl.asset)
        generator.videoComposition = tl.video
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 100)

        let start = 0.0
        let length = tl.duration
        let frameCount = max(1, Int(length * fps))

        // Render frames once.
        var images: [CGImage] = []
        for i in 0..<frameCount {
            let t = CMTime(seconds: start + Double(i) / fps, preferredTimescale: 600)
            images.append(try await generator.image(at: t).image)
            progress?(Double(i + 1) / Double(frameCount))
        }
        // Ping-pong: append the interior frames reversed so it plays forward then back.
        let sequence = (bounce && images.count > 2)
            ? images + images[1..<(images.count - 1)].reversed()
            : images

        try? FileManager.default.removeItem(at: output)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL,
                                                         UTType.gif.identifier as CFString,
                                                         sequence.count, nil) else {
            throw StyledExportError.exportSessionFailed("could not create GIF destination")
        }
        // Loop count 0 = infinite; 1 = play once.
        let gifProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFLoopCount as String: loop ? 0 : 1]]
        CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFDelayTime as String: 1.0 / fps]]
        for img in sequence {
            CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
        }

        if !CGImageDestinationFinalize(dest) {
            throw StyledExportError.exportSessionFailed("could not finalize GIF")
        }
    }
}
