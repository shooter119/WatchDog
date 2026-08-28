# WatchDog 全面审核主问题台账与验收记录

审核日期：2026-08-27～2026-08-28
审核负责人：WatchDog 主 Agent  ；协作组：后端与架构、Flutter App 功能、UI/UX、安全与隐私、测试与质量、性能与工程质量。
范围：`app/`、`backend/`、`deploy/`、Android 构建与发布工作流、README/关于我们、测试配置及数据库迁移。
工作区策略：保留用户原有未提交改动；本轮不 commit、不 push、不发版。审核辅助材料均在本目录。

## 台账说明

六份分组报告记录了每个发现的完整字段（影响范围、复现/证据、根因、文件、方案、状态、验证）；本表是主 Agent 的去重、修复状态和最终验证索引。分组报告是审查时点快照，若其中状态与本表不同，以本表为准。

状态含义：

- `已修复/待验收`：代码和回归证据已具备，仍需在最终命令/生产环境中复核的项目。
- `部分修复`：低风险部分已处理，但仍有明确缺口；不能作为最终通过依据。
- `待外部/产品决策`：当前代码无法在不发明身份模型、改变核心规则或获得生产权限的情况下安全闭合。
- `待处理`：问题有代码或逻辑证据，尚未修改。

## A. 后端与架构组

详见：[backend-architecture.md](backend-architecture.md)、[backend-cross-review.md](backend-cross-review.md)。

| 编号 | 级别 | 影响/证据 | 根因、文件与方案 | 当前状态与验证 |
|---|---|---|---|---|
| BACK-001 | 严重 | 历史 `unit_id=NULL` 记录可能跨单位可见。 | 读取路径未带租户过滤；`backend/src/server.js`、`db-sqlite.js`、`db-postgres.js` 改为按认证单位读取，历史数据不自动归属。 | 已修复读取边界；`npm test`、单位隔离用例通过；历史数据治理待生产决策。 |
| BACK-002 | 严重 | 固定验证码和认证暴力尝试会影响所有单位入口。 | 认证缺少限流且种子固定；加入 IP+单位限流、生产 Token fail-fast，种子改为测试环境或显式配置。 | 已修复代码；后端 117/117、Token e2e 通过；真实生产凭据轮换待外部验收。 |
| BACK-003 | 严重 | 客户端可伪造设备/操作者标识。 | 当前协议只有可伪造 header/profile，没有用户身份或会话签发模型；`server.js` 仅能使用认证后设备档案作减损。 | 待外部/产品决策；需确定账号、会话、RBAC 与设备注册模型。 |
| BACK-004 | 严重 | 名单/热词等全局高影响删除接口缺少角色授权。 | `MANAGEMENT_TOKEN` 只覆盖日志清空，现有 App 没有管理员角色契约；`server.js` 删除路由。 | 待外部/产品决策；直接加门禁会改变现有管理流程。 |
| BACK-005 | 严重 | Express 4 async 拒绝可能导致请求挂起。 | 路由未统一转发 Promise 错误；`server.js:forwardAsyncRouteErrors` 已包裹已注册 async route。 | 已修复；故障注入返回 JSON 500，后端全量通过。 |
| BACK-006 | 严重 | 业务状态写入与事件写入不是原子幂等，重试可能状态/时间线不一致。 | `client_op_id` 只保护事件唯一索引；需数据库事务/RPC 或专用 operation ledger。 | 待外部架构改造；当前只做了冲突检查和重复出场保护。 |
| BACK-007 | 严重 | 离线补传 ID 跨警情/类型复用会吞操作。 | 全局唯一 ID 与业务作用域不一致；`server.js` 已拒绝跨警情复用，创建警情也检查任意既有事件。 | 部分修复；冲突测试通过；跨表原子幂等仍属 BACK-006。 |
| BACK-008 | 严重 | 记录级气瓶容量丢失会导致压力复核倒计时错误。 | entries schema/DTO 未保存参数；新增 `cylinder_vol_l`、`consumption_lpm` 及 App DTO/离线 payload。 | 已修复；API、SQLite 迁移、计算回归通过。 |
| BACK-009 | 严重 | 多实例同时新建警情仍可能绕过冷却。 | 仅进程内队列，数据库无跨实例原子约束；`server.js` creation queue。 | 部分修复；单进程测试通过；CloudBase 多实例事务待外部数据库/RPC。 |
| BACK-010 | 严重 | PostgreSQL 并发活动时间/自动归档可能出现旧值或重复事件。 | 更新缺少条件 MAX、归档事件缺少 changed 判定；两个 DB driver 已加入条件更新和返回元数据，SQLite 归档再增加 `status='active'` 条件并依据实际 changes 判定。 | 部分修复；SQLite 重复归档回归、模拟仓储测试和后端 117/117 通过；真实 PG 并发待生产/预生产。 |
| BACK-011 | 严重 | DB 初始化失败时健康检查误报 200。 | readiness 未进入 HTTP 响应；`server.js` 现在未就绪返回 503。 | 已修复健康语义；readiness 测试通过；自动恢复策略仍未实现。 |
| BACK-012 | 严重 | ASR/解析/聊天外部资源可被高频调用或高基数 key 占用内存。 | 限流原按设备 header；已增加 IP+单位 ASR/parse 限流、聊天 key 清理并改为 IP+单位。 | 部分修复；代码逻辑已覆盖，CloudBase 多实例共享限流仍待网关配置。 |
| BACK-013 | 严重 | 原文、姓名、解析和日志可放大数据库/上游成本。 | 依赖总 body 限制而无字段约束；加入 JSON 512KB、parse 4000、entry/name/raw、音频/日志上限。 | 部分修复；离线原文与全量容量压测仍待补测。 |
| BACK-014 | 严重 | ASR/解析正文进入普通成员可查询的操作日志。 | 日志信任客户端脱敏；App/server 均做摘要、长度和递归敏感字段脱敏，业务时间线仍按功能保留随手记正文。 | 部分修复；日志脱敏回归通过；是否允许业务正文进入时间线需产品/隐私决策。 |
| BACK-015 | 一般 | 数据库缺少 FK/CHECK，路由代码承担全部一致性。 | 早期 schema 未建约束；`migrations/001_initial.sql`。 | 待处理；需兼容现有历史数据后设计迁移。 |
| BACK-016 | 一般 | 警情列表无分页并有 N+1 forces/归档写入。 | `incidentView` 逐条拉取；`server.js`、两个 driver。 | 待处理；需结合业务容量上限和 CloudBase 查询能力优化。 |
| BACK-017 | 严重 | 自定义服务部署健康检查可能指错地址。 | 部署脚本曾固定 URL；`deploy/deploy.sh` 已支持 `WATCHDOG_HEALTH_URL`，并由本轮实际部署执行健康检查。 | 已修复并完成生产复验；CloudBase Deployment successful，`/api/health` 返回 `ok=true, ready=true, databaseReady=true, asrConfigured=true, llmConfigured=true`。 |
| BACK-018 | 一般 | 迁移无版本表/总事务，失败可留下半套 schema。 | `scripts/migrate-cloudbase.js` 逐条执行 DDL。 | 待外部数据库改造；需确认 CloudBase PostgREST/迁移权限。 |
| BACK-019 | 一般 | 容器 root 运行且缺 HEALTHCHECK。 | Dockerfile 默认配置；已添加非 root 用户和容器健康检查。 | 已修复代码；真实镜像构建/启动未完成。 |
| BACK-020 | 优化 | SQLite/PG 的种子行为不一致。 | 各 driver 各自硬编码；已统一为测试环境或显式 `WATCHDOG_SEED_UNIT_*`，生产不默认写入 0570。 | 已修复；源码/迁移检查和后端测试通过。 |

