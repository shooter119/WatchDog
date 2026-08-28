# WatchDog UI/UX 第二轮复核与修复记录

审查日期：2026-08-27
审查范围：仅复核 UI-UX-003 至 UI-UX-009：控件命中区、连接状态、减少动效、大字体/横屏、Semantics、主题 token、品牌文案。
审查方式：阅读当前工作区源码、UI 规范与品牌资料，核对现有 Widget 测试，并运行 Flutter 静态分析、专项测试和全量测试；对代码证据明确且风险低的项目直接修复。
变更边界：本轮修改了产品源码、测试源码和主题 token；工作区既有未提交改动未回滚，均以最终台账和验证命令为准。

## 结论

UI-UX-003 至 UI-UX-009 的代码级问题均已修复并补充回归验证。真实 Android 设备上的 TalkBack、系统字体设置和不同厂商渲染仍需设备验收，不能用本机 Widget 测试替代。

同时确认以下相关部分不应重复记为缺陷：底部导航 `_NavItem` 的外层约束至少为 48dp、导航槽位高度为 56dp；`VoiceButton` 默认命中容器为 72dp；现有测试覆盖 320/360/390/430dp 底部导航无溢出。这些实现与当前规范一致。

## 问题总览

| 编号 | 严重程度 | 当前结论 | 主要证据 |
|---|---|---|---|
| UI-UX-003 | 一般 | 已修复 | 关键进场/出场/更新压力/发送/加入/编辑操作扩展至规范命中区，并保留命中区回归断言 |
| UI-UX-004 | 一般 | 已修复 | `ConnectionStatus` 区分已连接、同步中、同步失败、已中断，失败态具备语义化重试 |
| UI-UX-005 | 一般 | 已修复 | 重复动效和录音反馈读取系统减少动效偏好；录音外扩光晕移除，危险态保留静态提示 |
| UI-UX-006 | 一般 | 已修复 | 详情倒计时和信息区对窄屏/大字体自动改为可滚动的单列布局并防溢出 |
| UI-UX-007 | 一般 | 已修复 | 折叠控件暴露展开状态与动作提示，统计排序具备 48dp 命中区和语义 |
| UI-UX-008 | 优化 | 已修复 | 分类、排行和设置 Hero 颜色收归 `AppColors` 语义 token |
| UI-UX-009 | 优化 | 已修复 | 设置 Hero 使用中文产品名“火场智控”，设计辅助页同步 |

## 详细问题台账

### UI-UX-003：高频/关键控件的最小命中区仍不足

- 严重程度：一般。
- 影响范围：戴手套或移动中操作时的日志录入、压力更新、人员/力量编辑、警情确认、问答发送和本地模型下载；小命中区增加误触或点不中的概率。
- 复现步骤或证据：按照 `fire-rescue-safety-app-ui-spec-v0.2.md:125-126`，普通控件最低为 `48×48dp`，录音、确认出场、发送等关键控件最低为 `56×56dp`。当前源码仍有以下明确尺寸约束：
  - `app/lib/pages/home_page.dart:1755-1765` 和 `:1844-1855` 的进入确认按钮固定高度 `52`，低于关键控件的 `56`；`:1768-1784`、`:1858-1874` 的继续录音/重试按钮固定高度 `44`。
  - `app/lib/pages/home_page.dart:1825-1833` 的移除人员按钮设置 `minimumSize: Size(0, 36)`；`:2480-2488` 的改名按钮设置最小宽高 `36`；`:2554-2575` 的退出/归档按钮最低高度 `42`；`:2642-2658` 的参战力量编辑/删除按钮最低宽高 `34`。
  - `app/lib/pages/board_page.dart:501-509` 的更新压力按钮固定高度 `44`；`app/lib/main.dart:643-647` 的文字问答发送按钮最低尺寸为 `48×44`，关键发送动作高度不足 `56`。
  - `app/lib/pages/settings_page.dart:885-891` 的身份编辑按钮固定 `40×40`；`:1470-1475` 的本地模型下载按钮固定高度 `44`。
  - `app/lib/pages/incident_selection_overlay.dart:583-591` 的加入按钮最低高度为 `44`。该列表行外层还有 `InkWell`，因此整行选择路径的命中区较大；这里仅记录子按钮本身未达到普通控件名义尺寸，不把它作为唯一的核心证据。
