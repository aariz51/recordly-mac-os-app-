import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

struct WebcamSettings: Equatable {
    enum Corner: String, CaseIterable, Identifiable {
        case bottomTrailing = "Bottom right"
        case bottomLeading = "Bottom left"
        case topTrailing = "Top right"
        case topLeading = "Top left"
        var id: String { rawValue }
    }
    var enabled = false
    var corner: Corner = .bottomTrailing
    var sizeFraction: Double = 0.22   // fraction of the canvas short side
}

/// Pre-decoded webcam frames (detached from their pixel buffers) keyed by time.
struct WebcamFrames {
    var frames: [(t: Double, image: CIImage)] = []
    var isEmpty: Bool { frames.isEmpty }

    func nearest(_ time: Double) -> CIImage? {
        guard !frames.isEmpty else { return nil }
        var best = frames[0].image
        for f in frames where f.t <= time { best = f.image }
        return best
    }
}

enum WebcamOverlay {

    static func load(for movie: URL, targetWidth: CGFloat = 400) async -> WebcamFrames {
        let url = WebcamRecorder.sidecarURL(for: movie)
        guard FileManager.default.fileExists(atPath: url.path) else { return WebcamFrames() }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return WebcamFrames() }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(output) else { return WebcamFrames() }
        reader.add(output)
        reader.startReading()

        let ctx = CIContext()
        var frames: [(Double, CIImage)] = []
        while reader.status == .reading, let sb = output.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            var ci = CIImage(cvPixelBuffer: pb)
            let scale = targetWidth / max(ci.extent.width, 1)
            ci = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let cg = ctx.createCGImage(ci, from: ci.extent) {
                frames.append((t, CIImage(cgImage: cg)))   // detached copy
            }
        }
        return WebcamFrames(frames: frames)
    }

    static func composite(base: CIImage,
                          canvas: CGSize,
                          webcam: WebcamFrames,
                          time: Double,
                          settings: WebcamSettings) -> CIImage {
        guard settings.enabled, let cam = webcam.nearest(time) else { return base }

        let shortSide = min(canvas.width, canvas.height)
        let diameter = shortSide * settings.sizeFraction

        // Center-crop the camera frame to a square.
        let ext = cam.extent
        let side = min(ext.width, ext.height)
        let crop = CGRect(x: ext.midX - side / 2, y: ext.midY - side / 2, width: side, height: side)
        var square = cam.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        square = square.transformed(by: CGAffineTransform(scaleX: diameter / side, y: diameter / side))

        let bubble = circleMask(square, diameter: diameter)

        let margin = shortSide * 0.04
        let x: CGFloat
        let y: CGFloat
        switch settings.corner {
        case .bottomTrailing: x = canvas.width - diameter - margin; y = margin
        case .bottomLeading:  x = margin;                           y = margin
        case .topTrailing:    x = canvas.width - diameter - margin; y = canvas.height - diameter - margin
        case .topLeading:     x = margin;                           y = canvas.height - diameter - margin
        }
        let positioned = bubble.transformed(by: CGAffineTransform(translationX: x, y: y))
        return positioned.composited(over: base)
    }

    private static func circleMask(_ image: CIImage, diameter: CGFloat) -> CIImage {
        let extent = image.extent
        let gen = CIFilter.roundedRectangleGenerator()
        gen.color = .white
        gen.extent = extent
        gen.radius = Float(diameter / 2)
        guard let mask = gen.outputImage else { return image }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask.cropped(to: extent)
        return blend.outputImage?.cropped(to: extent) ?? image
    }
}
