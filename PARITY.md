# Recordly → Reclip feature parity audit

Line-by-line verification that every Recordly feature exists in Reclip (our original
native macOS app). ✅ = have · 🟡 = partial · ❌ = missing. Engine work is tracked here;
UI wiring is owned by the UI/UX developer.

_Legend for "where": the Reclip engine file that implements (or would implement) it._

## Recording
| Recordly feature | Reclip | Where / note |
|---|---|---|
| Record a full display | ✅ | ScreenRecorder (CaptureSource.display) |
| Record a single window | ✅ | ScreenRecorder (CaptureSource.window) |
| Jump from recording into the editor | ✅ | ContentView → EditorView after stop |
| Capture microphone audio | ✅ | ScreenRecorder.captureMicrophone |
| Capture system audio | ✅ | ScreenRecorder.captureSystemAudio |
| Native capture backend | ✅ | ScreenCaptureKit |
| Open existing recording to edit | ✅ | ContentView "Open a recording…" |
| Save/reopen `.recordly` project files | ❌ | needs a project file format + editor-state persistence |

## Timeline & editing
| Recordly feature | Reclip | Where / note |
|---|---|---|
| Trim unwanted sections | ✅ | StyledExport trim (in preview + export) |
| Automatic zoom (cursor activity) | ✅ | ZoomTimeline.autoZoom |
| Manual zoom regions | 🟡 | ZoomRegion model supports it; no add/edit API yet |
| Speed up / slow down | 🟡 | global speed only; per-segment speed regions missing |
| Text annotations | ✅ | Annotations (captions) |
| Image / figure annotations | ❌ | only text captions today |
| Extra audio regions on timeline | ❌ | not implemented |
| Crop the recorded frame | ❌ | compositor crop rect missing |
| Drag-and-drop timeline UI | ❌ | UI-layer; owned by UI dev |
| Save/reopen project with editor state | ❌ | see project files above |

## Cursor controls
| Recordly feature | Reclip | Where / note |
|---|---|---|
| Show / hide cursor | ✅ | ScreenRecorder.showCursor (batch 1) |
| Cursor size adjustment | ❌ | needs rendered-cursor overlay |
| Cursor smoothing | ❌ | have cursor track; no smoothed overlay render |
| Cursor motion blur | ❌ | needs rendered-cursor overlay |
| Cursor click bounce | ❌ | needs click capture + overlay |
| Cursor sway | ❌ | needs rendered-cursor overlay |
| Cursor loop mode | ❌ | needs rendered-cursor overlay |
| macOS-style cursor assets | ❌ | needs rendered-cursor overlay |

_Note: Reclip captures the real cursor. A full cursor-polish system (hide the OS cursor,
render a smoothed sprite along the tracked path) is the single biggest remaining feature._

## Webcam overlay
| Recordly feature | Reclip | Where / note |
|---|---|---|
| Enable / disable webcam | ✅ | WebcamSettings.enabled |
| Size control | ✅ | WebcamSettings.sizeFraction |
| Preset positions | ✅ | 4 corners |
| Custom X/Y placement | ❌ | only corner presets |
| Margin control | ✅ | WebcamSettings.marginFraction (batch 1) |
| Roundness control | ✅ | WebcamSettings.roundness (batch 1) |
| Mirror | ✅ | WebcamSettings.mirror (batch 1) |
| Shadow | ✅ | WebcamSettings.shadow (batch 1) |
| Upload / replace / remove footage | ❌ | Reclip records live webcam only |
| Zoom-reactive scaling | ❌ | not implemented |

## Frame styling & backgrounds
| Recordly feature | Reclip | Where / note |
|---|---|---|
| Solid color backgrounds | ✅ | StyleOptions.Background.solid |
| Gradient backgrounds | ✅ | StyleOptions.Background.gradient |
| Frame padding | ✅ | StyleOptions.paddingFraction |
| Rounded corners | ✅ | StyleOptions.cornerRadiusFraction |
| Drop shadows | ✅ | StyleOptions.shadow* |
| Built-in wallpapers | ❌ | no image backgrounds |
| Custom uploaded backgrounds | ❌ | no image backgrounds |
| Background blur | ❌ | blurred-source background missing |
| Aspect ratio presets | ❌ | fixed to source aspect |

## Export
| Recordly feature | Reclip | Where / note |
|---|---|---|
| MP4 export | ✅ | StyledExport.export |
| GIF export | ✅ | GifExport.export |
| Export quality selection | ✅ | ExportQuality (batch 1) |
| GIF frame-rate selection | 🟡 | fps param exists; UI exposure by UI dev |
| GIF loop toggle | ✅ | GifExport loop (batch 1) |
| GIF size presets | 🟡 | maxWidth param exists; presets not enumerated |
| Aspect / output dimension controls | ❌ | needs render-size control |
| Reveal exported files in Finder | ✅ | NSWorkspace reveal |

## Workflow & usability
| Recordly feature | Reclip | Where / note |
|---|---|---|
| Customizable keyboard shortcuts | ❌ | not implemented |
| In-app shortcut reference | ❌ | not implemented |
| Feedback / issue links | 🟡 | can add repo issue link |
| Project persistence | ❌ | see project files |

---

### Remaining engine work (prioritized)
1. Background blur (blurred-source background) — compositor
2. Aspect ratio presets + output dimensions — compositor render size
3. Crop the recorded frame — compositor crop rect
4. Manual zoom regions (add/edit API) — model exists, expose mutation
5. Webcam custom X/Y + zoom-reactive scaling — compositor
6. `.reclip` project file (save/reopen editor state) — codable of all settings
7. Per-segment speed regions — time-map extension
8. Image annotations — annotation type extension
9. **Cursor polish system** (hide OS cursor + rendered smoothed sprite, size, motion blur,
   click bounce, sway, loop) — the largest remaining feature
10. Extra audio regions — timeline audio mixing

_This file is refreshed as the deep code inventory of Recordly completes._
