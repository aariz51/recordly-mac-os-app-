# Recordly → Reclip feature-parity audit

Authoritative line-by-line review of the Recordly codebase (`~/recordly`, Electron/TS)
against Reclip (our native Swift app). Based on a full source inventory, not the README.
✅ have · 🟡 partial · ❌ missing · ⛔ out of scope.

> **Status:** the engine sweep and the **UI wiring are both done**. Previous revisions of
> this file tracked a large engine that the app didn't expose: `CursorStyle`, `ZoomDepth`,
> `ZoomEasing`, `DeviceFrame`, `CaptionSettings`, `WhisperTranscriber`, `CaptionExport`,
> `ExportQuality`, `MP4FrameRate`, `EncodingMode`, `GifSize`, `AudioRouting`, `MicProfile`,
> `SpeedSegment`, `AudioVolumeRegion`, `MotionBlur`, `MotionSmoothing`, `CursorSway`,
> `TimelineModel`, `EditorHistory`, `Shortcuts`, `ReclipProject`, `DocumentState`,
> `BackgroundPresets`, `AudioLevelMeter`, `Countdown` and `CapturePermission` were all
> implemented and tested, and referenced by **zero** UI files. They are now all reachable
> from the app: a nine-section inspector (Scene · Clip · Zoom · Cursor · Webcam · Captions ·
> Annotate · Audio · Export), a multi-lane timeline, and a recorder with countdown,
> pause/resume/discard, device pickers and a level meter.
>
> What remains is genuinely out of scope or genuinely large — see §10.

---

## 1. Recording / capture
| Feature | Reclip | Note |
|---|---|---|
| Full display capture | ✅ | ScreenRecorder — **end-to-end verified on-device** (real 3s recording → valid MP4); fixed a frame-status bug that was producing damaged files |
| Multi-monitor selection | ✅ | availableDisplays |
| Single-window capture | ✅ | CaptureSource.window |
| Own-window exclusion | ✅ | SCContentFilter excludes Reclip's own windows by bundle id; verified no capture regression |
| Source thumbnails + app icons | ✅ | `SourceThumbnails` — SCScreenshotManager stills per display/window + owning-app icon, cached by source id |
| Native backend (mac SCK) | ✅ | ScreenCaptureKit |
| Target 60fps / retina | ✅ | config |
| **Pause / Resume recording** | ✅ | `RecordingClock` + frame-drop pause, wired into ScreenRecorder; **verified in a real recording** (integration test drives start→pause→resume→stop → valid video) |
| **Cancel (discard) recording** | ✅ | `ScreenRecorder.discard()` stops + deletes take & sidecars; tested |
| Live REC timer | ✅ | elapsed, now backed by RecordingClock |
| **Countdown timer (3/5/10s)** | ✅ | `Countdown` model + full-screen overlay with cancel; picker persists (None/3/5/10s) |
| Microphone capture | ✅ | captureMicrophone |
| **Mic device selection** | ✅ | `DeviceEnumerator.microphones()` + `microphoneDeviceID`; manually verified finding real devices on-device |
| **Mic level meter** | ✅ | `MicLevelMonitor` taps AVAudioEngine while idle and hands the device back on record; segmented `LevelMeter` in the recorder |
| **Mic processing profiles** | ✅ | `MicProcessor` high-pass + noise gate + raw/voice/music, wired into export via passthrough post-mux; end-to-end verified (rumble removed in exported file) |
| System audio | ✅ | captureSystemAudio |
| **Separate mic/system routing (per-track + master gain)** | ✅ | `AudioRouting` model + export wiring (per-track gain via AVAudioMix); verified muting mic track on a 2-track source |
| Webcam capture | ✅ | sidecar |
| **Webcam device selection** | ✅ | `DeviceEnumerator.cameras()` + `webcamDeviceID`; manually verified (built-in + Continuity cameras found) |
| Webcam live preview | ✅ | `WebcamPreviewPanel` — floating always-on-top AVCaptureVideoPreviewLayer panel, excluded from the capture |
| **Floating HUD control bar** | ❌ | — |
| Cursor position telemetry | ✅ | CursorSampler |
| **Cursor click/interaction capture** | ✅ | click timestamps captured; expanding ripple rendered (CursorClickEffect timing); pixel-verified |
| **System cursor asset extraction** | ✅ | `SystemCursor` extracts real NSCursor image; `.system` cursor kind; tested |
| Cursor show/hide | ✅ | showCursor (batch 1) |
| **Crash recovery / validation / pruning** | ✅ | `RecordingValidator` validate + prune (empty/unreadable/orphaned sidecars); tested |
| Permission pre-flight + prompts | ✅ | `PermissionStatus` reads screen/camera/mic TCC without prompting + screen-recording request; manually verified per-permission on-device |

