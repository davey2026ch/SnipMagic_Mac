# SnipMagic for macOS

**SnipMagic** (截图大师) is a native macOS screenshot tool written in Swift: region capture, scrolling long capture,
**GIF screen recording**, multi-tab annotation editing, side-by-side comparison, zooming, a screen colour picker and
OCR text/table extraction — ready to use out of the box.

![Swift](https://img.shields.io/badge/Swift-5.9%2B-F05138) ![macOS](https://img.shields.io/badge/macOS-14%2B-000000) ![License](https://img.shields.io/badge/License-MIT-green) ![Release](https://img.shields.io/badge/version-v4.0.0-blue)

English | [简体中文](README.md)

## Highlights

- **Capture**: region capture and scrolling long capture, one tab per image.
- **Pointer is optional**: region captures leave the mouse arrow out by default (a toggle in
  Settings can include it); long captures never include it, because stitching would repeat the
  arrow across frames; GIF recordings include it by default so viewers can follow your clicks.
- **Multi-tab editor**: every capture becomes a tab (P1, P2, …) you can switch, reorder by
  dragging, and close from the right-click menu.
- **Compare two images**: drag a tab onto the right half (or use the tab context menu) to
  show two images side by side, with synchronised scrolling on by default.
- **Theme**: dark / light / follow system, chosen in Settings.
- **One-click tools, double-click to lock**: the active tool is highlighted; after a single
  use the editor returns to **Select** (框选) automatically, so you never have to click back.
  Double-click a shape tool and a small **padlock** appears in its corner — it then stays
  active so you can draw several shapes in a row (like a locked Format Painter in Office).
  Click it once more to unlock.
- **Extract graphic (AI cut-out)**: frame a subject (icon, person, product, …) and let the
  cloud model remove its background. The subject lands back on the canvas as a
  **transparent floating layer** — drag it, resize it, and `⌘C` it into WeChat / Keynote /
  Word with real alpha preserved.
- **OCR / content extraction**: text + tables (and images on some pages), exported to
  Markdown, Word or Excel.
- **GIF recording**: a hollow recording window frames the area; the result opens as an
  animated tab where you can **annotate individual frames**, **delete frames from the thumbnail
  strip** (current / all on the left / all on the right) and export — annotations and deletions
  are baked into the saved `.gif`.

## Capture modes

| Mode | Default shortcut | Notes |
| --- | --- | --- |
| Region capture | `⌘ ⇧ R` | Drag to select any area; our own windows are excluded. The pointer is **off by default** (Settings → "录制鼠标箭头 / 截图") |
| Long capture | `⌘ ⇧ E` | Select an area, then scroll the page — frames are stitched into one tall image. The pointer is **never** included (stitching would repeat it) |

**Stitching algorithm**: row signatures (16 segments) + full dy-offset search + candidate
pixel verification + seam refinement (SAD correlation), with sticky top/bottom detection and
document-coordinate de-duplication, so overlapping scroll regions join without ghosting.

## Editor

- **Tools**: select, rectangle, rounded rectangle, ellipse, arrow, line, freehand pen,
  text, mosaic, numbered badges, solid shapes for covering content.
- **Non-destructive**: annotations can be selected, moved, resized and restyled; undo/redo
  with `⌘Z` / `⌘⇧Z`.
- **Text**: font size, bold, colour and optional opaque background.
- **Mosaic density** adjustable in Settings (2–64 px per block).
- **Zoom**: `⌘ + scroll wheel` (10 %–800 %, snaps near 100 %), or trackpad pinch. Note the
  direction is **scroll up to zoom out, scroll down to zoom in**.
- **Colour**: click the swatch in the sidebar to open a colour wheel / RGB / HEX panel, plus
  a full-screen eyedropper that samples a colour from anywhere on screen.
- **`⌘C`** copies intelligently: rubber-band selection → selected pasted image → selected
  shape's bounding box → whole image.

## GIF recording

The **GIF** button in the toolbar opens a hollow recording window: the hole is live desktop
pixels, the border and the bottom control bar sit outside it and are never recorded. Frame the
area, press **● Record**.

- The window keeps the three standard macOS traffic lights, can be dragged and resized, and is
  **locked in place while recording**. Closing it or pressing `Esc` cancels.
- Control bar: `● Record / ✕ Cancel` → `⏸ Pause / ■ Stop` → `● Resume / ■ Stop`, with a live
  "recording 00:05 · 12 frames · 24 fps" readout. Its colours follow the app theme.
- **Frame rate** is configurable (1–60, default 24). GIF delays bottom out at 2/100 s, so the
  capture rate is `min(setting, 50)` — the window says "GIF 上限 50" when capped.
- **Static scenes are merged**: unchanged frames are not added, the previous frame simply stays
  longer (2 s per frame at most), so recording a still screen does not produce hundreds of frames.
- Playback never starts by itself: use the play button or `Space`. Without looping it stops on
  the last frame; pressing play again restarts from frame 1.
- On the playback page you can **✎ edit the current frame** with the normal annotation tools
  (arrows, text, mosaic, magic erase …) while the strip and control bar stay usable, and
  **right-click a thumbnail** to delete the current frame, all frames to its left, or all frames
  to its right. Saving the GIF bakes both kinds of edits into the file.

## Content extraction (OCR)

- Click **Extract content** in the toolbar: the current tab (or just the selection) is sent
  for recognition and the result comes back as Markdown, copied to the clipboard.
- Two channels: a free lightweight parser first, falling back to the precise (vlm) API when
  it times out or fails. The precise channel needs a MinerU token, set in Settings.
- Export the result to Markdown (with an `images/` folder), Word (`.docx`) or Excel
  (`.xlsx`) — images are embedded inline in Word and anchored to their row in Excel.

> On macOS, WPS is sandboxed to the Desktop / Documents / Downloads folders. If you export a
> Markdown folder somewhere else, WPS will not load the images inside it — open it with
> Typora / VS Code, or move the folder to one of those locations.

## Settings

- Region / long capture hotkeys (record a new combination; at least one modifier key).
- **Theme**: dark / light / follow system (default: follow system).
- Mosaic density, line width, extraction timeout, MinerU token.
- **GIF frame rate** (1–60, default 24) and **录制鼠标箭头** — two checkboxes that decide whether
  screenshots and GIF recordings include the mouse pointer (screenshots off, GIF on by default).
  The timeout (0–600 s) is how long the lightweight parser may take before the app falls back
  to the precise (vlm) channel — **set it to `0` to skip the lightweight parser and use the
  precise channel directly**.
- The settings sheet shows the current version and build time.

## Configuration file

Everything is stored in `~/.SnipMagic.ini` (created automatically on first launch):

```
capture_hotkey=Command+Shift+R
long_hotkey=Command+Shift+E
mosaic=10
line_width=4
token=sk-...
agent_timeout=10
theme=system        # dark / light / system (default when missing)
gif_fps=24          # GIF recording frame rate (1–60)
cursor_screenshot=0 # include the mouse pointer in screenshots (0/1)
cursor_gif=1        # include the mouse pointer in GIF recordings (0/1)
```

Older config files that do not contain `theme` are treated as **follow system**; saving the
settings sheet writes the key back.

> **Renamed in v3.1.0**: on first launch the app finds the legacy `~/.截图工具`, copies it to
> `~/.SnipMagic.ini` (your MinerU token and Volcengine API key are kept) and renames the old
> file to `~/.截图工具.bak`. This migration runs once.

## Installation

1. Download the latest `.dmg` from [Gitee Releases](https://gitee.com/mrpu2020/SnipMagic_Mac/releases):
   - **Apple Silicon (M series)**: `截图大师SnipMagic-v4.0.0.dmg` (arm64)
   - **Intel Mac**: `截图大师SnipMagic-v4.0.0-x86_64.dmg` (x86_64)
2. Open the dmg and drag **截图大师SnipMagic** into `Applications`.
3. **First launch**: the app is self-signed, so right-click it in `Applications` → **Open** →
   **Open** again to get past Gatekeeper.
4. Grant **Screen Recording** permission when asked (restart the app afterwards for the
   permission to take effect).

**Requirements**: macOS 14.0 (Sonoma) or later.

## Building from source

```bash
git clone https://gitee.com/mrpu2020/SnipMagic_Mac.git
cd SnipMagic_Mac

# Run from source
swift build --disable-sandbox
swift run ScreenshotTool

# Package (arm64 + x86_64 dmgs; signs and verifies the architectures)
./build_app.sh

# Single architecture:
# ./build_app.sh --native       # arm64 dmg only
# ./build_app.sh --x86_64       # Intel dmg only
# ./build_app.sh --universal    # one universal dmg
# ./build_app.sh --app-only     # .app only, no dmg
```

`--disable-sandbox` is required for SwiftPM in restricted environments.

**Architecture conventions**: `dist/截图大师SnipMagic.app` always contains the **arm64** build only
(so it can be double-clicked locally); only the dmgs distinguish architectures
(`截图大师SnipMagic-vX.dmg` = arm64, `截图大师SnipMagic-vX-x86_64.dmg` = Intel). Non-arm64 dmgs are assembled
in a temporary directory under `/tmp`, so `dist/` stays clean. Cross-compiling the Intel
build only needs `swift build --triple x86_64-apple-macosx14.0.0` — no Intel machine needed.

## License

MIT. See [LICENSE](LICENSE).