### 后端交叉复核新增项

| 编号 | 级别 | 影响/证据 | 根因、文件与方案 | 当前状态与验证 |
|---|---|---|---|---|
| BCR-001 | 严重 | 旧 SQLite 在索引 DDL 阶段因缺 `scene` 列无法启动。 | 初始化索引早于兼容迁移；`db-sqlite.js` 迁移顺序调整。 | 已修复；旧库子进程迁移测试通过。 |
| BCR-002 | 严重 | 旧库重建 entries 后缺新计算字段。 | 重建 DDL/复制列集合不完整；已加入三列及复制。 | 已修复；旧库升级后读写回归通过。 |
| BCR-003 | 严重 | `/api/auth/verify` 错误 Token 曾返回 200。 | Token 中间件跳过认证入口；已统一受 API_TOKEN 保护。 | 已修复；Token e2e 错误 bootstrap 401 通过。 |
| BCR-004 | 严重 | 轮换 `X-Device-Id` 可绕过认证失败限流。 | 客户端 header 作为主键；已改 IP+单位。 | 已修复；6 次轮换设备测试为 403×5+429。 |
| BCR-005 | 严重 | 复用 note/entry 操作 ID 可创建无建档事件的孤儿警情。 | 新建路由只检查 `incident_created`；已检查任意既有事件并冲突返回 409。 | 已修复；timeline 冲突回归通过。 |
| BCR-006 | 一般 | PATCH 可持久化超长姓名。 | POST 与 PATCH 校验不一致；已补 64 字限制。 | 已修复；API 超长 PATCH 测试通过。 |
| BCR-007 | 一般 | 单位码/认证头缺字段上限。 | 只有 body 总上限；已补 code/header/id 长度校验。 | 已修复；超长 unit code API 测试通过。 |
| BCR-008 | 一般 | SQLite/PG 分页参数接受负数或小数；SQLite 负 LIMIT 可退化为无界读取，增加资源压力。 | 两个 driver 增加有限正整数下限、取整和上限；`backend/test/db.test.js` 增加边界回归。 | 已修复；后端 117/117 通过。 |

## B. Flutter App 功能组

详见：[flutter-function.md](flutter-function.md)。

