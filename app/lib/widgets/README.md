# WatchDog Client Custom Widgets (`app/lib/widgets`)

## Overview
客户端通用视图组件库，承载多处复用的复杂组合部件与系统级容器视图。

## Interface
- **画中画系统外壳**: [`pip_shell.dart`](./pip_shell.dart)
  - 核心组件：`PipShell`
  - 功能：支持在 Android 8.0+ 原生画中画（Picture-in-Picture）模式下渲染视频流播放画面，自动隐藏顶部导航、底部菜单及次要操作元素，恢复前台后重置渲染目标。

## Invariants
- `[pip:render-target]`：当系统检测到进入 PiP 模式时，仅渲染全景或监控视频画面本体；回到前台后强制触发渲染表面重建，避免黑屏或静止在最后一帧。

## Side Effects
- 与原生系统画中画通道进行状态同步。

## Verification
- Run: `flutter test`（在 `app/` 目录下）
