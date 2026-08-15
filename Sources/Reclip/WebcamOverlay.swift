import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

struct WebcamSettings: Equatable {
    enum Corner: String, CaseIterable, Identifiable {
        // Original four (raw values preserved so existing .reclip projects still decode)…
        case bottomTrailing = "Bottom right"
        case bottomLeading = "Bottom left"
        case topTrailing = "Top right"
        case topLeading = "Top left"
        // …plus the five mid positions for a full 9-cell grid.
        case topCenter = "Top center"
        case centerLeading = "Center left"
        case center = "Center"
        case centerTrailing = "Center right"
        case bottomCenter = "Bottom center"
        var id: String { rawValue }
    }
    var enabled = false
    var corner: Corner = .bottomTrailing
    var sizeFraction: Double = 0.22   // width, as a fraction of the canvas short side
    var aspectRatio: Double = 1.0     // height / width (1 = square bubble)
    var marginFraction: Double = 0.04 // gap from the frame edge, fraction of short side
    var roundness: Double = 1.0       // 1 = fully round, 0 = square corners
    var mirror: Bool = true           // selfie-style horizontal flip
    var shadow: Bool = true           // soft drop shadow behind the bubble
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
        let bw = shortSide * CGFloat(settings.sizeFraction)               // bubble width
        let bh = bw * CGFloat(max(0.2, min(settings.aspectRatio, 5.0)))   // bubble height

        // Crop the camera frame to the bubble's aspect (bw:bh), centered.
        let ext = cam.extent
        let target = bw / bh
        let cropW: CGFloat, cropH: CGFloat
        if ext.width / ext.height > target { cropH = ext.height; cropW = ext.height * target }
        else { cropW = ext.width; cropH = ext.width / target }
        let crop = CGRect(x: ext.midX - cropW / 2, y: ext.midY - cropH / 2, width: cropW, height: cropH)
        var img = cam.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        // Selfie-style horizontal mirror.
        if settings.mirror {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: cropW, y: 0))
        }
        img = img.transformed(by: CGAffineTransform(scaleX: bw / cropW, y: bh / cropH))

        let cornerRadius = (min(bw, bh) / 2) * CGFloat(max(0, min(settings.roundness, 1)))
        let bubble = roundedMask(img, radius: cornerRadius)

        let margin = shortSide * CGFloat(settings.marginFraction)
        // Horizontal (leading/center/trailing) and vertical (bottom/middle/top) anchors.
        let leftX = margin, midX = (canvas.width - bw) / 2, rightX = canvas.width - bw - margin
        let botY = margin, midY = (canvas.height - bh) / 2, topY = canvas.height - bh - margin
        let x: CGFloat
        let y: CGFloat
        switch settings.corner {
        case .topLeading:      x = leftX;  y = topY
        case .topCenter:       x = midX;   y = topY
        case .topTrailing:     x = rightX; y = topY
        case .centerLeading:   x = leftX;  y = midY
        case .center:          x = midX;   y = midY
        case .centerTrailing:  x = rightX; y = midY
        case .bottomLeading:   x = leftX;  y = botY
        case .bottomCenter:    x = midX;   y = botY
        case .bottomTrailing:  x = rightX; y = botY
        }
        let positioned = bubble.transformed(by: CGAffineTransform(translationX: x, y: y))

        var result = base
        if settings.shadow, let shadow = makeShadow(positioned) {
            result = shadow.composited(over: result)
        }
        return positioned.composited(over: result)
    }

    private static func roundedMask(_ image: CIImage, radius: CGFloat) -> CIImage {
        let extent = image.extent
        let gen = CIFilter.roundedRectangleGenerator()
        gen.color = .white
        gen.extent = extent
        gen.radius = Float(radius)
        guard let mask = gen.outputImage else { return image }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = mask.cropped(to: extent)
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    /// Soft drop shadow from the bubble's alpha, offset slightly down.
    private static func makeShadow(_ image: CIImage) -> CIImage? {
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = image
        matrix.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 0.45)
        guard let sil = matrix.outputImage else { return nil }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = sil
        blur.radius = Float(min(image.extent.width, image.extent.height) * 0.06)
        return blur.outputImage?.transformed(by: CGAffineTransform(translationX: 0, y: -image.extent.height * 0.03))
    }
}