| 编号 | 级别 | 影响/根因/文件 | 当前状态与验证 |
|---|---|---|---|
| FLT-001 | 严重 | 长按松手早于异步录音启动；Home/Chat 增加请求代际、占用与取消检查。 | 已修复；Flutter 178/178。 |
| FLT-002 | 严重 | 离线压力/出场本地列表不更新；`AppController` 即时替换/标记。 | 已修复；压力复核还会投影记录级倒计时；离线专项与 Flutter 178/178 通过。 |
| FLT-003 | 严重 | 单条气瓶参数离线/复核丢失；Entry、payload、后端字段补齐。 | 已修复；后端计算回归与 Flutter 通过。 |
| FLT-004 | 严重 | 认证失效不回门禁；结构化 `ApiException` 处理 UNIT/API_TOKEN 失败。 | 已修复代码；Flutter 全量通过，真实失效会话待集成环境。 |
| FLT-005 | 严重 | APK 固化 API token；设置默认空值，认证浮层显式输入并做受保护探测。 | 已修复；Token e2e/Widget 通过。 |
| FLT-006 | 严重 | 离线队列切单位后可能用新身份补传旧警情；`OfflineQueue.drain` 增加允许警情集合。 | 已修复发送边界；队列真实设备切换集成测试待补。 |
| FLT-007 | 严重 | 阈值/计算参数可为负或 0；Settings 常量、setter、页面整体校验补齐。 | 已修复；新增校验测试通过。 |
| FLT-008 | 一般 | 保存期间第二次编辑被丢；加入 queued save。 | 已修复代码；全量 Flutter 通过。 |
| FLT-009 | 一般 | 共享 ApiClient 取消可能影响其他请求。 | 部分修复；聊天使用独立 client，同步仍需更细粒度请求池。 |
| FLT-010 | 一般 | 非 JSON 网关错误会泄露 FormatException；ApiClient 所有响应入口统一 `_decodeJson`。 | 已修复；analyze/test 通过。 |
| FLT-011 | 一般 | 自动记日志失败仍跳日志页；仅成功后导航。 | 已修复；Flutter 全量通过。 |
| FLT-012 | 一般 | 详情出场主请求异常边界不完整；拆分主状态与后置日志错误反馈。 | 已修复；Flutter 全量通过。 |
| FLT-013 | 严重 | AlarmService init 失败后不可重试；成功后才置 `_inited`。 | 已修复代码；插件真实失败待设备验证。 |
| FLT-014 | 严重 | 通知调度失败仍标成功；成功后才写 `_scheduled`。 | 已修复；Flutter 全量通过。 |
| FLT-015 | 一般 | 本地 ASR 下载无连接/流读取超时；加入 60 秒 timeout 与 160MB 上限。 | 已修复；模型网络实测待外部环境。 |
| FLT-016 | 严重 | 关闭云 ASR 未等待模型检查；异步 toggle 现先检查/下载，成功才保存。 | 已修复代码；analyze/test 通过。 |
| FLT-017 | 一般 | 自定义服务器仍使用编译期模型地址。 | `LocalAsrService` 现按构造参数 > `WATCHDOG_MODEL_BASE_URL` > 运行时 `Settings.serverUrl/models` 解析模型源；新增生命周期回归覆盖自定义服务器。 | 已修复；定向测试通过，全量 Flutter 196/196、analyze 0 issues。 |
| FLT-018 | 一般 | Chat 历史加载/发送/清空可能并发覆盖。 | `chat_page.dart` 增加历史代际/清空屏障；`chat_history.dart` 增加串行 mutation queue，持久化不阻塞 UI。 | 已修复；页面/持久化并发回归与 Flutter 178/178 通过。 |
| FLT-019 | 优化 | 语音问答空转写或页面销毁操作日志未结束；异常分支已有 `transcribe_error` 终态。 | `ChatPage.finishRecording()` 与 `dispose()` 对空转写和页面销毁路径补齐 `op_end`，新增两个 Widget 回归。 | 已修复；定向回归通过，全量 Flutter 196/196。 |
| FLT-020 | 优化 | 实名字段同步白名单但不上传/应用；已补 `real_name`。 | 已修复；后端用户设置测试通过。 |
| FLT-021 | 优化 | release 缺签名文件静默 debug；CI 现在 fail-fast 并做签名指纹校验。 | 已修复代码；本机 APK 已用 `apksigner` 验证 v2 签名和正式证书，CI 实际运行仍待 Actions。 |

## C. UI/UX 组

详见：[ui-ux.md](ui-ux.md)。UI-UX-001 是设计基线冲突，不能凭审查者偏好改动默认入口。

| 编号 | 级别 | 影响/证据与文件 | 当前状态与验收 |
|---|---|---|---|
| UI-UX-001 | 严重 | `main.dart` 当前默认语音页，旧设计资料要求看板页，测试也锁定语音页。 | 待产品决策；不得在无基线选择时修改。 |
| UI-UX-002 | 严重 | 认证浮层固定 Column 在横屏/键盘短高度可能裁剪。 | 已修复为 `Expanded + SingleChildScrollView`；Flutter 全量通过。 |
| UI-UX-003 | 一般 | 若干高风险自定义控件显式小于 48dp。 | 已修复；关键操作命中区统一到普通 48dp/关键 56dp，并由 Widget 几何断言覆盖。 |
| UI-UX-004 | 一般 | 连接状态二态/重试反馈不完整。 | 已修复；组件接入同步中/失败状态、Tooltip、语义化重试；设备级网络切换待外部。 |
| UI-UX-005 | 一般 | 动效未响应系统减少动效。 | 已修复；重复动效、录音页反馈和折叠/导航过渡接入减少动效偏好；设备级 TalkBack 待外部。 |
| UI-UX-006 | 一般 | 详情固定两列对大字体/窄屏不友好。 | 已修复；320dp/2 倍文字缩放采用线性进度与单列信息布局，专项用例通过。 |
| UI-UX-007 | 一般 | 自定义折叠/排序动作语义不完整。 | 已修复；展开状态、动作提示、排序语义和 48dp 命中区已补。 |
| UI-UX-008 | 优化 | 日志颜色绕过主题 token。 | 已修复；分类、排行和 Hero 色彩集中到 `AppColors`。 |
| UI-UX-009 | 优化 | 设置 Hero 展示内部英文名。 | 已修复；设置页和设计辅助页统一中文品牌名。 |
| UI-UX-010 | 优化 | PNG 头像不符合透明 CustomPainter 规范。 | 仅建议，尚无运行时缺陷证据；不作为阻断。 |
| UI-UX-011 | 一般 | 320dp/2 倍字体下日志页标题操作行、统计排行标题可能横向溢出。 | 已修复为响应式标题布局；新增 Notes/Stats 专项 Widget 回归，最终 Flutter 178/178。 |

