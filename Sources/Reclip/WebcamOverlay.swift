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
    var cropZoom: Double = 1.0        // 1 = full frame; >1 zooms into the center of the feed
    var cropOffsetX: Double = 0       // -1…1 pan within the feed (only meaningful when cropZoom>1)
    var cropOffsetY: Double = 0
    var timeOffset: Double = 0        // seconds to shift the webcam track vs the screen (sync)
    var reactToZoom: Bool = false     // grow the bubble as the screen zooms in
    var marginFraction: Double = 0.04 // gap from the frame edge, fraction of short side
    var roundness: Double = 1.0       // 1 = fully round, 0 = square corners
    var mirror: Bool = true           // selfie-style horizontal flip
    var shadow: Bool = true           // soft drop shadow behind the bubble
    /// User-attached footage; nil uses the sidecar recorded alongside the clip.
    var sourcePath: String? = nil
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

    /// Loads the webcam sidecar recorded alongside `movie`, or `override` when the user has
    /// attached their own footage (Recordly lets a clip be paired with any camera file).
    static func load(for movie: URL, override: URL? = nil,
                     targetWidth: CGFloat = 400) async -> WebcamFrames {
        let url = override ?? WebcamRecorder.sidecarURL(for: movie)
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
                          settings: WebcamSettings,
                          zoomScale: CGFloat = 1.0) -> CIImage {
        guard settings.enabled, let cam = webcam.nearest(time + settings.timeOffset) else { return base }

        let shortSide = min(canvas.width, canvas.height)
        // React-to-zoom: grow the bubble modestly as the screen zooms in.
        let react = settings.reactToZoom ? (1 + max(0, zoomScale - 1) * 0.35) : 1.0
        let bw = shortSide * CGFloat(settings.sizeFraction) * react       // bubble width
        let bh = bw * CGFloat(max(0.2, min(settings.aspectRatio, 5.0)))   // bubble height

        // Crop the camera frame to the bubble's aspect (bw:bh), centered.
        let ext = cam.extent
        let target = bw / bh
        let cropW: CGFloat, cropH: CGFloat
        if ext.width / ext.height > target { cropH = ext.height; cropW = ext.height * target }
        else { cropW = ext.width; cropH = ext.width / target }
        // Optional center zoom into the feed (crop a smaller region, then scale it up to fill).
        let zoom = CGFloat(max(1.0, min(settings.cropZoom, 3.0)))
        let zCropW = cropW / zoom, zCropH = cropH / zoom
        // Pan within the available margin (clamped so the crop stays inside the feed).
        let marginX = (ext.width - zCropW) / 2, marginY = (ext.height - zCropH) / 2
        let cx = ext.midX + CGFloat(max(-1, min(settings.cropOffsetX, 1))) * marginX
        let cy = ext.midY + CGFloat(max(-1, min(settings.cropOffsetY, 1))) * marginY
        let crop = CGRect(x: cx - zCropW / 2, y: cy - zCropH / 2, width: zCropW, height: zCropH)
        var img = cam.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        // Selfie-style horizontal mirror.
        if settings.mirror {
            img = img.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
                .transformed(by: CGAffineTransform(translationX: zCropW, y: 0))
        }
        img = img.transformed(by: CGAffineTransform(scaleX: bw / zCropW, y: bh / zCropH))

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
