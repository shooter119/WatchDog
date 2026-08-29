# 第二十轮：国内 OTA 上传契约修复与恢复验收

日期：2026-08-29

范围：CloudBase PG Storage 对象上传、GitHub Release 工作流、App 更新清单契约

关联问题：`CI-OTA-001`、`CI-OTA-002`、`CI-OTA-003`

## 阶段结论

- 后端与架构组依据 CloudBase PG Storage 官方 OpenAPI 复核确认：普通对象接口支持 `POST` 二进制正文直传；此前只试过预签名 `PUT` 和普通接口 multipart `POST`，没有按该契约执行普通接口二进制 `POST`。
- 旧 multipart 请求把完整 HTTP 缓存指令传给只接受缓存秒数的 `cacheControl` 表单字段，属于明确的请求契约偏差，可解释已观测到的 HTTP 400；后续 502/超时不能再单独归因为平台故障。
- 发布工作流已改用独立流式上传器：固定 CloudBase HTTPS 域名、`POST` 原始文件正文、显式 `Content-Length`/`Content-Type`/`Cache-Control`、`x-upsert: true`，且不跟随重定向。
- 测试与质量组交叉复核后增加版本化 `manifest.json` 小对象探针；只有探针无认证公开回读并逐字节一致后才上传 APK，APK 完整下载、大小和 SHA-256 通过后才覆盖 `latest.json`。
- Flutter App 组确认客户端无需改动；发布端继续提供既有七字段清单，App 仍按 HTTPS、版本号、大小、SHA-256、包名和 APK 内部 versionCode 逐层校验。
- 本地实现与全量质量门禁已通过；真实 CloudBase 生产上传和公开分发必须由新 tag 的 GitHub Actions 实跑后才能关闭本问题。

## 问题台账

### CI-OTA-003：CloudBase 对象上传方法与 multipart 字段不符合官方契约

- 严重程度：严重
- 影响范围：国内 OTA 自动发布；`latest.json` 与 APK 无法形成可公开下载对象。
- 复现步骤或证据：`v1.2.2+58` 发布运行的普通对象接口 multipart `POST` 依次返回 HTTP 400、502 和 300 秒超时；CloudBase OpenAPI 明确 multipart `cacheControl` 为缓存秒数，而旧工作流传入完整缓存指令；OpenAPI 同时明确普通对象接口可使用二进制正文 `POST`。
- 根本原因：发布脚本混用了 multipart 表单元数据契约与 HTTP Header 契约，并遗漏普通对象接口的二进制正文 `POST` 路径。
- 涉及文件：`.github/workflows/release.yml`、`.github/workflows/quality.yml`、`.github/scripts/cloudbase-ota-upload.cjs`、`.github/scripts/cloudbase-ota-upload.test.cjs`。
- 修改方案：以 Node 原生 HTTPS 流实现二进制正文 `POST`；固定目标域名、显式长度与 MIME；仅重试网络错误、408/425/429/5xx；限制响应体并校验成功响应 `Id/Key`；拒绝超过 CloudBase 100 MB 单对象上限的文件；在质量和发布工作流中运行契约测试。
- 修复状态：代码已修复，待新版本生产流水线验收。
- 验证结果：上传器契约测试 6/6、工作流 YAML 解析、`git diff --check`、后端 162 项、`flutter analyze` 0 问题、Flutter 223 项均通过。

## 发布顺序与失败边界

1. 读取现有 `latest.json`，拒绝 versionCode 倒退或相等。
2. 生成完整七字段清单并上传到 `releases/<tag>/manifest.json`。
3. 无认证公开下载版本清单并逐字节比对；失败时不上传 APK。
4. 上传版本化 arm64 APK；公开完整下载后核对字节数和 SHA-256。
5. 最后覆盖 `latest.json`；公开回读后同时做逐字节和字段契约校验。
6. 国内 OTA 全部通过后才创建 GitHub Release。

任何阶段失败都不得提前更新 `latest.json`，因此 App 不会发现一个尚未完成验证的安装包。

## 当前验收状态

| 验收项 | 状态 | 证据 |
|---|---|---|
| 官方上传契约 | 通过 | CloudBase PG Storage OpenAPI：普通对象接口支持 binary body `POST` |
| 上传器离线契约 | 通过 | Node 6/6；覆盖 URL 编码、正文/头、完整重试、确定性错误不重试、响应校验和 100 MB 上限 |
| 后端回归 | 通过 | `backend/npm test`：162/162 |
| Flutter 静态检查 | 通过 | `flutter analyze`：0 问题 |
| Flutter 回归 | 通过 | `flutter test`：223/223 |
| 生产小对象探针 | 待实跑 | 由新 tag 的 GitHub Actions 执行 |
| 生产 APK 上传与公开哈希 | 待实跑 | 由新 tag 的 GitHub Actions 执行 |
| 生产 `latest.json` 与 App 兼容性 | 待实跑 | 由新 tag 的 GitHub Actions 执行 |

## README 与关于页面核查

本轮没有改变品牌、功能入口或客户端更新协议，只修复发布端传输实现；README 与 App「关于我们」现有“CloudBase 国内 OTA”说明仍准确，无需实质改写。版本号按补丁修复升级为 `1.2.3+59`，并同步 `app/pubspec.yaml` 与设置页常量。
