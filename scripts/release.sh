#!/usr/bin/env bash
#
# 一键发版：改版本号 → 跑门禁 → 提交推送 → 打 tag → 构建 arm64 APK
#          → 上传 VPS OTA → 原子更新 latest.json → 公网校验
#          → 同步官网（版本号/下载链接 + 重建容器）→（可选）GitHub Release
#
# 约定（与 app/lib/services/update_service.dart 保持一致）：
#   tag 形式为 v<版本>+<构建号>，APK 使用 split-per-abi，arm64 的
#   versionCode = 2000 + 构建号，App 端从 tag 自行推算，不读清单里的 version_code。
#
# 用法：
#   scripts/release.sh --version 1.8.3 --notes-file notes.md
#   scripts/release.sh --version 1.8.3 --notes "修复若干问题" --build 91
#   scripts/release.sh --version 1.8.3 --notes "..." --dry-run
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APK_DIR_REL="app/build/app/outputs/flutter-apk"
APK_PREFIX="watchdog"

# OTA 主机与目录，可用环境变量覆盖
OTA_HOST="${OTA_HOST:-ali}"
OTA_DIR="${OTA_DIR:-/opt/watchdog/ota}"
PUBLIC_BASE="${PUBLIC_BASE:-https://fireman119.xyz}"

# 官网：本地目录、VPS 目录与 compose 文件
WEBSITE_DIR="${WEBSITE_DIR:-${REPO_ROOT}/website}"
WEBSITE_REMOTE_DIR="${WEBSITE_REMOTE_DIR:-/opt/watchdog/website}"
COMPOSE_FILE="${COMPOSE_FILE:-/opt/watchdog/deploy/vps/docker-compose.yml}"

VERSION=""
BUILD=""
NOTES=""
NOTES_FILE=""
DO_GH=0
DRY_RUN=0
SKIP_GATES=0
SKIP_UPLOAD=0
SKIP_WEBSITE=0
VERIFY_DOWNLOAD=1

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m错误：%s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,/^set -euo pipefail$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
  cat <<'EOF'

参数：
  --version <x.y.z>     必填，新版本号（不要带 +构建号）
  --build <n>           可选，构建号；默认取「已有 tag 与 pubspec 中较大者 +1」
  --notes <text>        更新说明（GitHub Release 与 changelog 共用）
  --notes-file <path>   从文件读更新说明（优先级高于 --notes）
  --github-release      同时创建 GitHub Release
  --skip-gates          跳过 analyze/test/后端测试（不建议）
  --skip-upload         跳过 OTA 上传与公网校验（只构建）
  --skip-website        跳过官网同步
  --no-verify-download  公网只校验 HEAD 与清单，不完整下载比对 sha256
  --dry-run             只打印将要执行的计划，不改动任何东西
  -h, --help            显示帮助

