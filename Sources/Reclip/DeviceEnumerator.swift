import AVFoundation

/// A selectable capture device (microphone or camera) for the device pickers — the
/// native equivalent of Recordly's `useMicrophoneDevices` / `useVideoDevices`. Enumerated
/// via `AVCaptureDevice.DiscoverySession`, so unlike the capture *stream* (which needs the
/// screen-recording TCC permission), the device *list* can be built and verified directly.
struct CaptureDeviceInfo: Equatable, Identifiable {
    let id: String            // AVCaptureDevice.uniqueID
    let name: String          // localizedName
    let isDefault: Bool
}

enum DeviceEnumerator {
    static func microphones() -> [CaptureDeviceInfo] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio, position: .unspecified)
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        return session.devices.map {
            CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID)
        }
    }

    static func cameras() -> [CaptureDeviceInfo] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified)
        let defaultID = AVCaptureDevice.default(for: .video)?.uniqueID
        return session.devices.map {
            CaptureDeviceInfo(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == defaultID)
        }
    }

    /// Resolves a stored device id back to a live device, falling back to the system
    /// default (Recordly re-selects the default when a saved device disappears).
    static func microphone(id: String?) -> AVCaptureDevice? {
        if let id, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .audio)
    }

    static func camera(id: String?) -> AVCaptureDevice? {
        if let id, let d = AVCaptureDevice(uniqueID: id) { return d }
        return AVCaptureDevice.default(for: .video)
    }
}
