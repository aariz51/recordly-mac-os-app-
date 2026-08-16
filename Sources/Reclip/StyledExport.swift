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
        case portrait = "3:4"
        case photo = "3:2"
        case photoPortrait = "2:3"
        case ultrawide = "21:9"
        var id: String { rawValue }
        var ratio: CGFloat? {
            switch self {
            case .source: return nil
            case .widescreen: return 16.0 / 9.0
            case .vertical: return 9.0 / 16.0
            case .square: return 1.0
            case .classic: return 4.0 / 3.0
            case .portrait: return 3.0 / 4.0
            case .photo: return 3.0 / 2.0
            case .photoPortrait: return 2.0 / 3.0
            case .ultrawide: return 21.0 / 9.0
            }
        }
    }

    var background: Background = .gradient(topRGB: (0.39, 0.36, 1.0), bottomRGB: (0.66, 0.33, 0.97))
    /// Optional user-supplied wallpaper. When set, it is aspect-filled behind the footage
    /// and takes precedence over `background`. Kept as a separate field (rather than a new
    /// `Background` case) so existing exhaustive switches over `Background` are unaffected.
    var backgroundImage: Data? = nil
    var paddingFraction: Double = 0.06     // fraction of the shorter side (linked, symmetric)
    /// Optional per-side padding (fractions of canvas width/height). When set it overrides
    /// the linked `paddingFraction`, so the footage need not be centered.
    struct PaddingInsets: Equatable {
        var top: Double = 0.06; var bottom: Double = 0.06
        var left: Double = 0.06; var right: Double = 0.06
    }
    var paddingInsets: PaddingInsets? = nil
    var cornerRadiusFraction: Double = 0.03
    var squircleCorners: Bool = false      // continuous (superellipse) corners instead of circular
    var shadowOpacity: Double = 0.35
    var shadowRadius: Double = 24
    var backgroundBlur: Double = 0         // 0 = off; blurs the source behind as the backdrop
    var aspect: Aspect = .source
    var deviceFrame: DeviceFrame = .none   // optional window/browser chrome around the footage
    var muteAudio: Bool = false            // drop the source audio from the export
    var audioVolume: Double = 1.0          // 0…2 gain applied to the source audio
    var normalizeAudio: Bool = false       // auto-boost quiet audio toward full scale
    var maxOutputHeight: Int? = nil        // cap output height (e.g. 1080/720); width scales with it

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
    case source = "Source"
    case high = "High"
    case medium = "Medium"
    case low = "Low"
    var id: String { rawValue }
    var preset: String {
        switch self {
        case .source, .high: return AVAssetExportPresetHighestQuality
        case .medium: return AVAssetExportPresetMediumQuality
        case .low: return AVAssetExportPresetLowQuality
        }
    }
}

/// Output frame-rate presets for the re-encode path (Recordly's 24/30/60).
enum MP4FrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24, fps30 = 30, fps60 = 60
    var id: Int { rawValue }
    var label: String { "\(rawValue) fps" }
}

/// Resolution-aware target bitrate, mirroring Recordly's `exportBitrate` tiers.
enum ExportBitrate {
    static let minimum = 2_000_000                      // Recordly MIN_MP4_BITRATE
    static func base(width: Int, height: Int) -> Int {
        let px = width * height
        if px <= 1280 * 720 { return 10_000_000 }
        if px <= 1920 * 1080 { return 20_000_000 }
        return 30_000_000
    }
    /// Recordly's getSourceQualityBitrate — the maximum tier for the "Source" quality.
    static func source(width: Int, height: Int) -> Int {
        let px = width * height
        if px > 2560 * 1440 { return 80_000_000 }
        if px > 1920 * 1080 { return 50_000_000 }
        return 30_000_000
    }
    static func mp4(width: Int, height: Int, quality: ExportQuality) -> Int {
        if quality == .source { return source(width: width, height: height) }
        let mult: Double
        switch quality { case .source, .high: mult = 1.0; case .medium: mult = 0.6; case .low: mult = 0.3 }
        return max(minimum, Int(Double(base(width: width, height: height)) * mult))
    }
}