## D. 安全与隐私组

详见：[security-privacy.md](security-privacy.md)。

| 编号 | 级别 | 影响/根因/文件 | 当前状态与验证 |
|---|---|---|---|
| SEC-001 | 严重 | App 固化共享 Token；`Settings.apiToken` 默认空，认证浮层输入。 | 已修复；Flutter/Token e2e 通过。 |
| SEC-002 | 严重 | 缺 API_TOKEN 时 fail-open；生产启动现在直接失败。 | 已修复代码；生产启动待 CloudBase 验证。 |
| SEC-003 | 严重 | header/profile 可冒用操作者；缺身份会话模型。 | 待外部/产品决策；与 BACK-003 同一根因，不重复修改。 |
| SEC-004 | 严重 | legacy NULL 单位记录越权；请求读取已按 unit 过滤。 | 已修复读取边界；历史回填/处置待生产决策。 |
| SEC-005 | 严重 | 日志清空/伪造破坏审计；清空改管理 Token，条目设备字段不再受信。 | 部分修复；完整 RBAC/不可抵赖审计待 BACK-004。 |
| SEC-006 | 严重 | 0570 种子和认证无限试错；默认种子已移除，失败限流已加。 | 已修复代码；真实单位码轮换待运维验证。 |
| SEC-007 | 一般 | 语音/异常正文泄露到日志；本地/服务端操作日志摘要化。 | 部分修复；业务时间线正文是否保留待产品/隐私决策。 |
| SEC-008 | 一般 | 外部资源上限和限流不足；音频、模型、ASR/parse/chat 均有本地/单实例控制。 | 部分修复；多实例网关限流待外部配置。 |
| SEC-009 | 严重 | CloudBase REST 地址若为 HTTP 可能携带 service role；旧 App 自定义地址也可能绕过统一传输校验。 | CloudBase 驱动强制 HTTPS；App 设置和前台保活拒绝非本地 HTTP，并迁移不安全旧值。可信 Host allowlist 仍待产品/部署信任模型。代码级已修复；HTTP 回归 1/1、后端 112/112、Flutter analyze/test 通过。 |
| SEC-010 | 一般 | App 服务器地址可改为任意 HTTPS。 | 待产品决定 allowlist/内网模式；当前至少拒绝非本地 HTTP。 |
| SEC-011 | 一般 | Token、单位码、现场内容在 SharedPreferences 明文。 | 认证失效和离开单位时已清除 API Token；完整 secure storage 迁移仍需跨平台改造。部分修复；代码级回归通过，明文存储风险待处理。 |
| SEC-012 | 一般 | Android ID 稳定指纹可跨重装关联。 | 待产品/隐私决策；需替代设备注册标识。 |
| SEC-013 | 一般 | 本地模型无签名/sha256 manifest。 | 待处理；需发布模型清单、公钥和部署资源协同。 |
| SEC-014 | 严重 | GitHub Action tag 可变，发布签名依赖 secrets。 | 签名缺失 fail-fast、arm64/质量门禁已加；9 处 Action 已固定到完整提交 SHA。代码级供应链风险已闭合；Actions 实跑和仓库分支保护仍待外部，YAML 解析、SHA 检查和本机签名验证通过。 |
| SEC-015 | 严重 | 生产 DB driver 缺失时静默 SQLite；`db.js` 现在生产只允许 PostgreSQL/CloudBase。 | 已修复；单测通过，生产启动待 CloudBase。 |
| SEC-016 | 优化 | RLS 开启但无租户策略，service_role 全表 DML。 | 待外部数据库策略设计；当前 API 层做租户过滤。 |
| SEC-017 | 一般 | 本机忽略的 env/key 文件权限曾未验证。 | 已修复本机工作区权限：`backend/.env`、`app/android/key.properties`、keystore 均收紧为 `0600`；未入库扫描通过。生产主机/CI secret 权限仍需运维平台验收。 |

## E. 测试与质量组

详见：[testing-quality.md](testing-quality.md)、[quality-cross-review.md](quality-cross-review.md)。

