# WatchDog Flutter UI/UX 只读审查

审查日期：2026-08-27
审查范围：`app/lib/` Flutter 页面、主题与组件，`app/test/widget_test.dart`，`opendesign/` 视觉资料，`fire-rescue-safety-app-ui-spec-v0.2.md`。
审查方式：代码与规范交叉核对、查看已有视觉参考、阅读 Widget 测试并运行现有 Flutter 验证。
变更边界：本轮未修改任何产品源码、测试源码、配置或资源；仅新增本台账。审查开始前工作区已有未提交改动，未将其归因于本轮。

## 严重程度与状态

- 阻断：核心流程无法继续或首屏/关键操作被阻断。
- 严重：核心安全、数据或高风险操作存在明显错误，或主要流程在常见设备条件下不可用。
- 一般：可访问性、适配、反馈或一致性问题，会影响部分用户或现场操作可靠性。
- 优化：规范偏差或可维护性建议；当前没有充分证据证明已经造成运行时缺陷。
- 本轮所有确认项均为“待修复（只读审查）”；报告不代表已修改源码。

## 问题总览

| 编号 | 严重程度 | 问题 | 结论 |
|---|---|---|---|
| UI-UX-001 | 严重 | 启动默认页与 V0.2 信息架构冲突 | 已确认，待统一产品基线 |
| UI-UX-002 | 严重 | 启动认证浮层在横屏/键盘短高度下不可滚动 | 已确认约束缺陷 |
| UI-UX-003 | 一般 | 多个高频或高风险控件显式小于 48dp | 已确认规范/操作风险 |
| UI-UX-004 | 一般 | 连接状态只有二态，重试控件缺少明确反馈与语义 | 已确认状态表达缺口 |
| UI-UX-005 | 一般 | 录音/危险动效外扩且未响应系统减少动效 | 已确认规范与无障碍缺陷 |
| UI-UX-006 | 一般 | 详情信息网格未适配大字体和窄屏重排 | 已确认布局约束风险 |
| UI-UX-007 | 一般 | 自定义折叠/排序控件未完整暴露动作和状态语义 | 已确认可访问性缺陷 |
| UI-UX-008 | 优化 | 日志分类颜色绕过主题 token，橙色语义与规范不一致 | 已确认规范偏差 |
| UI-UX-009 | 优化 | 设置 Hero 展示内部英文代码名 | 已确认品牌规范偏差 |
| UI-UX-010 | 优化 | 助手头像仍为栅格 PNG，不符合透明 CustomPainter 规范 | 建议，非已确认运行时缺陷 |

## 详细台账

### UI-UX-001：启动默认页与 V0.2 信息架构冲突

- 严重程度：严重
- 影响范围：首次启动、重启后首屏、值班人员查看整体态势的路径。
- 复现步骤或证据：启动 `WatchDog`，当前 `app/lib/main.dart:75` 将 `_tab` 初始化为 `2`，默认进入“警情处置/语音”页；`fire-rescue-safety-app-ui-spec-v0.2.md:37` 明确规定“App 启动默认进入看板”。现有 `app/test/widget_test.dart:2105-2123` 还将语音页作为预期行为进行断言。
- 根本原因：实现、Widget 测试和 V0.2 信息架构没有使用同一份产品基线；当前测试固化了与规范相反的默认页。
- 涉及文件：`app/lib/main.dart:75`；`app/test/widget_test.dart:2105-2123`；`fire-rescue-safety-app-ui-spec-v0.2.md:33-47`。
- 修改方案：先统一产品基线；若继续遵守 V0.2，则初始化为看板索引并将启动测试改为看板，同时核查 README/关于页是否仍描述旧入口。若产品有意改为语音页，应反向更新 V0.2 及相关验收资料。
- 状态：已确认，待产品/主 Agent 统一入口决策；本轮未修改。
- 验证结果：现有 Flutter 测试通过，但其断言的是当前语音页行为，因此不能视为规范验收通过。

### UI-UX-002：启动认证浮层在横屏/键盘短高度下不可滚动

