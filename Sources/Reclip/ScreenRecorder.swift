import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// The thing being recorded: a whole display or a single window.
enum CaptureSource: Hashable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

/// Captures a display or window (optionally with system audio + microphone) using
/// ScreenCaptureKit and writes an H.264 MP4 with AVAssetWriter. Original implementation.
@MainActor
final class ScreenRecorder: NSObject, ObservableObject {

    enum RecorderError: LocalizedError {
        case noSource
        case alreadyRecording
        case notRecording
        case writerSetupFailed
        var errorDescription: String? {
            switch self {
            case .noSource: return "No screen or window was available to record."
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
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var timer: Timer?
    private var wallStart: Date?

    private let sampleQueue = DispatchQueue(label: "com.aariz51.reclip.sample")
    private let cursorSampler = CursorSampler()
    private(set) var outputURL: URL?

    // MARK: - Discovery

    private func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    func availableDisplays() async throws -> [SCDisplay] {
        try await shareableContent().displays
    }

    /// On-screen windows worth offering (named, reasonably sized).
    func availableWindows() async throws -> [SCWindow] {
        let content = try await shareableContent()
        return content.windows.filter { win in
            guard let title = win.title, !title.isEmpty else { return false }
            guard win.frame.width > 120, win.frame.height > 80 else { return false }
            return win.isOnScreen
        }
    }

    // MARK: - Recording lifecycle

    func start(source: CaptureSource, to url: URL) async throws {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        let content = try await shareableContent()
        let filter: SCContentFilter
        let pixelWidth: Int
        let pixelHeight: Int

        switch source {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw RecorderError.noSource
            }
            filter = SCContentFilter(display: display, excludingWindows: [])
            pixelWidth = display.width * 2
            pixelHeight = display.height * 2
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else {
                throw RecorderError.noSource
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            pixelWidth = Int(window.frame.width) * 2
            pixelHeight = Int(window.frame.height) * 2
        }

        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = captureSystemAudio
        if captureMicrophone {
            config.captureMicrophone = true
        }

        try setupWriter(url: url, width: pixelWidth, height: pixelHeight)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if captureSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        self.stream = stream
        self.outputURL = url

        try await stream.startCapture()
        isRecording = true
        wallStart = Date()
        cursorSampler.start()
        startElapsedTimer()
    }

    func stop() async throws {
        guard isRecording, let stream else { throw RecorderError.notRecording }
        try await stream.stopCapture()
        self.stream = nil

        let track = cursorSampler.stop()
        if let url = outputURL { track.save(besides: url) }

        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        if let writer { await writer.finishWriting() }
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

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 48000,
            AVEncoderBitRateKey: 128000
        ]
        if captureSystemAudio {
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            if writer.canAdd(aInput) { writer.add(aInput) }
            self.systemAudioInput = aInput
        }
        if captureMicrophone {
            let mInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            mInput.expectsMediaDataInRealTime = true
            if writer.canAdd(mInput) { writer.add(mInput) }
            self.micInput = mInput
        }

        writer.startWriting()
        self.writer = writer
    }

    private func cleanup() {
        isRecording = false
        sessionStarted = false
        writer = nil
        videoInput = nil
        systemAudioInput = nil
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
        Task { @MainActor in self.append(sampleBuffer, of: type) }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer, writer.status == .writing else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }

        switch type {
        case .screen:
            if let input = videoInput, input.isReadyForMoreMediaData { input.append(sampleBuffer) }
        case .audio:
            if let input = systemAudioInput, input.isReadyForMoreMediaData { input.append(sampleBuffer) }
        case .microphone:
            if let input = micInput, input.isReadyForMoreMediaData { input.append(sampleBuffer) }
        default:
            break
        }
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.cleanup() }
    }
}
