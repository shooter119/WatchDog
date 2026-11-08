# 四岗极简战术协同闭环 (Four-Role Tactical Collaboration Loop)

*   **Author:** shooter119
*   **Status:** Approved & Remediation-Completed
*   **Date:** 2026-11-08

--------------------------------------------------------------------------------

## Overview

在灭火救援现场，信息流面临严重的“孤岛效应与非结构化阻断”：
- **安全员**：专注于入口登记与倒计时，目前通过极简语音报送姓名和压力，数据沉淀于底层但缺乏向上快速提炼；
- **指挥员**：身处前沿面临认知过载，缺少 3 秒内一瞥即知的安全与战术底线全景；
- **通讯员**：疲于应对后方指挥中心与外部政务通讯软件催报，手动拼凑易夹杂请示套话或遗漏数据；
- **驾驶员/战斗员**：处于高度紧张的现场作业中，绝对没有精力和时间在手机上做额外的信息填报。

**四岗信息漏斗闭环（Information Funnel Topology）：**
本方案构建的“四岗闭环”并非要求四个岗位各自在手机上操作一套独立复杂的新系统，而是形成一个**以事实为核心的现场信息漏斗**：
1. **安全员（上游数据基石，0新增输入）**：维持原有用手机语音记录姓名和压力的极简方式，源源不断向系统提供在场指战员与空呼消耗基准；
2. **战术聚合中枢（本地自治）**：自动从安全员数据、警情台账与战术随手记中萃取态势；
3. **指挥员与通讯员（下游高频受惠者）**：指挥员通过重构升级的单行态势卡 3 秒掌控安全底线；通讯员通过一键速报直接生成无请示公文纯文本复制至外部政务软件；
4. **驾驶员与一线战斗员（被动消费源，0输入负荷）**：在出动与作战途中被动享受路况导航与重点单位水源图纸，不向系统录入任何数据，注意力 100% 聚焦于自身实战。

## The Problem

1. **通讯员跨软件汇报痛点剧烈**：现场向上级指挥中心或政务群（微信/政务钉）报送战况时，依赖外部专有通讯软件。通讯员在现场既要接听电台、操控无人机或摄像，又要手工把零散信息拼凑为文字通报，耗时费力，且容易出现请示套话、口语化表达或排版乱码。
2. **指挥员缺乏极简底线感知**：指挥员无法在 3 秒内迅速了解“内攻最短空呼还有多久”、“当前在场几人”、“关键战术进展”，现有的现场监控缺乏对木桶最短板的收敛呈现。
3. **一线录入不能做加法**：火场一线极端危险、双手沾水带手套，任何增加驾驶员手动打卡或复杂表单的设计都会直接导致一线抵触与弃用。

## Goals

*   **Goal 1（通讯员战情速报生成器）**：在客户端提供独立的火场速报助手，100% 从本地已有的 `entries`、`currentIncident`、`forces`、`notes` 自动提炼装配出符合消防公文规范、去富文本杂质、纯客观陈述（绝无请示口吻）的标准化纯文本，提供单手一键复制到剪贴板功能。
*   **Goal 2（指挥员3秒态势卡重构升级）**：重构并升级客户端主页既有的现场监控组件为高对比度 `CommanderGlanceCard`，严格维持单行紧凑高度，聚合在场总人数、木桶最短余压人员与时间胶囊、最新战术推进摘要，支持 3 秒内完成底线研判并直跳看板。
*   **Goal 3（零新增录入与离线可用）**：全功能不增加一线指战员任何新增必填项，不依赖物联网外部硬件，在完全断网环境下秒级离线渲染与生成。

## Non-Goals

*   **Non-Goal 1**：不做任何要求驾驶员、战斗员现场手动打卡、填报水压或调整状态机的功能。
*   **Non-Goal 2**：不依赖或假设具备远传无线空呼表、智能消火栓水压表等物联网硬件设备。
*   **Non-Goal 3**：不做任何与微信、钉钉等第三方通讯工具的底层私有 API 逆向接入，严格维持标准化纯文本剪贴板方案。

## Open Questions & Resolutions

*   **Question 1**：通讯员战况速报生成的触发入口放在何处？
    - **Resolution**: 采用双入口设计：主入口挂载在首页「现场工具」网格第 6 个空白槽位（形成完美的 2x3 对称布局）；快捷入口挂载在 `notes_page.dart` 顶层标题栏中 `_buildConnectionStatus()` 左侧。
*   **Question 2**：指挥员「3秒态势卡」在未选择警情或现场无内攻人员时的空态交互？
    - **Resolution**: 严格遵守 UI Spec v2.0，在未选警情或无在场人员时，呈现单行极简浅色胶囊提示“暂无在场内攻人员”，点击跳转至看板或提示选择警情，绝不占据额外竖向空间。

