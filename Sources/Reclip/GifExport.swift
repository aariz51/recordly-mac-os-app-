import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

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

        try? FileManager.default.removeItem(at: output)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL,
                                                         UTType.gif.identifier as CFString,
                                                         frameCount, nil) else {
            throw StyledExportError.exportSessionFailed("could not create GIF destination")
        }
        // Loop count 0 = infinite; 1 = play once.
        let gifProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFLoopCount as String: loop ? 0 : 1]]
        CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFDelayTime as String: 1.0 / fps]]

        for i in 0..<frameCount {
            let t = CMTime(seconds: start + Double(i) / fps, preferredTimescale: 600)
            let result = try await generator.image(at: t)
            CGImageDestinationAddImage(dest, result.image, frameProps as CFDictionary)
            progress?(Double(i + 1) / Double(frameCount))
        }

        if !CGImageDestinationFinalize(dest) {
            throw StyledExportError.exportSessionFailed("could not finalize GIF")
        }
    }
}
