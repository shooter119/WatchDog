# WatchDog 项目约定

## 工作流

- 改完代码后**不自动 commit/push/发版**，等用户明确通知再操作。后端部署（`deploy/deploy.sh`）除外，见下。
- commit 前检查 `git status` / `git diff`，只提交本次相关的改动。
- 提交信息简洁中文，符合仓库现有风格。
- 临时调试文件（含密钥等）不入库。
- 设计任务的辅助文件（方案页、草图、计划、品牌规范、导出元数据）统一放在 `opendesign/`，不在项目根目录创建；正式运行资源按用途放入 App 资产目录。
- **README 同步核查**：每次改动完成后核查 README 是否有必要更新（品牌、功能、架构、入口变化都算）；README 有实质内容变更时，App 内「关于我们」页（`app/lib/pages/about_page.dart`）必须同步更新，反之亦然。
- 提交前必须通过验证（见下），构建/测试失败不允许提交。
- **后端代码（backend/src/、deploy/）有修改时，验证通过后直接运行 `deploy/deploy.sh` 部署到线上**，无需用户提醒。
- **版本号与发版由用户决定**：用户要求发版时，依据改动规模判断升级幅度（小优化/修复 → 补丁 +0.0.1；新功能 → 次版本 +0.1.0；重大重构/首个稳定版 → 主版本 +1.0.0），`+` 号后构建号必须递增。同步更新 `app/pubspec.yaml` 的 `version:` 与 `app/lib/pages/settings_page.dart` 的 `appVersion` 常量。
- **发版流程**：验证通过后 commit + push，再 `git tag v<版本号>+<构建号>` + `git push origin <tag>` → GitHub Actions 自动构建 arm64 正式签名 APK → 发布 GitHub Release（含 sha256 与自动 changelog）。
- 发版前兜底检查：`git status` 确认改动已全部提交；`git diff HEAD` 确认版本号常量与要打的 tag 一致。
- **CI 触发注意**：GitHub 对**已存在 tag 的 force push 不触发 workflow**。若需用新提交更新已发布版本，必须先删远端 tag（`git push origin :refs/tags/<tag>`）再重新创建并 push。
- 发布后确认 Actions 状态，失败（如签名校验）先修 workflow 再重打 tag，不能带着失败发布。
  - **CI 触发注意**：GitHub 对**已存在 tag 的 force push 不触发 workflow**。若需用新提交更新已发布版本，必须先删远端 tag（`git push origin :refs/tags/<tag>`）再重新创建并 push；tag 打错位置同理。发布后确认 Actions 状态，失败（如签名校验）先修 workflow 再重打 tag，不能带着失败发布。
- **OTA 分发链路**：GitHub Releases 直连（公开仓库免 token）；release body 必须含 `SHA256: <64位hex>` 行（CI 自动写入，App 下载后校验）；App 端 `app/lib/services/update_service.dart` 负责查询/比较/下载。

## 验证命令

- 后端：在 `backend/` 下运行 `npm test`（node:test），改 server/db/parse/calc 必须通过。
- App：在 `app/` 下运行 `flutter analyze`（0 问题）+ `flutter test`。
- 两套测试目前后端 117、App 196 个用例，改动后不应减少。

## 架构速览

```
backend/                 Node.js 后端（Express + ws + node:sqlite，端口 3000）
  src/server.js          全部 REST API + Token/场景码校验 + CORS + 请求日志 + 定时清理 + 操作日志埋点 + 智能体问答(/api/chat，限流+历史上下文)
  src/asr.js             豆包 Seed-ASR WebSocket 客户端
  src/parse.js           DeepSeek 语义解析（intent: entry/exit/note/ask/ignore + action + 姓名 + 压力，含 guardrail）
  src/calc.js            可用时间 = 容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
  src/db.js              SQLite（WAL），表：entries / firefighters / hotwords / logs / chat_messages（名单与热词全局共享、装机自带，其余带 scene）
  src/logger.js          统一日志
  test/                  node:test 单测
app/                     Flutter 客户端（org com.firewatch.watchdog）
  lib/pages/             board(看板) / home(语音) / chat(辅助问答) / roster(名单热词) / settings / entry_detail / op_log(操作日志) / stats(数据统计，设置二级入口)
  lib/api/api_client.dart 全部接口调用（X-Scene-Code / X-Api-Token / X-Device-Id / X-Op-Id）
  lib/state/app_controller.dart 5 秒轮询 + 每秒阈值检查 + TTS/通知调度 + 问答接口封装
  lib/services/          audio(录音 wav 16kHz) / tts / alarm / screen_on / settings / op_log
  test/                  widget 测试 + 姓名解析测试
deploy/                  部署脚本与配置
```

## 语音意图路由

- 底部语音按钮长按 → 转写 → AI 判断意图，按意图跳转：entry/exit → 语音页确认面板；note → 自动记入日志并跳日志页；ask → 跳「辅助」问答页自动发送；ignore（环境音/无关内容）→ 丢弃并提示重新录入，不跳转。
- 问答页长按语音按钮 → 就地录音，识别为提问直接发送；其余按上述规则路由。
- 进出场登记（进场确认/出场/全员离场）同步写一条火场日志，只记名字+动作（如"张伟进场、李娜进场"），不带压力读数。
- 意图判断：后端 `parse.js` guardrailIntent（宁记不错过——环境音文本含名单/火场痕迹时降级 note）；App 端 `LocalParser._intentFor` 规则版兜底离线场景。

## 密钥与不入库清单

- `backend/.env`（VOLC_APP_ID / VOLC_ACCESS_TOKEN / DEEPSEEK_API_KEY / API_TOKEN）不入库，只维护 `.env.example`。
- `app/android/key.properties` 与 `watchdog-release.keystore` 不入库（正式签名）。
- 涉及真实 key 的临时调试脚本不入库（如 `backend/asr-debug.js`）。
- CI 签名：keystore/key.properties 已配为 GitHub Actions secrets（`WATCHDOG_KEYSTORE_B64` / `WATCHDOG_STORE_PASSWORD` / `WATCHDOG_KEY_ALIAS` / `WATCHDOG_KEY_PASSWORD`），workflow 构建后 keytool 指纹比对防静默 debug 签名。

## 部署（CloudBase 云托管）

- 线上地址：`https://watchdog-prod-d6gch930m378d9a16-1351750301.ap-shanghai.app.tcloudbase.com`（HTTP 网关根路径转发到 `watchdog-api-prod`）。
- 一键部署：先完成 CloudBase CLI 登录并设置 `CLOUDBASE_ENV_ID`，再运行 `deploy/deploy.sh`；脚本会打包后端和端侧 ASR 模型，部署后执行健康检查。
- 云托管服务名 `watchdog-api-prod`，容器端口 3000；生产密钥只配置在 CloudBase 运行时环境变量中，不入库。
- 平台决策：iOS 暂缓，集中开发 Android；改动部署相关代码后建议运行 `deploy/deploy.sh --dry-run` 验证部署包。