| 编号 | 级别 | 影响/证据 | 当前状态与验证 |
|---|---|---|---|
| TQ-001 | 一般 | `AGENTS.md` 与 CI 测试数量基线曾滞后于实际用例。 | 已更新为后端 112、App 178；质量/发布 workflow 同步更新为只允许数量增加，并拒绝 skipped/todo。 | 已修复；最终命令实测一致。 |
| TQ-002 | 严重 | 发布前曾不运行质量门禁。 | 已新增 quality workflow，并在 release 中重复 backend/npm 与 Flutter analyze/test。静态 YAML 检查通过，Actions 待外部。 |
| TQ-003 | 一般 | ASR/parse HTTP 边界覆盖不足。 | 待补；现有逻辑测试和限流代码有证据，但无真实上游契约。 |
| TQ-004 | 严重 | App 真同步/离线队列被替身绕开。 | 逻辑已修复，真实网络/断网集成仍待设备与环境。 |
| TQ-005 | 严重 | 真实录音、权限、本地 ASR 模型未覆盖。 | 待外部 Android 设备集成验证。 |
| TQ-006 | 严重 | 真正报警/TTS/前台保活插件未覆盖。 | 阈值校验和服务失败重试已有单测；插件行为待设备。 |
| TQ-007 | 一般 | ApiClient 传输层边界历史覆盖不足。 | 非 JSON/结构化异常代码已补；独立 ApiClient mock 测试仍待补。 |
| TQ-008 | 严重 | PG/PostgREST 真实迁移与契约未验证。 | fake repository 和 schema 已过；CloudBase 凭据/环境阻塞。 |
| TQ-009 | 一般 | 管理端点/归档页面边界不足。 | 待补。 |
| TQ-010 | 优化 | 测试依赖墙钟/固定尺寸/pumpAndSettle，可能脆弱。 | 本轮已修复日志可视性断言；其余待逐步稳定。 |
| TQ-011 | 优化 | 无覆盖率产物/最低门槛。 | 待工程决策。 |

### 质量交叉复核新增项

| 编号 | 级别 | 影响/证据 | 当前状态与验证 |
|---|---|---|---|
| QCR-001 | 严重 | 认证浮层曾先落 Token、未把 Token传入回调。 | 已修复为回调携带 Token，认证+受保护 probe 成功后才持久化；Widget/Token e2e 通过。 |
| QCR-002 | 严重 | 录音 start 抛错会留临时路径。 | `AudioService.start` 回滚删除，dispose 也清理；Flutter 全量通过。 |
| QCR-003 | 严重 | permission/start 异步期间可双 begin。 | Home/Chat generation+starting 闸门；延迟 permission 测试与全量测试通过。 |
| QCR-004 | 严重 | 设置保存可能部分写入/非法值。 | 保存前整体校验、setter 共用范围；3 个新增校验用例通过。 |
| QCR-005 | 严重 | 日志脱敏更新后旧 UI hit-test 断言失败。 | 测试改为验证脱敏字段存在且原文不可见；Flutter 178/178。 |
| QCR-006 | 严重 | Bearer、嵌套字段和服务端日志边界可泄露。 | App/server 递归脱敏、异常日志脱敏；日志测试与 Flutter 全量通过。 |
| QCR-007 | 严重 | release 独立于质量门禁。 | release workflow 已加入同套质量步骤；未触发远程 Actions。 |
| QCR-008 | 一般 | tag/pubspec/App 版本可能不一致。 | release workflow 已在构建前比较三者；当前发布候选 `1.2.1+49` 的 tag/pubspec/App 版本需在打 tag 前保持一致。 |

## F. 性能与工程质量组

详见：[performance-engineering.md](performance-engineering.md)。

| 编号 | 级别 | 影响/根因/方案 | 当前状态与验证 |
|---|---|---|---|
| PE-001 | 一般 | 录音无时长上限且有内存复制；加入 15MB 客户端/服务端大小上限。 | 部分修复；时长上限仍待产品容量定义。 |
| PE-002 | 一般 | stop 异常临时 WAV 泄漏；AudioService finally 清理。 | 已修复；Flutter 全量通过。 |
| PE-003 | 一般 | 页面卸载时活动录音可能遗留；dispose 释放。 | 已修复代码；真机生命周期待外部。 |
| PE-004 | 一般 | 主 isolate/前台服务双 5 秒轮询和唤醒锁。 | 待处理；需确定保活架构，不能直接删除一条轮询。 |
| PE-005 | 一般 | 前台回调重叠；加入 in-flight 闸门。 | 已修复代码；Flutter/静态检查通过。 |
| PE-006 | 优化 | 每秒 tick 触发大树重建。 | 待处理。 |
| PE-007 | 一般 | 同步列表触发归档写和 N+1 forces。 | 部分修复了归档单位边界；查询/写放大待处理。 |
| PE-008 | 一般 | 操作日志上传会清空上传期间新日志。 | 已修复为快照删除；Flutter 全量通过。 |
| PE-009 | 一般 | 诊断上传会删掉上传期间新 pending。 | 已修复为快照/仅删已上传 op；Flutter 全量通过。 |
| PE-010 | 一般 | 每条操作日志完整写 SharedPreferences。 | 待处理；需批量/文件队列迁移。 |
| PE-011 | 一般 | chat rate Map 高基数无过期；已清理并改 key。 | 已修复单实例内存生命周期；多实例限流待网关。 |
| PE-012 | 一般 | SSE 客户端断开未取消 DeepSeek 上游。 | 已修复；`server.js` 绑定下游生命周期并取消上游 fetch/reader；SSE 断连回归通过。 |
| PE-013 | 优化 | 服务端日志逐条写 DB。 | 待处理。 |
| PE-014 | 一般 | 模型下载无超时；已加连接/流读取 timeout 与尺寸上限。 | 已修复代码；真实网络待外部。 |
| PE-015 | 严重 | 告警 Future 异常可能卡 looping；AlarmService/controller 安全包装。 | 已修复代码；插件实测待设备。 |
| PE-016 | 一般 | arm64 标识与实际 APK ABI 不符。 | 已修复 release workflow 使用 split-per-abi；本地 arm64 APK 仅含 arm64，包 47.2MB。 |
| PE-017 | 优化 | 依赖有 discontinued/落后版本。 | 待维护窗口；本轮不擅自升级依赖。 |
| PE-018 | 优化 | 静默异常多、缺指标。 | 部分补了诊断/错误日志；完整监控待部署平台。 |

