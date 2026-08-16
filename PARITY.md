# Recordly → Reclip feature-parity audit

Authoritative line-by-line review of the Recordly codebase (`~/recordly`, Electron/TS)
against Reclip (our native Swift app). Based on a full source inventory, not the README.
✅ have · 🟡 partial · ❌ missing. Engine work tracked here; UI wiring owned by the UI dev.

> **Scope reality:** the deep audit shows Recordly is a large, mature product — it has
> whole subsystems Reclip doesn't (auto-captions/Whisper, a plugin+marketplace system, a
> full timeline editor, a cursor-polish engine, project files, i18n). Reclip currently
> implements roughly the **core record→polish→export loop (~20%)**. Full parity is a
> multi-developer, multi-week effort; this file is the roadmap and running status.

---

## 1. Recording / capture
| Feature | Reclip | Note |
|---|---|---|
| Full display capture | ✅ | ScreenRecorder — **end-to-end verified on-device** (real 3s recording → valid MP4); fixed a frame-status bug that was producing damaged files |
| Multi-monitor selection | ✅ | availableDisplays |
| Single-window capture | ✅ | CaptureSource.window |
| Own-window exclusion | ✅ | SCContentFilter excludes Reclip's own windows by bundle id; verified no capture regression |
| Source thumbnails + app icons | ❌ | picker is text-only |
| Native backend (mac SCK) | ✅ | ScreenCaptureKit |
| Target 60fps / retina | ✅ | config |
| **Pause / Resume recording** | ✅ | `RecordingClock` + frame-drop pause, wired into ScreenRecorder; **verified in a real recording** (integration test drives start→pause→resume→stop → valid video) |
| **Cancel (discard) recording** | ✅ | `ScreenRecorder.discard()` stops + deletes take & sidecars; tested |
| Live REC timer | ✅ | elapsed, now backed by RecordingClock |
| **Countdown timer (3/5/10s)** | ✅ | `Countdown` model (remaining/finished) unit-tested; UI hookup pending |
| Microphone capture | ✅ | captureMicrophone |
| **Mic device selection** | ✅ | `DeviceEnumerator.microphones()` + `microphoneDeviceID`; manually verified finding real devices on-device |
| **Mic level meter** | 🟡 | RMS/peak math ported + tested (`AudioLevelMeter`); live tap needs mic permission |
| **Mic processing profiles** | ❌ | raw only |
| System audio | ✅ | captureSystemAudio |
| Webcam capture | ✅ | sidecar |
| **Webcam device selection** | ✅ | `DeviceEnumerator.cameras()` + `webcamDeviceID`; manually verified (built-in + Continuity cameras found) |
| Webcam live preview | ❌ | needs capture-session preview layer |
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
| **Undo / redo** | ✅ | `EditorHistory` — bounded 100-entry stack, redo-clear on new edit, initialized/applied/unchanged/recorded results; unit-tested (UI keybinding pending) |
| **Drag/resize regions on a timeline** | ❌ | UI (UI dev) |
| Auto zoom (cursor) | ✅ | ZoomTimeline.autoZoom |
| **Manual zoom regions (add/edit)** | ✅ | ZoomTimeline.addRegion + depth presets |
| Zoom depth presets (6) + manual focus + easing (4 curves) | ✅ | ZoomDepth + ZoomEasing |
| Zoom connect-neighbors ✅ / motion-blur tuning | 🟡 | `connectNeighbors(maxGap:)` merges regions (tested); temporal motion-blur still open |
| **Speed regions (per-segment)** | ✅ | `SpeedMap` piecewise mapping wired into compositor (scaleTimeRange + synced overlays); duration-verified |
| **Playback controls (play/pause/skip/volume)** | 🟡 | preview loops; no scrub UI |

## 3. Annotations
| Feature | Reclip | Note |
|---|---|---|
| Text captions | ✅ | Annotations |
| **Text typography (weight/color/bg toggle+color)** | ✅ | weight, text colour, pill on/off + colour (font-family/align still fixed) |
| Image annotations | ✅ | Annotation.kind=.image (+ fade in/out) |
| Arrow annotations (stroke, color, 8-dir) | ✅ | Annotation.kind=.arrow + arrowAngle (any direction) |
| Blur / censor region | ✅ | Annotation.kind=.blur/.box |
| **Audio mute + volume + normalize + per-region volume** | ✅ | mute, 0–2x volume, peak-normalize, per-region ducking (AVAudioMix ramps, windowed-RMS verified) |

## 4. Cursor polish engine  🟡 (v1 landed)
Reclip now renders a stylized cursor (arrow/dot) from the tracked path with smooth
interpolation, size control, and correct source-space compositing so crop/zoom carry it
(CursorRenderer + CursorStyle; capture with showCursor=false). The **motion math is now
ported and unit-tested**: `MotionSmoothing` (analytical damped-spring cursor+zoom
smoothing, exact Recordly tuning), `CursorSway` (speed-scaled rotation), and
`CursorClickEffect` (click-bounce sine dip + delayed ripple timing). Still needs **your
eyes to tune the look** (spring feel, sway amount, ripple color/opacity) and wiring into
the render/capture path; **cursor spotlight** (dim-around-pointer) now landed + pixel-verified; more cursor styles, loop mode, and motion presets remain.

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
| **Upload / replace / remove footage** | ❌ | live only |
| **Time-offset alignment** | ✅ | `timeOffset` shifts webcam vs screen; tested |

