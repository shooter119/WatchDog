# WatchDog Client Services Layer (`app/lib/services`)

## Overview
客户端核心服务层，承载底层系统能力抽象、本地数据持久化、音频与语音识别引擎、实时同步与事件协调器、离线补偿队列以及前台保活服务。

## Interface
- **同步与网络协调**:
  - [`realtime_sync_client.dart`](./realtime_sync_client.dart): 单设备 WebSocket 长连接、心跳探活与断线重连。
  - [`sync_coordinator.dart`](./sync_coordinator.dart): Bootstrap 拉取全量快照、补拉遗漏游标、30 秒周期性校准。
  - [`sync_reducer.dart`](./sync_reducer.dart): 增量事件去重、游标连续性校验与状态快照转换。
  - [`offline_queue.dart`](./offline_queue.dart): 基于 SQLite 的本地离线操作队列（进退场/压力/随手记），网络恢复后按顺序幂等重传。
- **语音与本地 AI**:
  - [`realtime_asr_service.dart`](./realtime_asr_service.dart): 云端流式 Seed-ASR 音频录制与分块传输。
  - [`local_asr_service.dart`](./local_asr_service.dart): 基于 `sherpa-onnx` 的纯本地离线语音识别与降噪模型加载。
  - [`local_parser.dart`](./local_parser.dart): 离线断网环境下的规则语义解析兜底。
- **多媒体与现场告警**:
  - [`audio_service.dart`](./audio_service.dart): 麦克风录音会话管理与格式编码（16kHz 16-bit 单声道 PCM/WAV）。
  - [`tts_service.dart`](./tts_service.dart): 文本语音播报（进退场确认、剩余 10 分钟提醒）。
  - [`alarm_service.dart`](./alarm_service.dart): 气瓶耗尽 5 分钟高分贝危险警报声。
  - [`camera_bridge.dart`](./camera_bridge.dart), [`media_capture_service.dart`](./media_capture_service.dart): 水印相机与相册双轨安全存盘。
- **设备与生命周期**:
  - [`foreground_keep_alive.dart`](./foreground_keep_alive.dart): 前台常驻通知与系统保活。
  - [`screen_on.dart`](./screen_on.dart): 火场状态下强制屏幕常亮。
  - [`update_service.dart`](./update_service.dart): VPS OTA 版本检测与 SHA-256 完整性校验下载。
  - [`diagnostic_log_service.dart`](./diagnostic_log_service.dart): 崩溃与脱敏日志本地滚动归档与上报。
  - [`hazmat_local_store.dart`](./hazmat_local_store.dart): 危化品双层本地 SQLite 存储（内置 65+ 种子词库与云端增量覆盖同步）。

## Invariants
- `[services:offline-safety]`：断网期间所有用户操作先写入 SQLite 离线表，必须在网络连通且获取到服务器 ack 后才标记移除。
- `[services:audio-duration]`：单次录音最长限制 60 秒，最后 10 秒倒计时提示，超时自动强制截断并交由解析流水线处理。
- `[services:alarm-priority]`：气瓶剩余 5 分钟属于致命危险，警报音播放强制请求音频焦点，不得被背景音乐或其他应用抑制。
- `[services:watermark-rollback]`：水印成片与原片成对保存至系统相册，任一份保存失败必须整体回滚，不产生残留脏文件。

## Side Effects
- 操作设备麦克风、扬声器、震动马达、相机与相册。
- 启动 Android 前台常驻服务与锁屏通知。
- 在本地 SQLite 数据库读写离线队列与诊断日志。
- 与 VPS OTA 服务器及外部云端 ASR 发起网络传输。

## Verification
- Run: `flutter test test/services_test.dart`（在 `app/` 目录下）
