# WatchDog 第七轮发布链路复核

复核日期：2026-08-29
复核小组：性能与工程质量组、测试与质量组、安全与隐私组
范围：GitHub Actions 发布顺序、国内 OTA 配置和 Release/OTA 一致性。

## CI-OTA-001：国内 OTA 配置缺失时会留下半完成 Release

- 级别：严重
- 影响范围：未来新 tag 发布时，如果国内 OTA 所需凭据未配置或上传校验失败，原 workflow 会先创建 GitHub Release，再进入 OTA 步骤；App 已改为读取国内 OTA 清单，因此可能出现 GitHub Release 已存在但国内更新链路未发布的半完成版本。
- 复现步骤/证据：只读执行 `gh secret list --repo shooter119/WatchDog`，当前仅有 `WATCHDOG_KEYSTORE_B64`、`WATCHDOG_KEY_ALIAS`、`WATCHDOG_KEY_PASSWORD`、`WATCHDOG_STORE_PASSWORD`，缺少 `CLOUDBASE_OTA_ENV_ID`、`CLOUDBASE_OTA_BUCKET_ID`、`CLOUDBASE_OTA_API_KEY_ID`、`CLOUDBASE_OTA_API_KEY`；读取 `.github/workflows/release.yml` 确认 `Create GitHub Release` 原先位于 `Publish domestic OTA` 之前。
- 根本原因：发布工作流把 GitHub Release 创建和国内 OTA 发布拆成了有先后关系的步骤，但未先完成 OTA 凭据/上传链路的安全前置检查。
- 涉及文件：`.github/workflows/release.yml`、`app/lib/services/update_service.dart`、`README.md`、`deploy/cloudbase/README.md`。
- 修改方案：将国内 OTA 发布与远端校验置于 GitHub Release 创建之前；OTA 配置缺失、版本倒退、APK 上传或清单校验失败时，workflow 在创建 GitHub Release 前失败，不产生新的半完成 Release。继续要求 OTA 使用独立、最小权限的四个 GitHub Secrets，不复用后端 service_role。
- 修复状态：workflow 顺序已修复；四个 OTA Secrets 尚未配置，仍需具备 CloudBase OTA bucket/API key 权限后进行新 tag 实跑验收。
- 验证结果：当前工作区 `git diff --check` 通过；Ruby YAML 解析通过，并确认 `Publish domestic OTA` 位于 `Create GitHub Release` 之前；只读仓库 Secrets 复核已确认外部配置缺口；未读取或写入任何密钥，未触发发布。

## 外部待办

1. 创建专用 CloudBase OTA 存储环境/桶和最小权限 API key。
2. 将四个值分别写入 GitHub Actions Secrets，不进入仓库和日志。
3. 使用新的递增 tag 实跑，确认 OTA APK 与 GitHub Release APK SHA-256、大小、版本号一致。
4. 验证 `latest.json` 的版本单调递增、缓存头和 App 下载校验。
