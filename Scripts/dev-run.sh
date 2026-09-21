#!/bin/bash
# 开发调试循环：构建 Debug → 退出旧实例 → 启动新构建产物
#
# 用法：
#   Scripts/devRun.sh              # 构建 + 重启应用
#   Scripts/devRun.sh --no-build   # 跳过构建，直接重启现有 Debug 产物
#
# 说明：
# - 产物路径由 xcodebuild -showBuildSettings 解析，不写死 DerivedData 目录名。
# - 关闭主窗口 ≠ 退出（菜单栏应用），所以先用 Apple Event 优雅退出，
#   再兜底 SIGTERM/SIGKILL，避免 LaunchServices 复活旧实例。
# - 默认 ad-hoc 签名时，每次重建 DR 都会变化，需在系统设置重新授予
#   「完全磁盘访问」；配置 Config/Local.xcconfig（个人证书）后一次授权通用。
set -euo pipefail
cd "$(dirname "$0")/.."

PROJ="TMSkip.xcodeproj"
SCHEME="TMSkip"
CONFIG="Debug"
APP_NAME="TMSkip"

if [ "${1:-}" = "--no-build" ]; then
    echo "==> 跳过构建"
else
    echo "==> 构建 $CONFIG"
    xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration "$CONFIG" \
        -destination 'platform=macOS' build
fi

BUILD_DIR="$(xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration "$CONFIG" \
    -showBuildSettings 2>/dev/null | awk '/ TARGET_BUILD_DIR =/{print $3}')"
BUILT_APP="$BUILD_DIR/$APP_NAME.app"
[ -d "$BUILT_APP" ] || { echo "错误：找不到构建产物 $BUILT_APP"; exit 1; }

quit_app() {
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
    echo "==> 退出正在运行的 $APP_NAME"
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || return 0
        sleep 0.2
    done
    echo "==> 优雅退出超时，发送 SIGTERM"
    pkill -TERM -x "$APP_NAME" || true
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null 2>&1 && { pkill -KILL -x "$APP_NAME" || true; sleep 0.5; }
    return 0
}
quit_app

echo "==> 启动 $BUILT_APP"
open "$BUILT_APP"

if [ ! -f "Config/Local.xcconfig" ]; then
    echo "!! 提示：当前 ad-hoc 签名，重建后需重新授予「完全磁盘访问」。"
    echo "!! 配置 Config/Local.xcconfig（见 .example）后授权一次即可。"
fi
