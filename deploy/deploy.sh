#!/usr/bin/env bash
# WatchDog 后端部署脚本（腾讯云 CloudBase 云托管）
# 用法: CLOUDBASE_ENV_ID=<环境ID> deploy/deploy.sh [--dry-run]
# 依赖: 已安装并登录 CloudBase CLI（命令 tcb）；未安装时脚本会通过 npx 临时调用。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
MODELS_DIR="$ROOT_DIR/deploy/models"
ENV_ID="${CLOUDBASE_ENV_ID:-${CLOUDBASE_ENV:-}}"
SERVICE_NAME="${CLOUDBASE_SERVICE_NAME:-watchdog-api-prod}"
SERVICE_PORT="${CLOUDBASE_SERVICE_PORT:-3000}"
HEALTH_URL="${WATCHDOG_HEALTH_URL:-https://watchdog-prod-d6gch930m378d9a16-1351750301.ap-shanghai.app.tcloudbase.com/api/health}"
MODEL_MANIFEST_URL="${WATCHDOG_MODEL_MANIFEST_URL:-${HEALTH_URL%/api/health}/models/manifest.json}"
CLOUDBASE_CLI_VERSION="${WATCHDOG_CLOUDBASE_CLI_VERSION:-3.8.1}"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)
      DRY_RUN=1
      ;;
    --help|-h)
      sed -n '1,5p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数: $arg" >&2
      exit 2
      ;;
  esac
done

if [ -z "$ENV_ID" ] && [ "$DRY_RUN" -eq 0 ]; then
  echo "请先设置 CLOUDBASE_ENV_ID（或 CLOUDBASE_ENV）" >&2
  exit 1
fi

STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/watchdog-cloudbase.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$STAGE_DIR/src" "$STAGE_DIR/models"
cp "$BACKEND_DIR/Dockerfile" "$STAGE_DIR/Dockerfile"
cp "$BACKEND_DIR/package.json" "$BACKEND_DIR/package-lock.json" "$STAGE_DIR/"
cp -R "$BACKEND_DIR/src/." "$STAGE_DIR/src/"

if [ ! -d "$MODELS_DIR" ] || [ ! -s "$MODELS_DIR/manifest.json" ]; then
  echo "错误：端侧 ASR 模型目录或 manifest.json 缺失，已拒绝部署。" >&2
  exit 1
fi
node "$ROOT_DIR/deploy/verify-model-manifest.js" local "$MODELS_DIR/manifest.json" "$MODELS_DIR"
cp -R "$MODELS_DIR/." "$STAGE_DIR/models/"
test -s "$STAGE_DIR/models/manifest.json"
node "$ROOT_DIR/deploy/verify-model-manifest.js" local "$STAGE_DIR/models/manifest.json" "$STAGE_DIR/models"

echo "==> CloudBase 部署包已准备: $STAGE_DIR"
echo "    环境: ${ENV_ID:-<未设置>}; 服务: $SERVICE_NAME; 端口: $SERVICE_PORT"
echo "    模型文件: $MODELS_DIR -> /models"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> dry-run：不调用 CloudBase CLI"
  echo "tcb cloudrun deploy --env-id <环境ID> --service-name $SERVICE_NAME --source <临时部署目录> --port $SERVICE_PORT --force --yes --wait"
  exit 0
fi

# 固定 CLI 版本，避免本地环境或 npx 最新版本变更部署参数语义。
CLOUD_BASE_CLI=(npx --yes --package "@cloudbase/cli@${CLOUDBASE_CLI_VERSION}" tcb)

echo "==> 部署到 CloudBase 云托管"
"${CLOUD_BASE_CLI[@]}" cloudrun deploy \
  --env-id "$ENV_ID" \
  --service-name "$SERVICE_NAME" \
  --source "$STAGE_DIR" \
  --port "$SERVICE_PORT" \
  --force \
  --yes \
  --wait

echo "==> 健康检查: $HEALTH_URL"
curl --fail --silent --show-error --retry 3 --retry-delay 2 "$HEALTH_URL"
echo
echo "==> 模型清单检查: $MODEL_MANIFEST_URL"
manifest_payload="$(curl --fail --silent --show-error --max-redirs 0 --retry 3 --retry-delay 2 "$MODEL_MANIFEST_URL")"
printf '%s' "$manifest_payload" | node "$ROOT_DIR/deploy/verify-model-manifest.js" remote "$MODELS_DIR/manifest.json"
case "$MODEL_MANIFEST_URL" in
  */manifest.json) MODEL_BASE_URL="${MODEL_MANIFEST_URL%/manifest.json}" ;;
  *) echo "错误：模型清单地址必须以 /manifest.json 结尾。" >&2; exit 1 ;;
esac
REMOTE_MODELS_DIR="$STAGE_DIR/remote-models"
while IFS=$'\t' read -r relative expected_size expected_sha; do
  [ -n "$relative" ] || continue
  target="$REMOTE_MODELS_DIR/$relative"
  mkdir -p "$(dirname "$target")"
  curl --fail --silent --show-error --max-redirs 0 --retry 3 --retry-delay 2 \
    "$MODEL_BASE_URL/$relative" -o "$target"
  actual_size="$(wc -c < "$target" | tr -d ' ')"
  actual_sha="$(node -e 'const fs=require("node:fs"); const crypto=require("node:crypto"); process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"));' "$target")"
  if [ "$actual_size" != "$expected_size" ] || [ "$actual_sha" != "$expected_sha" ]; then
    echo "错误：线上模型资源校验失败：$relative" >&2
    exit 1
  fi
done < <(node -e '
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
for (const [relative, item] of Object.entries(manifest.files)) {
  process.stdout.write(`${relative}\t${item.sizeBytes}\t${String(item.sha256).toLowerCase()}\n`);
}
' "$MODELS_DIR/manifest.json")
echo "CloudBase 部署完成 ✅"