- 根本原因：页面为压缩视觉高度使用 `visualDensity.compact`、固定 `height` 或小 `BoxConstraints`，但没有稳定的外层命中容器来满足规范；视觉图标尺寸和可点击区域没有一致分离。
- 涉及文件：`app/lib/pages/home_page.dart`、`app/lib/pages/board_page.dart`、`app/lib/main.dart`、`app/lib/pages/settings_page.dart`、`app/lib/pages/incident_selection_overlay.dart`；规范 `fire-rescue-safety-app-ui-spec-v0.2.md:125-126`。
- 修改方案：保留现有视觉密度时，将交互外层统一扩展到普通 `48×48dp`、关键 `56×56dp`；删除关键动作的低高度固定约束，并针对每个控件用 `tester.getSize` 或语义节点矩形增加断言。
- 修复实施：关键进场/出场、更新压力、文字发送、加入、编辑和本地模型下载操作扩大到普通 48dp 或关键 56dp；同步更新压力卡高度断言。
- 修复状态：已修复。
- 验证结果：`test/widget_test.dart` 全量通过；关键更新压力控件几何断言为 48dp，导航与横屏用例通过。

### UI-UX-004：连接状态模型仍无法表达同步中与同步失败

- 严重程度：一般。
- 影响范围：看板、日志、设置、统计页面的数据新鲜度判断；弱网时用户可能看到“已连接”却不知道本轮同步失败，也缺少一致的恢复入口。
- 复现步骤或证据：
  1. `app/lib/theme/app_widgets.dart:450-510` 的 `ConnectionStatus` 只有 `bool connected`，只渲染“已连接”或“已中断”；断线交互由裸 `GestureDetector` 的 `onTap` 触发，没有显式的“重试同步”文案、`Tooltip`、按下态或自定义 `Semantics` 描述。
  2. `app/lib/state/app_controller.dart:50-52,390-450` 已有 `syncing` 和 `syncError`，但四个页面只在 `app/lib/pages/{board_page.dart,notes_page.dart,settings_page.dart,stats_page.dart}` 传入 `!controller.connectionLost`，没有把这两个状态传给组件。`syncing = true` 也只在同步完成/失败的 finally 中通知监听者，当前组件没有机会显示同步中。
  3. `app/lib/pages/board_page.dart:68-77` 只在 `connectionLost && syncError != null` 时补充错误文本；日志、设置和统计页没有同等的错误原因或重试提示。当同步失败但尚未超过 30 秒阈值时，`connectionLost` 仍为 false，页面会继续显示“已连接”。
  4. `app/test/widget_test.dart:2441-2470` 的现有测试明确只验证两态，并断言“连接中”和 `cloud_sync_outlined` 不存在；没有同步中、同步失败、最后同步时间或语义树断言。
- 根本原因：连接组件接口以“是否超过 30 秒未成功”为唯一显示模型，和同步任务状态/错误状态脱节；重试动作采用视觉手势实现，没有单独的可访问交互组件。
- 涉及文件：`app/lib/theme/app_widgets.dart:450-510`、`app/lib/state/app_controller.dart:50-52,390-450`、`app/lib/pages/board_page.dart`、`app/lib/pages/notes_page.dart`、`app/lib/pages/settings_page.dart`、`app/lib/pages/stats_page.dart`、`app/test/widget_test.dart:2441-2470`、规范 `fire-rescue-safety-app-ui-spec-v0.2.md:209-211`。
- 修改方案：引入连接状态枚举或等价模型，至少区分已连接、同步中、云端断开、同步失败，并传递最近成功同步时间和可读失败原因；失败态提供带语义名称的“重试同步”按钮，保留本地数据时明确标注时效。
- 修复实施：`ConnectionStatus` 增加 syncing/syncError 输入，区分已连接、同步中、同步失败和已中断；失败态增加 Tooltip、语义标签、重试提示和至少 48dp 命中区，五个页面统一传递控制器状态。
- 修复状态：已修复。
- 验证结果：新增同步中/失败、重试和语义数据断言；Flutter 全量通过。

### UI-UX-005：减少动效偏好未接入，录音态仍有外扩光晕

