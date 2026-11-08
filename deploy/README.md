# WatchDog Deployment Subsystem Blueprint (`deploy`)

## Overview
WatchDog 项目的生产运维、容器编排、离线模型分发与地图瓦片部署子系统。以轻量级 VPS Docker Compose 为核心，依托 Caddy 反向代理网关提供统一的 HTTPS 与静态模型分发能力。

## Subdirectories & Boundaries
- [`vps/`](./vps/README.md): VPS Docker Compose 拓扑配置、Caddyfile 路由定义与重点单位管理端发布流程。
- [`maps/`](./maps/README.md): 重点单位高分辨率正射影像航拍切片工具与目录服务。
- [`models/`](./models/README.md): 离线语音识别 `sherpa-onnx` 模型清单（`manifest.json`）与完整性校验。

## Global Invariants
- `[deploy:security]`：生产敏感凭据（数据库密码、API Token、私有签名）绝对严禁提交至公开 Git 仓库，统一通过 VPS 私有环境变量注入。
- `[deploy:persistence]`：数据库数据卷与 `/app/data` 私有文件卷必须与容器生命周期完全解耦，升级容器时不丢失现场资料与正射影像。
- `[deploy:ota-integrity]`：OTA 分发目录（`/opt/watchdog/ota/`）中的安装包必须与 `latest.json` 保持哈希（SHA-256）与字节大小的严格一致。

## Global Side Effects
- 构建与启动生产 Docker 容器。
- 申请和续期 Let's Encrypt / ZeroSSL TLS 证书。

## Subsystem Verification
- Run: `node deploy/verify-model-manifest.js`
