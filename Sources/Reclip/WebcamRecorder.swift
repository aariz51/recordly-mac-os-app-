import Foundation
import AVFoundation

/// Records the default camera to a sidecar `.webcam.mov` alongside the screen recording,
/// so the editor can later composite it as a webcam bubble overlay.
final class WebcamRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {

    private let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    /// The device the session is currently wired to, so a changed selection reconfigures
    /// instead of silently recording from the previous camera.
    private var configuredDeviceID: String?
    private var configured = false

    static func sidecarURL(for movie: URL) -> URL {
        movie.deletingPathExtension().appendingPathExtension("webcam.mov")
    }

    /// True if a usable camera is present.
    static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
            || AVCaptureDevice.default(for: .video) != nil
    }

    /// Configures the session for `deviceID` (nil = system default). Re-runs whenever the
    /// selected camera changes.
    private func configureIfNeeded(deviceID: String?) -> Bool {
        if configured && configuredDeviceID == deviceID { return true }
        session.beginConfiguration()
        // Swapping cameras means dropping the previous input first, or the session ends up
        // with two video inputs and refuses to add the new one.
        for input in session.inputs { session.removeInput(input) }
        session.sessionPreset = .high

        guard let device = DeviceEnumerator.camera(id: deviceID)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
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
        configuredDeviceID = deviceID
        return true
    }

    func start(besides movie: URL, deviceID: String? = nil) {
        guard configureIfNeeded(deviceID: deviceID) else { return }
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
