#!/bin/bash
# 从大图生成 macOS AppIcon.icns (圆角遮罩 + 多尺寸)
# 用法: bash tools/make_icon.sh
set -e

P="$(cd "$(dirname "$0")/.." && pwd)"
PY="$HOME/.cuktech-tools/bin/python3"
SRC="$P/Build/icon_source.jpg"
ICONSET="$P/Build/AppIcon.iconset"
OUT_ICNS="$P/Build/AppIcon.icns"

if [ ! -f "$SRC" ]; then echo "缺少源图: $SRC"; exit 1; fi

rm -rf "$ICONSET"; mkdir -p "$ICONSET"

"$PY" - "$SRC" "$ICONSET" <<'PY'
import sys
from PIL import Image, ImageDraw

src, out = sys.argv[1], sys.argv[2]
im = Image.open(src).convert("RGBA")

def rounded(img, radius_ratio=0.225):
    """macOS Big Sur 风格圆角(超椭圆近似), 输出带透明圆角的方形图"""
    size = img.size[0]
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    r = int(size * radius_ratio)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    out = img.copy()
    out.putalpha(mask)
    return out

selections = {
    "icon_16x16.png": 16, "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32, "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128, "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256, "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512, "icon_512x512@2x.png": 1024,
}
base = rounded(im)
for fn, size in selections.items():
    base.resize((size, size), Image.LANCZOS).save(f"{out}/{fn}")
print("iconset 生成完成")
PY

iconutil -c icns "$ICONSET" -o "$OUT_ICNS"
echo "icns 生成: $OUT_ICNS"