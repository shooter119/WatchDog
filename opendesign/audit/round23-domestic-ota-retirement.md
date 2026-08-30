# 第二十三轮：国内 OTA 功能下线与主线收敛

## 决策

用户决定暂时放弃国内 OTA，不再让 CloudBase 国内对象存储成为正式发布的前置条件。完整的国内 OTA 实现保留在 GitHub 分支 `codex/archive-domestic-ota`，主线只保留其他产品能力和 GitHub Release 正式发布链路。

## 主线处理范围

- 删除 GitHub Actions 中的国内 OTA 凭据校验、对象上传、远端 APK 回读和 `latest.json` 发布步骤。
- App 更新检查恢复为公开 GitHub Releases API；保留 arm64 资产筛选、SHA-256 校验、下载大小限制、版本比较和系统安装器安全校验。
- 删除后端旧 `/ota/*` 兼容重定向和未执行的国内 OTA bucket 迁移，避免主线继续暴露无效下载入口或保留无用数据库变更。
- README、部署说明和 App「关于我们」同步改为 GitHub Release 发布说明。
- 历史审计记录不删除，继续保留此前国内 OTA 的失败证据和整改轨迹。

## 验收标准

1. 主线搜索不到国内 OTA 发布凭据、CloudBase OTA 上传脚本和默认国内清单地址（历史审计目录除外）。
2. GitHub Release workflow 不依赖任何 `CLOUDBASE_OTA_*` Secret。
3. 后端和 App 原有测试数量不下降；后端、Flutter analyze、Flutter test 全部通过。
4. 国内 OTA 分支可独立查看，后续若重新建设不污染主线。

## 当前风险

旧版已经安装的 App 若仍指向 CloudBase 国内清单，将无法通过该旧地址自动发现新版本；用户需通过 GitHub Release、人工安装或后续重新设计的分发方案升级。该兼容影响是放弃国内 OTA 的已知结果，不涉及业务数据和后端核心接口。
