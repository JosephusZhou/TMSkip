#!/bin/bash
# 本地发布 TMSkip GitHub Release：一次 universal 编译 → lipo 分包 arm64 / x86_64 DMG
# → 通过 GitHub API 上传 DMG 并创建/更新 Release，自动绑定 v<版本> tag。
#
# 取代原 .github/workflows/release-dmg.yml（GitHub 运行器 macOS SDK 较老，UI 与
# 本机最新 SDK 有差异），全部在本机完成，产出与本机构建一致的包。
#
# 用法：
#   ./Scripts/release-github.sh [版本号]            # 版本缺省读构建产物 Info.plist
#   ./Scripts/release-github.sh --skip-build       # 复用 dist 已有 DMG，只做发布
#   ./Scripts/release-github.sh --dry-run          # 构建打包，但不 push tag / 不调 API
#
# 环境变量：
#   GITHUB_TOKEN    GitHub PAT，需 repo 权限（推荐）。缺省时尝试 gh CLI 登录态。
#   GH_OWNER/GH_REPO 覆盖仓库（缺省从 git remote origin 解析）
#   GH_API_BASE     API 地址（默认 https://api.github.com；企业版可覆盖）
#   GH_UPLOAD_BASE  资产上传地址（默认 https://uploads.github.com）
#   DRAFT=1         创建草稿 Release（不对外发布，可编辑后再手动发布）
#   ALLOW_PARTIAL=1 允许某个架构 DMG 缺失时继续（默认必须 arm64 + x86_64 齐全）
#   ANON=1          强制 ad-hoc 重签（包内不含证书身份，匿名分发；最高优先级）
#   IDENTITY        指定重签身份（如 "Developer ID Application: xxx"，或 "-" 表示 ad-hoc）
#                   以上两者透传给 make-dmg.sh，覆盖 lipo 分包后的重签身份。
#
# tag 绑定规则：
#   - 本地或远端没有 v<版本> 时，自动在当前 HEAD 打 tag 并 push 到 origin；
#   - tag 已存在则直接绑定（绝不移动已有 tag）；若仅远端存在会 fetch 到本地。
#   - 同一版本重复执行 = 更新已有 Release 并重传资产（同名资产先删后传）。
set -euo pipefail
cd "$(dirname "$0")/.."

PROJ="TMSkip.xcodeproj"
SCHEME="TMSkip"
DIST="dist"
API="${GH_API_BASE:-https://api.github.com}"
UPLOAD_API="${GH_UPLOAD_BASE:-https://uploads.github.com}"

VERSION=""
SKIP_BUILD=0
DRY_RUN=0

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- 参数 ----------
for a in "$@"; do
  case "$a" in
    --help|-h) usage; exit 0 ;;
    --skip-build) SKIP_BUILD=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    --*) echo "未知参数: $a" >&2; usage; exit 2 ;;
    *) VERSION="$a" ;;
  esac
done
VERSION="${VERSION#v}"   # 容错：允许传 v0.4.0

# ---------- 前置检查 ----------
command -v curl >/dev/null 2>&1 || { echo "错误：缺少 curl" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "错误：缺少 python3（用于解析 GitHub API 响应）" >&2; exit 1; }

# ---------- 解析仓库 ----------
if [ -n "${GH_OWNER:-}" ] && [ -n "${GH_REPO:-}" ]; then
  OWNER="$GH_OWNER"; REPO="$GH_REPO"
else
  REMOTE="$(git remote get-url origin)"
  REPO_PATH="$(printf '%s' "$REMOTE" | sed -E 's#.*github\.com[:/]##; s#\.git$##')"
  OWNER="${REPO_PATH%/*}"
  REPO="${REPO_PATH#*/}"
  [ -n "$OWNER" ] && [ -n "$REPO" ] && [ "$OWNER" != "$REPO_PATH" ] \
    || { echo "错误：无法从 git remote 解析 GitHub 仓库：$REMOTE（可用 GH_OWNER/GH_REPO 覆盖）" >&2; exit 1; }