- 严重程度：严重
- 影响范围：首次认证、横屏设备、系统大字体、键盘弹出后的启动流程；认证失败时用户可能无法到达“认证并继续”。
- 复现步骤或证据：在横屏短高度（例如逻辑尺寸约 `800×390`）或认证表单弹出键盘时打开认证浮层。`app/lib/pages/incident_selection_overlay.dart:134-260` 使用不可滚动的 `Column`，包含标题、说明、3 个 `TextField`、错误文本、`Spacer`、52dp 提交按钮和说明文字；同文件 `:281-310` 将浮层固定为 `height = min(maxHeight - 32, 640)`。短高度下内容没有 `SingleChildScrollView` 或基于键盘 inset 的重排，存在 `RenderFlex overflow` 或底部控件不可见的直接约束冲突。
- 根本原因：认证表单按正常竖屏高度设计，外层卡片使用固定高度，内部又用 `Spacer` 占位，没有为横屏和 `viewInsets` 留出可滚动空间。
- 涉及文件：`app/lib/pages/incident_selection_overlay.dart:134-260`、`:281-310`；`app/test/widget_test.dart:1981-2055`、`:2057-2075`。
- 修改方案：认证分支改为键盘感知的 `SingleChildScrollView`/`ConstrainedBox`，移除短高度下不可用的 `Spacer`，按钮保持可到达；为横屏、键盘和大字体增加尺寸化 Widget 测试。
- 状态：已确认约束缺陷，待修复；本轮未修改。
- 验证结果：现有测试覆盖正常认证提交、认证失败和零尺寸约束，但没有横屏认证、键盘认证或大字体认证用例；不能证明该边界已通过。

### UI-UX-003：多个高频或高风险控件显式小于 48dp

- 严重程度：一般
- 影响范围：戴手套、移动设备、误触敏感的任务编辑/结束/删除动作，以及聊天发送和模型下载。
- 复现步骤或证据：UI 规范要求普通控件至少 `48×48dp`、关键触控至少 `56×56dp`（`fire-rescue-safety-app-ui-spec-v0.2.md:124-126`）。当前代码存在明确小尺寸约束：
  - `app/lib/pages/home_page.dart:1779-1787` 移除人员按钮 `minimumSize: Size(0, 36)`；`:2434-2441` 重命名按钮使用紧凑密度和 `36×36` 约束；`:2508-2529` 结束/归档按钮最小高度 `42`；`:2596-2612` 编辑/删除按钮 `34×34`。
  - `app/lib/pages/board_page.dart:492-520` 压力更新按钮高度 `44`；`app/lib/main.dart:635-653` 聊天发送按钮为 `48×44`。
  - `app/lib/pages/settings_page.dart:856-863` 身份编辑按钮为 `40×40`；`:1435-1441` 模型下载按钮高度 `44`；`app/lib/pages/incident_selection_overlay.dart:544-551` 加入按钮高度 `44`。
- 根本原因：为了压缩视觉高度使用 `visualDensity.compact` 和硬编码最小尺寸，但没有把视觉图标与满足规范的外层命中区域分离。
- 涉及文件：上述页面与 `app/lib/main.dart`；规范 `fire-rescue-safety-app-ui-spec-v0.2.md:125-126`。
- 修改方案：保留视觉图标大小，扩展父级可点击区域；普通动作至少 `48×48dp`，确认出场/发送/结束等关键动作至少 `56×56dp`，并补充 Widget 命中区域断言。
- 状态：已确认规范/操作风险，待修复；本轮未修改。
- 验证结果：现有测试验证底栏窄屏不重叠和部分按钮流程，但没有对上述控件的实际命中尺寸做断言。

### UI-UX-004：连接状态只有二态，重试控件缺少明确反馈与语义

