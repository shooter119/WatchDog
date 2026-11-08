# WatchDog Flutter Client Library (`app/lib`)

## Overview
WatchDog 移动客户端的核心 Dart 源码架构蓝图。采用经典分层架构（Presentation / State / Services / Models / Network API），遵循 UI Spec v2.0，面向一线消防安全员提供毫秒级低延迟语音处置、空呼安全看板与全流程离线应急保障能力。

## Local Interface & Invariants
- **应用入口**: [`main.dart`](./main.dart)
  - 启动阶段完成 `WidgetsFlutterBinding.ensureInitialized()`、初始化 SQLite 本地存储、注册全局 `AppController` 单例并挂载根路由。

## Subdirectories & Boundaries
- [`api/`](./api/README.md): REST 客户端与网络会话管理。
- [`models/`](./models/README.md): 强类型数据实体与 JSON 序列化映射。
- [`services/`](./services/README.md): 实时同步协调器、离线队列、本地 sherpa-onnx 语音引擎、TTS、警报与前台保活。
- [`state/`](./state/README.md): 全局响应式状态控制器 `AppController`。
- [`theme/`](./theme/README.md): UI Spec v2.0 规范组件、调色板与主题方案。
- [`widgets/`](./widgets/README.md): 通用复杂组合部件与系统画中画外壳。
- [`pages/`](./pages/README.md): 五大主入口页面与二级业务功能视图。

## Global Invariants
- `[client:uninterrupted-timing]`：火场空呼倒计时每秒轮询不可被任何后台省电或低内存策略无故终止，依赖前台常驻服务保活。
- `[client:safe-state-transition]`：离线切换与网络波动不导致当前警情状态丢失或卡死，本地 SQLite 队列优先保障操作落盘。
- `[client:ui-spec-v2]`：严格遵循 `fire-rescue-safety-app-ui-spec-v2.0.md` 规范，所有业务卡片统一复用 `AppCard`，严禁多层阴影边框重叠。

## Global Side Effects
- 与后端建立 HTTPS API 与 WebSocket 链接。
- 调用硬件能力：录音麦克风、扬声器音频焦点、前台通知、屏幕常亮、原生相机相册。

## Subsystem Verification
- Run: `flutter analyze`（要求严格 0 警告 0 报错）
- Run: `flutter test`（CI 门禁基线 444+ 用例，本地严格 471+ 用例全绿）