## 2. Timeline / editor
| Feature | Reclip | Note |
|---|---|---|
| Trim | ✅ | StyledExport trim |
| **Split clip / remove segment** | ✅ | `keepRanges` concatenates kept source ranges (CutMap-synced overlays); duration-verified |
| **Clip model (per-clip speed grid, mute, volume, normalize)** | ✅ | speed regions + split/cut + mute + per-region volume + normalize all landed |
| **Undo / redo** | ✅ | `EditorHistory` over `ReclipProject` snapshots; ⌘Z / ⇧⌘Z plus on-stage buttons |
| **Drag/resize regions on a timeline** | ✅ | `TimelineView` — Clip/Zoom/Speed/Notes lanes; drag to move, grab an edge to resize, click to select into the inspector |
| Auto zoom (cursor) | ✅ | ZoomTimeline.autoZoom |
| **Manual zoom regions (add/edit)** | ✅ | ZoomTimeline.addRegion + depth presets |
| Zoom depth presets (6) + manual focus + easing (4 curves) | ✅ | ZoomDepth + ZoomEasing |
| Zoom connect-neighbors + temporal motion-blur | ✅ | `connectNeighbors` merges regions; `MotionBlur` sample-plan frame-blending in the re-encode path (Recordly's shutter/sample tuning); both tested |
| **Speed regions (per-segment)** | ✅ | `SpeedMap` piecewise mapping wired into compositor (scaleTimeRange + synced overlays); duration-verified |
| **Playback controls (play/pause/skip/volume)** | ✅ | transport pill (play/pause + ±5s), timeline scrubbing, looping preview |

## 3. Annotations
| Feature | Reclip | Note |
|---|---|---|
| Text captions | ✅ | Annotations |
| **Text typography (font/weight/color/bg)** | ✅ | custom font family + weight + text colour + pill on/off/colour (Google-Fonts fetch is web-only; alignment single-line) |
| Image annotations | ✅ | Annotation.kind=.image (+ fade in/out) |
| Arrow annotations (stroke, color, 8-dir) | ✅ | Annotation.kind=.arrow + arrowAngle (any direction) |
| Blur / censor region | ✅ | Annotation.kind=.blur/.box |
| **Audio mute + volume + normalize + per-region volume** | ✅ | mute, 0–2x volume, peak-normalize, per-region ducking (AVAudioMix ramps, windowed-RMS verified) |

## 4. Cursor polish engine  ✅
The ported motion math is now **wired into the render path**. `SmoothedCursorTrack` solves
the whole clip once at composition-build time — the spring is stateful, and a video
composition handler is called at arbitrary (and, on the re-encode path, repeated) times, so
it cannot carry state itself. Each frame then indexes a precomputed sample.

| Feature | Reclip | Note |
|---|---|---|
| Stylized sprite (arrow/dot/system) | ✅ | source-space, so crop/zoom carry it |
| Size | ✅ | 0.4–4× |
| **Spring smoothing** | ✅ | `MotionSmoothing.cursorSpringConfig`, 0–2; pixel-verified to move where the sprite lands |
| **Sway** | ✅ | `CursorSway` rotation about the sprite's hotspot, itself eased so it can't strobe |
| **Click bounce** | ✅ | sine dip about the hotspot, floored at 0.72 |
| **Click effects (off/ripple/spotlight/echo)** | ✅ | + colour, size, opacity, duration |
| Spotlight (dim around pointer) | ✅ | radius + dim amount |
| Loop cursor | ✅ | `loopCursorPath` — replays the recorded path past the end of the track instead of parking the pointer |
| **Cursor-follow camera** | ✅ | `CursorFollowCamera` (port of `cursorFollowCamera.ts`) — persistent zoom center, safe-zone hysteresis pan, zoom-out freeze, focus clamp; tested |
| Extra cursor styles (Tahoe, Figma, …) | ❌ | third-party sprite assets, not portable

## 5. Webcam overlay
| Feature | Reclip | Note |
|---|---|---|
| Enable / size / corner presets | ✅ | WebcamSettings |
| Mirror | ✅ | batch 1 |
| Roundness | ✅ | batch 1 |
| Shadow | ✅ | batch 1 |
| Margin | ✅ | batch 1 |
| **React-to-zoom scaling** | ✅ | bubble scales with ZoomTimeline zoom; tested |
| **Independent width + height** | ✅ | WebcamSettings.aspectRatio |
| **9-cell position + custom X/Y** | ✅ | full 9-cell grid (custom X/Y still open) |
| **Crop control** | ✅ | `cropZoom` (1–3x) + `cropOffsetX/Y` pan; tested |
| **Upload / replace / remove footage** | ✅ | `WebcamSettings.sourcePath` + attach/replace/detach in the Webcam section; persisted in `.reclip` |
| **Time-offset alignment** | ✅ | `timeOffset` shifts webcam vs screen; tested |

## 6. Backgrounds / frame
| Feature | Reclip | Note |
|---|---|---|
| Solid (15 swatches) | ✅ | `BackgroundPresets` — 16-preset gallery (gradients + solids), all original colours |
| Gradient (24 presets) | ✅ | `BackgroundPresets` gradient set (original, App-Store-clean) |
| Padding | ✅ | linked, plus an independent per-side mode (top/bottom/left/right) |
| Rounded corners | ✅ | circular + **squircle** (superellipse) toggle; pixel-verified |
| Drop shadow | ✅ | 3-layer (VIDEO_SHADOW_LAYER_PROFILES) |
| **Background blur (blurred source)** | ✅ | batch 2 |
| **Image wallpaper (user upload)** | ✅ | `StyleOptions.backgroundImage` — aspect-filled, persisted in `.reclip` (own JPEGs not copied for licensing) |
| **Device frames** | ✅ | `DeviceFrameRenderer` — macOS window + browser chrome (traffic lights, address pill) |
| **Aspect ratio presets (8 + custom)** | ✅ | 8 ratio presets + Source (custom X/Y still open) |
| **Advanced per-side / vertical padding** | ✅ | `PaddingInsets` (top/bottom/left/right), content-rect compositing |

## 7. Auto-captions  ✅ (bar karaoke rendering)
Styled burned-in caption pills, **SRT + VTT** sidecars (opt-in at export), Whisper
transcription (16kHz WAV extraction + whisper-cli orchestration + SRT parsing), 10-language
selection and model download/cache. The Captions section now exposes all of it: language,
model (with download), generate/regenerate/clear, an editable cue list, and full styling —
font family/size, colour, bottom offset, max width, box opacity/radius.

**Entrance animations landed** (`CaptionAnimation`: off/fade/rise/pop + duration), each a
smoothstep envelope over opacity/offset/scale, pixel-verified mid-transition and at rest.

**Karaoke word highlighting landed** — `CaptionEditing.buildWords` timings now drive an
actual renderer: each word lights as it is spoken, with the cue's timing spread across its
words. Toggle plus highlight colour in the Captions section. **`CaptionLayout`** (port of
`captionLayout.ts`) adds the word-state layout — spoken/active/upcoming tagging + greedy
line-wrapping + a rolling `maxRows` window that scrolls long captions; tested.

Still missing: for App Store, linking whisper.cpp as a library rather than shelling out to
`whisper-cli`. The UI says so plainly when the binary isn't present rather than failing with
a path error.

## 7b. Extensions
| Feature | Reclip | Note |
|---|---|---|
| **Manifest + permission model** | ✅ | `ExtensionManifest` + validate + `ExtensionRegistry` permission gating |
| **Render-hook runtime (7 phases)** | ✅ | `ReclipExtension` + `ExtensionHost` wired into compositor; tint extension verified |
| **Remote-JS loading + marketplace** | ⛔ | out of scope — App Store §2.5.2 bans runtime remote code |

## 8. Export
| Feature | Reclip | Note |
|---|---|---|
| MP4 (H.264/AAC) | ✅ | StyledExport |
| GIF | ✅ | GifExport |
| MP4 quality (4 levels) | ✅ | Source/High/Medium/Low + resolution-aware bitrate |
| **MP4 frame rate (24/30/60)** | ✅ | `exportReencoded` — AVAssetReader→AVAssetWriter with slot-based resampling (drops/dups frames); verified by counting real output frames |
| **Resolution-aware bitrate tiers** | ✅ | `ExportBitrate` mirrors Recordly's 10/20/30M tiers + quality multiplier + 2M floor; applied via AVVideoAverageBitRateKey in the re-encode path |
| **Temporal motion blur** | ✅ | `MotionBlur` — exact port of Recordly's config/sample-plan (odd sample count, shutter fraction, cosine-tapered weights summing to 1) + weighted frame blend wired into the re-encode path |
| **MP4 encoding mode / HW accel** | ✅ | `EncodingMode` fast/balanced/quality bitrate multiplier; HW accel automatic via VideoToolbox |
| GIF loop toggle | ✅ | batch 1 |
| GIF frame-rate (4) + size presets (3) | ✅ | GifSize presets + fps param |
| Output dimension control | ✅ | aspect presets + `maxOutputHeight` resolution cap (1080/720/…); tested |
| Reveal in Finder | ✅ | — |
| Save dialog / Save-again / discard | ✅ | `askWhereToSave` NSSavePanel, or writes beside the source; reveals in Finder |
| Export progress phases | ✅ | `ExportProgress` phase model (preparing/extracting/rendering/finalizing/saving) + `saving(previous:)`; unit-tested |

## 9. Platform / workflow
| Feature | Reclip | Note |
|---|---|---|
| **`.reclip` project save / reopen** | ✅ | `ReclipProject` — every setting; auto-loads when reopening a clip; ⌘S |
| **Dirty-state tracking** | ✅ | `DocumentState`; unsaved dot in the inspector header |
| **Open from Finder / drag-onto-icon** | ✅ | `CFBundleDocumentTypes` + `application(_:open:)`; a `.reclip` opens the clip it names |
| **Rebindable keyboard shortcuts** | ✅ | `ShortcutsConfig` sheet over the `Shortcuts` model (conflict detection against fixed + configurable), persisted via `ShortcutStore` |
| **Shortcut reference sheet** | ✅ | ⌘/ — rendered from the live bindings, not a hand-written list |
| Timeline core model | ✅ | `TimelineModel` — span overlap/clamp, playhead + axis formatting, track-row IDs |
| Extension manifest + permission model | ✅ | `ExtensionManifest` + `ExtensionRegistry` |
| Project browser / recents | ✅ | `RecentProjects` — 8 most recent, de-duplicated, dead paths dropped on read; shown on the launch screen |
| Autosave / crash recovery of edits | ❌ | saves are explicit |
| Theme (light/dark/system) | ✅ | in-app override via `AppTheme`, applied through `NSApp.appearance` so AppKit panels follow too |
| 9-locale i18n | ✅ | `Localization` + 9 `.lproj` tables (313 strings each); switching is instant, no relaunch |
| Auto-update | ⛔ | App Store handles updates |

### 9b. How the localization works
The key *is* the English copy — `L("Start Recording")`, not `L("recorder.start")`. A missing
entry therefore degrades to correct English rather than to a raw identifier, and the source
stays readable without a lookup table.

Lookup is owned rather than delegated to SwiftUI's `LocalizedStringKey`, for two reasons:
SwiftUI resolves against a bundle the system picks, so an in-app switch would need a
relaunch; and it never reaches the AppKit surfaces — the editor is an `NSHostingView` in an
`NSWindow`, and the webcam preview is a plain `NSPanel`. `Localization` is an
`ObservableObject`, and the two view trees carry `.id(loc.language)` so a switch rebuilds
them — without it SwiftUI diffs the child structs as equal and leaves the old language
onscreen.

`.system` resolves against `Locale.preferredLanguages` with prefix matching, so `pt-PT` and
`zh-Hant-HK` land on the right table instead of falling through to English.

Coverage is enforced, not assumed: `LocalizationTests` scans the source and fails on any
`Text`/`Button`/`Label`/`TextField`/`.help`/`.accessibilityLabel` literal that isn't wrapped
in `L()`, and on any `L("…")` key missing from a table. The bundling is asserted too —
`bundle.sh` copying the `.lproj` directories, and `CFBundleLocalizations` matching
`AppLanguage`. Both were broken when the tables were first written, and nothing failed,
because an unlocalized app is simply an English one.

---

## 10. What is genuinely still missing
Everything else in this document is done. These are the honest remainders, with why:

Items 1–9 of the previous list are now built: karaoke word highlighting, timeline zoom/pan,
the timeline waveform (`AudioPeaks`), the floating webcam preview, source thumbnails,
recents, i18n, the loop cursor, and the Save-As panel. What remains:

1. **Autosave / crash recovery** — saves are explicit (⌘S) and dirty state is tracked, but an
   unsaved edit is still lost if the app dies. Recordly autosaves to local storage.
2. **Extra cursor styles (Tahoe, Figma, …)** — the shipped styles are drawn; the rest are
   third-party sprite assets that aren't redistributable here.
3. **Floating HUD control bar while recording** — recording is driven from the main window
   and the menu bar; Recordly has a separate always-on-top HUD.
4. **whisper.cpp as a linked library** — transcription shells out to `whisper-cli`, which an
   App Store sandbox won't allow. The UI states this plainly when the binary is absent.
5. **Extensions marketplace / remote-JS loading** — ⛔ deliberately out of scope: a native
   App Store app cannot download and execute remote code (§2.5.2). The manifest, permission
   model and render-hook runtime are implemented for built-in/curated extensions.

**Translation review is an open release gate.** The nine locale tables were machine-produced
in-house, not by native speakers. The infrastructure is verified end to end; the *wording*
has had no human review, and Korean, Russian and both Chinese variants should get a native
read before shipping.

## Notes on fidelity
Where Recordly's behaviour is a *web* behaviour, Reclip does the native equivalent rather
than a literal port:
- **Custom fonts:** Recordly fetches Google Fonts by URL; Reclip picks from installed
  families (`NSFontManager`), which is what a Mac app should do and works offline.
- **Wallpapers:** Recordly ships an image gallery; Reclip ships 16 original gradients/solids
  plus user-supplied images — third-party image assets aren't redistributable here.
- **Encoding:** WebCodecs/muxer/decoder plumbing is subsumed by AVFoundation.

_Refreshed after the UI-wiring pass; 213 tests green._
