# WatchDog 项目约定

## 工作流

- 改完代码后**自动 commit 并 push**，无需用户每次手动要求。
- commit 前检查 `git status` / `git diff`，只提交本次相关的改动。
- 提交信息简洁中文，符合仓库现有风格。
- 临时调试文件（含密钥等）不入库。
- 提交前必须通过验证（见下），构建/测试失败不允许提交。
- **后端代码（backend/src/、deploy/）有修改时，验证通过后直接运行 `deploy/deploy.sh` 部署到线上**，无需用户提醒。
- **版本号由 AI 智能决定**：每次准备发新版时，依据改动规模判断升级幅度（小优化/修复 → 补丁 +0.0.1；新功能 → 次版本 +0.1.0；重大重构/首个稳定版 → 主版本 +1.0.0），`+` 号后构建号必须递增。同步更新 `app/pubspec.yaml` 的 `version:` 并打 tag（`v<版本号>`），随发版一起 commit + push。

## 验证命令

- 后端：在 `backend/` 下运行 `npm test`（node:test），改 server/db/parse/calc 必须通过。
- App：在 `app/` 下运行 `flutter analyze`（0 问题）+ `flutter test`。
- 两套测试目前后端 71、App 70 个用例，改动后不应减少。

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

## 部署（bytevirt VPS）

- 线上地址：`https://bytevirt.meiyou.xyz:8443`（nginx 反代到本地 3100 端口，`/api/` 前缀）。
- 一键部署：`deploy/deploy.sh`（rsync 同步 backend/src + 配置，pm2 重启，nginx 校验，健康检查）。
- pm2 应用名 `watchdog-api`，环境变量读 `/opt/watchdog/.env`（服务器上手动维护，不入库）。
- 后端本地端口 3100（生产），本地开发 3000；改端口/依赖需同步 `deploy/ecosystem.config.cjs` 与 nginx 配置。
- 平台决策：iOS 暂缓，集中开发 Android；改动部署相关代码后建议跑一遍 deploy.sh 验证。
