# 安全员助手 WatchDog — 项目状态

消防救援现场安全管控 App：安全员语音录入（姓名+气瓶压力）→ 云端 ASR + LLM 解析 → 自动计算可用时间并倒计时，看板实时显示在场人员，多设备云端同步。

## 当前状态（更新于 2026-08-02）

| 模块 | 状态 |
| --- | --- |
| 后端（Express + node:sqlite） | ✅ 开发完成，冒烟测试通过 |
| App（Flutter） | ✅ 代码完成，`flutter analyze` 0 问题，Android debug APK 构建通过 |
| iOS 构建 | ⚠️ 未验证（Xcode 环境未跑通构建） |
| 豆包 ASR / DeepSeek | ✅ key 已配置，端到端联调通过（wav 16kHz 实测识别正确） |
| VPS 部署 | ⛔ 未开始 |

## 架构

```
backend/                 Node.js 后端（Express + ws + node:sqlite，端口 3000）
  src/server.js          全部 REST API + Token/场景码校验 + CORS
  src/asr.js             豆包 Seed-ASR WebSocket 客户端（热词注入）
  src/parse.js           DeepSeek 语义解析（enter/exit + 姓名 + 压力）
  src/calc.js            可用时间 = 气瓶容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
  src/db.js              SQLite（WAL），表：entries / firefighters / hotwords，均带 scene
  .env.example           环境变量模板
app/                     Flutter 客户端（org com.firewatch.watchdog，包名 watchdog）
  lib/main.dart          四 Tab：看板 / 语音录入 / 名单 / 设置
  lib/pages/             board / home(语音) / roster(名单热词) / settings
  lib/api/api_client.dart 全部接口调用（带 X-Scene-Code / X-Api-Token）
  lib/state/app_controller.dart 5 秒轮询同步 + 每秒阈值检查 + TTS/通知调度
  lib/services/          audio(录音 wav 16kHz) / tts(播报) / alarm(本地通知+警报音)
  assets/sounds/alarm.wav 警报音（Android 另存于 res/raw/ 供通知使用）
```

## 环境变量（backend/.env）

| 变量 | 说明 |
| --- | --- |
| VOLC_APP_KEY / VOLC_ACCESS_TOKEN | 豆包语音（火山引擎）凭证 |
| VOLC_RESOURCE_ID | 默认 volc.bigasr.sauc.duration |
| DEEPSEEK_API_KEY / BASE_URL / MODEL | DeepSeek，默认 deepseek-chat |
| CYLINDER_VOL_L=6.8 / FULL_PRESSURE_MPA=30 / CONSUMPTION_LPM=40 | 计算参数 |
| WARN_MIN=10 / ALARM_MIN=5 | 提醒阈值 |
| PORT=3000 / API_TOKEN | API_TOKEN 设置后所有接口须带 X-Api-Token |

## API 清单

- `GET /api/health`（免 token）、`GET /api/config`
- `POST /api/transcribe`（raw 音频 ≤15MB，Content-Type: audio/wav | pcm | mp3 | ogg，未知按 wav）
- `POST /api/parse`（{text} → enter/exit/unknown + name + pressure_mpa）
- `GET/POST /api/entries`、`POST /api/entries/:id/exit`
- `GET/POST/DELETE /api/firefighters`、`/api/hotwords`（名单/热词按场景隔离，热词注入 ASR 提升识别率）

## 豆包 ASR 协议要点（联调结论，改代码前必读）

- 不支持 m4a/aac（服务端报 unsupported format），App 录音必须 wav/pcm 16kHz 16bit 单声道
- nostream 端点 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream`
- 客户端帧：`[4B header][4B size][payload]`，header = 0x11 + (type<<4|flags) + (serial<<4|comp) + 0
- 所有客户端消息**不带 sequence**（服务端自动分配，带了会报 autoAssignedSequence mismatch）；音频分包发送（每包 200ms，gzip 可选）+ 结尾空 LAST 包（flags=NEG_SEQUENCE=2，不压缩）
- 响应帧：`[4B header][seq 4B（flags&1）][size 4B][JSON]`；每帧 JSON 是完整快照，last 帧 flags=3 即最终结果，**不要跨帧拼接**
- 最终响应结构：`{audio_info:{duration}, result:{text}}`，文本在 `result.text`（object 而非数组）；错误帧 type=15，payload=`[code 4B][size 4B][JSON]`

## 运行

```bash
cd backend && cp .env.example .env && node src/server.js   # 需先配 .env 的 key
cd app && flutter run                                      # 真机，设置页填服务器地址/场景码/令牌
```

## 产品规则（重要）

- 语音识别到「进入火场」后停在确认页，压力**必填**才能登记（不默认满压）
- 长按说话、松手自动转写；识别到「出火场」自动登记出火场
- 未报压力时后端 400 拒绝，App 提示补填
- 倒计时阈值：剩余 warnMin 提醒、alarmMin 报警、超时报警；后台走本地通知，前台 TTS+警报音
- 报「姓名，20兆帕」时按名单热词提升识别率

## 待办

1. 真机录音链路验证（App 已改 wav，需真机跑通 录音→转写→解析）
2. iOS 构建验证（xcodebuild / 模拟器）
3. VPS 部署（node 运行 + 反代 HTTPS + 设置 API_TOKEN）
4. 真机多设备同步测试（场景码 + 轮询）
5. git init + 提交
