#!/bin/zsh
# 截图工具打包脚本（多架构 + dmg 一体化）
#
# 架构约定（重要）：
#   dist/截图工具.app  —— 只放 **arm64（M 芯片）** 版本，永远只有一个架构，方便本机双击即用；
#   dist/*.dmg         —— 按需区分架构：默认同时出 arm64 与 x86_64 两份（Intel / M 各自下载）。
#   非 arm64 的 dmg 在 /tmp 的临时目录里组装 .app，不污染 dist/截图工具.app。
#
# 用法：
#   ./build_app.sh                # 默认：同时打 arm64 和 x86_64 两份 dmg（dist 里的 .app 仍是 arm64）
#   ./build_app.sh --native       # 只打 arm64 dmg（Apple Silicon）
#   ./build_app.sh --x86_64       # 只打 x86_64 dmg（Intel Mac）
#   ./build_app.sh --universal    # 打 arm64+x86_64 通用二进制 dmg（一包通吃）
#   ./build_app.sh --app-only     # 不打 dmg，只产出 dist/截图工具.app（arm64）
#   ./build_app.sh --skip-build   # 跳过 swift build，直接用已编译好的二进制打 dmg（调试用）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="截图工具"
BIN_NAME="ScreenshotTool"
DIST="$ROOT/dist"
MIN_MACOS="14.0.0"  # 由 Package.swift platforms: [.macOS(.v14)] 决定，必须对齐
# 非 arm64 架构组装 .app 的临时目录（用完即删）
TMP_APP_ROOT="/tmp/截图工具-build-$$"

cleanup() { rm -rf "$TMP_APP_ROOT"; }
trap cleanup EXIT

# 从 Info.plist 读版本号（CFBundleShortVersionString）
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null || echo unknown)"
echo "==> Version: $VERSION"

MODE="${1:-all}"

# ============================ 函数 ============================

# build_one <triple-or-empty> <scratch-path> <output-label>
# triple 为空 = 用本机架构（host）
# 日志输出到 stderr，最后一行 stdout = 编译产物的绝对路径
build_one() {
    local triple="$1"
    local scratch="$2"
    local label="$3"
    echo "  -> swift build ($label, triple=${triple:-host}, scratch=$scratch)" >&2
    if [[ -n "$triple" ]]; then
        swift build -c release --disable-sandbox \
            --triple "$triple" \
            --scratch-path "$scratch" >&2 2>&1
    else
        swift build -c release --disable-sandbox \
            --scratch-path "$scratch" >&2 2>&1
    fi
    echo "$scratch/release/$BIN_NAME"
}

# assemble_app <binary-path> <app-path>
assemble_app() {
    local bin="$1"
    local app="$2"
    [[ -f "$bin" ]] || { echo "Binary not found: $bin" >&2; exit 1; }
    echo "  -> Binary arch: $(lipo -info "$bin" 2>/dev/null | sed 's/.*: //')"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin" "$app/Contents/MacOS/$BIN_NAME"
    cp "$ROOT/Resources/Info.plist" "$app/Contents/Info.plist"
    if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
        cp "$ROOT/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$app/Contents/Info.plist" || true
    fi
    codesign --force --deep --sign - "$app"
}

# make_dmg <app-path> <dmg-path>
# 暂存目录 = .app + /Applications 软链，UDBZ 压缩
make_dmg() {
    local app="$1"
    local dmg="$2"
    local staging="/tmp/截图工具-dmg-staging-$$"
    rm -rf "$staging" && mkdir -p "$staging"
    cp -R "$app" "$staging/"
    ln -s /Applications "$staging/Applications"
    rm -f "$dmg"
    hdiutil create -volname "$APP_NAME" -fs HFS+ -format UDBZ \
        -srcfolder "$staging" "$dmg" 2>&1 | tail -3
    rm -rf "$staging"
    echo "  -> dmg: $dmg ($(ls -la "$dmg" | awk '{print $5}') bytes)"
    # 验证 dmg 内二进制架构
    local mnt="/tmp/截图工具-verify-$$"
    hdiutil attach -nobrowse -readonly "$dmg" -mountpoint "$mnt" >/dev/null 2>&1
    lipo -info "$mnt/$APP_NAME.app/Contents/MacOS/$BIN_NAME" 2>&1 || true
    hdiutil detach "$mnt" >/dev/null 2>&1 || true
}

# app_path_for_suffix <dmg-suffix>
# 约定：只有 arm64（无后缀）那份组装进 dist/截图工具.app；
# 其余架构（-x86_64 / -universal）只在 /tmp 临时目录里组装，打完 dmg 就丢。
app_path_for_suffix() {
    if [[ -z "$1" ]]; then
        echo "$DIST/$APP_NAME.app"
    else
        echo "$TMP_APP_ROOT/$APP_NAME.app"
    fi
}