- 严重程度：一般。
- 影响范围：启用系统“减少动效/移除动画”的用户、低功耗设备，以及录音和报警状态的辨识；持续动画会增加视觉干扰和无必要的渲染开销。
- 复现步骤或证据：
  - `app/lib/theme/app_widgets.dart:411-417` 的 `PulseGlow` 动画控制器无条件 `repeat(reverse: true)`，该组件在 `app/lib/pages/board_page.dart:472-475` 和 `app/lib/pages/entry_detail_page.dart:217` 的危险状态实际使用。
  - `app/lib/theme/app_widgets.dart:549-565` 的 `VoiceButton` 录音波形无条件 `_wave.repeat()`；`:622-649` 的录音态仍使用 `blurRadius: 22`、`spreadRadius: 4` 的橙色 `boxShadow`。这与规范 `fire-rescue-safety-app-ui-spec-v0.2.md:148-156` 要求波形只在按钮内部且不使用持续橙色光晕不一致。
  - `app/lib/pages/home_page.dart:2199-2216` 的录音页 `_PulseMic` 还使用 `AnimatedScale` 和橙色阴影；`app/lib/main.dart:689-692,748-751`、`app/lib/pages/op_log_page.dart:264`、`app/lib/pages/settings_page.dart:2050-2057` 也存在动画过渡。
  - 对 `app/lib` 与 `app/test` 搜索 `disableAnimations`、`accessibleNavigation`、`SemanticsTester` 没有命中；现有 `VoiceButton` 测试只验证四种视觉/交互态，没有传入系统减少动效环境并验证动画停止。当前没有代码分支读取 `MediaQuery` 的减少动效偏好。
- 根本原因：动画组件将“播放动画”作为固定实现，没有把系统可访问性偏好作为渲染输入；录音状态又把外部阴影作为反馈手段。
- 涉及文件：`app/lib/theme/app_widgets.dart:349-447,549-649`、`app/lib/pages/home_page.dart:2187-2227`、`app/lib/pages/board_page.dart:472-475`、`app/lib/pages/entry_detail_page.dart:217`、`app/lib/main.dart:689-692,748-751`、`app/lib/pages/op_log_page.dart:264`、`app/lib/pages/settings_page.dart:2050-2057`、规范 `fire-rescue-safety-app-ui-spec-v0.2.md:148-156,213-217`。
- 修改方案：在动画组件中读取 `MediaQuery` 的减少动效/可访问导航偏好；偏好开启时停止重复控制器并保留静态颜色、文字、图标、倒计时和错误提示。移除录音按钮外扩光晕，仅保留按钮内部波形或静态录音态，并补充减少动效 Widget 测试。
- 修复实施：`PulseRing`、`PulseGlow`、`VoiceButton`、录音页核心圆、底部导航状态过渡、压力面板过渡和操作/设置折叠在系统减少动效时停止重复动画或使用零时长；录音态移除外扩光晕，保留内部静态反馈。
- 修复状态：已修复。
- 验证结果：新增 `VoiceButton` 减少动效 Widget 用例；Flutter 全量通过。设备级系统设置仍待 Android smoke。

### UI-UX-006：详情信息网格未适配大字体和窄屏横向重排

- 严重程度：一般。
- 影响范围：人员详情页的进场时间、预计出场、压力、容量、消耗率和来源等关键数据；320dp 窄屏或系统大字体下可能出现横向溢出、文字裁剪或关键字段不可读。
- 复现步骤或证据：
  1. `app/lib/pages/entry_detail_page.dart:318-373` 将 8 个字段固定放入四个双列 `Row`；每个 `_infoTile` 在 `:376-407` 中由 `Expanded` 包住，但标题又是不可伸缩的 `Row`（图标、5dp 间距、完整 `Text`），没有 `Flexible`、折行保护或窄屏 breakpoint。
  2. 在逻辑宽度 320dp 下，页面左右各 16dp、卡片左右各 14dp 后，信息卡内宽约 `260dp`，每个半列约 `130dp`。系统文字缩放为 2.0 时，`12sp` 的五字标签“实测消耗率”理论文字宽度约 120dp，再加 14dp 图标和 5dp 间距已超过该半列；代码没有 `maxLines`/`overflow`/单列重排来吸收该约束。数值 Text 同样没有溢出保护。
  3. 外层 `SingleChildScrollView` 位于 `app/lib/pages/entry_detail_page.dart:97-117`，只解决纵向滚动，不会改变 `_infoGrid` 的横向几何布局。
  4. 现有测试覆盖普通详情和 `411dp` 统计筛选、首页横屏，但 `app/test` 中没有 `textScaler`/`textScaleFactor` 或详情页 320/360dp 大字体测试；本次全量测试也没有发现普通尺寸下的异常，不能反证该边界风险。