## Critical User Journeys (CUJs)

### CUJ 1: 通讯员一键生成并复制火场速报至外部政务软件
*   **Given**: 通讯员到达火场，安全员已通过语音录入 4 人进场（最低空呼余量 14 分钟），火场日志已有 1 条出水枪推进记录，警情台账显示出动 2 站 3 车 14 人。
*   **When**: 通讯员打开 WatchDog 客户端，点击现场工具「战况速报」，并点击【一键复制全文】。
*   **Then**: 剪贴板中即时存入排版干净、无 Markdown 符号、纯客观事实陈述的公文级战况文本；通讯员切到外部政务通讯软件，长按直接粘贴并发出，全程耗时不超过 5 秒。

### CUJ 2: 前方指挥员 3 秒快速研判安全底线
*   **Given**: 指挥员在前沿指挥位置，现场环境嘈杂强光。
*   **When**: 指挥员点亮手机屏幕（屏幕常亮），扫视 WatchDog 主页现场监控行。
*   **Then**: 3 秒内从态势卡第一眼确认：在场 4 人，最短可用时间 14 分钟（张伟，黄色预警），最新战况为“东侧出水 2 支水枪内攻”，无需逐个翻查人员列表即可完成下阶段战术下达。

--------------------------------------------------------------------------------

## Technical Plan (Architecture)

### 1. 架构定位与数据流转 (System Architecture)

系统核心由原本分散的单点数据，升级为由「纯客户端战术聚合器」统一提炼的两路呈现管道：
- **不新增任何后端 API 与数据表**：所有计算在移动客户端本地内存和 SQLite 中自治完成；
- **单向数据流转闭环**：

```text
+-------------------------------------------------------------------------------+
|                      现有数据源 (Existing Ingestion)                          |
|  - 警情台账 (currentIncident): 队伍、到场时间、灾情等级、事发地址、气象       |
|  - 参战力量 (IncidentForce): 站点、车辆数、指战员数 (来自 forces)             |
|  - 安全员空呼 (Entry): 在场名单、初始/当前压力、预计耗尽时间、isActive        |
|  - 战术分类日志 (Note): 部署 / 搜救 / 出水 / 撤离 / 异常随手记                 |
+-------------------------------------------------------------------------------+
                                      |
                                      v
+-------------------------------------------------------------------------------+
|               战术事实聚合引擎 (TacticalBriefEngine / Pure Client)            |
|  - 动态短板木桶算法: 严格过滤 e.isActive，按 (e.exitAt - now) ~/ 60000 算余量 |
|  - 战术语义折叠: 逆序抓取最新战术日志，剔除纯进退场流水，提炼最新推进摘要      |
|  - 公文规范槽位填充: 缺省项填补“截至目前未发现被困人员，暂无人员伤亡”         |
|  - 数据安全过滤 (Sanitization): 自动遵循脱敏规范，屏蔽敏感内部标识            |
+-------------------------------------------------------------------------------+
                 |                                             |
                 v                                             v
+----------------------------------+        +-----------------------------------+
|      指挥员端: 3秒态势卡         |        |    通讯员端: 纯文本速报生成器     |
|   (CommanderGlanceCard)          |        |    (TacticalBriefSheet)           |
| - 单行自适应紧凑卡片 (UI Spec v2)|        | - 格式化纯文本实时预览 (无MD杂质) |
| - 空呼底线 (在场数/最短余压胶囊) |        | - 模块勾选 (力量/人员/战况/伤亡)  |
| - 战术动态 (最新出水/搜救进度)   |        | - 【一键复制全文】物理级大按钮    |
+----------------------------------+        +-----------------------------------+
                                                               |
                                                               v
                                            +-----------------------------------+
                                            | 外部政务通讯软件 (微信/政务钉群)  |
                                            | - 原生剪贴板秒级粘贴、即刻发送    |
                                            +-----------------------------------+
```

### 2. 核心组件与职责划分 (Components)

1. **`TacticalBriefEngine`（位于 `app/lib/services/tactical_brief_engine.dart`）**
   - 输入契约：`Incident? incident`, `List<IncidentForce> forces`, `List<Entry> entries`, `List<Note> notes`；
   - 算法实现：
     - `getAirSafetySummary(List<Entry> entries, {int? nowMillis})`：
       - 过滤活动人员：`final active = entries.where((e) => e.isActive).toList();`；
       - 若 `active.isEmpty`，返回空安全摘要；
       - 动态计算最短剩余分钟：`final remainingMin = ((e.exitAt - now) / 60000).ceil();`；
       - 返回木桶最低余压人员姓名及状态等级（红 `<10m`，黄 `<15m`，绿 `正常`）；
     - `getLatestTacticalProgress(List<Note> notes)`：过滤纯动作流水，提取包含出水、搜救、破拆、排烟等实质性进展的最新记录；
     - `formatObjectiveBrief(...)`：生成标准无请示的公文级纯文本字符串，融合 `IncidentForce` 力量清单；
     - `sanitizeBriefText(String text)`：按 `AGENTS.md` 规则脱敏。
