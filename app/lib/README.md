# WatchDog Flutter Client Library (`app/lib`)

## Overview
WatchDog 移动客户端的核心 Dart 源码架构蓝图。采用 Feature-First 分层架构（`app/` / `core/` / `design_system/` / `features/` / `state/` / `services/`），严格遵循 Design System v3.0，面向一线消防安全员提供毫秒级低延迟语音处置、空呼安全监控与全流程离线应急保障能力。

## Local Interface & Invariants
- **应用入口**: [`main.dart`](./main.dart)（≤ 200 行纯启动入口）
  - 通过 `AppBootstrap.run` 在同一 Zone 完成绑定初始化、数据纪元检查、主题偏好加载与全局异常捕获，唯一挂载 `CommandAppShell`（4 Tab + 中置 64dp 语音指令键）。

## Subdirectories & Boundaries
- `app/`: 启动引导、版本常量（`app_version.dart`）、`CommandAppShell` 根外壳、依赖装配与跨域编排器。
- `core/`: 网络基础传输、SSE 解析、日志脱敏（`AppLogger`/`LogSanitizer`）、同步基础 Store 与通用 UI 能力。
- `design_system/`: Design System v3.0 唯一 UI 规范实现（Tokens、`DsTheme`/`buildCommandTheme` 与标准组件库），通过 `design_system.dart` 单入口导出，零业务反向依赖。
- `features/`: 按业务域拆分的独立功能模块（每个文件 ≤ 500 行，Store 间 0 互调）。
- [`api/`](./api/README.md): REST 客户端兼容门面与会话令牌管理。
- [`models/`](./models/README.md): 强类型数据实体转发出口与 JSON 序列化映射。
- [`services/`](./services/README.md): 实时同步协调器、离线队列、本地 sherpa-onnx 语音引擎、主题控制器（昼白/暗曜/跟随系统）、TTS、警报与前台保活。
- [`state/`](./state/README.md): 按业务域 URI `part` 分片组织的响应式状态控制器 `AppController`（每文件 ≤ 500 行）。

## Global Invariants
- `[client:uninterrupted-timing]`：火场空呼倒计时每秒轮询不可被任何后台省电或低内存策略无故终止，依赖前台常驻服务保活。
- `[client:safe-state-transition]`：离线切换与网络波动不导致当前警情状态丢失或卡死，本地 SQLite 队列优先保障操作落盘。
- `[client:design-system-v3]`：全仓唯一使用 `design_system.dart` 与 `context.ds`，旧版 `theme/`、`pages/`、`widgets/` 已彻底清退并由静态门禁守护。

## Global Side Effects
- 与后端建立 HTTPS API 与 WebSocket 链接。
- 调用硬件能力：录音麦克风、扬声器音频焦点、前台通知、屏幕常亮、原生相机相册。

## Subsystem Verification
- Run: `flutter analyze --no-pub`（要求严格 0 警告 0 报错）
- Run: `flutter test --no-pub`（严格全绿，CI 门禁基线 444+）