- 严重程度：一般
- 影响范围：看板、日志、统计、设置中的数据新鲜度判断，以及断线恢复和读屏用户。
- 复现步骤或证据：`app/lib/theme/app_widgets.dart:450-452` 明确将组件定义为只有绿色/红色两态；`:463-510` 的 API 只有 `bool connected`，显示“已连接/已中断”，断线时用裸 `GestureDetector` 调用重试，没有 `Semantics`、`Tooltip` 或按下态反馈。`app/lib/pages/board_page.dart:60-77`、`app/lib/pages/notes_page.dart:58-61`、`app/lib/pages/settings_page.dart:599-602`、`app/lib/pages/stats_page.dart:94-97` 也只传递连接布尔值。规范要求显示“已连接、同步中、云端断开或同步失败”，并保留时效和“重试同步”（`fire-rescue-safety-app-ui-spec-v0.2.md:207-211`）。
- 根本原因：连接组件的数据模型不足以表达同步中/同步失败/数据时效，重试交互采用无波纹的手势容器，也没有为非视觉用户声明动作名称。
- 涉及文件：`app/lib/theme/app_widgets.dart:450-510`；上述各页面；规范 `fire-rescue-safety-app-ui-spec-v0.2.md:207-211`。
- 修改方案：使用连接状态枚举并传入同步中、失败和最近同步时间；失败态提供明确的“重试同步”按钮；用 `Material`/`InkWell` 或等价反馈，并补充 `Semantics(button: true, label, hint)`。
- 状态：已确认状态表达缺口，待修复；本轮未修改。
- 验证结果：现有测试只断言“已连接/已中断”和点击回调，未覆盖同步中、同步失败、重试反馈或语义树。

### UI-UX-005：录音/危险动效外扩且未响应系统减少动效

- 严重程度：一般
- 影响范围：录音反馈、危险状态、减少动效用户、低功耗设备；也可能让录音反馈与报警视觉混淆。
- 复现步骤或证据：`app/lib/theme/app_widgets.dart:637-649` 在 `VoiceButton` 录音态使用 `boxShadow`，录音时 `blurRadius: 22`、`spreadRadius: 4`，形成持续外扩橙色光晕；同文件 `:349-447` 的 `PulseRing`/`PulseGlow` 使用重复动画控制器，未读取 `MediaQuery.disableAnimations` 或 `accessibleNavigation`。规范要求录音波形只在按钮内部、不使用持续橙色光晕（`fire-rescue-safety-app-ui-spec-v0.2.md:148-156`），并要求减少动效时保留静态报警信息（`:213-217`）。
- 根本原因：录音和报警组件无统一的减少动效分支，录音态把外层阴影当成状态反馈；动画控制器无系统偏好门控。
- 涉及文件：`app/lib/theme/app_widgets.dart:349-447`、`:590-649`；规范 `fire-rescue-safety-app-ui-spec-v0.2.md:148-156`、`:213-217`。
- 修改方案：录音态只保留按钮内部短波形，移除外扩光晕；当系统禁用动效时停止重复动画并保留静态颜色、文字、图标和倒计时；增加 `disableAnimations` Widget 测试。
- 状态：已确认规范与无障碍缺陷，待修复；本轮未修改。
- 验证结果：现有测试覆盖 VoiceButton 状态和尺寸，但没有减少动效、动画次数或外部阴影的验证。

### UI-UX-006：详情信息网格未适配大字体和窄屏重排

- 严重程度：一般
- 影响范围：详情页的压力、容量、消耗率、来源等关键信息；320dp 窄屏和系统大字体用户。
- 复现步骤或证据：`app/lib/pages/entry_detail_page.dart:261-305` 固定把 8 个信息放入四个双列 `Row`；`:307-331` 的 `_infoTile` 在每个半宽单元内再次使用不可伸缩的标签 `Row`（图标、间距、完整 `Text`），没有 `Flexible`、折行、截断或单列 breakpoint。以 320dp 屏幕计算，卡片内每格约 130dp；在 `textScaleFactor/textScaler` 较大时，“实测消耗率”等标签连同图标没有足够空间，可能产生横向溢出或关键信息裁剪。规范要求大系统字体下关键信息不可截断（`fire-rescue-safety-app-ui-spec-v0.2.md:221-228`）。
- 根本原因：信息卡用固定双列几何布局，未根据可用宽度和文字缩放动态切换单列或允许标签重排。
- 涉及文件：`app/lib/pages/entry_detail_page.dart:261-331`；规范 `fire-rescue-safety-app-ui-spec-v0.2.md:221-228`。
- 修改方案：用 `LayoutBuilder`/文本缩放感知 breakpoint，在窄屏或大字体时改为单列；标签允许折行或使用可读的短标签；为 320/360dp 与 `textScaler` 边界增加无溢出及完整文本测试。
- 状态：已确认布局约束风险，待补充运行时复现和修复；本轮未修改。
- 验证结果：现有测试覆盖部分窄屏页面，但未搜索到 `textScaler`/大字体布局测试，当前不能视为大字体验收通过。