环境变量：
  OTA_HOST（默认 ali）、OTA_DIR（默认 /opt/watchdog/ota）、
  PUBLIC_BASE（默认 https://fireman119.xyz）
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:-}"; shift 2 ;;
    --build) BUILD="${2:-}"; shift 2 ;;
    --notes) NOTES="${2:-}"; shift 2 ;;
    --notes-file) NOTES_FILE="${2:-}"; shift 2 ;;
    --github-release) DO_GH=1; shift ;;
    --skip-gates) SKIP_GATES=1; shift ;;
    --skip-upload) SKIP_UPLOAD=1; shift ;;
    --skip-website) SKIP_WEBSITE=1; shift ;;
    --no-verify-download) VERIFY_DOWNLOAD=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[[ -n "$VERSION" ]] || { usage; die "缺少 --version"; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 x.y.z，收到：$VERSION"

if [[ -n "$NOTES_FILE" ]]; then
  [[ -f "$NOTES_FILE" ]] || die "找不到说明文件：$NOTES_FILE"
  NOTES="$(cat "$NOTES_FILE")"
fi
[[ -n "$NOTES" ]] || die "缺少更新说明：请用 --notes 或 --notes-file"

cd "$REPO_ROOT"

step "检查工作区"
[[ -z "$(git status --porcelain)" ]] || die "工作区有未提交改动，先提交或还原再发版"
info "工作区干净"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || die "当前分支是 $BRANCH，发版必须在 main 上"
info "当前分支：main"

step "计算构建号"
CUR_PUBSPEC="$(sed -n 's/^version: //p' app/pubspec.yaml | head -1)"
CUR_BUILD="${CUR_PUBSPEC##*+}"
LAST_TAG="$(git tag --sort=-v:refname | head -1 || true)"
LAST_BUILD="0"
if [[ -n "$LAST_TAG" && "$LAST_TAG" == *+* ]]; then
  LAST_BUILD="${LAST_TAG##*+}"
  LAST_BUILD="${LAST_BUILD%%[^0-9]*}"
fi
if [[ -z "$BUILD" ]]; then
  if (( LAST_BUILD > CUR_BUILD )); then BUILD=$((LAST_BUILD + 1)); else BUILD=$((CUR_BUILD + 1)); fi
fi
[[ "$BUILD" =~ ^[0-9]+$ ]] || die "构建号必须是数字，收到：$BUILD"
TAG="v${VERSION}+${BUILD}"
VERSION_CODE=$((2000 + BUILD))
APK_NAME="${APK_PREFIX}-${VERSION}+${BUILD}-arm64-v8a.apk"
APK_URL="${PUBLIC_BASE}/ota/versions/${APK_NAME}"
info "当前 pubspec：${CUR_PUBSPEC}"
info "最近 tag：${LAST_TAG:-无}"
info "新版本：${VERSION}+${BUILD}（tag ${TAG}，APK versionCode ${VERSION_CODE}）"

step "检查 tag 是否已存在"
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  die "本地已存在 tag ${TAG}"
fi
if git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1; then
  die "远端已存在 tag ${TAG}（重发请先删除远端 tag）"
fi
info "tag ${TAG} 可用"

if (( DRY_RUN )); then
  step "dry-run 结束"
  info "将更新 app/pubspec.yaml 与 app/lib/pages/settings_page.dart 的版本号为 ${VERSION}+${BUILD}"
  info "将提交并推送 main，创建并推送 tag ${TAG}"
  info "将构建 ${APK_NAME} 并上传到 ${OTA_HOST}:${OTA_DIR}/versions/"
  info "将更新 ${PUBLIC_BASE}/ota/latest.json 并做公网校验"
  info "将同步官网 ${WEBSITE_DIR} → ${OTA_HOST}:${WEBSITE_REMOTE_DIR} 并重建 website 容器"
  [[ $DO_GH -eq 1 ]] && info "将创建 GitHub Release ${TAG}"
  exit 0
fi

if (( SKIP_GATES == 0 )); then
  step "跑门禁：flutter analyze"
  ( cd app && env -u GIT_CONFIG_COUNT flutter analyze 2>&1 | tee /tmp/release-analyze.log | tail -3 )
  grep -q "No issues found" /tmp/release-analyze.log || die "flutter analyze 未通过"

  step "跑门禁：flutter test"
  ( cd app && env -u GIT_CONFIG_COUNT flutter test 2>&1 | tee /tmp/release-test.log | tail -2 )
  grep -q "All tests passed" /tmp/release-test.log || die "flutter test 未通过"

  step "跑门禁：后端 npm test"
  if [[ -d backend/node_modules ]]; then
    ( cd backend && npm test 2>&1 | tee /tmp/release-backend.log | tail -6 )
    grep -qE "^# fail 0|ℹ fail 0" /tmp/release-backend.log || die "后端测试未通过"
  else
    warn "backend/node_modules 不存在，跳过后端测试"
  fi
else
  warn "已按 --skip-gates 跳过门禁"
fi

step "写入版本号"
sed -i '' -E "s/^version: .*/version: ${VERSION}+${BUILD}/" app/pubspec.yaml
sed -i '' -E "s/^const appVersion = '.*';/const appVersion = '${VERSION}+${BUILD}';/" app/lib/pages/settings_page.dart
grep -n '^version:' app/pubspec.yaml
grep -n '^const appVersion' app/lib/pages/settings_page.dart

step "提交并推送"
git add app/pubspec.yaml app/lib/pages/settings_page.dart
git commit -m "chore: 版本号升至 ${VERSION}+${BUILD}"
git push origin main

step "打 tag ${TAG}"
git tag -a "$TAG" -m "$TAG"
git push origin "$TAG"

step "构建 release APK（arm64 split）"
( cd app && env -u GIT_CONFIG_COUNT flutter build apk --release \
    --target-platform android-arm64 --split-per-abi 2>&1 | tail -3 )
APK_PATH="${APK_DIR_REL}/app-arm64-v8a-release.apk"
[[ -f "$APK_PATH" ]] || die "构建产物不存在：$APK_PATH"

step "校验 APK"
AAPT2="$(ls "$HOME"/Library/Android/sdk/build-tools/*/aapt2 2>/dev/null | tail -1 || true)"
APKSIGNER="$(ls "$HOME"/Library/Android/sdk/build-tools/*/apksigner 2>/dev/null | tail -1 || true)"
[[ -n "$AAPT2" ]] || die "找不到 aapt2，无法校验 versionCode"
BADGING_TMP="$(mktemp -t watchdog-release-badging.XXXXXX.txt)"
"$AAPT2" dump badging "$APK_PATH" > "$BADGING_TMP" 2>/dev/null
INFO_OUT="$(awk '/^package/{print; exit}' "$BADGING_TMP")"
rm -f "$BADGING_TMP"
echo "$INFO_OUT"
echo "$INFO_OUT" | grep -q "versionCode='${VERSION_CODE}'" || die "APK versionCode 不是 ${VERSION_CODE}"
echo "$INFO_OUT" | grep -q "versionName='${VERSION}'" || die "APK versionName 不是 ${VERSION}"
if [[ -n "$APKSIGNER" ]]; then
  "$APKSIGNER" verify "$APK_PATH" >/dev/null || die "APK 签名校验失败"
  info "签名校验通过"
fi
SIZE_BYTES="$(wc -c < "$APK_PATH" | tr -d ' ')"
SHA256="$(shasum -a 256 "$APK_PATH" | awk '{print $1}')"
info "大小：${SIZE_BYTES} 字节"
info "SHA-256：${SHA256}"

if (( SKIP_UPLOAD )); then
  step "已跳过 OTA 上传"
  info "产物：${REPO_ROOT}/${APK_PATH}"
  exit 0
fi

step "上传到 OTA（${OTA_HOST}:${OTA_DIR}）"
scp -q "$APK_PATH" "${OTA_HOST}:${OTA_DIR}/incoming/${APK_NAME}"
REMOTE_SHA="$(ssh "$OTA_HOST" "sha256sum '${OTA_DIR}/incoming/${APK_NAME}' | awk '{print \$1}'")"
[[ "$REMOTE_SHA" == "$SHA256" ]] || die "上传后校验失败：远端 ${REMOTE_SHA} != 本地 ${SHA256}"
info "远端校验一致"

step "生成并上传 latest.json"
MANIFEST_TMP="$(mktemp -t watchdog-ota-manifest.XXXXXX.json)"
export REL_TAG="$TAG" REL_VERSION_CODE="$VERSION_CODE" REL_APK_URL="$APK_URL" \
       REL_SIZE="$SIZE_BYTES" REL_SHA256="$SHA256" REL_CHANGELOG="$NOTES"
python3 - "$MANIFEST_TMP" <<'PY'
import json, os, sys
data = {
    "tag_name": os.environ["REL_TAG"],
    "version_code": int(os.environ["REL_VERSION_CODE"]),
    "apk_url": os.environ["REL_APK_URL"],
    "size_bytes": int(os.environ["REL_SIZE"]),
    "sha256": os.environ["REL_SHA256"],
    "changelog": os.environ["REL_CHANGELOG"],
}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
PY
scp -q "$MANIFEST_TMP" "${OTA_HOST}:${OTA_DIR}/incoming/latest.json"

step "原子替换（先备份旧清单）"
ssh "$OTA_HOST" "set -e
  cd '${OTA_DIR}'
  cp -f latest.json latest.json.bak
  mv -f 'incoming/${APK_NAME}' 'versions/${APK_NAME}'
  mv -f incoming/latest.json latest.json
  ls -l 'versions/${APK_NAME}' latest.json"
rm -f "$MANIFEST_TMP"

step "公网校验"
REMOTE_MANIFEST="$(curl -fsS --max-time 20 "${PUBLIC_BASE}/ota/latest.json")"
TAG="$TAG" VERSION_CODE="$VERSION_CODE" SIZE_BYTES="$SIZE_BYTES" SHA256="$SHA256" \
  REMOTE_MANIFEST="$REMOTE_MANIFEST" python3 - <<'PY'
import json, os, sys
data = json.loads(os.environ["REMOTE_MANIFEST"])
expect = {
    "tag_name": os.environ["TAG"],
    "version_code": int(os.environ["VERSION_CODE"]),
    "size_bytes": int(os.environ["SIZE_BYTES"]),
    "sha256": os.environ["SHA256"],
}
for key, want in expect.items():
    got = data.get(key)
    if got != want:
        print(f"清单字段不一致：{key} 期望 {want} 实际 {got}", file=sys.stderr)
        sys.exit(1)
print("清单字段一致：", ", ".join(f"{k}={v}" for k, v in expect.items()))
PY
HEADERS="$(curl -fsSI --max-time 20 "$APK_URL")"
echo "$HEADERS" | grep -qi "^HTTP/2 200\|^HTTP/1.1 200" || die "APK 公网响应不是 200"
LEN="$(echo "$HEADERS" | awk 'BEGIN{IGNORECASE=1} /^content-length:/{gsub(/\r/,""); print $2}')"
[[ "$LEN" == "$SIZE_BYTES" ]] || die "公网 Content-Length ${LEN} 与本地 ${SIZE_BYTES} 不一致"
info "APK 公网 200，长度一致（${SIZE_BYTES} 字节）"

if (( VERIFY_DOWNLOAD )); then
  step "下载比对 SHA-256"
  DL_TMP="$(mktemp -t watchdog-ota-download.XXXXXX.apk)"
  curl -fsS --max-time 300 -o "$DL_TMP" "$APK_URL"
  DL_SHA="$(shasum -a 256 "$DL_TMP" | awk '{print $1}')"
  rm -f "$DL_TMP"
  [[ "$DL_SHA" == "$SHA256" ]] || die "下载文件 SHA-256 不一致：${DL_SHA} != ${SHA256}"
  info "下载文件 SHA-256 一致"
fi

if (( DO_GH )); then
  step "创建 GitHub Release ${TAG}"
  gh release create "$TAG" --title "$TAG" --notes "$NOTES"
  info "GitHub Release 已创建"
fi

if (( SKIP_WEBSITE == 0 )); then
  if [[ -d "$WEBSITE_DIR" ]]; then
    step "同步官网"
    python3 - "$WEBSITE_DIR/index.html" "${VERSION}+${BUILD}" "$APK_URL" <<'PY'
import re, sys
path, version, apk_url = sys.argv[1], sys.argv[2], sys.argv[3]
html = open(path, encoding="utf-8").read()
html = re.sub(r'(id="site-version">)[^<]*(<)', lambda m: m.group(1) + version + m.group(2), html)
html = re.sub(r'(data-download href=")[^"]*(")', lambda m: m.group(1) + apk_url + m.group(2), html)
html = re.sub(r'https://[^"\s]+/ota/versions/watchdog-[^"\s]+\.apk', apk_url, html)
open(path, "w", encoding="utf-8").write(html)
print(f"index.html 已更新为 {version} / {apk_url}")
PY
    rsync -az --delete "$WEBSITE_DIR/" "${OTA_HOST}:${WEBSITE_REMOTE_DIR}/"
    ssh "$OTA_HOST" "cd '$(dirname "$COMPOSE_FILE")/../..' && docker compose -f '${COMPOSE_FILE}' build website >/dev/null && docker compose -f '${COMPOSE_FILE}' up -d website >/dev/null && echo website_rebuilt"
    PAGE="$(curl -fsS --max-time 20 "${PUBLIC_BASE}/")"
    echo "$PAGE" | grep -q "id=\"site-version\">${VERSION}+${BUILD}<" \
      || die "官网版本未更新（OTA 已发布，仅官网未同步）：请检查 ${OTA_HOST} 上的 website 容器"
    echo "$PAGE" | grep -q "${APK_NAME}" \
      || die "官网下载链接未指向 ${APK_NAME}（OTA 已发布，仅官网未同步）"
    info "官网已更新并重建容器，页面版本 ${VERSION}+${BUILD}"
  else
    warn "本地 website/ 目录不存在，跳过官网同步"
  fi
else
  warn "已按 --skip-website 跳过官网同步"
fi

step "发版完成"
info "版本：${VERSION}+${BUILD}（tag ${TAG}）"
info "APK：${APK_URL}"
info "清单：${PUBLIC_BASE}/ota/latest.json"
cat <<EOF

后续动作：
  - 已安装旧版本的设备会在下次检查更新时看到 ${TAG}
  - 如需推送安装包：adb install -r "$APK_PATH"
  - 回滚清单：ssh ${OTA_HOST} 'cp ${OTA_DIR}/latest.json.bak ${OTA_DIR}/latest.json'
EOF
