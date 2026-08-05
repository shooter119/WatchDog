#!/usr/bin/env bash
# WatchDog 后端部署脚本（bytevirt VPS）
# 用法: deploy/deploy.sh
# 依赖: ssh config 中的 bytevirt 主机、rsync、pm2
set -euo pipefail

HOST="bytevirt"
REMOTE_DIR="/opt/watchdog"
BACKEND_DIR="$(cd "$(dirname "$0")/../backend" && pwd)"

echo "==> 同步代码到 $HOST:$REMOTE_DIR"
ssh "$HOST" "mkdir -p $REMOTE_DIR/src"
rsync -az --delete -e ssh "$BACKEND_DIR"/src/ "$HOST:$REMOTE_DIR/src/"
rsync -az -e ssh "$BACKEND_DIR"/package.json "$BACKEND_DIR"/package-lock.json "$HOST:$REMOTE_DIR/"

echo "==> 同步部署配置（ecosystem + nginx）"
scp "$(dirname "$0")/ecosystem.config.cjs" "$HOST:$REMOTE_DIR/ecosystem.config.cjs"
scp "$(dirname "$0")/nginx-watchdog.conf" "$HOST:/etc/nginx/conf.d/watchdog.conf"

echo "==> 安装依赖并重启"
ssh "$HOST" "cd $REMOTE_DIR && npm install --omit=dev --silent && pm2 restart watchdog-api --update-env && pm2 save && nginx -t && systemctl reload nginx"

echo "==> 健康检查"
sleep 2
ssh "$HOST" "curl -s http://127.0.0.1:3100/api/health"
echo
echo "部署完成 ✅"
