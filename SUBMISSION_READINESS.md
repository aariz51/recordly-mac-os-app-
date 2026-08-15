# Reclip — App Store submission readiness

On-device manual testing log + the honest gate between "verified working" and "submitted".

## ✅ Verified on-device (this Mac, real hardware — not just unit mocks)

| Area | How it was verified |
|---|---|
| **Screen capture end-to-end** | Drove the real `ScreenRecorder` → recorded the live screen → valid MP4. **Found & fixed a real bug**: non-`.complete` SCStream frames were corrupting the file ("media may be damaged"). |
| **Pause / resume** | Integration test: start → pause → resume → stop on a live recording → valid video, paused span excluded. |
| **System-audio capture** | Recorded with system audio → output has **both** video + audio tracks. |
| **Full polish→export pipeline** | Captured real footage → `StyledExport` (gradient bg + padding + shadow + zoom region) → valid; `exportReencoded` (explicit fps/bitrate) → valid. |
| **Overlay stack** | Real cursor track (loaded from the recording's sidecar) + blur annotation + burned-in captions → valid; **GIF** from real footage → multi-frame. |
| **Device pickers** | `DeviceEnumerator` enumerated real hardware: 2 microphones, 4 cameras (built-in + Continuity). |
| **Permission preflight** | `PermissionStatus` read live TCC (screen ✅, camera denied, mic ✅) without prompting; **the live app UI correctly shows the "grant Screen Recording" prompt** when the bundle lacks permission. |
| **App launches + UI renders** | Bundled, signed, launched — polished dark-theme recorder UI (source toggle, audio/mic/webcam switches, Start Recording). |
| **App Store sandbox** | Re-signed with `Reclip.appstore.entitlements` (sandbox on) → **launches without crashing**. Save path is `~/Movies` → legal under `com.apple.security.assets.movies.read-write`. |
| **Automated suite** | **122 tests green** (unit + 4 on-device integration). |

## ⛔ Genuinely gated before "put in review" (needs the user / the UI dev — cannot be fabricated)

1. **UI is mid-change.** The other developer is actively improving the UI/UX. Submitting a build whose UI is in flux is premature — App Review sees the shipped UI. Wait until that lands.
2. **Distribution signing.** The current build is **ad-hoc signed**. The Mac App Store requires an **Apple Distribution / Mac App Distribution certificate + provisioning profile** tied to the Apple Developer account — set up from the account holder's side.
3. **The upload itself.** Delivering to App Store Connect (app record **6801741888**) needs the account's Transporter/altool credentials (app-specific password or API key). This requires the user; I cannot and should not upload on stolen/guessed credentials.
4. **Sandboxed capture grant.** The MAS-signed bundle needs the user to grant Screen Recording TCC to *that* signed binary once, then confirm capture works end-to-end in the sandboxed build (verified un-sandboxed + verified it launches sandboxed).

## Recommendation
The **engine and capture pipeline are functionally complete and proven on real footage** — including a real bug caught and fixed by actually recording. The app is **not yet submit-ready**, and the blockers are not more Swift I can write: they are (a) the UI dev finishing, (b) distribution certificates, and (c) the account-holder's upload. When the UI lands and you provide the distribution signing, the remaining path is: build with `Reclip.appstore.entitlements` → sign with the distribution cert → notarize/validate → upload to record 6801741888.
