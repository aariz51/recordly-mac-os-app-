import SwiftUI
import AVKit

/// The preview surface for the editor.
///
/// SwiftUI's `VideoPlayer` aborts at launch in a SwiftPM-built bundle — its
/// generic metadata cannot resolve the superclass of `AVPlayerView`
/// ("failed to demangle superclass of VideoPlayerView from 'So12AVPlayerViewC'"),
/// which killed the app the instant the editor opened. Wrapping `AVPlayerView`
/// directly links the class for real, and it also lets us pick the *floating*
/// control style: translucent chrome that sits over the video while it plays
/// instead of taking a permanent strip out of the layout.
struct PlayerStage: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.allowsPictureInPicturePlayback = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
