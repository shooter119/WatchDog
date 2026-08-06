# WatchDog 项目约定

## 工作流

- 改完代码后**自动 commit 并 push**，无需用户每次手动要求。
- commit 前检查 `git status` / `git diff`，只提交本次相关的改动。
- 提交信息简洁中文，符合仓库现有风格。
- 临时调试文件（含密钥等）不入库。
- 提交前必须通过验证（见下），构建/测试失败不允许提交。

## 验证命令

- 后端：在 `backend/` 下运行 `npm test`（node:test），改 server/db/parse/calc 必须通过。
- App：在 `app/` 下运行 `flutter analyze`（0 问题）+ `flutter test`。
- 两套测试目前各 34 个用例，改动后不应减少。

## 架构速览

```
backend/                 Node.js 后端（Express + ws + node:sqlite，端口 3000）
  src/server.js          全部 REST API + Token/场景码校验 + CORS + 请求日志 + 定时清理 + 操作日志埋点
  src/asr.js             豆包 Seed-ASR WebSocket 客户端
  src/parse.js           DeepSeek 语义解析（enter/exit + 姓名 + 压力）
  src/calc.js            可用时间 = 容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
  src/db.js              SQLite（WAL），表：entries / firefighters / hotwords / logs，均带 scene
  src/logger.js          统一日志
  test/                  node:test 单测
app/                     Flutter 客户端（org com.firewatch.watchdog）
  lib/pages/             board(看板) / home(语音) / roster(名单热词) / settings / entry_detail / op_log(操作日志)
  lib/api/api_client.dart 全部接口调用（X-Scene-Code / X-Api-Token / X-Device-Id / X-Op-Id）
  lib/state/app_controller.dart 5 秒轮询 + 每秒阈值检查 + TTS/通知调度
  lib/services/          audio(录音 wav 16kHz) / tts / alarm / screen_on / settings / op_log
  test/                  widget 测试 + 姓名解析测试
deploy/                  部署脚本与配置
```

## 密钥与不入库清单

- `backend/.env`（VOLC_APP_ID / VOLC_ACCESS_TOKEN / DEEPSEEK_API_KEY / API_TOKEN）不入库，只维护 `.env.example`。
- `app/android/key.properties` 与 `watchdog-release.keystore` 不入库（正式签名）。
- 涉及真实 key 的临时调试脚本不入库（如 `backend/asr-debug.js`）。