- 根本原因：信息卡用固定双列布局实现，未根据可用宽度和文本缩放选择单列/可折行布局；字体和数据内容是动态的，但布局假定了单一尺寸。
- 涉及文件：`app/lib/pages/entry_detail_page.dart:97-117,318-407`、`app/test/widget_test.dart:676-786`、规范 `fire-rescue-safety-app-ui-spec-v0.2.md:221-228`。
- 修改方案：使用 `LayoutBuilder` 或可用宽度/文本缩放感知 breakpoint；窄屏或大字体时改为单列，标题和值允许折行并确保关键值完整显示；增加 320/360dp、横屏和大字体的无溢出及可见性测试。
- 修复实施：详情页倒计时区在 320dp 或大字体下改为线性进度 + 可缩放倒计时布局，信息网格在窄屏/大字体下改单列，标题和数值增加折行保护。
- 修复状态：已修复。
- 验证结果：新增 320dp、2 倍文字缩放无溢出用例；Flutter 全量 166/166 通过。

### UI-UX-007：自定义折叠和排序控件的状态/动作语义不完整

- 严重程度：一般。
- 影响范围：读屏用户、低视力用户及依赖较大触控区域的用户；操作日志/设置折叠状态和统计排序方式不容易被辅助技术正确理解。
- 复现步骤或证据：
  - `app/lib/pages/op_log_page.dart:224-260` 的折叠头部用 `InkWell(onTap: () => setState(...))` 切换 `_expanded`，`:254-260` 只通过箭头图标改变视觉；没有显式 `Semantics` 的“已展开/已收起”状态、动作提示或当前组的可访问名称。
  - `app/lib/pages/settings_page.dart:2004-2049` 的 `_SettingsAccordion` 同样只用 `_expanded` 和上下箭头表达状态，没有显式状态语义。`InkWell` 可为普通触摸提供点击动作，但不能据此证明展开状态已对读屏用户暴露。
  - `app/lib/pages/stats_page.dart:111-134` 的排序切换是裸 `GestureDetector`，直接包住约 15dp 图标与 12sp 文案，没有 `ConstrainedBox`/`SizedBox` 的 48dp 命中区、Tooltip、明确的“当前排序/点击后切换到……”语义，也没有 InkWell 按下反馈。
  - `app/test` 搜索不到 `SemanticsTester`、`tester.getSemantics` 或等价语义树断言；已有操作日志测试只验证可见文本和触摸展开流程。
- 根本原因：交互逻辑先按视觉组件实现，状态字段没有同步建模到 Semantics；统计排序控件还把可交互区域限制在内容的 intrinsic size。
- 涉及文件：`app/lib/pages/op_log_page.dart:224-278`、`app/lib/pages/settings_page.dart:1974-2063`、`app/lib/pages/stats_page.dart:111-134`、规范 `fire-rescue-safety-app-ui-spec-v0.2.md:221-228`。
- 修改方案：为折叠头部显式提供标题、按钮角色、展开/收起状态和动作提示；为排序控件提供当前排序方式、切换后的目标状态和至少 48dp 的外层命中区；增加 Semantics 树断言并验证禁用/处理中状态。
- 修复实施：操作日志和设置折叠头部加入展开状态/动作提示语义；统计排序加入 Tooltip、当前状态/目标动作语义和 48dp 命中区。
- 修复状态：已修复。
- 验证结果：语义数据与交互回归在 `test/widget_test.dart` 通过；Flutter 全量通过。

### UI-UX-008：页面内颜色字面量绕过主题 token，语义色与规范不一致

- 严重程度：优化。
- 影响范围：日志分类、统计排行和设置 Hero 的色彩一致性、主题集中维护以及后续深色/高对比度扩展；当前主要是可维护性和视觉规范风险，不据此推断已有功能故障。
- 复现步骤或证据：
  - `app/lib/pages/notes_page.dart:337-342` 的 `NoteColor` 在页面内定义 `#2F6FED`、`#F97316`、`#6B7280`。`AppColors` 已在 `app/lib/theme/app_widgets.dart:15-37` 集中定义颜色，但没有这些命名 token；其中水类使用的 `#F97316` 也不是规范的 `AppColors.voice #FF9500`，而规范 `fire-rescue-safety-app-ui-spec-v0.2.md:22,75,90,95` 将橙色限定为语音动作。
  - `app/lib/pages/stats_page.dart:295-301` 又在页面内定义排行金/银/铜颜色 `#F5B301`、`#9AA5B1`、`#B77B4A`，没有主题层 token。
  - `app/lib/pages/settings_page.dart:1668-1751` 的 Hero 还直接散落 `#A9B1BD`、`#C5F4CC`、`#BFC7D2`、`#9BA5B2` 以及多处 `Colors.white`；这些不是统一的主题语义 token。
  - 规范明确要求页面复用 `AppColors`/主题层 token，不在页面内建立视觉体系（`fire-rescue-safety-app-ui-spec-v0.2.md:30-31,73-97,230-242`）。