### 第二轮定向复核新增项

详见：[round2-quality.md](round2-quality.md)、[round2-uiux.md](round2-uiux.md)。以下项目均已完成代码级修复；真实 CloudBase/Android/GitHub Actions 证据仍按 H、I 节记录。

| 编号 | 级别 | 影响/证据 | 根因、文件与方案 | 当前状态与验证 |
|---|---|---|---|---|
| R2-QA-001 | 一般 | 合法 JSON 的错误顶层/嵌套形状曾触发 Dart cast 异常。 | `api_client.dart` 为 List/Map/events 增加统一响应形状校验，并以 `INVALID_RESPONSE_SHAPE` 抛出结构化异常。 | 已修复；ApiClient 回归与 Flutter 178/178 通过。 |
| R2-QA-002 | 严重 | 多人解析重试找回人员后 guardrail 仍读取第一次响应，可能错过进场确认。 | `parse.js` 构造最终解析快照供 intent/action guardrail 共用。 | 已修复；定向 23/23，后端 112/112 通过。 |
| R2-QA-003 | 严重 | 离线压力复核入队后看板仍显示旧压力/倒计时。 | `AppController` 使用记录级容量/耗气率立即本地投影新压力与 `exitAt`。 | 已修复；离线控制器回归与 Flutter 178/178 通过。 |
| R2-QA-004 | 一般 | 单条损坏离线 payload 曾阻塞整批合法操作补传。 | `OfflineQueue` 逐行解码，坏行写入 quarantine；隔离失败保留原行，合法分组继续。 | 已修复；新增队列回归与 Flutter 178/178 通过。 |
| R2-QA-005 | 严重 | ASR 五个文件逐个替换可能形成新旧混合集合。 | 版本化 staging 完整下载并写 marker 后原子切换 active 指针。 | 已修复；新增 ASR 集合回归与 Flutter 178/178 通过。 |
| R2-QA-006 | 一般 | CI 曾只看退出码，无法阻止测试数量减少。 | quality/release workflow 解析运行时报告并比较 112/178 基线。 | 已修复；YAML 解析、本机运行时计数均通过，Actions 实跑待外部。 |

### 第三轮多 Agent 交叉复核新增项

详见：[round3-cross-review.md](round3-cross-review.md)。以下记录主 Agent 汇总后的去重结果；页面并发、窄屏大字体和 SSE 资源释放均已完成代码级闭环。

| 编号 | 级别 | 影响/证据 | 根因、文件与方案 | 当前状态与验证 |
|---|---|---|---|---|
| BACK-R3-001 | 严重 | SSE 客户端断开后上游模型请求可能运行到超时，浪费连接和额度。 | `server.js` 未绑定下游生命周期；增加 `AbortController`、下游断开监听和 reader 取消；新增 `sse_disconnect.test.js`。 | 已修复；SSE 断连回归通过，后端 112/112。 |
| BACK-R3-002 | 一般 | 上游错误正文可能把供应商内部信息回显给客户端。 | `server.js` 错误处理直接使用上游正文；改为通用客户端错误 + 脱敏日志。 | 已修复；错误正文脱敏回归通过，后端 112/112。 |
| R3-FLT-001 | 一般 | 历史读取、发送和清空并发时可能恢复旧消息或丢当前消息。 | `chat_page.dart` 增加历史代际/清空屏障；`chat_history.dart` 增加串行 mutation queue；UI 不等待本地 I/O。 | 已修复；页面并发 3/3、持久化并发 2/2、Flutter 178/178。 |
| R3-UI-001 | 一般 | 同步中可能不显示，或同步时错误显示已中断。 | `sync()` 开始立即通知；`ConnectionStatus` 优先显示同步中。 | 已修复；Flutter analyze 0 issues、178/178。 |
| R3-UI-002 | 一般 | 外层 Semantics 与内层 InkWell 重复声明同一动作。 | 外层排除子语义、内层排除重复语义；涉及日志/设置/统计页。 | 已修复；Flutter 178/178；TalkBack 真机待外部。 |
| R3-UI-003 | 一般 | 320dp/2 倍字体看板人员卡曾横向溢出 22px。 | 标题与人员卡改为窄屏/大字号纵向布局，状态/动作使用 `Wrap`。 | 已修复；专项目测 1/1、Flutter 178/178。 |
| SEC-R3-001 | 严重 | HTTP CloudBase 地址可能携带 service role；旧 App 地址存在绕过入口。 | CloudBase 驱动强制 HTTPS；设置和前台保活拒绝非本地 HTTP，并迁移不安全旧值。 | 代码级已修复；HTTP 回归 1/1；可信 Host allowlist 待部署决策。 |
| SEC-R3-002 | 一般 | 本机 0644 secret/签名文件可被同机其他用户读取。 | 收紧 `backend/.env`、`key.properties`、keystore 为 0600。 | 已完成本机修复；权限和 tracked 敏感文件扫描通过。 |
| TQ-R3-001 | 一般 | Flutter 后台历史写入与未模拟平台插件交叉时，全量测试可挂起。 | ChatPage 测试组安装内存 SharedPreferences；生产发送不等待持久化，队列仍保证写入顺序。 | 已修复；Flutter JSON reporter 178/178，无挂起。 |
| PE-R3-001 | 优化 | CI 测试/构建挂起会长期占用 runner。 | quality/release job 增加 `timeout-minutes`。 | 已修复配置；YAML 解析通过，Actions 实跑待外部。 |

