# 第十九轮：正式发布收口与 CloudBase OTA 外部阻塞

日期：2026-08-29

## 审核范围

- 版本：`v1.2.2+58`，tag 已推送至 `shooter119/WatchDog`。
- 工作流：Quality Checks、Build & Release APK。
- 产物：Android arm64 正式 APK、GitHub Release、CloudBase PG Storage `watchdog-ota` 首次对象上传。
- 台账：`CI-OTA-001`、`CI-OTA-002`、`TQ-002`。

## 证据与复核

1. GitHub Actions 运行 `33248992374` 的质量门禁已通过；发布 Job `99091280705` 的构建、版本、ABI 和签名阶段通过，失败集中在 CloudBase OTA 对象上传阶段。
2. 本轮之前已依次验证预签名 PUT、关闭 `Expect` 的 PUT、显式 `Content-Length` 的二进制 PUT、CloudBase 控制台上传和 PG Storage multipart POST。`v1.2.2+55`～`+58` 的上传阶段分别出现 502、无响应超时、401 重试耗尽或 400；所有失败均未形成可读对象。
3. 公开入口复核：`latest.json` 和 `releases/v1.2.2+58/watchdog-1.2.2+58-arm64-v8a.apk` 均为 HTTP 404；控制台 bucket 当前无本轮对象。没有把 404 误记为上传成功。
4. 本地按当前源码重建并核验 arm64 APK：包名 `com.firewatch.watchdog`、versionCode `2058`、versionName `1.2.2`、仅含 `arm64-v8a`、v2 签名有效、大小 `47446468` 字节；SHA-256 已写入 GitHub Release 正文。
5. 在 OTA 网关外部阻塞下，按用户已授权的发布兜底方案创建 GitHub Release `v1.2.2+58`，上传资产名为 `watchdog-1.2.2+58-arm64-v8a.apk`。Release 资产状态为 `uploaded`，GitHub 记录的 digest 与正文 `SHA256:` 一致。
6. 发布后本地收口门禁通过：`cd backend && npm test` 为 `162/162`，`cd app && flutter analyze` 为 `0 issues`，`cd app && flutter test` 为 `223/223`，均无失败或跳过。

## 问题台账

### `CI-OTA-001`：严重

- 影响范围：自动发布链路的 OTA 先行门禁和 GitHub Release 自动创建。
- 根本原因：配置和权限前置已具备，但 CloudBase 对象上传网关在大 APK 首次写入时不稳定/拒绝请求，导致既定“OTA 成功后自动创建 Release”链路停在上传阶段。
- 涉及文件：`.github/workflows/release.yml`、`app/lib/services/update_service.dart`、`opendesign/audit/`。
- 修改方案：保留专用 OTA 凭据、版本单调校验、远端回读和失败即停；不绕过自动链路的校验。当前版本先以人工核验的 GitHub Release 交付 APK，待 CloudBase 上传能力恢复后补齐同版本 OTA 清单或递增版本重跑。
- 修复状态：配置和质量门禁已闭合；自动 OTA 发布未闭合；GitHub Release 已通过人工兜底交付。
- 验证结果：质量 Actions 通过；Release 资产已上传并完成哈希一致性核对。

### `CI-OTA-002`：严重、外部阻塞

- 影响范围：国内 OTA 自动更新；App 无法通过 `latest.json` 发现本次版本。
- 复现证据：CLI 直传、预签名上传、curl 二进制上传、控制台文件上传和 multipart 上传均未产生对象；当前公开对象入口仍返回 404。
- 根本原因：现有 CloudBase PG Storage 上传网关/对象写入链路的实际行为与官方接口契约不一致或受平台侧限制；本地代码、凭据配置和多种请求形态均不足以消除该外部失败。
- 涉及文件：`.github/workflows/release.yml`、`app/lib/services/update_service.dart`、`backend/src/server.js`、`backend/migrations/009_ota_public_bucket.sql`。
- 修改方案：暂停重复上传和无限重试；由 CloudBase 平台侧核对 bucket 写权限、对象 API、网关错误日志及大文件限制，恢复后先上传小型探针对象，再上传 APK、`latest.json` 并公开回读验证。不得以伪造清单、改写客户端校验或暴露后端密钥替代修复。
- 修复状态：阻塞，已升级为平台/环境外部事项；未宣称 OTA 完成。
- 验证结果：GitHub Release 可下载 APK，但 `latest.json` 尚不存在。

## 发布结论

- GitHub Release：已完成，地址为 <https://github.com/shooter119/WatchDog/releases/tag/v1.2.2%2B58>。
- CloudBase 国内 OTA：未完成，不能作为自动更新链路验收通过。
- 项目整体：代码级测试、正式包和手动下载发布可继续验收；整体项目仍保留 `CI-OTA-002` 外部阻塞，不宣布全部验收完成。

## 后续动作

1. 保持当前 Release 和 tag，不删除、不强推、不复用已发布 tag。
2. 待 CloudBase 平台上传链路可用后，先做无业务影响的小对象写入/删除验证，再补齐 `releases/v1.2.2+58/...apk` 和 `latest.json`；若平台要求重新触发工作流，必须使用更高构建号的新版本。
3. 发布前重新执行后端测试、Flutter analyze、Flutter test、APK 哈希/签名、公开对象回读和 GitHub Release 一致性检查。