- 根本原因：分类、排行和 Hero 在页面实现时各自创建颜色映射，主题 token 没有覆盖这些语义；缺少静态检查或测试阻止新颜色字面量进入页面。
- 涉及文件：`app/lib/pages/notes_page.dart:337-349`、`app/lib/pages/stats_page.dart:295-301`、`app/lib/pages/settings_page.dart:1668-1751`、`app/lib/theme/app_widgets.dart:15-37`、规范 `fire-rescue-safety-app-ui-spec-v0.2.md:73-97`。
- 修改方案：先在主题层定义有语义名称的分类/排行/Hero token，再由页面引用；确认水类颜色不与语音橙色冲突，并为主题切换/对比度方案增加颜色来源和可读性检查。若产品决定保留排行金银铜，应将其正式纳入规范和 token，而不是保留页面字面量。
- 修复实施：分类色、排行金银铜色和设置 Hero 中性/状态色全部移入 `AppColors` 语义 token；水类改用注意色 token，不复用语音橙色。
- 修复状态：已修复。
- 验证结果：页面颜色字面量专项搜索已清零；Flutter analyze/test 通过。

### UI-UX-009：设置 Hero 仍展示未纳入中文品牌层级的英文标识

- 严重程度：优化。
- 影响范围：设置页首屏品牌识别、中文现场用户对产品名称的理解以及品牌改名后的可替换性；不影响核心业务操作，但会造成品牌层级不一致。
- 复现步骤或证据：打开设置页，`app/lib/pages/settings_page.dart:1651-1680` 的 Hero 在中文“现场处置”上方固定渲染英文 `FIREWATCH CONTROL`。品牌资料 `opendesign/logo-renaming-plan.md:23-29,58-65` 已确认产品主名为“火场智控”，技术内部代号不进入用户界面，现场界面默认使用中文主名；`README.md:1`、`app/lib/main.dart:227` 和 `AndroidManifest.xml:18` 已使用“火场智控”，因此这里是孤立的英文品牌标识。
- 根本原因：设置 Hero 文案仍沿用早期英文视觉稿，未接入当前中文品牌命名层级；设计辅助页 `opendesign/settings-page-redesign.html:766` 也保留同一文案。
- 涉及文件：`app/lib/pages/settings_page.dart:1651-1680`、`opendesign/settings-page-redesign.html:766`、`opendesign/logo-renaming-plan.md:23-29,58-65`、`README.md:1`、`app/lib/main.dart:227`、`app/android/app/src/main/AndroidManifest.xml:18`。
- 修改方案：用“火场智控”或经确认的中文功能说明“消防救援智能体”替换英文 Hero eyebrow；将品牌主名集中为可替换配置，并同步更新设计辅助页和设置页文案测试。技术包名、服务频道等内部字符串继续留在代码层，不进入 UI。
- 修复实施：设置 Hero 和设计辅助页统一使用“火场智控”，移除用户界面的早期英文品牌标识。
- 修复状态：已修复。
- 验证结果：源码与设计辅助页搜索不再命中 `FIREWATCH CONTROL`；Flutter 全量通过。

## 验证记录

执行目录：`/Users/vavavoom/Documents/WatchDog/app`

- `flutter analyze`：通过，`No issues found!`。
- `flutter test test/widget_test.dart --reporter compact`：通过，`86/86`。
- `flutter test --reporter compact`：通过，`166/166`，`All tests passed!`。
- 静态专项搜索：当前 `app/lib` 已有 `disableAnimations` 分支，`app/test/widget_test.dart` 已有减少动效、语义数据、窄屏/大字体专项断言；`accessibleNavigation`、`SemanticsTester` 未采用，不能据此声称覆盖更多系统语义。
- 本轮未进行真实 Android 设备、横屏截图、高对比度或 TalkBack 实测；本机已覆盖横屏布局、大字体和减少动效逻辑测试，设备级结果仍保持“待外部验收”。

## 交叉复核结论

- 本轮没有把已通过的底部导航等距、语音 72dp 命中区或普通尺寸下的无溢出测试重复升级为缺陷。
- UI-UX-004、005、007 的结论来自当前组件接口和状态/语义代码，而不是视觉偏好；UI-UX-006 的风险来自固定约束和可计算的窄屏/缩放条件；UI-UX-008、009 有规范与品牌资料的直接对照证据。
- 本报告的初始复核由 UI/UX 组完成；随后主 Agent 已按交叉复核结论统一修改源码并补齐专项测试，状态以本报告前文和主台账为准。
