# 安全员助手 WatchDog — 项目状态

消防救援现场安全管控 App：安全员语音录入（姓名+气瓶压力）→ 云端 ASR + LLM 解析 → 自动计算可用时间并倒计时，看板实时显示在场人员，多设备云端同步。

## 当前状态（更新于 2026-08-06）

| 模块 | 状态 |
| --- | --- |
| 后端（Express + node:sqlite） | ✅ 单测 34/34 通过（calc/db/API 集成/token 鉴权/操作日志），含请求日志、旧数据自动清理、场景列表 |
| App（Flutter） | ✅ `flutter analyze` 0 问题，测试 50/50 通过（widget 30 + 姓名解析 7 + 本地解析器 13） |
| 操作日志 | ✅ 每次语音操作（录音→转写→解析→确认/出场）客户端+服务端双端埋点，同一 opId 串起全链路；设置页二级页面按操作分组查看（展开步骤+原始数据 JSON）；日志批量上报服务器（`POST /api/logs`），开发者可用 `GET /api/logs` 调试 |
| 按人可调气瓶容量 | ✅ 确认页可改单人气瓶容量（默认取全局配置，1~20L 校验），可用时间实时重算；后端 `POST /api/entries` 支持 `volume_l`（可空） |
| Android Release APK | ✅ 已配置正式签名（watchdog-release.keystore）+ minify/shrink，构建通过（128.6MB，含 sherpa-onnx 原生库） |
| Android 保活/常亮 | ✅ 精确闹钟 USE_EXACT_ALARM + 运行时通知权限申请 + 屏幕常亮（原生 FLAG_KEEP_SCREEN_ON，无第三方依赖） |
| iOS 构建 | ⏸ 暂缓（集中开发 Android） |
| 豆包 ASR / DeepSeek | ✅ key 已配置，端到端联调通过（wav 16kHz 实测识别正确） |
| 端侧 ASR / 解析备份 | ✅ sherpa-onnx 流式 zipformer-transducer 中文模型（zh-14M int8，31MB，hf-mirror 国内直链）本机识别 + 纯 Dart 规则解析器；字级词表支持名单热词（modified_beam_search 上下文加权），断网/无信号时人名识别同样有热词加持；设置页两个联网开关可分别控制「云端优先失败自动切本地」或「强制本地」；模型首次使用时在设置页下载，之后完全离线（下载后自动清理旧版模型） |
| 录音→转写→解析→进出场 全链路 | ✅ 本地端到端验证通过（/tmp/asr-test.wav 实测） |
| 多设备同步 | ✅ 双客户端场景码隔离 + 轮询同步行为已验证（API 级） |
| VPS 部署 | ✅ 已上线 bytevirt（Debian 11）：HTTPS 8443 + pm2 自启 + 证书自动续期，公网全链路验证通过 |

## 架构

```
backend/                 Node.js 后端（Express + ws + node:sqlite，端口 3000）
  src/server.js          全部 REST API + Token/场景码校验 + CORS + 请求日志 + 定时清理旧记录 + 操作日志埋点（同 opId 与 App 对齐）
  src/asr.js             豆包 Seed-ASR WebSocket 客户端（热词注入）
  src/parse.js           DeepSeek 语义解析（enter/exit + 姓名 + 压力）
  src/calc.js            可用时间 = 气瓶容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
  src/db.js              SQLite（WAL），表：entries / firefighters / hotwords / logs（名单与热词全局共享、装机自带，其余带 scene）
  src/logger.js          统一日志（时间戳 + 级别）
  test/                  node:test 单测（calc / db / API 集成 / token 鉴权 / 操作日志），npm test 运行
  .env.example           环境变量模板
app/                     Flutter 客户端（org com.firewatch.watchdog，包名 watchdog）
  lib/main.dart          三 Tab + 中央语音按钮：看板 / 语音录入 / 设置（UI 规范 v0.1）
  lib/theme/             设计 Token（颜色/间距/圆角/字级/阴影）+ 通用组件（卡片/徽章/倒计时/脉冲/连接状态/语音按钮）
  lib/pages/             board(看板+概览横幅) / home(语音) / roster(名单热词) / settings / entry_detail(人员详情) / op_log(操作日志)
  lib/api/api_client.dart 全部接口调用（带 X-Scene-Code / X-Api-Token / X-Device-Id / X-Op-Id）
  lib/state/app_controller.dart 5 秒轮询同步 + 每秒阈值检查 + TTS/通知调度 + 转写/解析云端优先失败自动切本地（两个联网开关控制）
  lib/services/          audio(录音 wav 16kHz) / local_asr(sherpa-onnx 流式 zipformer-zh 本地识别，名单热词加权+模型下载) / local_parser(纯 Dart 规则解析) / tts(播报) / alarm(精确闹钟通知+警报音) / screen_on(常亮) / settings / op_log(日志本地缓冲+批量上报)
  android/app/watchdog-release.keystore + key.properties  正式签名（勿提交 keystore 与密码）
  assets/sounds/alarm.wav 警报音（Android 另存于 res/raw/ 供通知使用）
```

