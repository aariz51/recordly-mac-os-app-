import AVFoundation
import CoreGraphics

/// Capture-permission preflight — the native equivalent of Recordly's permission checks.
/// Reads the current TCC authorization for screen recording, camera, and microphone
/// *without* prompting, so the UI can show accurate status and a "grant" affordance before
/// a recording is attempted. Screen-recording access can only be granted by the user in
/// System Settings (a hard OS gate), so this reports it — it can't bypass it.
enum CapturePermission: Equatable {
    case authorized, denied, notDetermined, restricted

    static func fromAVStatus(_ s: AVAuthorizationStatus) -> CapturePermission {
        switch s {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
}

enum PermissionStatus {
    /// Screen-recording authorization (does not prompt).
    static func screenRecording() -> CapturePermission {
        CGPreflightScreenCaptureAccess() ? .authorized : .denied
    }

    static func camera() -> CapturePermission {
        .fromAVStatus(AVCaptureDevice.authorizationStatus(for: .video))
    }

    static func microphone() -> CapturePermission {
        .fromAVStatus(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Requests screen-recording access, prompting the user if undetermined. Returns the
    /// pre-request state (the grant only takes effect after the app is relaunched).
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
