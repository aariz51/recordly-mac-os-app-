import Foundation
import AVFoundation

/// Records the default camera to a sidecar `.webcam.mov` alongside the screen recording,
/// so the editor can later composite it as a webcam bubble overlay.
final class WebcamRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {

    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private var configured = false

    static func sidecarURL(for movie: URL) -> URL {
        movie.deletingPathExtension().appendingPathExtension("webcam.mov")
    }

    /// True if a usable camera is present.
    static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
            || AVCaptureDevice.default(for: .video) != nil
    }

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
        return true
    }

    func start(besides movie: URL) {
        guard configureIfNeeded() else { return }
        let url = Self.sidecarURL(for: movie)
        try? FileManager.default.removeItem(at: url)
        if !session.isRunning { session.startRunning() }
        output.startRecording(to: url, recordingDelegate: self)
    }

    func stop() {
        if output.isRecording { output.stopRecording() }
        if session.isRunning { session.stopRunning() }
    }

    // AVCaptureFileOutputRecordingDelegate
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        // Sidecar written (or failed silently); the editor checks for its presence.
    }
}
