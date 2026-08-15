# Reclip

A native macOS screen recorder — built in Swift with ScreenCaptureKit and AVFoundation.

Reclip records your display (with optional system audio and microphone) and is being
built toward a full recording + polish workflow: auto-zoom, cursor effects, webcam
overlays, styled backgrounds, and MP4/GIF export.

## Status

Early development. Current milestone: screen capture → MP4.

## Build

```bash
swift build -c release        # compile
scripts/bundle.sh release     # assemble Reclip.app (+ code sign)
open build/Reclip.app
```

Requires macOS 14+ and Xcode command line tools. On first run, grant **Screen Recording**
permission in System Settings → Privacy & Security.

## License

© 2026 Aariz Rasheed. All rights reserved. Original work — see [LICENSE](LICENSE).
