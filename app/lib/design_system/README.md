# WatchDog Design System v3.0 (`app/lib/design_system`)

## Overview
WatchDog 唯一 UI 设计系统与标准组件库（Design System v3.0），覆盖 Tokens（昼白/暗曜双主题色板、字阶、圆角、间距、尺寸、图标）、主题构建器与现场高可用标准组件。业务层一律通过 `design_system.dart` 单一出口引入，严禁反向依赖业务域或状态层。

## Interface
- **单一出口**：[`design_system.dart`](./design_system.dart)
- **Tokens**（`tokens/`）：`DsColors`、`DsTypography`、`DsSpacing`、`DsRadius`、`DsSizes`、`DsIcons`、`DsMotion`
- **主题**（`theme/`）：`DsTheme`、`context.ds`、`buildCommandTheme(Brightness)`
- **标准组件**（`components/`）：
  - `SurfaceCard`：`flat`（无边框浅底次级区）/ `outlined`（1px 细描边主卡片）/ `raised`（轻浮起）
  - `CommandButton`：`primary` / `secondary` / `ghost` / `danger` / `dangerOutlined`（克制危险描边）
  - `IncidentHeader`：警情头部态势概览栏（支持 `embedded: true` 无缝融入单张主卡片）
  - `StatusPill` / `ConnectionPill` / `MetricReadout` / `CommandScaffold` / `CommandNavBar` / `CommandSheet` / `ToolGrid` / `TimelineList` / `StatePlaceholder`

## Invariants

### 一、原子与可访问性硬指标
- `[ds:single-entry]`：业务代码仅通过 `design_system.dart` 引入并通过 `context.ds` 读取语义令牌，禁止 `static final` 缓存色彩与字阶。
- `[ds:touch-target]`：常规点击区 ≥ 48dp（`DsSizes.touchTarget`），主操作/紧急操作 ≥ 56dp（`DsSizes.primaryAction`），中置语音键 64dp。
- `[ds:text-scale]`：360dp 窄屏 + 130% 系统字号缩放下零溢出、不截断、不重叠。
- `[ds:dual-channel]`：状态表达必须同时包含图标与文字，禁止纯色表达；数值读数统一启用 `tabularFigures`。
- `[ds:contrast]`：正文及状态字对比度 ≥ 4.5:1，关键读数 ≥ 7.0:1。

### 二、页面组合与数据展示规范（组件拼装与真实数据红线）
1. **`[ds:no-duplicate-info]` 同屏去重与语义色唯一**
   - 同一业务属性（如警情类别、官方状态、队伍数量、与主标题一致的事件摘要）不得在同一屏/同一张展开卡片内重复呈现；
   - 同类标签的语义色必须全局唯一，严禁同一概念在上下相邻区域呈现两种冲突配色。
2. **`[ds:no-nested-borders]` 卡片内次级区去重框，拉开视觉层级**
   - 外层主卡片使用 `SurfaceCard(level: DsSurfaceLevel.outlined)`，其内部次级操作条或数据条目一律使用**无边框**的 `SurfaceCard(level: DsSurfaceLevel.flat)` 或 1px 细 `Divider` 分隔，严禁在卡片内连续堆叠多层灰底描边盒子；
   - 操作栏、跳转入口行、数据条目三类元素必须通过外观清晰区分；同级区块标题必须保持统一字号与字重；展开/收起控件不重复摆放。
3. **`[ds:title-anchor-first]` 主标题视觉锚点优先**
   - 详情页顶部第一视觉锚点必须为当前对象的主标题（如警情名称），附属关联项或辅助入口（如重点单位绑定）不得越级置顶在主标题上方。
4. **`[ds:restrained-destructive]` 低频/破坏性操作视觉克制与同列等高**
   - 满宽实心红按钮（`CommandButtonVariant.danger`）仅用于二次确认抽屉内的最终确认或紧急告警主操作，严禁在编辑/表单抽屉中与主色按钮（`CommandButtonVariant.primary`）上下相邻堆叠或等权并排；
   - 详情页底部或编辑抽屉内的低频破坏性操作（如归档警情、删除日志）使用克制的 `CommandButtonVariant.dangerOutlined`，避免抢占核心主操作视觉重心，且仍须经过二次确认；
   - 同一操作区或上下相邻的满宽按钮必须采用**同一触控高度档位**（如统一 56dp `CommandButtonSize.large`），严禁 48dp 与 56dp 混排造成高度落差。
5. **`[ds:sheet-form-layout]` 编辑型底部抽屉表单规范**
   - 抽屉副标题（常承载时间与编号）统一采用等宽数字字阶（`captionTabular`）；
   - 必填表单的底部主操作按钮必须与输入状态联动，内容为空时自动禁用（`enabled: false`），杜绝点击无反馈的死按钮；
   - 长文本字符计数不裸露在输入框外侧下方，统一置于字段标题行右侧以低噪音等宽弱化字展示（临近上限时切换预警色）。
6. **`[ds:chip-group-grid]` 固定数量短标签组规整排布**
   - 固定 4~8 项的短分类选项（如 6 项火场日志分类）优先采用规整等宽网格（常规 3 列，窄屏或系统字号 > 115% 自动降为 2 列），避免单行硬挤或在窄屏/大字号下出现“5+1”孤儿行，同时保证每项触控高度 ≥ 48dp 且圆角与表单控件体系一致。
7. **`[ds:clean-display-data]` 展示层数据清洗**
   - 时间字段在展示前必须格式化为人类易读格式（如 `YYYY-MM-DD HH:mm:ss` 并启用等宽数字），严禁直接裸露 ISO-8601 原始字符串（如含 `T` / `+08:00`）；
   - 组合拼接字段（如 `role · name`）必须执行空值过滤与同值去重，杜绝出现 `报警人 · 报警人` 类重复文案；
   - 基础资料页短元数据字段在常规宽屏下优先采用响应式 2 列排布减少右侧留白，在窄屏或大字号（> 115%）下自动回退单列保证零溢出。

## Verification
- 静态与隔离门禁：`flutter analyze`（0 警告）+ `flutter test test/design_system/`
- **实景饱满数据验收**：涉及页面布局与信息展示的改动，提交前必须在实体机或模拟器上使用**真实饱满数据**（含长地址、多字段、联系人、参战力量）截屏核对，不得仅凭空态或极简假数据放行。