fi
echo "==> 仓库: ${OWNER}/${REPO}"

# ---------- 1) 编译 + 分包 DMG ----------
if [ "$SKIP_BUILD" = 0 ]; then
  echo "==> 构建 universal Release 并分包 DMG（arm64 + x86_64）"
  if [ "${ANON:-0}" = "1" ]; then
    echo "    （ANON=1：分包重签强制 ad-hoc，包内不含证书身份）"
  elif [ -n "${IDENTITY:-}" ]; then
    echo "    （IDENTITY=${IDENTITY}：覆盖分包重签身份）"
  fi
  if [ -n "$VERSION" ]; then
    ./Scripts/make-dmg.sh "$VERSION"
  else
    ./Scripts/make-dmg.sh
  fi
else
  echo "==> --skip-build：复用 ${DIST} 现有 DMG"
fi

# ---------- 2) 确定版本（参数 > 构建产物 Info.plist > DMG 文件名） ----------
if [ -z "$VERSION" ]; then
  BUILD_DIR="$(xcodebuild -project "$PROJ" -scheme "$SCHEME" -configuration Release \
      -showBuildSettings 2>/dev/null | awk '/ TARGET_BUILD_DIR =/{print $3}')"
  if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR/TMSkip.app" ]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD_DIR/TMSkip.app/Contents/Info.plist")"
  fi
fi
if [ -z "$VERSION" ]; then
  FIRST_DMG="$(ls "$DIST"/TMSkip-*.dmg 2>/dev/null | head -1 || true)"
  [ -n "$FIRST_DMG" ] || { echo "错误：找不到任何 DMG（${DIST}/TMSkip-*.dmg），也无法读取版本" >&2; exit 1; }
  VERSION="$(basename "$FIRST_DMG" .dmg)"
  VERSION="${VERSION#TMSkip-}"; VERSION="${VERSION%-arm64}"; VERSION="${VERSION%-x86_64}"
fi
[ -n "$VERSION" ] || { echo "错误：无法确定版本号" >&2; exit 1; }
TAG="v${VERSION#v}"

echo "==> 版本: ${VERSION}（tag: ${TAG}）"

# ---------- 3) 收集资产 ----------
ARM_DMG="$DIST/TMSkip-$VERSION-arm64.dmg"
X64_DMG="$DIST/TMSkip-$VERSION-x86_64.dmg"
ASSETS=()
for f in "$ARM_DMG" "$X64_DMG"; do
  if [ -f "$f" ]; then ASSETS+=("$f"); else echo "!! 缺少：$f"; fi
done
if [ "${#ASSETS[@]}" = 0 ]; then
  echo "错误：${DIST} 中没有 ${VERSION} 的 DMG（期望 arm64 与 x86_64 各一个）" >&2
  exit 1
fi
if [ "${#ASSETS[@]}" -lt 2 ] && [ "${ALLOW_PARTIAL:-0}" != 1 ]; then
  echo "错误：默认要求 arm64 + x86_64 两个 DMG 齐全（缺架构请检查构建日志；" >&2
  echo "      确认后可用 ALLOW_PARTIAL=1 只发布现有资产）" >&2
  exit 1
fi

echo "==> 生成 SHA256 校验和（仅当前版本的 DMG）"
( cd "$DIST" && for f in "${ASSETS[@]}"; do shasum -a 256 "$(basename "$f")"; done > SHA256SUMS.txt && cat SHA256SUMS.txt )
ASSETS+=("$DIST/SHA256SUMS.txt")

# ---------- 4) 绑定 tag（缺失则创建并 push） ----------
TAG_EXISTS_LOCAL=0; TAG_EXISTS_REMOTE=0
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
  TAG_EXISTS_LOCAL=1
