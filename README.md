# WatchDog 安全员助手

消防救援现场安全管控应用：安全员**语音录入**（姓名 + 气瓶压力）→ 云端 ASR + LLM 语义解析 → 自动计算气瓶可用时间并倒计时 → 看板实时显示在场人员 → 多设备云端同步。

## 功能

- **语音录入**：按住即录，自动转写并解析「张三 24 兆帕」「李四进场」等口语，无需手动打字
- **气瓶倒计时**：可用时间 = 气瓶容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)，自动倒数并在阈值（10min / 5min）提醒
- **实时看板**：在场人员、剩余时间一目了然，超时脉冲 + TTS 播报 + 精确闹钟通知
- **名单与热词**：维护人员名单，热词注入 ASR 提升姓名识别率
- **多设备同步**：场景码隔离，5 秒轮询，多台手机/平板协同
- **离线友好**：Android 保活、屏幕常亮，适合火场环境

## 架构

```
backend/    Node.js 后端（Express + ws + node:sqlite，端口 3000）
  src/server.js      全部 REST API + Token/场景码校验 + CORS + 请求日志 + 定时清理
  src/asr.js         豆包 Seed-ASR WebSocket 客户端（热词注入）
  src/parse.js       DeepSeek 语义解析（enter/exit + 姓名 + 压力）
  src/calc.js        可用时间计算
  src/db.js          SQLite（WAL），表：entries / firefighters / hotwords
app/        Flutter 客户端（Android 优先）
  lib/pages/         board(看板) / home(语音) / roster(名单) / settings / entry_detail
  lib/state/         5 秒轮询同步 + 阈值检查 + TTS/通知调度
  lib/services/      audio(录音 wav 16kHz) / tts / alarm / screen_on / settings
deploy/     VPS 一键部署脚本（HTTPS + pm2 + 证书自动续期）
```

## 快速开始

### 后端

```bash
cd backend
cp .env.example .env   # 填入豆包 / DeepSeek key
npm install
node --env-file=.env src/server.js   # 或 npm start
npm test               # 单测 21 例
```

### App

```bash
cd app
flutter run            # 真机运行，设置页填服务器地址 / 场景码 / 令牌
flutter build apk --release   # 正式包（需 android/key.properties 签名配置）
```

### 部署到 VPS

```bash
./deploy/deploy.sh     # 一键部署（HTTPS 8443 + pm2 自启 + 证书自动续期）
```

## 环境变量

`backend/.env`（详见 `backend/.env.example`）：

| 变量 | 说明 |
| --- | --- |
| VOLC_APP_KEY / VOLC_ACCESS_TOKEN / VOLC_RESOURCE_ID | 豆包语音（火山引擎）凭证 |
| DEEPSEEK_API_KEY / BASE_URL / MODEL | DeepSeek 语义解析 |
| CYLINDER_VOL_L=6.8 / FULL_PRESSURE_MPA=30 / CONSUMPTION_LPM=40 | 气瓶计算参数 |
| WARN_MIN=10 / ALARM_MIN=5 | 提醒阈值 |
| PORT=3000 / API_TOKEN | 服务端口；API_TOKEN 设置后所有接口须带 `X-Api-Token` |
| PURGE_EXITED_DAYS=7 | 自动清理已出场超 N 天的记录 |
| LOG_LEVEL=info | 日志级别 |

## API 摘要

- `GET /api/health`、`GET /api/config`、`GET /api/scenes`
- `POST /api/transcribe`（raw 音频 ≤15MB，wav/pcm/mp3/ogg）
- `POST /api/parse`（{text} → enter/exit/unknown + name + pressure_mpa）
- `GET/POST /api/entries`、`POST /api/entries/:id/exit`
- `GET/POST/DELETE /api/firefighters`、`/api/hotwords`（名单/热词按场景隔离）

## 技术栈

- 后端：Node.js ≥24、Express、ws、node:sqlite（内置 SQLite，无需外部依赖）
- AI：豆包 Seed-ASR（语音转写）、DeepSeek（语义解析）
- App：Flutter、record / flutter_tts / audioplayers / flutter_local_notifications

## 项目状态

详见 [STATUS.md](STATUS.md)：后端单测 21/21、Flutter analyze 0 问题、widget 测试 13/13、Android Release 签名构建通过、VPS 已上线。
