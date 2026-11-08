# WatchDog Engineering & Operations Scripts (`scripts`)

## Overview
工程自动化与运维交付脚本套件。覆盖端到端版本发布、多重质量门禁校验、VPS 重点单位后台部署、以及全量异地备份与完整性验证。

## Interface
- **一键发布流水线**: [`release.sh`](./release.sh)
  - 核心参数：`--version x.y.z --notes-file notes.md [--dry-run] [--skip-website] [--skip-upload] [--skip-gates]`
  - 流程：版本号与构建号同步 -> 全套门禁（Flutter analyze/test + Node.js 严格测试） -> 自动 Git 提交与 Tag -> 构建正式 arm64 分包 -> VPS OTA 上传与 `latest.json` 原子替换 -> 公网健康重试与校验。
- **异地灾备同步工具**: [`backup-pull.sh`](./backup-pull.sh)
  - 核心功能：从 VPS 远程拉取 PostgreSQL 归档转储包（`pg_dump -Fc`）、`/app/data` 私有文件卷与 `latest.json`，双向哈希比对并解压校验 TOC 成员，安全留存于外部目录 `~/WatchDog-backups`。
- **管理后台部署与验收**: [`deploy-key-sites.sh`](./deploy-key-sites.sh), [`verify-key-sites.mjs`](./verify-key-sites.mjs)
  - 核心功能：灰度构建、Caddyfile 原地热重载、端点匿名安全性核验与回滚保护。
- **危化品与模式生成工具**: [`generate-hazmat-samples.js`](./generate-hazmat-samples.js), [`generate-key-site-schema.mjs`](./generate-key-site-schema.mjs)

## Invariants
- `[scripts:gate-strictly-enforced]`：`release.sh` 默认执行 fail 0 严格门禁；绝不允许绕过质量检查擅自发布版本。
- `[scripts:ota-sha256]`：生成的 `latest.json` 必须包含经过实机/构建包实际测算的真实 `sha256` 与 `size_bytes`，缺字段或哈希错误的清单会被 App 整份拒收。
- `[scripts:atomic-backup]`：异地拉取备份必须先在远端打包并比对 SHA-256，拉取到本地后校验签名完整，确保可恢复性。

## Side Effects
- 在本地构建正式 APK（执行 `flutter build apk --release`）。
- 向生产服务器执行 SSH/SCP 远程部署、重启容器或拉取备份文件。
- 创建 Git Tag 并向远程仓库推送。

## Verification
- Run: `bash scripts/release.sh --dry-run --version 1.13.0`
