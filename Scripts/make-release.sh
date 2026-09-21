#!/bin/bash
# 构建 TMSkip 发布包 → dist/TMSkip-<版本>.zip
#
# 两种模式（自动检测，可用 IDENTITY 环境变量覆盖）：
#
# 1) 本机存在 "Developer ID Application" 证书（需付费开发者计划）：
#    以该证书重签（Hardened Runtime + 时间戳）并公证，产出 Gatekeeper 友好的包：
#    用户下载解压即可打开，首次使用只需授权一次「完全磁盘访问」。
#    公证凭据需一次性配置：
#      xcrun notarytool store-credentials TMSkipNotary \
#          --apple-id <AppleID> --team-id <TeamID> --password <App专用密码>
#
# 2) 没有 Developer ID：按工程当前签名打包（仓库默认 ad-hoc，
#    本机若配置了 Config/Local.xcconfig 则用个人证书）。
#    接收方首次打开需绕过 Gatekeeper：右键 → 打开；或 `xattr -cr TMSkip.app`。
#
# 环境变量：
#   ANON=1          匿名分发：强制 ad-hoc 重签（包内不含任何证书/姓名/邮箱），
#                   跳过公证。接收方体验不变，首次打开需右键 → 打开。
#                   优先级最高，即使检测到 Developer ID 证书也用 ad-hoc。
#   IDENTITY        指定签名身份（默认自动检测 Developer ID）
#   NOTARY_PROFILE  公证 profile（默认 TMSkipNotary）
set -euo pipefail
cd "$(dirname "$0")/.."

PROJ="TMSkip.xcodeproj"
DIST="dist"
NOTARY_PROFILE="${NOTARY_PROFILE:-TMSkipNotary}"

echo "==> 构建 Release"
xcodebuild -project "$PROJ" -scheme TMSkip -configuration Release \
    -destination 'platform=macOS' build

BUILD_DIR="$(xcodebuild -project "$PROJ" -scheme TMSkip -configuration Release \
    -showBuildSettings 2>/dev/null | awk '/ TARGET_BUILD_DIR =/{print $3}')"
BUILT_APP="$BUILD_DIR/TMSkip.app"
[ -d "$BUILT_APP" ] || { echo "错误：找不到构建产物 $BUILT_APP"; exit 1; }

rm -rf "$DIST"
mkdir -p "$DIST"
STAGE="$DIST/TMSkip.app"
ditto "$BUILT_APP" "$STAGE"

echo "==> 检测签名身份"
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"

if [ "${ANON:-0}" = "1" ]; then
    echo "==> 匿名模式：ad-hoc 重签（包内不含证书身份）"
    codesign --force --options runtime --sign - "$STAGE"
    codesign --verify --strict "$STAGE"
elif [ -n "$IDENTITY" ]; then
    echo "==> 使用 Developer ID 重签：$IDENTITY"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$STAGE"
    codesign --verify --strict "$STAGE"

    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --json >/dev/null 2>&1; then
        echo "==> 提交公证（profile: $NOTARY_PROFILE）"
        SUBMIT_ZIP="$DIST/TMSkip-submit.zip"
        ditto -c -k --keepParent --sequesterRsrc "$STAGE" "$SUBMIT_ZIP"
        xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        rm -f "$SUBMIT_ZIP"
        echo "==> 装订公证票据"
        xcrun stapler staple "$STAGE"
        xcrun stapler validate "$STAGE"
    else
        echo "!! 未配置公证凭据（keychain profile: $NOTARY_PROFILE），跳过公证。"
        echo "!! 未公证的 Developer ID 包：用户首次打开需右键 → 打开。"
    fi
else
    echo "==> 未找到 Developer ID 证书，保持工程签名打包。"
    echo "!! 注意：若本机配置了 Config/Local.xcconfig（个人证书），包内会包含证书身份（姓名/邮箱）。"
    echo "!! 想匿名分发请改用：ANON=1 $0"
    echo "!! 接收方首次打开需右键 → 打开，或执行：xattr -cr TMSkip.app"
    echo "!! 如需对 Gatekeeper 完全友好的分发，请加入付费开发者计划并配置 Developer ID 证书。"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGE/Contents/Info.plist")"
OUT_ZIP="$DIST/TMSkip-$VERSION.zip"
ditto -c -k --keepParent --sequesterRsrc "$STAGE" "$OUT_ZIP"
rm -rf "$STAGE"

echo
echo "==> 完成: ${OUT_ZIP}"
echo "    包内签名信息:"
TMPV="$DIST/.verify"
ditto -x -k "$OUT_ZIP" "$TMPV"
codesign -dv "$TMPV/TMSkip.app" 2>&1 | grep -E "Authority|TeamIdentifier|Signature=" || true
rm -rf "$TMPV"
