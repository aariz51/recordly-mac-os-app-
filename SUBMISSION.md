# Reclip — Mac App Store submission checklist

Reclip is an original app (© Aariz Rasheed). This is the path to a Mac App Store listing.

## Prerequisites (one-time)
- [ ] Apple Developer Program membership (team `9Y959T63P7`)
- [ ] Accept the latest **Paid Apps / Free Apps agreement** in App Store Connect → Business
- [ ] Certificates needed (create in developer portal): **Apple Distribution** + **Mac Installer Distribution** (Apple Distribution already present)
- [ ] Provisioning profile: **Mac App Store** profile for `com.aariz51.reclip`

## Blocking prerequisite: real testing
- [ ] Run `Reclip.app`, grant Screen Recording + Camera + Microphone
- [ ] Verify: record display, record window, system audio, mic, webcam
- [ ] Verify editor: background presets, padding, corners, shadow, auto-zoom, trim, webcam bubble
- [ ] Verify export: MP4 opens & looks right; GIF loops & looks right
- [ ] Confirm the app runs correctly **under the App Store sandbox** entitlements
  (`packaging/Reclip.appstore.entitlements`)

## Build for the store
- [ ] Bundle with sandbox entitlements + Apple Distribution signing
- [ ] Wrap in a signed `.pkg` with Mac Installer Distribution cert
- [ ] Validate + upload via `xcrun altool`/Transporter or Xcode Organizer

## App Store Connect (web — must be done by the account holder)
- [ ] Create the app record (Apple's API cannot create the initial macOS app record)
- [ ] Bundle ID `com.aariz51.reclip`, primary category **Video**, price **Free**
- [ ] Metadata: name, subtitle, description, keywords (ASO), support URL
- [ ] Screenshots (macOS, 2880×1800 or 1280×800): launcher, editor, exported result
- [ ] Privacy: declares Screen Recording, Camera, Microphone usage
- [ ] Submit for review

## Notes
- Screen recorders are accepted on the Mac App Store when native + sandboxed (this app is both).
- Global input hooks are NOT used (cursor position is read via `NSEvent.mouseLocation`, sandbox-safe).