### 第四轮验收复核新增项

详见：[round4-cross-review.md](round4-cross-review.md)。本轮先复核前一轮修改，再对新增测试、响应式布局、即时重试和生产部署结果做交叉验收。

| 编号 | 级别 | 影响/证据 | 根因、文件、方案与状态 | 验证 |
|---|---|---|---|---|
| BACK-R4-001 | 严重 | 重复归档可能重复写入事件或覆盖已归档元数据。 | SQLite 归档 UPDATE 增加 `status='active'` 条件，并用实际 `changes` 计算 `changed`；`backend/src/db-sqlite.js`、`backend/test/db.test.js`。 | 已修复 SQLite 路径；重复归档回归通过，后端 112/112；PG 事务闭环仍属 BACK-006/BACK-010 外部架构项。 |
| WD-APP-LIFECYCLE-20260828-01 | 一般 | 启动、认证、刷新、ASR 模型切换和前台服务并发时可能重复请求、旧会话回写或资源竞态。 | 以 Future single-flight、会话代次、API 快照和串行操作保护 `AppController`、`LocalAsrService`、`ForegroundKeepAlive`；测试中隔离 audioplayers platform channel。涉及上述 4 个 App 源文件及 `controller_service_lifecycle_test.dart`。 | 已修复；定向与全量 Flutter 179/179、analyze 0 issues。 |
| PE-R4-001 | 一般 | 登录启动可能重复拉取名单/热词，首次认证前发起无效请求。 | `AppController` 认证后统一启动服务并合并名单加载 Future。 | 已修复；生命周期并发回归通过，Flutter 178/178。 |
| UI-UX-004-R1 | 一般 | “重试同步”点击在同步定时器已启动后可能不真正发起即时同步。 | 各页面 `ConnectionStatus.onRetry` 从一次性 `startSync` 改为等待实际请求的 `refreshNow`。 | 已修复；相关页面复核、analyze 和 Flutter 178/178 通过。 |
| UI-UX-011 | 一般 | 320dp/2 倍字体下火场日志标题操作行、统计排行标题有横向溢出风险。 | Notes 标题区改为窄屏纵向 + `Wrap`；`SectionTitle` 标题采用可收缩布局；新增两项窄屏大字体 Widget 测试。 | 已修复；`widget_test.dart` 定向通过，全量 Flutter 178/178。 |
| WD-QA-20260828-01 | 严重 | 新增生命周期测试初次运行触发 `audioplayers.global MissingPluginException`，会阻塞 App 门禁。 | 测试组为平台 MethodChannel 安装显式 mock，生产代码不改变平台行为。 | 已修复；JSON reporter `visible_tests=178 skipped=0 failures=0 done_success=True`。 |
| WD-QA-20260828-02 | 严重 | CI 数量门禁原先可能让 skipped/todo 测试满足数量下限。 | quality/release workflow 增加 Node `skipped/todo=0` 与 Flutter `skipped=0` 检查，并把基线更新为 178。 | 已修复配置；YAML 解析、静态门禁检查通过；GitHub Actions 实跑待外部。 |
| PE-MODEL-001 | 一般 | 进程被杀或重复更新后 ASR 旧 generation 可能残留并占用磁盘。 | 已增加下载前清理崩溃遗留 `.staging` 与 `.active.*.part`，不触碰 active generation；旧 generation GC、保留数量和低存储策略仍需设备/架构决策；`local_asr_service.dart`。 | 部分修复；新增清理回归通过，App 179/179；进程杀/低存储实测与旧 generation 策略待外部。 |

### 恢复后的续审新增项

| 编号 | 级别 | 影响/证据 | 根因、文件与方案 | 当前状态与验证 |
|---|---|---|---|---|
| WD-APP-R6-001 | 严重 | 已保存警情因单位切换、服务端撤销或权限收紧而不可见时，App 曾继续展示旧警情快照，存在跨单位误呈现/信息残留风险。 | `app/lib/state/app_controller.dart` 异常分支未处理 `INCIDENT_NOT_FOUND`；现已清除当前警情、entries/notes/forces，停止保活/告警调度，并新增 `app/test/app_controller_offline_test.dart` 回归。 | 已修复；定向与全量 Flutter 196/196、analyze 0 issues；API 33 模拟器修复前后 UI 对比和隔离后端单位归属新建警情通过。 |
| FLT-017（续审闭合） | 一般 | 自定义服务器仍使用编译期模型地址。 | `LocalAsrService` 现按构造参数 > `WATCHDOG_MODEL_BASE_URL` > 运行时 `Settings.serverUrl/models` 解析模型源；新增自部署服务器回归。 | 已修复；定向与全量 Flutter 196/196、analyze 0 issues。 |
| FLT-019（续审闭合） | 优化 | 辅助页空转写或页面销毁后操作日志曾缺少 `op_end`。 | `ChatPage.finishRecording()` 与 `dispose()` 现对空转写写入 `op_end(outcome=no_speech)`，对页面销毁写入 `op_end(outcome=page_disposed)`；新增两个 Widget 回归。 | 已修复；定向回归通过；全量 Flutter 196/196、analyze 0 issues。 |

## G. 交叉复核结论

