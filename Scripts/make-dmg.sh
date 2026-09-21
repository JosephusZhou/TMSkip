#!/bin/bash
# 构建 TMSkip DMG（单架构）→ dist/TMSkip-<版本>-<架构>.dmg
#
# 用法：
#   ./Scripts/make-dmg.sh arm64     # Apple Silicon（原生构建）
#   ./Scripts/make-dmg.sh x86_64    # Intel（原生构建；arm64 机器上即交叉编译）
#
# CI 中由 .github/workflows/release-dmg.yml 按架构并行调用，各架构互不影响。
# 签名沿用工程配置（默认 ad-hoc）：无 Developer ID 证书时包不公证，
# 接收方首次打开需右键 → 打开。正式对外分发请先配置证书与公证（见 README「分发」）。
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${1:-}"
case "$ARCH" in
  x86_64|arm64) ;;
  *) echo "用法: $0 <x86_64|arm64>" >&2; exit 2 ;;
esac

PROJ="TMSkip.xcodeproj"
DIST="dist"
mkdir -p "$DIST"

echo "==> 构建 Release ($ARCH)"
xcodebuild -project "$PROJ" -scheme TMSkip -configuration Release \
    -destination 'platform=macOS' \
    ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO \
    build

BUILD_DIR="$(xcodebuild -project "$PROJ" -scheme TMSkip -configuration Release \
    -showBuildSettings 2>/dev/null | awk '/ TARGET_BUILD_DIR =/{print $3}')"
BUILT_APP="$BUILD_DIR/TMSkip.app"
[ -d "$BUILT_APP" ] || { echo "错误：找不到构建产物 $BUILT_APP" >&2; exit 1; }

echo "==> 校验二进制包含 $ARCH 切片"
if lipo -archs "$BUILT_APP/Contents/MacOS/TMSkip" 2>/dev/null | tr ' ' '\n' | grep -qx "$ARCH"; then
    echo "    包含 $ARCH 切片 ✓"
else
    echo "错误：构建产物不包含 $ARCH 切片（$(lipo -archs "$BUILT_APP/Contents/MacOS/TMSkip" 2>/dev/null || echo 无)）" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
OUT_DMG="$DIST/TMSkip-$VERSION-$ARCH.dmg"

echo "==> 制作 DMG（版本 ${VERSION}）"
STAGE="$(mktemp -d)/TMSkip"
mkdir -p "$STAGE"
ditto "$BUILT_APP" "$STAGE/TMSkip.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT_DMG"
hdiutil create -volname "TMSkip $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO -fs HFS+ "$OUT_DMG" >/dev/null
rm -rf "$STAGE"

echo "==> 校验 DMG"
hdiutil verify "$OUT_DMG" >/dev/null

echo
echo "==> 完成: ${OUT_DMG}"