## 操作日志（调试链路）

每次语音操作（长按说话）生成一个 `opId`，贯穿客户端与服务端全部步骤，双方日志落同一张 `logs` 表：

- 客户端步骤：`record_start` → `record_stop`（时长/字节）→ `transcribe_ok/err`（文本+耗时）→ `parse_ok/err`（解析 JSON+耗时）→ `confirm_enter`（姓名/压力/容量/结果）→ `op_end`（结果汇总）；出火场走 `exit_ok / exit_skip`
- 服务端步骤（X-Op-Id 头透传）：`transcribe_received`（音频大小/格式/热词数）→ `asr_done`（ASR 原文+耗时）→ `revise_done`（修正前后文本）→ `transcribe_resp`；`parse_req/parse_done`；`entry_created / entry_conflict / entry_exited`
- App 内：设置 → 操作日志，按操作分组查看，可展开每步明细（含原始 JSON）；同步开关默认开，每次操作结束自动批量上传（断网时积压待传，启动时补传）
- 服务器调试：`curl -H 'X-Scene-Code: <场景码>' -H 'X-Api-Token: <令牌>' 'https://bytevirt.meiyou.xyz:8443/api/logs?limit=100'`（可按 `?op_id=` / `?device=` 过滤；`DELETE /api/logs` 清空）
- 日志保留 30 天自动清理（`LOG_PURGE_DAYS` 可调），本地最多保留 200 步

## 环境变量（backend/.env）

| 变量 | 说明 |
| --- | --- |
| VOLC_APP_KEY / VOLC_ACCESS_TOKEN | 豆包语音（火山引擎）凭证 |
| VOLC_RESOURCE_ID | 默认 volc.bigasr.sauc.duration |
| DEEPSEEK_API_KEY / BASE_URL / MODEL | DeepSeek，默认 deepseek-chat |
| CYLINDER_VOL_L=6.8 / FULL_PRESSURE_MPA=30 / CONSUMPTION_LPM=40 | 计算参数 |
| WARN_MIN=10 / ALARM_MIN=5 | 提醒阈值 |
| PORT=3000 / API_TOKEN | API_TOKEN 设置后所有接口须带 X-Api-Token |
| PURGE_EXITED_DAYS=7 | 自动清理已出场超过 N 天的记录（启动时 + 每 24h） |
| LOG_PURGE_DAYS=30 | 自动清理超过 N 天的操作日志（与出场记录同周期） |
| LOG_LEVEL=info | debug 输出更多细节 |

## API 清单

- `GET /api/health`（免 token）、`GET /api/config`、`GET /api/scenes`（活跃场景列表）
- `POST /api/transcribe`（raw 音频 ≤15MB，Content-Type: audio/wav | pcm | mp3 | ogg，未知按 wav；带 `X-Op-Id` 时服务端记录全链路日志）
- `POST /api/parse`（{text} → enter/exit/unknown + name + pressure_mpa）
- `POST /api/entries`（{name, pressure_mpa, volume_l?}，volume_l 可空即用全局容量，0~20L）、`POST /api/entries/:id/exit`
- `GET/POST/DELETE /api/firefighters`、`/api/hotwords`（名单/热词全局共享、装机自带，注入 ASR 提升识别率）
- `POST /api/logs`（批量上报操作日志，单次 ≤100 条）、`GET /api/logs?limit=&op_id=&device=`（调试查询）、`DELETE /api/logs`（清空本场景日志）

