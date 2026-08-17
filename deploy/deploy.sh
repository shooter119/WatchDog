#!/usr/bin/env bash
# WatchDog 后端部署脚本（bytevirt VPS）
# 用法: deploy/deploy.sh
# 依赖: ssh config 中的 bytevirt 主机、rsync、pm2
set -euo pipefail

HOST="bytevirt"
REMOTE_DIR="/opt/watchdog"
BACKEND_DIR="$(cd "$(dirname "$0")/../backend" && pwd)"

# 部署防呆：仅允许 log 分支上线，防止 main 旧代码回滚覆盖新功能
CUR_BRANCH="$(git -C "$BACKEND_DIR" branch --show-current)"
if [ "$CUR_BRANCH" != "log" ]; then
  echo "仅允许 log 分支部署，当前分支: ${CUR_BRANCH}（如确认无误可临时加 --force 跳过）"
  if [ "${1:-}" != "--force" ]; then
    exit 1
  fi
fi

echo "==> 同步代码到 $HOST:$REMOTE_DIR"
ssh "$HOST" "mkdir -p $REMOTE_DIR/src"
rsync -az --delete -e ssh "$BACKEND_DIR"/src/ "$HOST:$REMOTE_DIR/src/"
rsync -az -e ssh "$BACKEND_DIR"/package.json "$BACKEND_DIR"/package-lock.json "$HOST:$REMOTE_DIR/"

echo "==> 同步部署配置（ecosystem + nginx）"
scp "$(dirname "$0")/ecosystem.config.cjs" "$HOST:$REMOTE_DIR/ecosystem.config.cjs"
scp "$(dirname "$0")/nginx-watchdog.conf" "$HOST:/etc/nginx/conf.d/watchdog.conf"

echo "==> 同步端侧 ASR 模型（deploy/models/，onnx 不入库）"
MODELS_DIR="$(dirname "$0")/models"
if [ -d "$MODELS_DIR" ]; then
  ssh "$HOST" "mkdir -p $REMOTE_DIR/models"
  rsync -az -e ssh "$MODELS_DIR"/ "$HOST:$REMOTE_DIR/models/"
fi

echo "==> 安装依赖并重启"
ssh "$HOST" "cd $REMOTE_DIR && npm ci --omit=dev --silent && nginx -t && pm2 restart watchdog-api --update-env && pm2 save && systemctl reload nginx"

echo "==> 健康检查"
for attempt in $(seq 1 20); do
  if ssh "$HOST" "curl --fail --silent --show-error --max-time 5 http://127.0.0.1:3100/api/health"; then
    echo
    echo "部署完成 ✅"
    exit 0
  fi
  sleep 1
done
echo "健康检查失败：后端未在 20 秒内就绪" >&2
exit 1
