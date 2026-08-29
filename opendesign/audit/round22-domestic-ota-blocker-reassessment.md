# 第二十二轮：国内 OTA 阻塞重评估

日期：2026-08-29

## 结论

本轮不把“静态托管小文件探针通过”误判为大 APK 可发布。静态托管候选已完成一次正式验证：321 字节版本 manifest 能落地，但约 47 MB arm64 APK 上传超过 15 分钟仍没有对象，流水线已取消；`latest.json` 未更新，GitHub Release 未创建。该候选撤回，不进入主线发布链路。

当前主线恢复到上一版 PG Storage 方案，避免把未验证的大文件入口留在生产代码中。下一条正式路线是独立腾讯云 COS（上海地域）+ 公共 HTTPS 分发；它与 App 现有“清单相对 `apkPath`、大小、SHA-256、包名和签名校验”兼容，不需要放宽客户端安全校验。

## 证据与台账

### CI-OTA-005：国内 OTA 大文件分发阻塞

- 严重程度：阻断
- 影响范围：国内 OTA 不能完成正式 APK 发布；旧版 App 仍无法自动迁移到新根地址。
- 已确认事实：PG Storage 网关上传约 47 MB APK 会返回 `STORAGE_ABORTED`；静态托管临时探针运行 `33258137182` 通过；静态托管正式运行 `33258304529` 在 manifest 成功后卡在 APK 上传并被取消；通用 COS 控制台当前存储桶数量为 0。
- 根本原因：当前 PG API 网关和现有 CloudBase 静态托管 CLI 都没有形成“47 MB APK 在国内公网稳定落地”的生产证据；经典 `get-objects-upload-info` 也没有可确认的目标桶与现有公开入口映射。
- 涉及文件：`.github/workflows/release.yml`、`app/lib/services/update_service.dart`、`app/lib/pages/about_page.dart`、`README.md`、`deploy/cloudbase/README.md`。
- 当前状态：代码候选已撤回；外部阻塞转为“创建独立上海 COS 桶、配置最小发布权限和公开读取域名”。

## 最优工作路径

1. 只在腾讯云控制台创建一个独立上海 COS 桶，专用于 OTA；不开启公共写入，不复用后端 service role。
2. 配置独立发布身份，仅允许写入 `ota/releases/*` 和 `ota/latest.json`；公开读取只允许 OTA 对象，版本文件不可变，`latest.json` 使用短缓存。
3. 使用 COS 分片上传或官方 COSCLI，在 GitHub Actions 中先上传不可变 APK，再从公网完整回读并核对大小、SHA-256、Content-Type，最后写 `latest.json`。
4. 清单继续使用相对 `apkPath`，将 App 根地址切换到 COS 公共 HTTPS 域名；所有源共用现有校验字段。
5. 新版本先以人工安装/GitHub Release 引导旧版完成一次迁移；新版本之后由国内 OTA 自动更新。
6. 必须完成 GitHub Runner、未登录公网和 Android 真机三层验收后，才重新创建新版本 tag；不复用已取消的 `v1.2.4+60`。

## 解除阻塞的最小证据

- GitHub Runner 分片上传约 47 MB APK 在 10 分钟内完成；
- 未登录国内 HTTPS 地址返回完整 APK，大小和 SHA-256 与本地一致；
- 版本 manifest 与 `latest.json` 字段一致，且 latest 在 APK 验证后才更新；
- 真机能检查、下载、校验并拉起安装器；
- 失败时不更新 latest、不创建 Release、不泄露发布凭据。

## 明确不再投入

- 不再增加 PG Storage 网关超时或重试次数；
- 不再把经典 COS 上传结果假定为 PG/静态托管对象；
- 不再通过临时签名下载 URL发布静态清单；
- 不再为了测试连续创建新 tag；
- 不再关闭 SHA-256、大小、版本或正式签名校验。