## 豆包 ASR 协议要点（联调结论，改代码前必读）

- 不支持 m4a/aac（服务端报 unsupported format），App 录音必须 wav/pcm 16kHz 16bit 单声道
- nostream 端点 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream`
- 客户端帧：`[4B header][4B size][payload]`，header = 0x11 + (type<<4|flags) + (serial<<4|comp) + 0
- 所有客户端消息**不带 sequence**（服务端自动分配，带了会报 autoAssignedSequence mismatch）；音频分包发送（每包 200ms，gzip 可选）+ 结尾空 LAST 包（flags=NEG_SEQUENCE=2，不压缩）
- 响应帧：`[4B header][seq 4B（flags&1）][size 4B][JSON]`；每帧 JSON 是完整快照，last 帧 flags=3 即最终结果，**不要跨帧拼接**
- 最终响应结构：`{audio_info:{duration}, result:{text}}`，文本在 `result.text`（object 而非数组）；错误帧 type=15，payload=`[code 4B][size 4B][JSON]`

## 运行

```bash
cd backend && cp .env.example .env && node --env-file=.env src/server.js   # 本地：需先配 .env 的 key
cd backend && npm test                                                      # 后端单测 21 例
cd app && flutter run                                                       # 真机，设置页填服务器地址/场景码/令牌
cd app && flutter build apk --release                                       # 正式包（需 android/key.properties）
./deploy/deploy.sh                                                          # 一键部署到 VPS（bytevirt）
```

## 生产部署（bytevirt VPS）

- 地址：`https://bytevirt.meiyou.xyz:8443`（nginx 8443 HTTPS 反代 → 127.0.0.1:3100；避开 proexam 的 3000 与 sing-box 的 443）
- 进程：pm2 管理（`watchdog-api`，开机自启已启用），日志 `/var/log/watchdog/`
- 证书：Let's Encrypt `bytevirt.meiyou.xyz`，certbot.timer 自动续期
- 配置：`/opt/watchdog/.env`（PORT 由 ecosystem 强制 3100）、`/opt/watchdog/ecosystem.config.cjs`
- 更新：`./deploy/deploy.sh`（rsync 代码 + npm install + pm2 restart + nginx reload）
- 注意：`.env` 与 `data/` 不上传，密钥与数据只在服务器

## 产品规则（重要）

- 语音识别到「进入火场」后停在确认页，压力**必填**才能登记（不默认满压）
- 确认页每人的气瓶容量可单独修改（默认取设置里的全局容量 6.8L），改动后可用时间实时重算；容量留空或 1~20L 外时不允许提交
- 长按说话、松手自动转写；识别到「出火场」自动登记出火场
- 未报压力时后端 400 拒绝，App 提示补填
- 倒计时阈值：剩余 warnMin 提醒、alarmMin 报警、超时报警；后台走本地精确闹钟通知（Android 14+ 用 USE_EXACT_ALARM，无需手动授权；设置页可见「精确闹钟被关闭」提示），前台 TTS+警报音
- 屏幕常亮默认开启（原生 FLAG_KEEP_SCREEN_ON），设置页可关
- 报「姓名，20兆帕」时按名单热词提升识别率（云端注入 ASR，本地模式经 sherpa-onnx 热词文件加权，两侧均生效）

## 待办

1. 真机录音链路验证 ✅（Release APK 真机实测：本地模型下载/识别/热词注入全链路通过，操作日志页 + 服务器 `GET /api/logs` 可观察全链路）→ 待补：真人语音下名单人名的热词纠偏效果实测（环境音转写已通）
2. 真机多设备同步 + 通知/报警实测（本地精确闹钟行为需 Android 13/14 真机确认）
3. App 指向生产服务器（设置页填 https://bytevirt.meiyou.xyz:8443 + 场景码 + 令牌）
4. iOS 构建验证（暂缓，集中 Android）
5. Android 正式签名 keystore 密码保护（当前开发密码，上架前需更换）
