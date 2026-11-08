# WatchDog Client Design System & Theme (`app/lib/theme`)

## Overview
WatchDog 统一 UI 设计系统与视觉规范实现层。严格遵循本地 `fire-rescue-safety-app-ui-spec-v2.0.md` 规范标准，统一封装全站圆角、高对比度消防色系、昼白/暖砂/夜间战术三套配色方案，以及规范级业务卡片与按钮基础组件。

## Interface
- **调色板与配色体系**: [`app_palette.dart`](./app_palette.dart)
  - 导出类：`AppPalette`
  - 三大主题配色：`AppThemeMode.dayLight`（昼白）、`AppThemeMode.warmSand`（暖砂）、`AppThemeMode.tacticalDark`（夜间战术）
  - 语义色：`primaryRed`、`warningOrange`、`tacticalGreen`、`dangerDark`
- **基础主题构建器**: [`app_theme.dart`](./app_theme.dart)
  - 导出方法：`AppTheme.buildTheme(AppPalette palette)`
- **标准组件库**: [`app_widgets.dart`](./app_widgets.dart)
  - 核心导出组件：
    - `AppCard`：全站统一业务卡片容器（严格默认统一圆角 `AppRadius.lg = 16`，内置防重影单层描边与柔和阴影，严禁手写嵌套 Container 阴影）
    - `AppBanner` / `AppNotice`：统一顶部状态通告横幅
    - `SectionTitle`：区块标准标题带指示色条
    - `StatusBadge`：自适应最小高度紧凑状态徽章（严禁固定矮高度压扁文字）
    - `CountdownText`：自适应空呼倒计时数字排版
- **辅助小部件**: [`assistant_avatar.dart`](./assistant_avatar.dart), [`fire_control_logo.dart`](./fire_control_logo.dart), [`nav_icons.dart`](./nav_icons.dart)

## Invariants
- `[ui-spec:no-nested-shadow]`：严禁手写带重叠阴影与双层边框的 Container；所有列表项与展示单元必须复用 `AppCard`。
- `[ui-spec:badge-height]`：`StatusBadge` 与 `CountdownText` 严禁写死截断字体的固定矮高度，确保大字体无障碍适配。
- `[ui-spec:contrast]`：夜间战术主题下前景与背景对比度必须满足暗光高能见度需求（WCAG AA/AAA）。

## Side Effects
- 无直接外部 I/O 副作用；控制 Flutter 渲染管道的 ThemeData 及全局组件样式。

## Verification
- Run: `flutter test test/theme_test.dart`（在 `app/` 目录下）