fi
if git ls-remote --tags origin "$TAG" 2>/dev/null | grep -q "refs/tags/$TAG"; then
  TAG_EXISTS_REMOTE=1
fi

if [ "$TAG_EXISTS_REMOTE" = 1 ]; then
  if [ "$TAG_EXISTS_LOCAL" = 0 ]; then
    echo "==> tag ${TAG} 仅远端存在，fetch 到本地"
    if [ "$DRY_RUN" = 0 ]; then
      git fetch origin "refs/tags/$TAG:refs/tags/$TAG"
    else
      echo "    [dry-run] git fetch origin refs/tags/${TAG}:refs/tags/${TAG}"
    fi
  fi
  echo "==> tag ${TAG} 已存在（远端），直接绑定，不创建/不移动"
elif [ "$TAG_EXISTS_LOCAL" = 1 ]; then
  LOCAL_SHA="$(git rev-parse "refs/tags/$TAG")"
  HEAD_SHA="$(git rev-parse HEAD)"
  if [ "$LOCAL_SHA" != "$HEAD_SHA" ]; then
    echo "!! 提示：本地 tag ${TAG} 指向 ${LOCAL_SHA:0:8}，而当前 HEAD 是 ${HEAD_SHA:0:8}。" >&2
    echo "!! 发布将绑定已有 tag 指向的 commit。如需发布当前代码，请先删除该 tag 再运行。" >&2
  fi
  echo "==> tag ${TAG} 已存在（仅本地），push 到 origin"
  if [ "$DRY_RUN" = 0 ]; then
    git push origin "$TAG"
  else
    echo "    [dry-run] git push origin ${TAG}"
  fi
else
  # 本地与远端都没有 → 在当前 HEAD 创建并 push
  HEAD_SHA="$(git rev-parse HEAD)"
  if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    : # HEAD 已是远端 main 祖先，正常
  else
    echo "!! 提示：tag ${TAG} 将指向本地未推到远端 main 的 commit（${HEAD_SHA:0:8}）。" >&2
    echo "!! 建议先 git push origin main 再发布，否则 Release 会绑定一个远端不可达的 commit。" >&2
  fi
  echo "==> 创建 tag ${TAG}（HEAD ${HEAD_SHA:0:8}）并 push"
  if [ "$DRY_RUN" = 0 ]; then
    git tag "$TAG"
    git push origin "$TAG"
  else
    echo "    [dry-run] git tag ${TAG}"
    echo "    [dry-run] git push origin ${TAG}"
  fi
fi
if [ "$DRY_RUN" = 1 ]; then
  echo
  echo "==> [dry-run] 到此为止：未创建/推送 tag，未调用 GitHub API。"
  echo "    将创建/更新 Release ${TAG} 并上传："
  for a in "${ASSETS[@]}"; do echo "    - $a"; done
  exit 0
fi

# ---------- 5) 创建或更新 Release ----------
# dry-run 已在上一步退出，到这里必然要调 API → 此时才要求 token
TOKEN="${GITHUB_TOKEN:-}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi
if [ -z "$TOKEN" ]; then
  echo "错误：需要 GITHUB_TOKEN（repo 权限）。" >&2
  echo "  生成：GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)，勾选 repo。" >&2
  echo "  使用：export GITHUB_TOKEN=ghp_xxx" >&2
  exit 1
fi

AUTH="Authorization: Bearer $TOKEN"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

get_release_id() {
  # 输出 Release id；不存在时输出空
  local status
  status="$(curl -sS -o "$TMP_DIR/get.json" -w '%{http_code}' \
      -H "$AUTH" -H 'Accept: application/vnd.github+json' \
      "$API/repos/$OWNER/$REPO/releases/tags/$TAG" 2>/dev/null || true)"
  if [ "$status" = 200 ]; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$TMP_DIR/get.json"
  fi
}

