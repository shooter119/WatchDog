# EGM Uninterrupted Full Flow Review Report: docs/designs/four-role-tactical-loop.md

**Target Document:** `docs/designs/four-role-tactical-loop.md`
**Scopes Audited:** Feature Range (L1-174) & Detailed Plan Range (L175-234)
**Context Evaluated:** `concepts_brief.md`, `app/lib/README.md`, `app/lib/theme/app_widgets.dart` (UI Spec v2.0), `app/lib/models/models.dart`, `app/lib/state/app_controller.dart`, `app/lib/pages/home_page.dart`, `app/lib/pages/notes_page.dart`, `AGENTS.md`.

---

## 审查状态汇总

| Stage & Lens | Status | Key Focus |
| :--- | :--- | :--- |
| **Stage 5**: `egm-zoom-out`, `egm-inventive-catalyst` | **completed** | 闭环定位、架构协同、现有模型资产榨取 |
| **Stage 6**: `egm-comprehension` | **completed** | 动态空呼算法、公文槽位规范、消防实战口径 |
| **Stage 7**: `egm-design`, `egm-structural`, `egm-style` | **completed** | UI Spec v2.0 合规、现有组件重构、挂载树定位 |
| **Stage 8**: `egm-zoom-out` | **completed** | 跨阶段结论调和与闭环逻辑校验 |
| **Stage 9**: `egm-implementation-readiness`, `egm-codebase-details`, `egm-style` | **completed** | 强类型签名锁定、脱敏合规、全套门禁基线 |

---

## 核心审查问题清单 (Prioritized Action Items)

### 🔴 Blocker 1: 修正模型类名（`Entry` 与 `Note`）
- **问题**：设计文档中使用了不存在的 `FiregroundEntry` 和 `IncidentNote`，代码库真实类名为 `Entry` 和 `Note`。
- **整改**：全面替换为真实类名，并引入真实存在的 `IncidentForce` 结构体。

### 🔴 Blocker 2: 消除与 UI Spec v2.0 及现有现场监控卡片的组件冲突
- **问题**：首页已有 `_buildActiveCombatLiveOverview`，UI Spec v2.0 禁止重复多层冗余卡片。
- **整改**：将方案调整为“重构升级现有 `_buildActiveCombatLiveOverview` 为独立的 `CommanderGlanceCard` 部件”，严格维持紧凑单行高度，仅呈现“在场人数 + 最短余压胶囊 + 关键行动摘要”，点击直跳看板。

### 🔴 Blocker 3: 补齐动态空呼衰减与已退场人员过滤算法
- **问题**：未排除 `e.exitedAt != null`，未指定以实时时间差分计算剩余分钟，未处理 `entries.isEmpty` 边界。
- **整改**：算法明确声明只遍历 `entries.where((e) => e.isActive)`，动态基于 `(e.exitAt - now) ~/ 60000` 计算短板，并在空集合时安全回退。

### 🟡 Major 4: 明确“四岗闭环”的信息漏斗拓扑与协同边界
- **问题**：文档偏向两岗交付，缺少对安全员生产源和驾驶员被动消费源的闭环阐释。
- **整改**：补充“火场信息漏斗拓扑”说明：安全员语音录入是上游基石，指挥员一瞥与通讯员速报是下游提炼，驾驶员被动消费水源与路线。

### 🟡 Major 5: 榨取 `IncidentForce` 结构体丰富战报力量要素
- **问题**：忽略了已有 `forces` 列表（到场队伍、车数、人数），战报力量槽位缺乏真实数据绑定。
- **整改**：`formatObjectiveBrief` 引入 `List<IncidentForce> forces`，自动聚合真实到场力量。

### 🟡 Major 6: 修正 NotesPage 入口挂载位置（非 AppBar）
- **问题**：`NotesPage` 没有 `AppBar`。
- **整改**：挂载点修正为 `notes_page.dart` 顶层标题栏中 `_buildConnectionStatus()` 左侧。

### 🟡 Major 7: 废除没有底层模型支撑的“组”伪造
- **问题**：`Entry` 无组概念，战报硬编码“共1组2人”会导致多人多组时严重失真。
- **整改**：公文槽位标准化为“现场内攻人员共 X 人（含 [名字列表]）”。

### 🟢 Nit 8: 伤亡缺省话术标准化与首页现场工具第 6 槽位填充
- **问题**：缺省伤亡话术“正在核实”过于敏感；首页工具存在空槽。
- **整改**：缺省伤亡话术标准化为“截至目前未发现被困人员，暂无人员伤亡”；将战况速报精准挂载到 `home_page.dart` 现场工具网格第 6 个空白槽位。

---

## 溯源矩阵 (Traceability Matrix)

| ID | Issue Description | Severity | Lens | Source Lines | Recommended Fix Location |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **TR-01** | `FiregroundEntry`/`IncidentNote` 类名不存在 | 🔴 Blocker | `codebase-details` | L100, L183-184 | `docs/designs/four-role-tactical-loop.md` §Detailed Implementation |
| **TR-02** | 首页现有现场监控与 GlanceCard 重复且违背 v2.0 | 🔴 Blocker | `design` | L105-108, L190-194 | `docs/designs/four-role-tactical-loop.md` §Components & Implementation |
| **TR-03** | 空呼计算未过滤退场人员与动态时间差分 | 🔴 Blocker | `comprehension` | L75, L101-102 | `docs/designs/four-role-tactical-loop.md` §Architecture & Engine Spec |
| **TR-04** | 四岗协同闭环缺乏角色数据拓扑阐释 | 🟡 Major | `zoom-out` | L11-18, L58-96 | `docs/designs/four-role-tactical-loop.md` §Overview & System Architecture |
| **TR-05** | 未复用 `IncidentForce` 现有结构体 | 🟡 Major | `inventive-catalyst` | L67, L120-122 | `docs/designs/four-role-tactical-loop.md` §Technical Plan & Engine Spec |
| **TR-06** | `NotesPage` 无 `AppBar` 导致挂载点失效 | 🟡 Major | `codebase-details` | L210-212 | `docs/designs/four-role-tactical-loop.md` §Target Files to Modify |
| **TR-07** | 战报伪造不存在的“组”数据结构 | 🟡 Major | `comprehension` | L123-128 | `docs/designs/four-role-tactical-loop.md` §Text Specification |
| **TR-08** | 伤亡公文措辞规范化及现场工具空槽复用 | 🟢 Nit | `design` / `comprehension` | L77, L127, L205 | `docs/designs/four-role-tactical-loop.md` §Slot-Filling & Field Tools |
