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
| Full display capture | ✅ | ScreenRecorder |
| Multi-monitor selection | ✅ | availableDisplays |
| Single-window capture | ✅ | CaptureSource.window |
| Own-window exclusion | 🟡 | not filtered |
| Source thumbnails + app icons | ❌ | picker is text-only |
| Native backend (mac SCK) | ✅ | ScreenCaptureKit |
| Target 60fps / retina | ✅ | config |
| **Pause / Resume recording** | ❌ | start/stop only |
| **Cancel (discard) recording** | ❌ | — |
| Live REC timer | ✅ | elapsed |
| **Countdown timer (3/5/10s)** | ❌ | — |
| Microphone capture | ✅ | captureMicrophone |
| **Mic device selection + level meter** | ❌ | default device only |
| **Mic processing profiles** | ❌ | raw only |
| System audio | ✅ | captureSystemAudio |
| Webcam capture | ✅ | sidecar |
| **Webcam device selection + live preview** | ❌ | default device only |
| **Floating HUD control bar** | ❌ | — |
| Cursor position telemetry | ✅ | CursorSampler |
| **Cursor click/interaction capture** | ❌ | position only |
| **System cursor asset extraction** | ❌ | — |
| Cursor show/hide | ✅ | showCursor (batch 1) |
| **Crash recovery / validation / pruning** | ❌ | — |
| Permission pre-flight + prompts | 🟡 | permission hint only |

## 2. Timeline / editor
| Feature | Reclip | Note |
|---|---|---|
| Trim | ✅ | StyledExport trim |
| **Split clip** | ❌ | — |
| **Clip model (per-clip speed grid, mute, volume, normalize)** | ❌ | single clip only |
| **Undo / redo** | ❌ | — |
| **Drag/resize regions on a timeline** | ❌ | UI (UI dev) |
| Auto zoom (cursor) | ✅ | ZoomTimeline.autoZoom |
| **Manual zoom regions (add/edit)** | ✅ | ZoomTimeline.addRegion + depth presets |
| Zoom depth presets (6) + manual focus + easing (4 curves) | ✅ | ZoomDepth + ZoomEasing |
| **Zoom connect-neighbors / motion-blur tuning** | ❌ | not implemented |
| **Speed regions (per-segment)** | 🟡 | global speed only |
| **Playback controls (play/pause/skip/volume)** | 🟡 | preview loops; no scrub UI |

## 3. Annotations
| Feature | Reclip | Note |
|---|---|---|
| Text captions | ✅ | Annotations |
| **Full text typography (font/size/style/align/color/bg/radius)** | ❌ | fixed style |
| Image annotations | ✅ | Annotation.kind=.image |
| Arrow annotations (stroke, color) | ✅ | Annotation.kind=.arrow (1 dir; 8-dir TODO) |
| Blur / censor region | ✅ | Annotation.kind=.blur/.box |
| **Extra audio regions (volume/normalize)** | ❌ | — |

## 4. Cursor polish engine  🟡 (v1 landed)
Reclip now renders a stylized cursor (arrow/dot) from the tracked path with smooth
interpolation, size control, and correct source-space compositing so crop/zoom carry it
(CursorRenderer + CursorStyle; capture with showCursor=false). Still missing vs Recordly:
more cursor styles, smoothing/lag tuning, motion blur, click bounce + 4 click effects,
sway, loop mode, motion presets. **Visual look needs your review** (can't verify blind).

## 5. Webcam overlay
| Feature | Reclip | Note |
|---|---|---|
| Enable / size / corner presets | ✅ | WebcamSettings |
| Mirror | ✅ | batch 1 |
| Roundness | ✅ | batch 1 |
| Shadow | ✅ | batch 1 |
| Margin | ✅ | batch 1 |
| **React-to-zoom scaling** | ❌ | — |
| **Independent width + height** | ✅ | WebcamSettings.aspectRatio |
| **9-cell position + custom X/Y** | 🟡 | 4 corners |
| **Crop control** | ❌ | — |
| **Upload / replace / remove footage** | ❌ | live only |
| **Time-offset alignment** | ❌ | — |

## 6. Backgrounds / frame
| Feature | Reclip | Note |
|---|---|---|
| Solid (15 swatches) | 🟡 | 2 solids |
| Gradient (24 presets) | 🟡 | 3 gradients |
| Padding | ✅ | linked only (no per-side) |
| Rounded corners | ✅ | (no squircle) |
| Drop shadow | ✅ | 1-layer |
| **Background blur (blurred source)** | ✅ | batch 2 (this commit) |
| **24 image wallpapers + video wallpaper + upload** | ❌ | — |
| **Device frames** | ❌ | — |
| **Aspect ratio presets (8 + custom)** | 🟡 | 5 presets (batch 2) |
| **Advanced per-side / vertical padding** | ❌ | — |

## 7. Auto-captions  🟡 (rendering half landed)
Reclip now renders styled burned-in caption pills (color/size/offset/width/box) from cues
and exports **SRT + VTT** sidecars (CaptionRenderer + CaptionExport). Still missing:
**Whisper transcription** (needs native ML + real audio), model management, 10 languages,
inline editing, karaoke word-highlighting.

## 8. Export
| Feature | Reclip | Note |
|---|---|---|
| MP4 (H.264/AAC) | ✅ | StyledExport |
| GIF | ✅ | GifExport |
| MP4 quality (4 levels) | 🟡 | 3 levels (batch 1) |
| **MP4 frame rate (24/30/60)** | ❌ | composition.frameDuration proven ineffective; needs AVAssetWriter re-encode |
| **MP4 encoding mode / HW accel** | ❌ | fixed |
| GIF loop toggle | ✅ | batch 1 |
| GIF frame-rate (4) + size presets (3) | ✅ | GifSize presets + fps param |
| Output dimension control | 🟡 | via aspect (batch 2) |
| Reveal in Finder | ✅ | — |
| Save dialog / Save-again / discard | 🟡 | fixed output path |
| Export progress phases | ❌ | busy flag only |

## 9. Platform / workflow  (mostly ❌)
Project files: **`.reclip` save/reopen of full editor state ✅ (ReclipProject)**; project browser, autosave, dirty-state/recovery, ~50 persisted
prefs + named presets, rebindable keyboard shortcuts + reference, auto-update, theme,
**9-locale i18n**, custom fonts, and the **entire extension/plugin + marketplace system** —
**none present in Reclip.**

---

## Engine work completed so far (this session, original Swift)
- Batch 1: cursor show/hide, webcam mirror/roundness/shadow/margin, GIF loop, MP4 quality.
- Batch 2: background blur (blurred-source), aspect-ratio presets + output canvas.

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
