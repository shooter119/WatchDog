# 第二十一轮：国内 OTA 解阻方案重整

日期：2026-08-29

## 结论先行

当前问题不是“再换一种 HTTP 上传写法”即可解决，而是原方案把大 APK 放在了不适合承载大请求体的 PG Storage API 网关上。`v1.2.3+59` 的生产证据是：319 字节版本清单可以上传并公开回读；约 47 MB APK 经同一网关约 300 秒后返回 `STORAGE_ABORTED`，随后 APK 和 `latest.json` 均未形成可读对象。

经官方文档、官方 SDK 源码和本地 CloudBase 环境核对，采用 CloudBase 静态网站托管作为新的国内 OTA 根入口：静态托管由 COS + CDN 提供 HTTPS 分发，官方文档明确支持 CI/CD 与单文件 50 MB 限制；当前 arm64 APK 为约 47 MB，满足当前发布门槛。新版 App 读取 `/ota/latest.json`，发布工作流把清单和 APK 放到静态托管的 `/ota/` 目录。

旧版 App 的更新清单地址已编译在旧 APK 中，不能由远端清单把 PG Storage 相对路径透明改写到另一域名。因此迁移采用一次性人工/USB/GitHub Release 引导：先安装包含新静态托管入口的版本，之后由国内 OTA 自动更新。发布说明和 App「关于我们」页已明确这一点，不伪造旧版自动迁移能力。

## 方案比较与淘汰理由

| 方案 | 生产可行性 | 结论 |
|---|---|---|
| PG Storage 普通 binary `POST` | 小对象已验证；大 APK 在 CloudBase 网关 300 秒超时 | 淘汰为 APK 传输方案，仅保留历史小对象证据 |
| PG Storage `object/upload/sign` | 预签名仍指向同一网关，历史递增版本已出现 502/超时/401 | 淘汰，不再重复尝试 |
| `get-objects-upload-info` + COS PUT | 官方接口属于经典云存储直传；与现有 PG Storage Bucket/旧 App 公共 URL 的映射没有生产证据，存在“上传成功但 App 读不到”的架构风险 | 不接入主链路，除非后续平台证明确切映射 |
| CloudBase 静态网站托管 | 本地已上传并通过公开 URL 回读；底层 COS + CDN，官方支持 CI/CD，当前 APK 小于 50 MB | 当前推荐方案 |
| 独立 COS/CDN + 新 App 根地址 | 可行，但需要新增 COS/CDN 资源、域名/权限配置，且同样需要旧版一次性迁移 | 暂不引入，作为 APK 超过静态托管 50 MB 后的升级路径 |
| 云托管中转 | 可绕过 GitHub 到上海网关的慢链路，但要新增后端接口、源站下载授权、超时/断点/SSRF 控制，复杂度和故障面明显增加 | 不作为当前最小解 |

## 问题台账

### CI-OTA-005：PG Storage 大 APK 网关超时，需要迁移国内 OTA 入口

- 严重程度：阻断
- 影响范围：当前已安装旧版无法通过 PG `latest.json` 自动发现新静态托管入口；新版本发布前国内 OTA 不可验收。
- 复现步骤或证据：`v1.2.3+59` Actions 运行中，小清单对象 HTTP 200 且逐字节一致；47 MB APK 经 PG binary `POST` 约 300 秒后 HTTP 400、`STORAGE_ABORTED`；已有 App 入口对 APK 仍返回 404。
- 根本原因：GitHub Runner 到 CloudBase PG Storage API 网关承载大请求体时触发固定上游连接时限；PG 预签名仍走同一网关。
- 涉及文件：`.github/workflows/release.yml`、`app/lib/services/update_service.dart`、`app/lib/pages/about_page.dart`、`README.md`、`deploy/cloudbase/README.md`。
- 修改方案：使用 CloudBase 静态托管 CDN 作为 `/ota/` 根入口；发布前检查 APK 小于 50,000,000 bytes；通过固定 API Key 登录 CLI，串行上传并公开完整回读验证；APK 校验成功后最后覆盖 `latest.json`；新版本清单仍保持七字段和相对 `releases/...` APK 路径。
- 修复状态：代码已实现；GitHub Actions 静态托管探针已通过，待正式构建、国内公开下载和真机升级验收。
- 验证结果：本地静态托管 `ota-probe/mapping-test.txt` HTTP 200 且与源文件一致；Actions 运行 `33258137182` 使用同一专用 API Key 上传临时 JSON，并从未登录公网地址逐字节回读通过；正式版本验证待新 tag 执行。

## 验证矩阵与停止条件

1. GitHub Actions 先上传一个临时 JSON 到静态托管并公开回读（已通过，运行 `33258137182`）；若 API Key 无静态托管写权限，停止发布，改为在控制台调整该专用 Key 权限，不再改变 App 校验。
2. 通过探针后运行后端、Flutter、OTA 脚本和 YAML 全量质量门禁；测试数量不得下降。
3. 新 tag 构建并校验包名、versionName、arm64、正式签名、大小和 SHA-256。
4. 上传版本化 manifest，再上传 APK；完整公开下载后核对大小和 SHA-256。
5. 最后上传 `ota/latest.json`，公开回读并核对七字段、版本号、APK 路径、大小和 SHA-256。
6. GitHub Release 只在上述步骤全部通过后创建；失败时不更新 latest、不宣布 OTA 完成。
7. 公开访问地址必须能在未登录的国内网络环境返回清单与 APK；真机安装新版本后再检查自动更新入口。

## 安全边界

- GitHub Actions 只使用专用 `CLOUDBASE_OTA_API_KEY`，不使用后端 service role；密钥不进入仓库、APK、输出文件或审计文档。
- 静态托管发布使用 CLI 内部认证，工作流不把密钥拼入 URL；临时验证文件只写 Runner 临时目录。
- 远端回读必须逐字节校验，不能只依据 CLI 成功或 HTTP 200。
- 当前静态托管域名是公开分发配置，不是密钥；若未来更换环境，必须同步工作流、App 默认地址、README 和关于页面。