## 6. Backgrounds / frame
| Feature | Reclip | Note |
|---|---|---|
| Solid (15 swatches) | ✅ | `BackgroundPresets` — 16-preset gallery (gradients + solids), all original colours |
| Gradient (24 presets) | ✅ | `BackgroundPresets` gradient set (original, App-Store-clean) |
| Padding | ✅ | linked only (no per-side) |
| Rounded corners | ✅ | circular + **squircle** (superellipse) toggle; pixel-verified |
| Drop shadow | ✅ | 3-layer (VIDEO_SHADOW_LAYER_PROFILES) |
| **Background blur (blurred source)** | ✅ | batch 2 |
| **Image wallpaper (user upload)** | ✅ | `StyleOptions.backgroundImage` — aspect-filled, persisted in `.reclip` (own JPEGs not copied for licensing) |
| **Device frames** | ✅ | `DeviceFrameRenderer` — macOS window + browser chrome (traffic lights, address pill) |
| **Aspect ratio presets (8 + custom)** | ✅ | 8 ratio presets + Source (custom X/Y still open) |
| **Advanced per-side / vertical padding** | ✅ | `PaddingInsets` (top/bottom/left/right), content-rect compositing |

## 7. Auto-captions  🟡 (rendering half landed)
Reclip now renders styled burned-in caption pills, exports **SRT + VTT** sidecars,
**wires Whisper transcription** (16kHz WAV extraction + whisper-cli orchestration + SRT
parsing — model-run needs a ggml model + real audio, verified on-device), ships **10-language
selection + model management** (`WhisperLanguage`/`WhisperModel`, download/cache), and now
**word-level cue timing** (`CaptionEditing` — text normalization + even word distribution,
the karaoke-highlight foundation). Still missing: the caption *editing UI*, karaoke
*rendering* (needs your eyes on the animation), and (for App Store) linking whisper.cpp as a
library instead of a subprocess.

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
| Save dialog / Save-again / discard | 🟡 | fixed output path |
| Export progress phases | ✅ | `ExportProgress` phase model (preparing/extracting/rendering/finalizing/saving) + `saving(previous:)`; unit-tested |

## 9. Platform / workflow  (partial)
Project files: **`.reclip` save/reopen of full editor state ✅ (ReclipProject)** + **dirty-state
tracking ✅ (`DocumentState`)**. **Timeline core model ✅ (`TimelineModel`** — span overlap/clamp,
playhead+axis time formatting, track-row IDs; the pure data layer the timeline UI consumes).
**Extension system foundation ✅ (`ExtensionManifest` + `ExtensionRegistry`** — schema
validation + permission gating). Note: the extension **marketplace / dynamic-JS loading is
deliberately out of scope** — a native App Store app can't download+execute remote code
(§2.5.2), so extensions here would be built-in/curated, not a JS plugin market.
Still absent: project browser, autosave/recovery, ~50 persisted prefs + named presets,
rebindable keyboard shortcuts, auto-update, theme, **9-locale i18n**, custom fonts.

---

## Engine work completed so far (original Swift)
- Batch 1: cursor show/hide, webcam mirror/roundness/shadow/margin, GIF loop, MP4 quality.
- Batch 2: background blur (blurred-source), aspect-ratio presets + output canvas.
- Batch 3 (deep parity sweep — pure logic ported line-by-line from Recordly, 91 tests):
  - **Engine/export:** temporal motion blur (`MotionBlur`), MP4 frame-rate 24/30/60 via
    AVAssetWriter re-encode + resampling, resolution-aware bitrate (`ExportBitrate`),
    aspect-canvas sizing fix (`ExportDimensions`, was upscaling), 3-layer shadow.
  - **Capture logic:** `RecordingClock` (pause/resume, wired live) + `Countdown`.
  - **Editor logic:** `EditorHistory` (undo/redo), `ExportProgress` phases, `DocumentState`
    (dirty tracking).
  - **Captions:** Whisper pipeline + `WhisperLanguage`/`WhisperModel` + `CaptionEditing`
    (word-level timing).
  - **Timing:** `MediaTiming` (clamp/duration).
  - **Animation math:** `MotionSmoothing` (damped-spring cursor+zoom smoothing), `CursorSway`,
    `CursorClickEffect` (bounce+ripple), `ZoomTransform` (invertible camera geometry).

### Remaining is no longer un-ported pure logic — it is one of:
- **Redundant** with existing tested code (Recordly's zoomRegionUtils ≈ `ZoomTimeline`,
  gifExporter ≈ `GifExport`, webcamOverlay ≈ `WebcamOverlay`) — re-porting would risk regressions.
- **Not applicable** (WebCodecs/muxer/decoder browser plumbing subsumed by AVFoundation).
- **UI-dev's active lane** (timeline model, drag-drop, preview player, editor preferences).
- **Capture-hardware-gated** (device pickers, meters, HUD, click telemetry — need a live recording).
- **Visual tuning + wiring** (the ported animation math needs your eyes on feel, then hookup).
- **Subsystem-scale** (extensions/marketplace, 9-locale i18n).

## Prioritized engine roadmap (feasible, high-value first)
1. Manual zoom regions add/edit API (model exists) + zoom depth presets & easing
2. More backgrounds (wallpaper images, more solids/gradients) + per-side padding + squircle
3. Crop (compositor crop rect + reset)
4. `.reclip` project file — Codable of every setting; save/open/recents
5. Webcam: independent W/H, 9-cell + custom XY, react-to-zoom
6. Export: frame-rate (24/30/60), GIF fps/size presets in UI, output-dimension picker, save dialog, progress phases
7. Recording: countdown, pause/resume/cancel, mic/webcam device pickers + meters
8. Rich annotations (typography, image, arrow, blur/censor)
9. **Cursor polish engine** (hide OS cursor + rendered smoothed sprite, size, motion blur, click bounce, click effects) — largest
10. **Auto-captions** (Whisper) and **extensions/marketplace** — each a subsystem; likely out of near-term scope

_Refreshed from the full Recordly source inventory._