2. **`CommanderGlanceCard`（位于 `app/lib/widgets/commander_glance_card.dart`）**
   - 遵循 `fire-rescue-safety-app-ui-spec-v2.0.md` 规范；
   - 重构替换原有 `home_page.dart` 中的 `_buildActiveCombatLiveOverview`；
   - 严格维持单行紧凑视觉设计，基于 `AppCard`（圆角 16、单层防重影），支持点击直接跳转至现场看板。
3. **`TacticalBriefSheet`（位于 `app/lib/pages/tactical_brief_sheet.dart`）**
   - 挂载点 1：`home_page.dart` 现场工具网格第 6 个空白槽位（替代原本占位的 `SizedBox.shrink()`）；
   - 挂载点 2：`notes_page.dart` 顶层标题栏中 `_buildConnectionStatus()` 左侧的图标按钮；
   - 提供独立全屏模态窗口，顶部呈现【现场态势速报】，中部展示纯文本卡片，底部常驻大尺寸【复制全文】按钮。

### 3. 速报文本格式标准 (Text Specification)

生成文本严格杜绝 Markdown 表格、链接或代码块标记，保证粘贴到微信、钉钉等移动端输入框时 100% 格式对齐：
```text
【火场态势速报】示例路站灭火救援作战动态（11:35）
对象：示例路与示例街交叉口商铺火灾

一、力量到场与阵地部署
出动2辆消防车、10名指战员，已到场展开。现场已出2支水枪实施扑救与堵截。

二、内攻作业与空呼管控
现场共有内攻人员4人（涉及：张伟、李娜等）。全部佩戴空气呼吸器，当前最低可用时间14分钟（安全员持续监测）。

三、搜救排查与人员伤亡
内攻人员正在深入内部逐层搜救，截至目前未发现被困人员，暂无人员伤亡。
```

--------------------------------------------------------------------------------

## Alternatives Considered

### Alternative A: 引入后端新表与网络接口实时合成战报
*   **Pros**: 可以在 Web 管理后台或数据库归档中保留历史生成的每一份战报草稿。
*   **Cons**: 增加了网络依赖，在火场地下室或断网环境下无法生成速报；同时增加了数据库架构迁移与 API 复杂度。
*   **Reason for Rejection**: 违背“现场断网自治可用”底线。客户端本地拥有所有最新事件快照，纯端侧组装能实现 0 毫秒网络延迟和 100% 离线可用。

### Alternative B: 通过系统标准 Share Intent 调用微信 SDK
*   **Pros**: 可直接唤起系统分享面板选择微信好友。
*   **Cons**: 在许多定制政务安卓机或后台保活受限设备上，跨进程拉起分享面板极易导致当前前台 App 被系统杀后台；且消防通讯员往往需要先预览、再切到特定常驻群发送。
*   **Reason for Rejection**: 增加崩溃与丢后台风险。直接拷贝到系统剪贴板（`Clipboard.setData`）是最稳健、最符合通讯员多开软件操作习惯的解法。

--------------------------------------------------------------------------------

## Non-Functional Requirements

### 1. 安全与脱敏合规 (Security & Privacy)
- **剪贴板输出强制脱敏**：速报文本生成时，自动运行脱敏过滤，屏蔽真实涉密人名与内部通信验证码，严格遵循 `AGENTS.md` 脱敏红线；
- **纯本地无痕操作**：战报文本合成与复制完全发生在移动端内存与原生剪贴板，严禁向外部日志或第三方统计平台上报文本内容。

### 2. 性能与响应延迟 (Performance & Latency)
- **零阻塞即时生成**：短板木桶算法与槽位拼接时间复杂度为 $O(N)$（$N \le 50$ 条人员/日志），单次文本组装耗时 $< 5\text{ms}$；
- **渲染流畅度保障**：`CommanderGlanceCard` 仅在人员进出、压力复核或新日志提交时局部触发刷新，确保 60fps 丝滑流畅。

### 3. 可靠性与版本兼容 (Rollout & Compatibility)
- **纯客户端无损发布**：无需触碰后端 PostgreSQL 数据库，保持 API 100% 向后兼容；
- **双轨签名隔离**：正式版（`com.firewatch.watchdog`）与本地测试版（`.debug`）物理隔离，支持真机无缝升级与调试；
- **严格遵循 UI Spec v2.0**：全站统一使用 `AppCard` 与 `AppPalette`，严禁多层阴影堆叠。

