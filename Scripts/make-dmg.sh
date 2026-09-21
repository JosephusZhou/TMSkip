#!/bin/bash
# 构建 TMSkip 发布 DMG：一次 universal 编译（x86_64 + arm64），再按架构 lipo 分包，
# 不依赖 Intel 运行器，任何 arm64 macOS 环境（本机 / GitHub macos-15）均可完成。
#
# 用法：
#   ./Scripts/make-dmg.sh [版本] [x86_64] [arm64]          # 默认：构建 + 打包全部架构
#   ./Scripts/make-dmg.sh build [版本]                      # 只构建 universal app（CI 复用）
#   ./Scripts/make-dmg.sh package [版本] [x86_64] [arm64]   # 复用已构建 app 分包（CI 分步隔离）
#
# 版本：显式传入会写入 CFBundleShortVersionString/CFBundleVersion（对齐 tag，
#       如 v0.2.0 → 0.2.0）；缺省读构建产物的 Info.plist。
# 签名：沿用工程配置（CI 无证书时即 ad-hoc）。lipo 分包改写了主二进制，必须重签；
#       重签身份取 xcodebuild 的 CODE_SIGN_IDENTITY，本地个人证书与 CI ad-hoc 都正确。
set -euo pipefail
cd "$(dirname "$0")/.."

PROJ="TMSkip.xcodeproj"
SCHEME="TMSkip"
DIST="dist"

MODE="full"
VERSION=""
DO_X86_64=0
DO_ARM64=0
for a in "$@"; do
  case "$a" in
    build)   MODE="build" ;;
    package) MODE="package" ;;
    x86_64)  DO_X86_64=1 ;;
    arm64)   DO_ARM64=1 ;;
    *)       VERSION="$a" ;;
  esac
done
if [ "$DO_X86_64" = 0 ] && [ "$DO_ARM64" = 0 ]; then DO_X86_64=1; DO_ARM64=1; fi

resolve_built_app() {
  BUILD_DIR="$(xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
      -showBuildSettings 2>/dev/null | awk '/ TARGET_BUILD_DIR =/{print $3}')"
  BUILT_APP="$BUILD_DIR/TMSkip.app"
  [ -d "$BUILT_APP" ] || { echo "错误：找不到构建产物 $BUILT_APP（请先 build）" >&2; exit 1; }
}

check_universal_slices() {
  ARCHS="$(lipo -archs "$BUILT_APP/Contents/MacOS/TMSkip" 2>/dev/null)"
  echo "    二进制架构: ${ARCHS}"
  echo "$ARCHS" | tr ' ' '\n' | grep -qx 'x86_64' || { echo "错误：缺少 x86_64 切片" >&2; exit 1; }
  echo "$ARCHS" | tr ' ' '\n' | grep -qx 'arm64'  || { echo "错误：缺少 arm64 切片" >&2; exit 1; }
}

build_universal() {
  echo "==> 构建 universal Release（x86_64 + arm64）"
  xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
      -destination 'platform=macOS' \
      ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO \
      build
  resolve_built_app
  check_universal_slices
}

package_archs() {
  VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")}"
  SIGN_ID="$(xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
      -showBuildSettings 2>/dev/null | awk -F' = ' '/CODE_SIGN_IDENTITY =/{print $2; exit}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  SIGN_ID="${SIGN_ID:--}"
  echo "==> 分包身份: ${SIGN_ID}，版本: ${VERSION}"
  mkdir -p "$DIST"
  STAGE_BASE="$(mktemp -d)"
  trap 'rm -rf "$STAGE_BASE"' EXIT

  for ARCH in x86_64 arm64; do
    if { [ "$ARCH" = x86_64 ] && [ "$DO_X86_64" = 0 ]; } || \
       { [ "$ARCH" = arm64 ] && [ "$DO_ARM64" = 0 ]; }; then
      continue
    fi
    echo "==> 分包 ${ARCH}"
    APP_STAGE="$STAGE_BASE/TMSkip-$ARCH"
    mkdir -p "$APP_STAGE"
    ditto "$BUILT_APP" "$APP_STAGE/TMSkip.app"

    BIN="$APP_STAGE/TMSkip.app/Contents/MacOS/TMSkip"
    lipo -extract "$ARCH" "$BUILT_APP/Contents/MacOS/TMSkip" -output "$BIN"
    SLICE="$(lipo -archs "$BIN" 2>/dev/null | tr -d ' ')"
    [ "$SLICE" = "$ARCH" ] || { echo "错误：${ARCH} 切片提取失败（lipo: ${SLICE}）" >&2; exit 1; }

    if [ -n "$VERSION" ]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_STAGE/TMSkip.app/Contents/Info.plist"
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_STAGE/TMSkip.app/Contents/Info.plist"
    fi

    # lipo 改写了主二进制，需重签（身份同上；无证书时 ad-hoc）
    codesign --force --options runtime --sign "$SIGN_ID" "$APP_STAGE/TMSkip.app"
    codesign --verify --strict "$APP_STAGE/TMSkip.app"

    ln -s /Applications "$APP_STAGE/Applications"
    OUT_DMG="$DIST/TMSkip-$VERSION-$ARCH.dmg"
    rm -f "$OUT_DMG"
    echo "==> 制作 DMG（${VERSION} / ${ARCH}）"
    hdiutil create -volname "TMSkip $VERSION" -srcfolder "$APP_STAGE" \
        -ov -format UDZO -fs HFS+ "$OUT_DMG" >/dev/null
    hdiutil verify "$OUT_DMG" >/dev/null
    echo "    完成: ${OUT_DMG}"
  done
}

case "$MODE" in
  build)
    build_universal
    echo "==> 构建完成: ${BUILT_APP}"
    ;;
  package)
    resolve_built_app
    check_universal_slices
    package_archs
    ;;
  full)
    build_universal
    package_archs
    ;;
esac