# build_one_arch_release <triple-or-empty> <scratch-path> <arch-label> <dmg-suffix>
# 完整跑一遍：编译 → 组装 .app → 签名 → 打 dmg → 验证
build_one_arch_release() {
    local triple="$1"
    local scratch="$2"
    local arch_label="$3"
    local dmg_suffix="$4"

    local bin
    bin="$(build_one "$triple" "$scratch" "$arch_label")"
    local app
    app="$(app_path_for_suffix "$dmg_suffix")"
    mkdir -p "$(dirname "$app")"
    assemble_app "$bin" "$app"
    local dmg="$DIST/${APP_NAME}-v${VERSION}${dmg_suffix}.dmg"
    make_dmg "$app" "$dmg"
    # 临时目录里的 .app 用完即弃，避免误当成可分发产物
    [[ "$app" == "$DIST/$APP_NAME.app" ]] || rm -rf "$app"
    echo "  -> dist/截图工具.app 架构：$(lipo -info "$DIST/$APP_NAME.app/Contents/MacOS/$BIN_NAME" 2>/dev/null | sed 's/.*: //' || echo '（尚未生成）')"
}

# ============================ 主流程 ============================

cd "$ROOT"
mkdir -p "$DIST"

case "$MODE" in
    all|"")
        echo "==> 默认模式：同时打 arm64 + x86_64 两份 dmg"
        echo "==> [1/2] 构建 arm64 版（Apple Silicon）→ 同时产出 dist/截图工具.app"
        build_one_arch_release "" "$ROOT/.build" "arm64" ""
        echo "==> [2/2] 构建 x86_64 版（Intel Mac）→ 只在临时目录组装，不影响 dist 里的 .app"
        build_one_arch_release "x86_64-apple-macosx$MIN_MACOS" "$ROOT/.build-x86_64" "x86_64" "-x86_64"
        echo "==> 全部完成："
        echo "  dist/截图工具.app : $(lipo -archs "$DIST/$APP_NAME.app/Contents/MacOS/$BIN_NAME" 2>/dev/null || echo '（未生成）')"
        ls -la "$DIST"/*.dmg 2>/dev/null
        ;;
    --native)
        echo "==> 单架构模式：arm64（Apple Silicon）"
        build_one_arch_release "" "$ROOT/.build" "arm64" ""
        ls -la "$DIST"/*.dmg 2>/dev/null | tail -5
        ;;
    --x86_64)
        echo "==> 单架构模式：x86_64（Intel Mac）"
        build_one_arch_release "x86_64-apple-macosx$MIN_MACOS" "$ROOT/.build-x86_64" "x86_64" "-x86_64"
        ls -la "$DIST"/*.dmg 2>/dev/null | tail -5
        ;;
    --universal)
        echo "==> 通用二进制模式：arm64 + x86_64 合并（一包通吃）"
        build_one "arm64-apple-macosx$MIN_MACOS" "$ROOT/.build-arm64" "arm64" >/dev/null
        build_one "x86_64-apple-macosx$MIN_MACOS" "$ROOT/.build-x86_64" "x86_64" >/dev/null
        lipo -create \
            "$ROOT/.build-arm64/release/$BIN_NAME" \
            "$ROOT/.build-x86_64/release/$BIN_NAME" \
            -output "$ROOT/.build/$BIN_NAME.merged"
        # 通用包也只在临时目录组装：dist/截图工具.app 始终只放 arm64。
        mkdir -p "$TMP_APP_ROOT"
        local_app="$TMP_APP_ROOT/$APP_NAME.app"
        assemble_app "$ROOT/.build/$BIN_NAME.merged" "$local_app"
        make_dmg "$local_app" "$DIST/${APP_NAME}-v${VERSION}-universal.dmg"
        rm -rf "$local_app"
        echo "  -> dist/截图工具.app 架构：$(lipo -info "$DIST/$APP_NAME.app/Contents/MacOS/$BIN_NAME" 2>/dev/null | sed 's/.*: //' || echo '（尚未生成）')"
        ls -la "$DIST"/*.dmg 2>/dev/null | tail -5
        ;;
    --app-only)
        echo "==> 只打 .app（默认 arm64，不打 dmg）"
        bin="$(build_one "" "$ROOT/.build" "arm64")"
        assemble_app "$bin" "$DIST/$APP_NAME.app"
        echo "==> Done: $DIST/$APP_NAME.app"
        echo "    双击打开，或: open \"$DIST/$APP_NAME.app\""
        ;;
    *)
        echo "Usage: $0 [all|--native|--x86_64|--universal|--app-only]" >&2
        echo "  无参/all       同时打 arm64 + x86_64 两份 dmg（默认）" >&2
        echo "  --native       只打 arm64 dmg" >&2
        echo "  --x86_64       只打 x86_64 dmg" >&2
        echo "  --universal    打通用二进制 dmg（一包通吃）" >&2
        echo "  --app-only     只打 .app，不打 dmg" >&2
        echo "" >&2
        echo "  约定：dist/截图工具.app 永远是 arm64（M 芯片）；只有 dmg 才区分 Intel / M。" >&2
        exit 64
        ;;
esac
