# WatchDog State Management (`app/lib/state`)

## Overview
客户端核心状态中枢，基于 `ChangeNotifier` 实现单例架构驱动的 `AppController`。统一管理当前警情、在场人员列表、气瓶倒计时生命周期、每秒阈值轮询、网络连接状态、TTS 语音提醒触发及离线队列调度。

## Interface
- **状态控制器主类**: [`app_controller.dart`](./app_controller.dart)
  - 核心属性（Getters）：
    - `currentIncident`：当前处置中的警情对象
    - `entries`：当前在场消防员列表（带气瓶实时可用时间与警戒级别）
    - `notes`：火场实时日志列表
    - `connectionStatus`：在线 / 离线 / 重连中 / 单机游客模式
    - `roster`：当前单位预设热词与指战员名单
    - `userProfile`：当前登录人员信息与管理员角色
  - 核心动作方法（Actions）：
    - `startIncident(...)` / `switchIncident(...)` / `archiveCurrentIncident()`
    - `recordEntries(...)` / `updatePressure(...)` / `exitEntry(...)` / `exitAll()`
    - `addIncidentNote(...)`
    - `handleIncomingEvent(SyncEvent event)`：接收 WebSocket 或增量拉取事件并驱动 UI 响应
    - `tickSeconds()`：每秒定时器回调，重算所有在场人员剩余气瓶时间并判断提醒/报警

## Invariants
- `[state:tick-guarantee]`：每秒钟定时触发一次 `tickSeconds()`，计算当前在场人员的消耗状态。
- `[state:threshold-alerts]`：
  - 剩余可用时间首次到达 10 分钟时，自动触发一次 TTS 语音预警；
  - 剩余可用时间首次到达 5 分钟时，触发高分贝持续警报，并将危险状态置顶；
  - 已经告警过的人员不再每秒重复播报，直到状态发生重置或读数复核更新。
- `[state:guest-mode]`：游客模式下禁用远程网络同步，所有数据完全在本地内存与 SQLite 运作，不阻塞核心空呼计时功能。

## Side Effects
- 触发 `notifyListeners()` 引起全局 Widget 树精准局部刷新。
- 联动 `TTSService` 与 `AlarmService` 播放音频。
- 调用 `SyncCoordinator` 与 `OfflineQueue` 执行网络上报与同步。

## Verification
- Run: `flutter test test/app_controller_test.dart`（在 `app/` 目录下）