### UI-UX-007：自定义折叠/排序控件未完整暴露动作和状态语义

- 严重程度：一般
- 影响范围：操作日志折叠组、设置折叠项、统计排序切换；TalkBack/VoiceOver 用户和依赖较大触控区域的用户。
- 复现步骤或证据：`app/lib/pages/settings_page.dart:1969-2010` 和 `app/lib/pages/op_log_page.dart:224-260` 用 `InkWell` 直接切换 `_expanded`，展开/收起状态只通过箭头图标表达，没有显式 `Semantics` 的 `expanded`/切换状态和动作提示。`app/lib/pages/stats_page.dart:111-134` 用裸 `GestureDetector` 包裹约 15dp 图标和 12sp 文案，未提供语义名称、动作提示或 48dp 命中容器。规范要求每个可触达控件提供语义名称、选中状态和可执行动作（`fire-rescue-safety-app-ui-spec-v0.2.md:221-228`）。
- 根本原因：自定义交互复用了视觉组件，却没有同步实现控件语义状态；统计排序区也没有按普通控件的最小命中尺寸布局。
- 涉及文件：`app/lib/pages/settings_page.dart:1932-2034`；`app/lib/pages/op_log_page.dart:197-278`；`app/lib/pages/stats_page.dart:111-134`。
- 修改方案：将折叠区声明为可切换控件并暴露“已展开/已收起”；排序控件声明当前排序方式和切换动作，外层命中区域至少 48dp；增加 `SemanticsTester` 或等价语义断言。
- 状态：已确认可访问性缺陷，待修复；本轮未修改。
- 验证结果：现有 Widget 测试没有 `SemanticsTester`、`textScaler`、`disableAnimations` 或高对比度专项覆盖；已有功能测试不能证明语义要求满足。

### UI-UX-008：日志分类颜色绕过主题 token，橙色语义与规范不一致

- 严重程度：优化
- 影响范围：日志时间线的颜色一致性、主题维护、颜色语义辨识。
- 复现步骤或证据：`app/lib/pages/notes_page.dart:335-349` 的 `NoteColor` 直接定义 `Color(0xFF2F6FED)`、`Color(0xFFF97316)`、`Color(0xFF6B7280)`，而不是复用 `AppColors`。其中橙色用于 `NoteCategory.water`；规范规定橙色代表语音动作，并要求页面复用 `AppColors`/主题 token、不得在页面内另建视觉体系（`fire-rescue-safety-app-ui-spec-v0.2.md:22-30`、`:73-97`）。
- 根本原因：日志分类在页面内部建立了独立四色映射，尚未纳入全局语义色 token。
- 涉及文件：`app/lib/pages/notes_page.dart:335-349`；`app/lib/theme/app_widgets.dart:11-37`；规范 `fire-rescue-safety-app-ui-spec-v0.2.md:22-30`、`:73-97`。
- 修改方案：将分类色定义为主题层语义 token，并重新确认“出水/注意”与“语音动作”的色彩是否需要不同 token；同步检查深色/高对比度方案（如有）。
- 状态：已确认规范偏差，待修复；本轮未修改。
- 验证结果：没有发现现有测试断言这些颜色的 token 来源或主题切换行为。

### UI-UX-009：设置 Hero 展示内部英文代码名

- 严重程度：优化
- 影响范围：设置页品牌识别、现场人员对产品名称的理解、品牌一致性。
- 复现步骤或证据：打开设置页，`app/lib/pages/settings_page.dart:1632-1638` 显示英文 `FIREWATCH CONTROL`。`opendesign/logo-renaming-plan.md:29` 说明 `WatchDog` 是内部代码，`:58-64` 要求技术代码不进入品牌锁定、设置等主要 UI，现场 UI 默认使用中文主名称；当前 Hero 同时有中文“现场处置”，但仍把英文内部/技术标识作为显著副标题展示。
- 根本原因：设置 Hero 的视觉文案没有跟随品牌命名约定收敛，且样式中还直接散落多组颜色值（同文件 `:1634-1717`）。
- 涉及文件：`app/lib/pages/settings_page.dart:1624-1717`；`opendesign/logo-renaming-plan.md:29`、`:50-65`。
- 修改方案：按品牌资料移除或替换英文代码名，保留明确的中文产品/页面名称；颜色改为主题 token；同步核查 README 与关于页的产品名。
- 状态：已确认品牌规范偏差，待修复；本轮未修改。
- 验证结果：视觉参考图和品牌资料均使用中文主名称；未发现现有测试覆盖设置 Hero 文案。

