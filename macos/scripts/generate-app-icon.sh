#!/bin/bash
# 从项目 Logo 生成 macOS 标准尺寸图标；不改变 Logo 的图案与透明背景。
set -euo pipefail
TAOSCREEN_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TAOSCREEN_MASTER="$TAOSCREEN_ROOT/Resources/Brand/TaoScreen-logo.png"
test -f "$TAOSCREEN_MASTER"
TAOSCREEN_ICON_WORK=$(mktemp -d -t taoscreen-icon)
trap 'rm -rf "$TAOSCREEN_ICON_WORK"' EXIT
TAOSCREEN_ICONSET="$TAOSCREEN_ICON_WORK/AppIcon.iconset"
mkdir "$TAOSCREEN_ICONSET"
for TAOSCREEN_SIZE in 16 32 128 256 512; do
    sips -z "$TAOSCREEN_SIZE" "$TAOSCREEN_SIZE" "$TAOSCREEN_MASTER" --out "$TAOSCREEN_ICONSET/icon_${TAOSCREEN_SIZE}x${TAOSCREEN_SIZE}.png" >/dev/null
    TAOSCREEN_RETINA=$((TAOSCREEN_SIZE * 2))
    sips -z "$TAOSCREEN_RETINA" "$TAOSCREEN_RETINA" "$TAOSCREEN_MASTER" --out "$TAOSCREEN_ICONSET/icon_${TAOSCREEN_SIZE}x${TAOSCREEN_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$TAOSCREEN_ICONSET" -o "$TAOSCREEN_ROOT/Resources/AppIcon.icns"
echo "已生成：$TAOSCREEN_ROOT/Resources/AppIcon.icns"
