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

if [ -d "$MODELS_DIR" ]; then
  cp -R "$MODELS_DIR/." "$STAGE_DIR/models/"
else
  echo "警告：未找到端侧 ASR 模型目录，部署后只能使用已安装模型的设备。" >&2
fi

echo "==> CloudBase 部署包已准备: $STAGE_DIR"
echo "    环境: ${ENV_ID:-<未设置>}; 服务: $SERVICE_NAME; 端口: $SERVICE_PORT"
echo "    模型文件: $MODELS_DIR -> /models"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "==> dry-run：不调用 CloudBase CLI"
  echo "tcb cloudrun deploy --env-id <环境ID> --service-name $SERVICE_NAME --source <临时部署目录> --port $SERVICE_PORT --force --yes --wait"
  exit 0
fi

if command -v tcb >/dev/null 2>&1; then
  CLOUD_BASE_CLI=(tcb)
else
  # @cloudbase/cli exposes the tcb binary, but npx only resolves a package
  # executable reliably when the package is declared explicitly.
  CLOUD_BASE_CLI=(npx --yes --package @cloudbase/cli tcb)
fi

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
echo "CloudBase 部署完成 ✅"