RELEASE_ID="$(get_release_id)"
if [ -z "$RELEASE_ID" ]; then
  echo "==> 创建 Release: ${TAG}"
  BODY="{\"tag_name\":\"$TAG\",\"name\":\"$TAG\",\"generate_release_notes\":true,\"draft\":${DRAFT:-false},\"prerelease\":false}"
  status="$(curl -sS -o "$TMP_DIR/create.json" -w '%{http_code}' \
      -H "$AUTH" -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' \
      -d "$BODY" "$API/repos/$OWNER/$REPO/releases" 2>/dev/null || true)"
  if [ "$status" != 201 ]; then
    echo "错误：创建 Release 失败（HTTP ${status}）" >&2
    cat "$TMP_DIR/create.json" >&2 || true
    exit 1
  fi
  RELEASE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["id"])' "$TMP_DIR/create.json")"
else
  echo "==> 更新已有 Release: ${TAG}（保留正文/资产，仅同步名称与 tag）"
  BODY="{\"tag_name\":\"$TAG\",\"name\":\"$TAG\"}"
  status="$(curl -sS -o "$TMP_DIR/update.json" -w '%{http_code}' -X PATCH \
      -H "$AUTH" -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' \
      -d "$BODY" "$API/repos/$OWNER/$REPO/releases/$RELEASE_ID" 2>/dev/null || true)"
  if [ "$status" != 200 ]; then
    echo "错误：更新 Release 失败（HTTP ${status}）" >&2
    cat "$TMP_DIR/update.json" >&2 || true
    exit 1
  fi
fi

# ---------- 6) 上传资产（同名先删后传，保证可重复执行） ----------
existing="$(curl -sS -H "$AUTH" -H 'Accept: application/vnd.github+json' \
    "$API/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets" 2>/dev/null || true)"
for FILE in "${ASSETS[@]}"; do
  NAME="$(basename "$FILE")"
  # 同名资产先删除
  ASSET_ID="$(printf '%s' "$existing" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    d=[]
print(next((a['id'] for a in d if a['name']==sys.argv[1]), ''))" "$NAME")"
  if [ -n "$ASSET_ID" ]; then
    echo "==> 删除旧资产 ${NAME}（同名重传）"
    curl -sS -X DELETE -H "$AUTH" -H 'Accept: application/vnd.github+json' \
        "$API/repos/$OWNER/$REPO/releases/assets/$ASSET_ID" >/dev/null 2>&1 || true
  fi
  echo "==> 上传 ${NAME}（$(( $(wc -c < "$FILE" | tr -d ' ') / 1024 / 1024 )) MB）"
  # 注意：不能用 -G + --data-binary（会把文件二进制塞进 URL 导致请求失败）；
  # 上传 API 要求 name 作为 query 参数，文件本体走 POST body。
  NAME_ENC="$(printf '%s' "$NAME" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')"
  status="$(curl -sS -o "$TMP_DIR/upload.json" -w '%{http_code}' -X POST \
      -H "$AUTH" -H 'Accept: application/vnd.github+json' \
      -H 'Content-Type: application/octet-stream' \
      --data-binary "@$FILE" \
      "$UPLOAD_API/repos/$OWNER/$REPO/releases/$RELEASE_ID/assets?name=$NAME_ENC" \
      2>"$TMP_DIR/upload.err" || true)"
  if [ "$status" != 201 ]; then
    echo "错误：上传 ${NAME} 失败（HTTP ${status}）" >&2
    cat "$TMP_DIR/upload.json" 2>/dev/null >&2 || true
    [ -s "$TMP_DIR/upload.err" ] && cat "$TMP_DIR/upload.err" >&2 || true
    exit 1
  fi
done

echo
echo "==> 完成：https://github.com/${OWNER}/${REPO}/releases/tag/${TAG}"
echo "    资产：${#ASSETS[@]} 个（arm64 + x86_64 DMG + SHA256SUMS.txt）"
