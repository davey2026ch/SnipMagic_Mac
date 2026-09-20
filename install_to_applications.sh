#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$ROOT/dist/截图大师SnipMagic.app"
APP_DST="/Applications/截图大师SnipMagic.app"
BUNDLE_ID="com.mimo.snipmagic"
RESET_TCC=0

if [[ "${1:-}" == "--reset-permission" ]]; then
  RESET_TCC=1
fi

if [[ ! -d "$APP_SRC" ]]; then
  echo "未找到 $APP_SRC，请先执行 ./build_app.sh" >&2
  exit 1
fi

echo "==> 退出正在运行的实例"
pkill -x ScreenshotTool 2>/dev/null || true
osascript -e 'tell application "截图大师 SnipMagic" to quit' 2>/dev/null || true
sleep 0.5

echo "==> 安装到 /Applications"
rm -rf "$APP_DST"
ditto "$APP_SRC" "$APP_DST"

if [[ "$RESET_TCC" == "1" ]]; then
  echo "==> 重置屏幕录制权限记录（TCC）"
  tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true
else
  echo "==> 保留现有屏幕录制权限（如需重置：./install_to_applications.sh --reset-permission）"
fi

echo "==> 启动应用"
open "$APP_DST"

echo ""
echo "完成：$APP_DST"
echo "若无法截图，请到 系统设置 → 隐私与安全性 → 屏幕录制 打开「截图大师 SnipMagic」。"