/// Output canvas sizing — a port of Recordly's `calculateMp4SourceDimensions`. An aspect
/// preset fits *within* the source's bounding box (so a square export of a 1920×1080 clip
/// is 1080×1080, not an upscaled 1920×1920), with all dimensions floored to even values.
enum ExportDimensions {
    static func evenFloor(_ v: Double) -> Int { max(2, Int((v / 2).rounded(.down)) * 2) }

    static func fit(maxWidth: Double, maxHeight: Double, ratio: Double) -> CGSize {
        let mw = Double(evenFloor(maxWidth)), mh = Double(evenFloor(maxHeight))
        let r = (ratio.isFinite && ratio > 0) ? ratio : 16.0 / 9.0
        if mw / mh > r {
            let h = mh, w = Double(evenFloor(h * r))
            return CGSize(width: min(w, mw), height: h)
        }
        let w = mw, h = Double(evenFloor(w / r))
        return CGSize(width: w, height: min(h, mh))
    }

    /// `ratio == nil` → native/source passthrough (even-floored).
    static func canvas(sourceWidth: Double, sourceHeight: Double, ratio: Double?) -> CGSize {
        let sw = evenFloor(sourceWidth), sh = evenFloor(sourceHeight)
        guard let r = ratio else { return CGSize(width: sw, height: sh) }
        let longSide = Double(max(sw, sh)), shortSide = Double(min(sw, sh))
        let maxW = r >= 1 ? longSide : shortSide
        let maxH = r >= 1 ? shortSide : longSide
        return fit(maxWidth: maxW, maxHeight: maxH, ratio: r)
    }
}

enum StyledExport {

