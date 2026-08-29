# 第八轮 OTA 公开地址复核

日期：2026-08-29

## CI-OTA-002：App 与发布链路指向不可用的 OTA 地址

- 唯一编号：`CI-OTA-002`
- 严重程度：严重
- 影响范围：国内 OTA 清单读取、APK 下载、旧版 App 更新、GitHub Actions 发布链路和正式版本可用性。
- 复现步骤或证据：
  1. 只读请求原 App 默认地址 `https://watchdog-prod-d6gch930m378d9a16-1351750301.ap-shanghai.app.tcloudbase.com/ota/latest.json`，线上返回 HTTP 401；该云托管网关没有把 `/ota` 映射为对象存储。
  2. 按 CloudBase PG Storage 公开对象接口探测预期入口 `https://watchdog-prod-d6gch930m378d9a16.api.tcloudbasegateway.com/v1/storages/object/public/watchdog-ota/latest.json`，返回 `STORAGE_BUCKET_NOT_FOUND`。
  3. 只读执行 `tcb storage buckets list --json`，当前生产环境没有返回 OTA bucket。
  4. 源码复核确认 `backend/src/server.js` 原先没有 `/ota` 路由，`.github/workflows/release.yml` 和 `app/lib/services/update_service.dart` 却把云托管网关 `/ota` 当作存储地址。
- 根本原因：把 CloudBase 云托管 HTTP 网关和 CloudBase PG Storage 的公开对象接口混为同一地址；同时发布前没有确保专用 bucket、公开读策略和对应最小权限 API Key 已存在。
- 涉及文件：
  - `app/lib/services/update_service.dart`
  - `.github/workflows/release.yml`
  - `backend/src/server.js`
  - `backend/migrations/009_ota_public_bucket.sql`
  - `backend/test/api.test.js`
  - `backend/test/migration-script.test.js`
  - `deploy/cloudbase/README.md`
- 修改方案：
  1. App 默认地址和 Release workflow 构建注入地址统一改为 CloudBase PG Storage 公开对象接口。
  2. 新增幂等迁移，创建 `watchdog-ota` 公开 bucket、大小/MIME 限制和对象读取 RLS；已存在但非公开时直接失败，交由人工复核。
  3. 云托管保留旧 `/ota/*` 兼容入口，但仅允许 `latest.json` 和限定格式的 arm64 APK 路径，并固定重定向目标，禁止任意路径或开放重定向。
  4. Release workflow 在构建前检查四个 OTA Secrets，在创建 GitHub Release 前完成 OTA 上传、APK/清单远端回读和 SHA-256/大小/版本校验。
- 修复状态：代码、workflow、迁移脚本和回归测试已完成；后端正式部署复验已完成。生产 bucket/公开策略、四个 GitHub OTA Secrets 和新递增 tag 实跑仍未完成。
- 验证结果：后端 `npm test` 160/160；Flutter `analyze` 0 issues；Flutter `test` 214/214；新增 API 回归确认旧 `/ota/latest.json` 只重定向到固定 PG 公开对象入口，任意私有路径返回 404；迁移契约测试确认 bucket 和公开读策略；workflow YAML、Node/Bash 语法和 `git diff --check` 通过。重新部署后线上 `/api/health` 返回 `ok=true`、`ready=true`、`databaseReady=true`；线上旧 `/ota/latest.json` 返回 HTTP 302 且 `Location` 为固定 PG Storage 公开对象地址；该地址当前返回 `STORAGE_BUCKET_NOT_FOUND`，与尚未执行 bucket 迁移的状态一致。
- 外部阻塞与下一步：
  1. 在备份和预生产条件具备后执行 `009_ota_public_bucket.sql`，确认 bucket 为 `watchdog-ota`、公开读取策略和对象接口返回 200。
  2. 为 GitHub Actions 配置 `CLOUDBASE_OTA_ENV_ID`、`CLOUDBASE_OTA_BUCKET_ID`、`CLOUDBASE_OTA_API_KEY_ID`、`CLOUDBASE_OTA_API_KEY`，API Key 仅授予 OTA bucket 最小写权限。
  3. 用新的递增 tag 实跑，确认 OTA APK 与 GitHub Release APK 的版本号、大小和 SHA-256 一致，再将问题关闭。

CloudBase 的 PG Storage 公开对象访问路径和公开读前提以官方说明为准：[CloudBase PG Storage 访问说明](https://docs.cloudbase.net/storage/pg/serving)、[CloudBase PG 对象接口](https://docs.cloudbase.net/en/http-api/storage-pg/object)。
