import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Captures a display (optionally with system audio + microphone) using ScreenCaptureKit
/// and writes an H.264 MP4 with AVAssetWriter. Original implementation for Reclip.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {

    enum RecorderError: LocalizedError {
        case noDisplay
        case alreadyRecording
        case notRecording
        case writerSetupFailed
        var errorDescription: String? {
            switch self {
            case .noDisplay: return "No display was available to record."
            case .alreadyRecording: return "A recording is already in progress."
            case .notRecording: return "There is no active recording to stop."
            case .writerSetupFailed: return "Could not set up the movie writer."
            }
        }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var captureMicrophone = false
    @Published var captureSystemAudio = true

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var startTime: CMTime = .zero
    private var timer: Timer?
    private var wallStart: Date?

    private let sampleQueue = DispatchQueue(label: "com.aariz51.reclip.sample")

    /// Output URL for the current recording.
    private(set) var outputURL: URL?

    // MARK: - Discovery

    func availableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                           onScreenWindowsOnly: true)
        return content.displays
    }

    // MARK: - Recording lifecycle

    func start(display: SCDisplay, to url: URL) async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        let config = SCStreamConfiguration()
        config.width = display.width * 2      // capture at retina scale
        config.height = display.height * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6
        if captureSystemAudio { config.capturesAudio = true }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        try setupWriter(url: url, width: config.width, height: config.height)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream
        self.outputURL = url

        try await stream.startCapture()

        isRecording = true
        wallStart = Date()
        startElapsedTimer()
    }

    func stop() async throws {
        guard isRecording, let stream else { throw RecorderError.notRecording }
        try await stream.stopCapture()
        self.stream = nil

        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        micInput?.markAsFinished()

        if let writer {
            await writer.finishWriting()
        }
        cleanup()
    }

    // MARK: - Writer

    private func setupWriter(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else {
            throw RecorderError.writerSetupFailed
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: width * height * 8,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vInput.expectsMediaDataInRealTime = true
        if writer.canAdd(vInput) { writer.add(vInput) }
        self.videoInput = vInput

        if captureSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 48000,
                AVEncoderBitRateKey: 128000
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) { writer.add(aInput) }
            self.audioInput = aInput
        }

        writer.startWriting()
        self.writer = writer
    }

    private func cleanup() {
        isRecording = false
        sessionStarted = false
        writer = nil
        videoInput = nil
        audioInput = nil
        micInput = nil
        timer?.invalidate()
        timer = nil
        elapsed = 0
    }

    private func startElapsedTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.wallStart else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }
}

// MARK: - SCStreamOutput

extension ScreenRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        Task { @MainActor in
            self.append(sampleBuffer, of: type)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer, writer.status == .writing else { return }

        if !sessionStarted {
            startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: startTime)
            sessionStarted = true
        }

        switch type {
        case .screen:
            if let input = videoInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        case .audio:
            if let input = audioInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        default:
            break
        }
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            self.cleanup()
        }
    }
}
