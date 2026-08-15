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
                       fps: Double = 12,
                       maxWidth: CGFloat = 720) async throws {
        let asset = AVURLAsset(url: source)
        let composition = try await StyledExport.makeComposition(for: asset, style: style, zoom: zoom,
                                                                 webcam: webcam, webcamSettings: webcamSettings,
                                                                 annotations: annotations)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.videoComposition = composition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth * 100)

        let totalDuration = try await asset.load(.duration).seconds
        let start = trim?.start.seconds ?? 0
        let length = trim?.duration.seconds ?? totalDuration
        let frameCount = max(1, Int(length * fps))

        try? FileManager.default.removeItem(at: output)
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL,
                                                         UTType.gif.identifier as CFString,
                                                         frameCount, nil) else {
            throw StyledExportError.exportSessionFailed("could not create GIF destination")
        }
        let gifProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFLoopCount as String: 0]]
        CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary as String:
                            [kCGImagePropertyGIFDelayTime as String: 1.0 / fps]]

        for i in 0..<frameCount {
            let t = CMTime(seconds: start + Double(i) / fps, preferredTimescale: 600)
            let result = try await generator.image(at: t)
            CGImageDestinationAddImage(dest, result.image, frameProps as CFDictionary)
        }

        if !CGImageDestinationFinalize(dest) {
            throw StyledExportError.exportSessionFailed("could not finalize GIF")
        }
    }
}