### UI-UX-010：助手头像实现与透明 CustomPainter 规范不一致（建议项）

- 严重程度：优化
- 影响范围：辅助页头像的视觉一致性、资源适配和后续主题维护。
- 复现步骤或证据：`app/lib/theme/assistant_avatar.dart:21-37` 使用 `Image.asset('assets/avatars/water-element-avatar-selected.png')`；该资源经文件检查为 RGB PNG（无 alpha 通道），外部再叠加白色圆形容器。规范要求欢迎页/消息统一使用 `AssistantAvatar`，但内部应为透明底 `CustomPainter` 重绘（`fire-rescue-safety-app-ui-spec-v0.2.md:193-199`）。现有 `app/test/widget_test.dart:1740` 只验证尺寸，没有验证透明背景或绘制结构。
- 根本原因：当前实现沿用了栅格资源，尚未按视觉规范迁移为可缩放、可主题化的矢量/CustomPainter 组件。
- 涉及文件：`app/lib/theme/assistant_avatar.dart:13-39`；`app/assets/avatars/water-element-avatar-selected.png`；规范 `fire-rescue-safety-app-ui-spec-v0.2.md:193-199`。
- 修改方案：这是后续设计/实现建议：按规范重绘透明底头像，并补充不同尺寸、背景和高对比度截图或 golden 检查。
- 状态：建议，非已确认运行时缺陷；本轮未修改。
- 验证结果：已有视觉参考与规范支持该偏差，但本轮没有发现足以证明当前 PNG 已造成布局、可读性或功能故障的运行时证据。

## 已核验但未记录为缺陷

- `app/lib/main.dart` 的底部导航使用五个 `Expanded` 等距槽位；已有测试覆盖 320/360/390/430dp，未发现重叠或横向溢出证据。
- 中央语音按钮的 64dp 视觉圆面与 72dp 命中区、底栏边界已有测试覆盖；本轮未把尺寸本身记录为缺陷。
- 横屏首页、聊天键盘避让、多行输入、长警情名称浮层换行、零尺寸浮层约束已有测试覆盖；没有把这些已通过场景重复列入问题。
- 未发现本轮证据表明页面存在“只靠颜色表达危险状态”的单一表达；状态徽标已有图标和文字冗余。连接状态的同步/失败缺口另列为 UI-UX-004。

## 验证记录

执行目录：`/Users/vavavoom/Documents/WatchDog/app`

- `flutter analyze`：通过，`No issues found! (ran in 1.2s)`。
- `flutter test`：通过，当前测试套件 `+146`，无失败。项目约定中的历史基线为 70；当前工作区已有测试相关改动，因此本报告只确认“本次运行未减少且全部通过”，不把数量差异归因于本轮。
- 未执行生产构建、部署或后端测试：本轮是 Flutter UI/UX 只读审查，未修改后端、部署配置或产品源码。
- 尚缺的验收覆盖：认证浮层横屏/键盘、大字体 `textScaler`、系统减少动效、语义树/读屏、关键控件命中尺寸、高对比度和真实设备多分辨率。

## 本轮结论

当前 Flutter 静态分析与已有功能测试通过，但不能据此宣布 UI/UX 验收通过。UI-UX-001、UI-UX-002 属于应优先处理的流程/布局问题；UI-UX-003 至 UI-UX-007 影响现场操作可靠性或无障碍；UI-UX-008、UI-UX-009 是明确规范偏差；UI-UX-010 仅为有资料依据的后续建议。所有确认项均保留给主 Agent 统一排期和修改，避免本只读小组越权改动产品源码。