- 后端交叉复核执行了旧 SQLite 启动迁移、错误 Token、轮换设备限流、跨类型操作 ID、超长 PATCH、async 数据库异常和分页边界复现；8 项新增问题均已修复并由后端测试回归。
- 质量交叉复核覆盖认证 Token 持久化时序、录音启动失败/重入、设置整体校验、Bearer/嵌套日志脱敏、发布质量门禁和版本一致性；8 项新增问题均完成代码修复或明确记录外部验收边界。
- 第二轮质量/UI 交叉复核闭合 ApiClient 响应结构、多人解析最终快照、离线状态投影、坏 payload 隔离、ASR 集合原子切换、测试数量门禁及 UI-UX-003～009；均有专项回归或静态搜索证据。
- 主 Agent 复核发现并处理了发布 APK 实际 ABI 与 workflow 门禁不匹配、单位 A 查询归档单位 B 警情、切换单位后离线队列发送边界、生产固定 0570 种子、API_TOKEN 失效回门禁、ApiClient 非 JSON 错误等补充问题。
- 第三轮交叉复核闭合 SSE 下游断开、上游错误脱敏、问答历史竞态、同步反馈时序、重复无障碍语义、看板大字体溢出、CloudBase HTTPS、本机 secret 权限和 CI 超时；剩余身份/RBAC、真实环境与设备项保持外部阻塞。
- 第四轮复核闭合 SQLite 重复归档状态保护、App 启动/刷新/ASR/前台服务竞态、页面即时重试、日志/统计窄屏大字体布局，以及测试平台隔离和 skipped/todo 门禁；恢复后的续审又闭合了 WD-APP-R6-001；性能指标、身份模型、PG 跨实例事务、物理 Android/Actions 仍需外部证据。

## H. 最终验证记录

| 验证项 | 结果 | 证据 |
|---|---|---|
| 后端测试 | 通过：117/117，0 失败 | `cd backend && npm test` |
| Flutter 静态分析 | 通过：0 issues | `cd app && flutter analyze` |
| Flutter 测试 | 通过：196/196，0 失败，skipped=0 | `cd app && flutter test --reporter json` |
| Android release 构建 | 通过 | `flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub`；最终构建成功 |
| APK ABI/签名 | 通过 | `app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` 仅含 `lib/arm64-v8a/`，47.3MB；`apksigner verify` v2=true、1 signer，证书 SHA-256：`0676114be5b9eb9d4448cb849d9b938b278214bb81de04a5debcde5eaf270668`；`1.2.1+49` 发布候选 APK SHA-256：`bb78090cd2b7983b43ee026f268f345f24441f02422143404242e57f13592d9a` |
| 部署包 dry-run | 通过 | `deploy/deploy.sh --dry-run` 能生成临时包并包含 backend/src 与 models |
| 生产部署 | 通过 | `CLOUDBASE_ENV_ID=watchdog-prod-d6gch930m378d9a16 ./deploy/deploy.sh`；CloudBase 返回 Deployment successful，健康检查 `ok=true, ready=true, databaseReady=true, asrConfigured=true, llmConfigured=true`。 |
| 生产未授权边界 | 通过 | 未带 `X-Api-Token` 请求 `/api/config` 返回 HTTP 401、`API_TOKEN_INVALID`；未使用真实令牌做业务写操作。 |
| README/关于我们 | 已同步 | 认证、单位种子、生产不默认 0570 的描述已同步；版本未发版未改。 |
| 密钥/临时文件 | 通过（仓库级） | `git diff --check` 通过；tracked 文件未发现 `.env`、`key.properties`、keystore 或调试脚本匹配项；release 构建产物位于 ignored build 目录；本机 `.env`、`key.properties`、keystore 均为 `0600`。主机上未验证的生产文件权限仍属运维边界。 |

## I. 当前验收判定

代码级回归验收通过：核心后端/App 测试、分析、构建、UI 边界、已复现缺陷修复和生产健康检查均有证据，当前运行时测试为后端 117、App 196，未减少。

整轮项目验收尚未宣告完成，原因是以下项目不是主 Agent 可以安全猜测或本机完成的外部阻塞；本轮发布操作已获用户明确授权，且不改变这些未闭合的项目级验收边界：

1. 操作者真实身份/RBAC/管理员权限模型尚未由项目定义；BACK-003、BACK-004、SEC-003 等不能靠继续增加 header 或硬编码角色安全闭合。
2. BACK-006/BACK-009/BACK-010 的跨表原子幂等、多实例冷却和 PG 事务仍需数据库/RPC 架构决策及并发环境验证。
3. UI-UX-001 的首屏默认入口存在“看板 vs 语音”设计基线冲突，需要产品选择。
4. 物理真机权限、录音插件、本地 ASR、通知/前台服务、TalkBack、弱网和真实 sqflite 流程仍需要 Android 设备/预生产环境；API 33 模拟器已完成部分权限和核心流程，本机/模拟器证据不能冒充物理真机验收。

在上述外部/产品条件满足前，本台账状态保持“项目级验收未通过”，不将本轮项目整体标记为完成。当前本机代码回归与生产健康检查均已通过；本轮按用户授权执行 `1.2.1+49` 发布，下一轮优先级是先补身份/RBAC 与管理流程决策，再完成 PG 跨实例事务/迁移验证、Android 真机回归，最后根据 UI 基线关闭 UI-UX-001 并复验未决一般项。