--------------------------------------------------------------------------------

### Additional Resources

*   本地 UI 设计规范：`fire-rescue-safety-app-ui-spec-v2.0.md`
*   全局架构契约：`app/lib/README.md`
*   头脑风暴概念简报：`concepts_brief.md`

### Future Improvements

*   **战术语音槽位自动丰富**：未来在安全员或通讯员日常对讲随手记中，通过 `parse.js` 现有意图分流自动提取出水枪数与攻防阵地，进一步丰富公文速报的细节丰满度。

--------------------------------------------------------------------------------

## Detailed Implementation Plan

### Target Files to Create/Modify

#### 1. `app/lib/services/tactical_brief_engine.dart` (Create)
*   **Type / Scope**: 纯 Dart 领域服务模块。
*   **Proposed Changes**:
    - 实现 `TacticalBriefEngine` 单例与核心方法；
    - `extractAirSafetySummary(List<Entry> entries, {int? nowMillis})`：严格过滤 `e.isActive`，按时间差分计算剩余可用分钟，返回木桶最短板；
    - `extractTacticalProgress(List<Note> notes)`：逆序检索实质性作战战术动作；
    - `formatObjectiveBrief(...)`：按槽位规则拼接标准化无请示纯文本，结合 `IncidentForce`；
    - `sanitizeBriefText(String text)`：按脱敏规范过滤敏感信息。

#### 2. `app/lib/widgets/commander_glance_card.dart` (Create)
*   **Type / Scope**: Flutter StatelessWidget 部件。
*   **Proposed Changes**:
    - 重构并替代原 `home_page.dart` 中的 `_buildActiveCombatLiveOverview`；
    - 呈现指挥员单行紧凑态势卡，严格复用 `AppCard`（`AppRadius.lg = 16`）；
    - 集成 `StatusBadge` 与 `CountdownText`，保持自适应高度；
    - 绑定 `AppController`，在状态变更时局部刷新。

#### 3. `app/lib/pages/tactical_brief_sheet.dart` (Create)
*   **Type / Scope**: Flutter 全屏模态底部抽屉。
*   **Proposed Changes**:
    - 展示生成的标准化战况纯文本预览卡片；
    - 底部提供大尺寸【一键复制全文】按钮，调用 `Clipboard.setData(ClipboardData(text: ...))`；
    - 复制成功后弹出轻量 Toast 提示“已复制标准化战报，可直接切至政务通讯群粘贴”。

#### 4. `app/lib/pages/home_page.dart` (Modify)
*   **Type / Scope**: 首页视图。
*   **Proposed Changes**:
    - 将原有行内 `_buildActiveCombatLiveOverview` 替换为引入的 `CommanderGlanceCard`；
    - 在「现场工具」网格第 6 个空白占位槽（原本的 `SizedBox.shrink()`）填入「战况速报」入口，点击弹出 `TacticalBriefSheet`。

#### 5. `app/lib/pages/notes_page.dart` (Modify)
*   **Type / Scope**: 火场日志视图。
*   **Proposed Changes**:
    - 在顶层标题栏中 `_buildConnectionStatus()` 左侧新增「战况速报」图标按钮，方便通讯员在记录日志时一键生成速报。

#### 6. `app/test/tactical_brief_engine_test.dart` (Create)
*   **Type / Scope**: 纯 Dart 单元测试驱动。
*   **Proposed Changes**:
    - 覆盖空数据边界、`isActive` 过滤与动态时间差分计算、战术日志过滤、力量结构体拼接、无请示公文要素组装、脱敏合规性测试用例。

#### 7. `app/test/commander_glance_card_test.dart` (Create)
*   **Type / Scope**: Flutter Widget 测试。
*   **Proposed Changes**:
    - 验证指挥员态势卡在未选警情、正常进场、临界告警等场景下的 UI 渲染与触控行为。

### Verification Plan

*   **静态代码分析**: `cd app && flutter analyze`（严格保持 0 警告 0 报错）；
*   **单元与部件测试**:
    - `cd app && flutter test test/tactical_brief_engine_test.dart`（100% 覆盖业务逻辑分支）；
    - `cd app && flutter test`（全量回归测试，基线 471+ 保持 100% 通过）；
*   **后端回归验证**: `cd backend && npm test`（保持 322/322 通过，证明无后端契约破坏）；
*   **真机交互验收**: 通过 `scrcpy` 投屏真机，验证通讯员一键复制至微信剪贴板排版无乱码、指挥员主页态势卡 3 秒无遮挡浏览。

--------------------------------------------------------------------------------

*Drafted & Remediation Verified with EGM*
