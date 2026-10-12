#!/bin/bash
# 无需完整 Xcode, 用 CommandLineTools 的 swiftc 构建
# 用法: bash tools/build_app.sh [monitor|debugger]   默认 monitor
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/CuktechMonitor"
SDK=$(xcrun --sdk macosx --show-sdk-path)

MODE="${1:-monitor}"
if [ "$MODE" = "debugger" ]; then
  NAME="CuktechDebugger"
  APP_FILES=("$SRC"/App/*.swift "$SRC"/Views/DebugView.swift)
else
  NAME="CuktechMonitor"
  APP_FILES=("$SRC"/Monitor/*.swift)
fi

OUT="$ROOT/Build/$NAME.app"
echo "==> 构建 $NAME ($MODE)"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

swiftc -parse-as-library -swift-version 5 -target arm64-apple-macosx13.0 -sdk "$SDK" \
  -framework SwiftUI -framework CoreBluetooth -framework CryptoKit -framework AppKit \
  -o "$OUT/Contents/MacOS/$NAME" \
  "${APP_FILES[@]}" \
  "$SRC"/BLE/*.swift "$SRC"/Crypto/*.swift \
  "$SRC"/Models/*.swift "$SRC"/Protocol/*.swift "$SRC"/Support/*.swift

echo "==> 生成最终 Info.plist"
if [ -f "$ROOT/Build/AppIcon.icns" ]; then
  cp "$ROOT/Build/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"
  echo "   已装入图标"
fi
python3 - "$SRC/Info.plist" "$NAME" > "$OUT/Contents/Info.plist" <<'PY'
import sys, plistlib
with open(sys.argv[1], 'rb') as f:
    pl = plistlib.load(f)

name = sys.argv[2]
# bundle id: 监控版用固定的 local.cuktech.monitor (换新 id 可重新触发蓝牙授权弹窗)
if name == "CuktechMonitor":
    bundle_id = 'local.cuktech.monitor'
else:
    bundle_id = 'local.cuktech.monitor.debugger'
replacements = {
    '$(EXECUTABLE_NAME)': name,
    '$(PRODUCT_BUNDLE_IDENTIFIER)': bundle_id,
    '$(PRODUCT_NAME)': name,
    '$(PRODUCT_BUNDLE_PACKAGE_TYPE)': 'APPL',
    '$(MACOSX_DEPLOYMENT_TARGET)': '13.0',
}
pl['CFBundleIconFile'] = 'AppIcon'
pl['CFBundleDisplayName'] = '酷态科 10 Ultra' if name == 'CuktechMonitor' else '酷态科调试器'

def walk(o):
    if isinstance(o, dict):
        return {k: walk(v) for k, v in o.items()}
    if isinstance(o, list):
        return [walk(v) for v in o]
    if isinstance(o, str):
        for k, v in replacements.items():
            o = o.replace(k, v)
        return o
    return o

pl = walk(pl)
with open(sys.stdout.buffer.fileno(), 'wb') as f:
    plistlib.dump(pl, f)
PY

printf 'APPL????' > "$OUT/Contents/PkgInfo"

echo "==> ad-hoc 签名"
codesign --force --sign - "$OUT" 2>/dev/null || true

echo "构建完成: $OUT"