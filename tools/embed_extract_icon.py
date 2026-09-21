#!/usr/bin/env python3
"""把 logo/ 下的「提取矢量图」图标重新内嵌进 Swift 源码。

用法（在仓库根目录执行）：

    python3 tools/embed_extract_icon.py

做两件事：
  1. 读取 logo/提取矢量图-黑色-128.png
  2. 重写 Sources/ScreenshotTool/Views/ExtractSubjectIcon.swift 里的 base64 段落

为什么要这个脚本：图标是**内嵌**在 Swift 源码里的（理由见该文件顶部注释 ——
SwiftPM 可执行产物 + 手工组装 .app 的打包方式下，走 bundle 资源容易丢图）。
内嵌的代价是"换图要手工改代码"，这个脚本就是把这个动作固定下来，
免得下次换图时手抄 base64 抄错。

换图流程：
  1. 新导出 PNG，按 `提取矢量图-黑色-<尺寸>.png` 命名放进 logo/
  2. 需要的话改下面的 SOURCE，跑一次本脚本
  3. swift build 确认能编过
"""

from __future__ import annotations

import base64
import pathlib
import textwrap

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = REPO_ROOT / "logo" / "提取矢量图-黑色-128.png"
TARGET = REPO_ROOT / "Sources" / "ScreenshotTool" / "Views" / "ExtractSubjectIcon.swift"

MARKER_START = "    /// `logo/"
MARKER_END = "\n}"


def base64_literal(data: bytes, indent: str = "        ", width: int = 96) -> str:
    """把字节编成 Swift 的多行字符串拼接字面量。"""
    encoded = base64.b64encode(data).decode()
    chunks = textwrap.wrap(encoded, width)
    lines = [f'{indent}"{chunk}" +' for chunk in chunks[:-1]]
    lines.append(f'{indent}"{chunks[-1]}"')
    return "\n".join(lines)


def main() -> int:
    if not SOURCE.is_file():
        print(f"找不到图标源文件：{SOURCE}")
        return 1
    if not TARGET.is_file():
        print(f"找不到目标 Swift 文件：{TARGET}")
        return 1

    text = TARGET.read_text(encoding="utf-8")
    start = text.find(MARKER_START)
    if start < 0:
        print(f"目标文件里找不到写入标记（{MARKER_START!r}），请检查文件是否被改过")
        return 1

    head = text[:start]
    literal = base64_literal(SOURCE.read_bytes())
    TARGET.write_text(
        head
        + f"    /// `{SOURCE.relative_to(REPO_ROOT)}` 的原样字节（base64）。\n"
        + "    private static let embeddedPNG =\n"
        + literal
        + "\n}\n",
        encoding="utf-8",
    )
    print(f"已内嵌 {SOURCE.relative_to(REPO_ROOT)}（{SOURCE.stat().st_size} 字节）→ {TARGET.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
