#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="截图工具"
APP="$ROOT/dist/$APP_NAME.app"
BIN_NAME="ScreenshotTool"

echo "==> Building (release)"
cd "$ROOT"
swift build -c release 2>&1

BIN="$ROOT/.build/release/$BIN_NAME"
if [[ ! -f "$BIN" ]]; then
    echo "Binary not found: $BIN" >&2
    exit 1
fi

echo "==> Assembling .app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BIN_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Optional icon
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" || true
fi

echo "==> Ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "    双击打开，或: open \"$APP\""