    /// A playable timeline (trim + speed applied) plus its styled video composition.
    struct StyledTimeline {
        let asset: AVAsset
        let video: AVMutableVideoComposition
        let duration: Double
        var audioMix: AVAudioMix? = nil
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
                             speedRegions: [SpeedSegment] = [],
                             keepRanges: [ClosedRange<Double>] = [],
                             cursor: CursorTrack? = nil,
                             cursorStyle: CursorStyle = CursorStyle(),
                             captions: [CaptionCue] = [],
                             captionSettings: CaptionSettings = CaptionSettings()) async throws -> StyledTimeline {
        let srcAsset = AVURLAsset(url: source)
        guard let vTrack = try await srcAsset.loadTracks(withMediaType: .video).first else {
            throw StyledExportError.noVideoTrack
        }
        let naturalSize = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let renderSize = naturalSize.applying(transform)
        let sourceSize = CGSize(width: abs(renderSize.width), height: abs(renderSize.height))
        // The output canvas may differ from the source (aspect-ratio presets); the
        // footage is then fit inside it and the background fills the rest. Sizing fits
        // within the source box (Recordly's calculateMp4SourceDimensions) so presets
        // don't upscale the source.
        let baseCanvas = ExportDimensions.canvas(sourceWidth: sourceSize.width,
                                                 sourceHeight: sourceSize.height,
                                                 ratio: style.aspect.ratio.map(Double.init))
        // Optional output-resolution cap; fraction-based padding/corners scale with it.
        let canvas: CGSize = {
            guard let maxH = style.maxOutputHeight, baseCanvas.height > CGFloat(maxH) else { return baseCanvas }
            let scale = CGFloat(maxH) / baseCanvas.height
            return CGSize(width: (baseCanvas.width * scale / 2).rounded() * 2,
                          height: (baseCanvas.height * scale / 2).rounded() * 2)
        }()
        let fullDuration = try await srcAsset.load(.duration)
        let srcRange = trim ?? CMTimeRange(start: .zero, duration: fullDuration)

        let comp = AVMutableComposition()
        guard let compV = comp.addMutableTrack(withMediaType: .video,
                                               preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StyledExportError.exportSessionFailed("could not create composition track")
        }
        // Multi-segment cut: insert only the kept source ranges, concatenated (empty = the
        // whole srcRange). Overlays follow via a CutMap; cuts are exclusive of speed edits.
        let insertRanges: [CMTimeRange] = keepRanges.isEmpty ? [srcRange]
            : keepRanges.sorted { $0.lowerBound < $1.lowerBound }.compactMap {
                let s = max(0, $0.lowerBound), e = min(fullDuration.seconds, $0.upperBound)
                guard e - s > 0.001 else { return nil }
                return CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600),
                                   duration: CMTime(seconds: e - s, preferredTimescale: 600))
            }
        var insertAt = CMTime.zero
        for r in insertRanges {
            try? compV.insertTimeRange(r, of: vTrack, at: insertAt)
            insertAt = insertAt + r.duration
        }
        compV.preferredTransform = transform
        // Audio passes through unless muted (Recordly's mute control).
        if !style.muteAudio {
            for aTrack in try await srcAsset.loadTracks(withMediaType: .audio) {
                if let compA = comp.addMutableTrack(withMediaType: .audio,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) {
                    var at = CMTime.zero
                    for r in insertRanges {
                        try? compA.insertTimeRange(r, of: aTrack, at: at)
                        at = at + r.duration
                    }
                }
            }
        }
        let cutMap: CutMap? = keepRanges.isEmpty ? nil
            : CutMap(keptRanges: insertRanges.map { ($0.start.seconds, $0.start.seconds + $0.duration.seconds) })

        let clampedSpeed = max(0.25, min(speed, 4.0))
        // Per-segment speed (overrides the single global speed when present). Skipped when
        // cutting, since cuts and speed edits are mutually exclusive.
        let trimStartSec = srcRange.start.seconds
        let speedMap: SpeedMap? = (cutMap != nil || speedRegions.isEmpty) ? nil : SpeedMap(
            regions: speedRegions.map { SpeedSegment(start: $0.start - trimStartSec, end: $0.end - trimStartSec, speed: $0.speed) },
            sourceDuration: srcRange.duration.seconds)
        if let speedMap {
            // Scale each non-1× segment. Right-to-left so a segment's composition range
            // still equals its source range when it's processed (left side unscaled).
            for seg in speedMap.segments.reversed() where abs(seg.speed - 1) > 1e-6 {
                let range = CMTimeRange(start: CMTime(seconds: seg.start, preferredTimescale: 600),
                                        duration: CMTime(seconds: seg.end - seg.start, preferredTimescale: 600))
                comp.scaleTimeRange(range, toDuration: CMTime(seconds: (seg.end - seg.start) / seg.speed, preferredTimescale: 600))
            }
        } else if cutMap == nil, abs(clampedSpeed - 1.0) > 0.01 {
            let scaled = CMTimeMultiplyByFloat64(srcRange.duration, multiplier: 1.0 / clampedSpeed)
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: srcRange.duration), toDuration: scaled)
        }

        let shortSide = min(canvas.width, canvas.height)
        let padding = shortSide * style.paddingFraction
        let corner = shortSide * style.cornerRadiusFraction
        // The rect (canvas coords, bottom-origin) the footage is fit + centered into.
        let contentRect: CGRect = {
            guard let ins = style.paddingInsets else {
                return CGRect(x: padding, y: padding,
                              width: canvas.width - padding * 2, height: canvas.height - padding * 2)
            }
            let l = canvas.width * ins.left, r = canvas.width * ins.right
            let t = canvas.height * ins.top, b = canvas.height * ins.bottom
            return CGRect(x: l, y: b, width: max(canvas.width - l - r, 1), height: max(canvas.height - t - b, 1))
        }()
        let ciContext = CIContext()
        let staticBackground = style.backgroundImage.map { makeImageBackground($0, size: canvas) }
            ?? makeBackground(style.background, size: canvas)
        let renderedAnnotations = Annotations.prerender(annotations, canvas: canvas)
        let trimStart = srcRange.start.seconds
        let blur = style.backgroundBlur
        let crop = style.crop

        let video = AVMutableVideoComposition(asset: comp) { request in
            // Output→source time: cut map (concatenated kept ranges), else piecewise speed
            // map, else the single-speed line.
            let srcT: Double
            if let cutMap {
                srcT = cutMap.sourceTime(forOutput: request.compositionTime.seconds)
            } else if let speedMap {
                srcT = trimStart + speedMap.sourceTime(forOutput: request.compositionTime.seconds)
            } else {
                srcT = trimStart + request.compositionTime.seconds * clampedSpeed
            }
            // Spotlight (dim around the cursor) then the stylized cursor, both in source
            // space so crop/zoom carry them.
            let lit = CursorRenderer.applySpotlight(on: request.sourceImage, track: cursor,
                                                    time: srcT, style: cursorStyle)
            let withCursor = CursorRenderer.draw(on: lit, track: cursor,
                                                 time: srcT, style: cursorStyle)
            let frame = applyCrop(withCursor, crop)
            // Background is either the static solid/gradient, or a blurred fill of the frame.
            let background = blur > 0.01
                ? blurredFill(frame, canvas: canvas, intensity: CGFloat(blur))
                : staticBackground
            let z = zoom.value(at: srcT)
            let zoomed = applyZoom(frame, scale: z.scale, focus: z.focus, canvas: canvas)
            let framed = DeviceFrameRenderer.apply(zoomed, frame: style.deviceFrame)
            let composed = compose(source: framed,
                                   background: background,
                                   canvas: canvas,
                                   contentRect: contentRect,
                                   corner: corner,
                                   squircle: style.squircleCorners,
                                   shadowOpacity: style.shadowOpacity,
                                   shadowRadius: style.shadowRadius,
                                   context: ciContext)
            let withCam = WebcamOverlay.composite(base: composed, canvas: canvas,
                                                  webcam: webcam, time: srcT, settings: webcamSettings,
                                                  zoomScale: z.scale)
            let withText = Annotations.composite(base: withCam, canvas: canvas,
                                                 rendered: renderedAnnotations, time: srcT)
            let withCaptions = CaptionRenderer.composite(base: withText, canvas: canvas,
                                                         cues: captions, time: srcT, settings: captionSettings)
            request.finish(with: withCaptions, context: nil)
        }
        video.renderSize = canvas

        // Optional audio-gain mix (Recordly's volume + normalize controls).
        var audioMix: AVAudioMix? = nil
        if !style.muteAudio {
            // Normalize: bring the loudest peak up toward full scale, then apply user gain.
            var gain = style.audioVolume
            if style.normalizeAudio {
                gain *= await Self.normalizationGain(for: srcAsset, range: srcRange)
            }
            if abs(gain - 1.0) > 0.001 {
                let audioTracks = comp.tracks(withMediaType: .audio)
                if !audioTracks.isEmpty {
                    let mix = AVMutableAudioMix()
                    mix.inputParameters = audioTracks.map { track in
                        let p = AVMutableAudioMixInputParameters(track: track)
                        p.setVolume(Float(max(0, min(gain, 4.0))), at: .zero)
                        return p
                    }
                    audioMix = mix
                }
            }
        }
        return StyledTimeline(asset: comp, video: video, duration: comp.duration.seconds, audioMix: audioMix)
    }

    /// Peak-normalization gain: scans the source audio for its loudest 16-bit sample and
    /// returns the gain that lifts it to ~0.95 full-scale (clamped 1…4). 1.0 if no/loud audio.
    private static func normalizationGain(for asset: AVURLAsset, range: CMTimeRange) async -> Double {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return 1.0 }
        reader.timeRange = range
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false])
        guard reader.canAdd(out) else { return 1.0 }
        reader.add(out)
        guard reader.startReading() else { return 1.0 }
        var peak: Int16 = 0
        while reader.status == .reading, let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            if let ptr, len > 1 {
                ptr.withMemoryRebound(to: Int16.self, capacity: len / 2) { p in
                    for i in 0..<(len / 2) { let a = Int16(truncatingIfNeeded: abs(Int(p[i]))); if a > peak { peak = a } }
                }
            }
        }
        guard peak > 0 else { return 1.0 }
        let target = 0.95 * Double(Int16.max)
        return min(4.0, max(1.0, target / Double(peak)))
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
        // Keep the zoom viewport inside the frame (Recordly's clampFocusToScale); a no-op
        // for centred focuses, but prevents a corner-biased zoom from running off the edge.
        let clampedFocus = FocusUtils.clampFocusToScale(focus, scale: scale)
        let extent = image.extent
        let fx = extent.minX + clampedFocus.x * extent.width
        let fy = extent.minY + (1.0 - clampedFocus.y) * extent.height   // top-left -> CI bottom-left
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
                       speedRegions: [SpeedSegment] = [],
                       keepRanges: [ClosedRange<Double>] = [],
                       quality: ExportQuality = .high,
                       cursor: CursorTrack? = nil,
                       cursorStyle: CursorStyle = CursorStyle(),
                       captions: [CaptionCue] = [],
                       captionSettings: CaptionSettings = CaptionSettings(),
                       progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let tl = try await makeTimeline(source: source, style: style, zoom: zoom,
                                        webcam: webcam, webcamSettings: webcamSettings,
                                        annotations: annotations, trim: trim, speed: speed,
                                        speedRegions: speedRegions, keepRanges: keepRanges,
                                        cursor: cursor, cursorStyle: cursorStyle,
                                        captions: captions, captionSettings: captionSettings)
        guard let export = AVAssetExportSession(asset: tl.asset, presetName: quality.preset) else {
            throw StyledExportError.exportSessionFailed("could not create export session")
        }
        export.videoComposition = tl.video
        export.audioMix = tl.audioMix
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

    /// Re-encodes through AVAssetReader → AVAssetWriter so the output frame-rate and
    /// bitrate are set explicitly. (AVAssetExportSession ignores a composition's
    /// frameDuration override, which is why the preset `export` can't change fps.)
    static func exportReencoded(source: URL,
                                to output: URL,
                                style: StyleOptions,
                                zoom: ZoomTimeline = ZoomTimeline(),
                                trim: CMTimeRange? = nil,
                                webcam: WebcamFrames = WebcamFrames(),
                                webcamSettings: WebcamSettings = WebcamSettings(),
                                annotations: [Annotation] = [],
                                speed: Double = 1.0,
                                quality: ExportQuality = .high,
                                frameRate: MP4FrameRate = .fps30,
                                motionBlur: Double = 0,
                                cursor: CursorTrack? = nil,
                                cursorStyle: CursorStyle = CursorStyle(),
                                captions: [CaptionCue] = [],
                                captionSettings: CaptionSettings = CaptionSettings(),
                                progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let tl = try await makeTimeline(source: source, style: style, zoom: zoom,
                                        webcam: webcam, webcamSettings: webcamSettings,
                                        annotations: annotations, trim: trim, speed: speed,
                                        cursor: cursor, cursorStyle: cursorStyle,
                                        captions: captions, captionSettings: captionSettings)
        let asset = tl.asset
        let video = tl.video
        video.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
        let canvas = video.renderSize
        let totalDuration = tl.duration

        // Reader: pull composed (styled) frames at the requested cadence.
        let reader = try AVAssetReader(asset: asset)
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)])
        vOut.videoComposition = video
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else { throw StyledExportError.exportSessionFailed("cannot read video") }
        reader.add(vOut)

        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        var aOut: AVAssetReaderAudioMixOutput?
        if !aTracks.isEmpty {
            let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2])
            o.audioMix = tl.audioMix    // apply the volume gain in the re-encode path too
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        // Writer: H.264 with an explicit average-bitrate + source-frame-rate hint.
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let bitrate = ExportBitrate.mp4(width: Int(canvas.width), height: Int(canvas.height), quality: quality)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(canvas.width), AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate.rawValue,
                AVVideoMaxKeyFrameIntervalKey: frameRate.rawValue * 2]])
        vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw StyledExportError.exportSessionFailed("cannot write video") }
        writer.add(vIn)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(canvas.width),
                kCVPixelBufferHeightKey as String: Int(canvas.height)])

        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
            i.expectsMediaDataInRealTime = false
            if writer.canAdd(i) { writer.add(i); aIn = i }
        }

        guard writer.startWriting() else {
            throw StyledExportError.exportSessionFailed(writer.error?.localizedDescription ?? "start failed")
        }
        guard reader.startReading() else {
            throw StyledExportError.exportSessionFailed(reader.error?.localizedDescription ?? "read failed")
        }
        writer.startSession(atSourceTime: .zero)

        let mbConfig = MotionBlur.config(amount: motionBlur)
        let frameDurationUs = 1_000_000.0 / Double(frameRate.rawValue)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await pumpResampledVideo(input: vIn, adaptor: adaptor, output: vOut,
                                         fps: frameRate.rawValue, duration: totalDuration,
                                         motionBlur: mbConfig, frameDurationUs: frameDurationUs,
                                         canvas: canvas) { t in
                    if let progress, totalDuration > 0 { progress(min(1, t / totalDuration)) }
                }
            }
            if let aIn, let aOut {
                group.addTask { await pump(input: aIn, output: aOut, label: "reclip.export.a", onTime: nil) }
            }
        }
        reader.cancelReading()
        await writer.finishWriting()
        if writer.status == .failed {
            throw StyledExportError.exportSessionFailed(writer.error?.localizedDescription ?? "write failed")
        }
    }

    /// Resamples composed frames to a fixed output frame-rate: each output slot at
    /// `k / fps` takes whichever source frame currently applies, so a lower fps drops
    /// frames and a higher fps duplicates them. This is how the output cadence is
    /// actually changed (the composition's own frameDuration is ignored by the reader).
    private static func pumpResampledVideo(input: AVAssetWriterInput,
                                           adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                           output: AVAssetReaderOutput,
                                           fps: Int,
                                           duration: Double,
                                           motionBlur: MotionBlur.Config? = nil,
                                           frameDurationUs: Double = 0,
                                           canvas: CGSize = .zero,
                                           onTime: (@Sendable (Double) -> Void)?) async {
        let queue = DispatchQueue(label: "reclip.export.v")
        let interval = 1.0 / Double(fps)
        let extent = CGRect(origin: .zero, size: canvas)
        let ciContext = motionBlur != nil ? CIContext() : nil
        let plan = motionBlur.map { MotionBlur.samplePlanUs(frameDurationUs: frameDurationUs, config: $0) }
        let window = motionBlur?.sampleCount ?? 1
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var current: CMSampleBuffer?
            var lookahead: CMSampleBuffer?
            var recent: [CIImage] = []       // last `window` composed frames, for temporal blur
            var boundary = 0.0               // time at which `current` stops applying
            var outIdx = 0
            var primed = false
            var done = false
            func pts(_ sb: CMSampleBuffer?) -> Double? {
                sb.map { CMSampleBufferGetPresentationTimeStamp($0).seconds }
            }
            func track(_ sb: CMSampleBuffer?) {
                guard window > 1, let sb, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
                recent.append(CIImage(cvPixelBuffer: pb))
                if recent.count > window { recent.removeFirst() }
            }
            // Emits `current` at `outTime`, blending the recent-frame window when motion
            // blur is on (weights come from the sample plan, oldest → newest).
            func emit(_ cur: CMSampleBuffer, at outTime: Double) {
                let time = CMTime(seconds: outTime, preferredTimescale: 600)
                if let plan, let ciContext, recent.count > 1, let pool = adaptor.pixelBufferPool {
                    let n = min(recent.count, plan.count)
                    let frames = Array(recent.suffix(n))
                    let weights = Array(plan.suffix(n))
                    let layers = zip(frames, weights).map { (image: $0, weight: $1.weight) }
                    if let blended = MotionBlur.blend(layers, extent: extent) {
                        var pb: CVPixelBuffer?
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                        if let pb {
                            ciContext.render(blended, to: pb)
                            adaptor.append(pb, withPresentationTime: time)
                            onTime?(outTime)
                            return
                        }
                    }
                }
                if let pb = CMSampleBufferGetImageBuffer(cur) {
                    adaptor.append(pb, withPresentationTime: time)
                    onTime?(outTime)
                }
            }
            input.requestMediaDataWhenReady(on: queue) {
                if !primed {
                    current = output.copyNextSampleBuffer()
                    lookahead = output.copyNextSampleBuffer()
                    boundary = pts(lookahead) ?? duration
                    track(current)
                    primed = true
                    if current == nil { input.markAsFinished(); cont.resume(); return }
                }
                while input.isReadyForMoreMediaData {
                    if done { input.markAsFinished(); cont.resume(); return }
                    let outTime = Double(outIdx) * interval
                    let atTail = lookahead == nil
                    if outTime < boundary - 1e-9 || (atTail && outTime <= duration + 1e-9) {
                        if let cur = current { emit(cur, at: outTime) }
                        outIdx += 1
                    } else if atTail {
                        done = true
                    } else {
                        current = lookahead
                        lookahead = output.copyNextSampleBuffer()
                        boundary = pts(lookahead) ?? duration
                        track(current)
                    }
                }
            }
        }
    }

    /// Drains one reader output into one writer input, resuming when the stream ends.
    private static func pump(input: AVAssetWriterInput,
                             output: AVAssetReaderOutput,
                             label: String,
                             onTime: (@Sendable (Double) -> Void)?) async {
        let queue = DispatchQueue(label: label)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard let sb = output.copyNextSampleBuffer() else {
                        input.markAsFinished(); cont.resume(); return
                    }
                    let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
                    if input.append(sb) {
                        onTime?(t)
                    } else {
                        input.markAsFinished(); cont.resume(); return
                    }
                }
            }
        }
    }

    // MARK: - Compositing

    private static func compose(source: CIImage,
                                background: CIImage,
                                canvas: CGSize,
                                contentRect: CGRect,
                                corner: CGFloat,
                                squircle: Bool = false,
                                shadowOpacity: Double,
                                shadowRadius: Double,
                                context: CIContext) -> CIImage {
        let targetWidth = contentRect.width
        let targetHeight = contentRect.height
        let srcExtent = source.extent
        guard srcExtent.width > 0, srcExtent.height > 0 else { return background }

        let scale = min(targetWidth / srcExtent.width, targetHeight / srcExtent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent

        // Center the footage within the content rect (not necessarily the whole canvas).
        let originX = contentRect.midX - scaledExtent.width / 2 - scaledExtent.minX
        let originY = contentRect.midY - scaledExtent.height / 2 - scaledExtent.minY
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: originX, y: originY))

        // Rounded-corner mask over the positioned footage.
        let rounded = roundCorners(positioned, radius: corner, squircle: squircle)

        // Layered drop shadow behind the footage card (Recordly stacks three profiles
        // — a wide soft base plus two tighter layers — for a more natural falloff than
        // a single blur). Each layer's alpha/blur/offset scales the user's settings.
        var result = background
        if shadowOpacity > 0.001 {
            for p in videoShadowProfiles {
                if let layer = makeShadowLayer(for: rounded,
                                               opacity: shadowOpacity * p.alphaScale,
                                               blur: shadowRadius * p.blurScale,
                                               offsetY: -shadowRadius * p.offsetScale) {
                    result = layer.composited(over: result)
                }
            }
        }
        return rounded.composited(over: result)
    }

    private static func roundCorners(_ image: CIImage, radius: CGFloat, squircle: Bool = false) -> CIImage {
        let extent = image.extent
        let maskImage: CIImage
        if squircle, let m = squircleMask(extent: extent, radius: radius) {
            maskImage = m
        } else {
            let mask = CIFilter.roundedRectangleGenerator()
            mask.color = CIColor.white
            mask.extent = extent
            mask.radius = Float(radius)
            guard let mm = mask.outputImage else { return image }
            maskImage = mm
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = maskImage.cropped(to: extent)
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    /// A superellipse (squircle) mask — white inside, clear outside — with corners that are
    /// fuller than a circle (continuous curvature, as Apple/Recordly use for cards).
    static func squircleMask(extent: CGRect, radius: CGFloat, n: CGFloat = 5) -> CIImage? {
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = min(radius, CGFloat(min(w, h)) / 2)
        ctx.addPath(squirclePath(width: CGFloat(w), height: CGFloat(h), radius: r, n: n))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }

    private static func squirclePath(width W: CGFloat, height H: CGFloat, radius r: CGFloat, n: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let steps = 14
        func pt(_ cx: CGFloat, _ cy: CGFloat, _ ang: CGFloat) -> CGPoint {
            let c = cos(ang), s = sin(ang)
            return CGPoint(x: cx + r * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                           y: cy + r * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        }
        func corner(_ cx: CGFloat, _ cy: CGFloat, _ a0: CGFloat, _ start: Bool) {
            for i in 0...steps {
                let a = a0 + (.pi / 2) * CGFloat(i) / CGFloat(steps)
                let p = pt(cx, cy, a)
                if start && i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
        corner(W - r, r, -.pi / 2, true)    // bottom-right
        corner(W - r, H - r, 0, false)      // top-right
        corner(r, H - r, .pi / 2, false)    // top-left
        corner(r, r, .pi, false)            // bottom-left
        path.closeSubpath()
        return path
    }

    /// One shadow layer: relative alpha/blur/offset scaling (Recordly's ShadowLayerProfile).
    /// Ratios mirror `VIDEO_SHADOW_LAYER_PROFILES` (blur 48/16/8, offset = 0.25·blur),
    /// re-expressed against the user's `shadowRadius` so the top layer spans ~2·radius.
    struct ShadowLayerProfile { let offsetScale: CGFloat; let alphaScale: Double; let blurScale: CGFloat }
    static let videoShadowProfiles: [ShadowLayerProfile] = [
        ShadowLayerProfile(offsetScale: 0.50,  alphaScale: 0.7, blurScale: 2.00),
        ShadowLayerProfile(offsetScale: 0.167, alphaScale: 0.5, blurScale: 0.66),
        ShadowLayerProfile(offsetScale: 0.083, alphaScale: 0.3, blurScale: 0.33),
    ]

    private static func makeShadowLayer(for image: CIImage, opacity: Double,
                                        blur: Double, offsetY: Double) -> CIImage? {
        // Black silhouette from the footage alpha, blurred and offset down the canvas.
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = image
        colorMatrix.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrix.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrix.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        guard let silhouette = colorMatrix.outputImage else { return nil }

        let blurFilter = CIFilter.gaussianBlur()
        blurFilter.inputImage = silhouette
        blurFilter.radius = Float(max(0, blur))
        return blurFilter.outputImage?.transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(offsetY)))
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

    /// Aspect-fills a user-supplied wallpaper image across the canvas, centered.
    private static func makeImageBackground(_ data: Data, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        guard let img = CIImage(data: data), img.extent.width > 0, img.extent.height > 0 else {
            return CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.12)).cropped(to: rect)
        }
        let scale = max(size.width / img.extent.width, size.height / img.extent.height)
        let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let e = scaled.extent
        return scaled.transformed(by: CGAffineTransform(
            translationX: (size.width - e.width) / 2 - e.minX,
            y: (size.height - e.height) / 2 - e.minY)).cropped(to: rect)
    }
}
