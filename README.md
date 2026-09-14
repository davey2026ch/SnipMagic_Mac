

# Screenshot Tool for macOS

A powerful, native screenshot application designed specifically for macOS. It provides comprehensive screenshot functionality with advanced image editing capabilities, including region/window/display capture, long screenshot stitching, and integrated OCR functionality.

## Key Features

### Capture Modes
- **Region Capture**: Draw a custom selection area on any screen.
- **Window Capture**: Select and capture individual application windows.
- **Full Screen Capture**: Quickly capture the entire contents of any display.
- **Long Capture (Scrolling)**: Automatically scroll and stitch together content that extends beyond the visible screen area (e.g., web pages or long documents).

### Integrated Editor
Annotate captured images directly within the app with a comprehensive set of tools:
- **Shapes**: Rectangles, ovals, arrows, and freehand paths.
- **Text**: Add text annotations with customizable fonts, sizes, and styles.
- **Mosaic/Blur**: Protect sensitive information by obscuring selected areas.
- **Numbering**: Quickly add sequential numbered badges.
- **Color Picker**: Choose custom colors for all annotation elements.

The editor supports non-destructive editing, allowing you to undo/redo changes and modify or remove annotations at any time.

### Optical Character Recognition (OCR)
- Extract text from your screenshots using the built-in OCR feature.
- Supports plain text extraction and intelligent table recognition.
- Copy results directly to your clipboard for easy use in other applications.

### Customization & Automation
- **Hotkey Support**: Define global keyboard shortcuts for instant region capture, window capture, and long capture.
- **Startup Options**: Optionally launch the app at system login for quick access.
- **System Tray Integration**: Manage screenshots via a convenient menu bar icon.

## System Requirements

- **macOS**: 12.0 (Monterey) or later
- **Hardware**: Any Mac capable of running the above macOS version

## Installation

### Using Homebrew (Recommended)
```bash
brew install --cask screenshot-tool-mac
```

### Manual Installation
1. Download the latest release from the [GitHub Releases](https://github.com/mrpu2020/screenshot-tool-Mac/releases) page.
2. Open the downloaded `.dmg` file.
3. Drag the application into your `Applications` folder.
4. (First Launch) Right-click the app in `Applications` and select **Open** to bypass macOS gatekeeper warnings.

### Post-Installation Permissions
On first launch, the app requires **Screen Recording** permission to capture screen content. A guide will walk you through granting this permission if it's not already enabled.

## Usage Guide

### Starting a Capture
1. Click the menu bar icon or use your configured hotkey.
2. Select the capture mode:
   - `Capture Region` (default)
   - `Capture Window`
   - `Capture Screen`
   - `Long Capture`
3. For region/window modes, follow the on-screen overlay instructions to make your selection.
4. Your capture will open in the editor automatically.

### Using the Editor
- **Select Tool**: Click on an existing annotation to select it.
- **Move/Resize**: Drag to move, or use the corner handles to resize.
- **Style Panel**: Change colors, line width, and other properties in the toolbar.
- **Undo/Redo**: Use `Cmd+Z` and `Cmd+Shift+Z` (or the toolbar buttons).

### Long Capture (Scrolling)
1. Select `Long Capture` from the menu or hotkey.
2. Select a window or region to capture. A control panel will appear.
3. Click **Start** (Enter) to begin scrolling.
4. The tool will automatically scroll and stitch the content.
5. Press **Finish** (Enter) when done, or **Cancel** (Escape) to abort.

### OCR Extraction
1. Open a screenshot in the editor.
2. Click `Extract Text` in the toolbar (or use the shortcut).
3. A progress panel will appear while the text is being recognized.
4. Once complete, the extracted text can be copied or closed.

## Configuration

### Hotkeys
Default hotkeys are provided, but you can customize them in **Settings**:
- **Region Capture**: `Cmd + Shift + 2`
- **Window Capture**: `Cmd + Shift + 3`
- **Long Capture**: `Cmd + Shift + 4`

### Editor Defaults
- **Mosaic Strength**: 10 (pixels per block)
- **Line Thickness**: 3 (points)

## Building from Source

If you wish to contribute or build the app manually:

1. **Clone the repository**:
   ```bash
   git clone https://github.com/mrpu2020/screenshot-tool-Mac.git
   ```
2. **Navigate to the directory**:
   ```bash
   cd screenshot-tool-Mac
   ```
3. **Build the project**:
   ```bash
   swift build
   ```
4. **Run the application**:
   ```bash
   swift run
   ```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License.