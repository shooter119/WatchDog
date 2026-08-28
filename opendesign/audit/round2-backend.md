# WatchDog 后端与架构组第二轮定向复核

复核日期：2026-08-27（Asia/Shanghai）
复核范围：未决 `BACK-003/004/006/009/012/015/016/018`，以及 CloudBase 多实例、迁移、鉴权边界；另记录本次 `R2-QA-002` 修复验收。
复核方式：当前工作区静态代码复核、现有后端测试、临时进程/临时数据库最小复现；不读取或输出任何密钥，不回滚既有工作区改动。

## 1. 结论摘要

- `R2-QA-002` 已修复：多人压力文本在第一次模型漏人、第二次重试找回人员后，两个 guardrail 均读取最终解析结果；定向 parse 测试 `23/23`，后端全量 `109/109` 通过。
- 本轮没有新增后端编号；下列 `BACK-*` 均为既有未决项的第二轮确认，不重复上一轮已闭合项。
- `BACK-003/004/006/009/012/015/016/018` 当前仍未闭合。其中 `BACK-006/009/012` 的单实例或临时进程证据不能替代 CloudBase 多实例真实验证。
- 真实 CloudBase PostgreSQL、扩缩容/重启、生产运行时环境变量、真实迁移和网关限流本机均不可验证。本机没有 `CLOUDBASE_ENV_ID/CLOUDBASE_ENV`，按项目约定尝试 `./deploy/deploy.sh` 后在前置检查处以退出码 1 停止，未调用 CloudBase CLI、未改变线上状态。

| 编号 | 严重程度 | 当前状态 | 本轮证据结论 |
|---|---|---|---|
| BACK-003 | 严重 | 未闭合 | 设备、实名和日志作者仍有客户端自报路径；可伪造审计归因。 |
| BACK-004 | 严重 | 未闭合 | 管理闸门存在但名单/热词/随手记删除路由未统一接入。 |
| BACK-006 | 严重 | 未闭合 | 事件幂等与业务状态写入仍非同一原子操作；并发同 op 可重复建业务记录。 |
| BACK-009 | 严重 | 未闭合 | 新建警情仅有进程内串行队列，多实例仍存在检查-写入竞态。 |
| BACK-012 | 严重 | 未闭合 | 上游限流为进程内计数；ASR/parse/chat 在多实例没有共享预算。 |
| BACK-015 | 一般 | 未闭合 | 关键跨表关系和数值不变量主要依赖应用层，无数据库外键/CHECK。 |
| BACK-016 | 一般 | 未闭合 | PostgreSQL 列表全量查询并逐警情加载 forces，缺少服务端分页/批量投影。 |
| BACK-018 | 一般 | 未闭合 | CloudBase 迁移按语句逐条执行，无版本表、校验和或整体事务。 |
| R2-QA-002 | 严重 | 已修复 | 最终 `intent=entry/action=enter`，多人及压力值正确；见第 3 节。 |

## 2. 未决问题复核台账

### BACK-003：设备和操作者身份由客户端输入控制

- 严重程度：严重。
- 影响范围：审计归因、实名发布、设备设置、限流和离线补传；调用方可构造新的设备标识或提交不同实名，服务端无法证明真实操作者。
- 复现步骤或证据：
  1. `backend/src/server.js:142-144` 的 `deviceKey()` 直接取 `X-Device-Id`，只截断长度，没有签名、注册证明或会话绑定。
  2. `backend/src/server.js:227-238` 的 `actorName()` 在非生产环境回退请求体/请求头姓名；生产仍允许通过设备档案关联身份，而 `PUT /api/profile` 可由持有业务访问权限的调用方写入档案。
  3. 当前 `POST /api/notes` 路径仍优先使用请求体 `author`（`backend/src/server.js:1468-1490` 附近），不是服务端签发的成员身份；此前临时认证复现已得到“真实甲→冒用乙→伪造作者”的不同提交均被保存。
  4. 当前 `POST /api/logs` 虽忽略日志条目中的 `device` 字段，但仍使用客户端 `X-Device-Id` 作为服务端记录的设备值，不能证明设备本身。
- 根本原因：单位验证码是请求级门槛，不产生绑定单位、设备、成员和角色的服务端会话；设备 ID 和作者名同时承担了身份与展示字段职责。
- 涉及文件：`backend/src/server.js:142-144,227-238,824-829,1468-1490,1529-1570`；对应设备/用户设置仓储文件。
- 修改方案：认证成功签发短期、可撤销且绑定单位/设备的会话；作者仅取服务端成员档案，设备 ID 只作关联元数据；身份变更和会话轮换写入受保护审计事件。
- 修复状态：未修复；本轮只确认既有问题，没有改动该路径。
- 验证结果：临时进程复现了自报设备/作者的影响；尚未有真实设备注册、会话轮换或生产身份服务证据。

### BACK-004：高影响删除/修改接口缺少统一管理授权

- 严重程度：严重。
- 影响范围：全局消防员名单、全局热词、警情随手记和操作日志的删除/修改；普通单位成员可能影响共享配置或审计证据。
- 复现步骤或证据：
  1. `backend/src/server.js:196-200` 已定义 `WATCHDOG_MANAGEMENT_TOKEN`/`hasManagementToken()`，但管理闸门没有统一覆盖全部管理路由。
  2. `DELETE /api/firefighters/:id`、`DELETE /api/hotwords/:id`（当前约 `1339-1362`）直接调用删除仓储，没有管理令牌或实名角色校验。
  3. `DELETE /api/notes/:id`（当前约 `1455-1480`）只要求当前活动警情，不要求管理权限；`DELETE /api/logs` 当前已接入管理令牌，但其他破坏性端点未形成同一授权矩阵。
  4. 既有后端日志测试曾以普通测试请求成功清空当前警情日志；本轮静态复核确认该类负向授权测试仍未覆盖名单/热词/随手记全矩阵。
- 根本原因：认证、现场操作和管理角色没有分层；已有管理 token helper 未被所有高影响路由统一调用。
- 涉及文件：`backend/src/server.js:196-200,1339-1362,1455-1480,1573-1595`；相关 CRUD 测试文件。
- 修改方案：定义最小角色和统一管理中间件；名单/热词删除、笔记删除、日志清空统一要求管理角色、二次确认和审计；补齐普通成员 403 的负向回归。
- 修复状态：未修复；本轮没有修改管理路由。
- 验证结果：静态控制流确认；没有生产角色配置或真实管理令牌轮换证据。

### BACK-006：`X-Op-Id` 只覆盖事件，不覆盖业务状态原子幂等

- 严重程度：严重。
- 影响范围：网络重试、离线补传、进退场状态、压力采样、时间线和计数一致性。
- 复现步骤或证据：
  1. `backend/src/server.js:203-216,469-506,580-676` 通过事件查询/唯一键处理部分 op，但 entries、pressure_samples、notes 状态写入与事件写入仍是多个独立调用。
  2. 同一 `X-Op-Id` 并发提交进场的临时复现结果为两个请求均 `201`、业务 `entry` 数量为 2，而对应事件数量只有 1；说明事件去重没有回滚第二次业务写入。
  3. 同一 entry 同一 `X-Op-Id` 连续出场的既有复现中，两次返回的 `exited_at` 不同，事件虽只有一条；出场状态更新仍可重复发生。
- 根本原因：客户端 op ID 没有映射到“操作结果”表或数据库事务/RPC；业务资源写入和事件写入之间存在并发窗口。
- 涉及文件：`backend/src/server.js:469-506,580-676`；`backend/src/db-sqlite.js`、`backend/src/db-postgres.js` 的 entry/pressure/event 写入方法；`backend/migrations/001_initial.sql:95-110,151`。
- 修改方案：以 `(unit_id/incident_id, client_op_id)` 绑定请求哈希和完整业务结果；用数据库事务/RPC 同时创建/更新业务资源和事件，重复请求返回第一次完整结果，内容冲突返回 409。
- 修复状态：未修复；现有 `ensureOperationScope()` 只能拒绝跨警情复用，不能消除同警情并发竞态。
- 验证结果：临时并发复现确认；没有真实 CloudBase PostgreSQL 事务和多实例结果证据。

### BACK-009：新建警情冷却、编号和建档事件在多实例下仍非原子

- 严重程度：严重。
- 影响范围：CloudBase 多实例同时建档、冷却提示、警情编号唯一性和初始时间线。
- 复现步骤或证据：
  1. `backend/src/server.js:483-526` 通过 `incidentCreationQueue` 只在单 Node 进程内串行化检查、创建和 `incident_created` 事件。
  2. 代码注释已明确“多实例部署仍需数据库事务/RPC”；不同容器各自持有一个 queue，无法互斥。
  3. `backend/src/db-postgres.js:300-305,332-345` 的编号选择、冷却查询和 INSERT 仍是分离的网络数据库操作；没有数据库唯一业务闸门包住冷却检查与创建。
- 根本原因：应用层队列不是分布式锁；冷却检查、编号选择、incident INSERT、初始事件没有统一数据库事务或唯一约束。
- 涉及文件：`backend/src/server.js:483-526`；`backend/src/db-postgres.js:300-345`；`backend/src/db-sqlite.js` 对应创建方法；`backend/migrations/001_initial.sql:81-110`。
- 修改方案：由 CloudBase PostgreSQL 事务/RPC 完成单位冷却闸门、编号生成、警情和初始事件；编号依靠唯一约束冲突重试；增加两个独立服务进程并发建档测试。
- 修复状态：未修复；单实例队列属于局部缓解。
- 验证结果：本机只能由静态控制流确认；没有 CloudBase 多实例/扩缩容环境，不能验证最终竞态概率或数据库锁语义。

### BACK-012：昂贵上游接口缺少共享限流和并发预算

- 严重程度：严重。
- 影响范围：ASR、DeepSeek 解析/问答的费用、上游配额、CPU/内存和服务可用性。
- 复现步骤或证据：
  1. `backend/src/server.js:831-890`、`:890-925` 使用 `upstreamRateLimited()`；`backend/src/server.js` 中 `upstreamRateBuckets` 是进程内 `Map`，不是 CloudBase 共享存储或网关限流。
  2. `chatRateBuckets`（约 `979-1000`）同样是实例本地内存计数；虽然当前 key 使用 `req.ip + unit` 并有本地高基数清理，两个实例仍各有独立额度，跨实例请求可获得两份预算。
  3. ASR 转写使用 `req.on('data')` 收集请求并在上游调用前后记录日志；没有跨实例并发舱壁、队列、单位预算或费用熔断。上游响应/超时只能由单请求处理，不能限制全局并发。
- 根本原因：限流状态没有下沉到网关/共享 Redis 类存储；本地 Map 只能快速止损，不能作为多实例一致性和成本预算。
- 涉及文件：`backend/src/server.js:831-925,979-1030`；`backend/src/asr.js`；`backend/src/parse.js:42-74` 及聊天上游调用路径。
- 修改方案：在 CloudBase 网关或共享存储按单位/会话/IP实施滑动窗口；为 transcribe/parse/chat 分别设置并发舱壁、超时、队列和预算；保留实例内限流作为第二层，并监控拒绝率与上游费用。
- 修复状态：未修复；当前改动只改善了实例内 key 生命周期和来源维度。
- 验证结果：代码证据确认多实例限流不共享；没有真实网关、扩缩容或上游配额压测，未调用真实 ASR/DeepSeek。

### BACK-015：数据库缺少外键和关键业务约束

- 严重程度：一般。
- 影响范围：迁移/维护脚本、PostgREST service role 直写、清理任务和未来新增接口；可能出现孤儿事件、孤儿 pressure sample 或非法压力/计数。
- 复现步骤或证据：
  1. `backend/migrations/001_initial.sql:54-70,97-130` 将 `pressure_samples.entry_id`、`incident_events.incident_id`、`incident_forces.incident_id` 定义为普通 `TEXT NOT NULL`，没有 `REFERENCES` 外键。
  2. 同一迁移没有对压力范围、消耗率范围、车辆/人员非负等核心数值建立 CHECK；SQLite DDL（`backend/src/db-sqlite.js:35-145`）也主要依赖应用校验。
  3. PostgreSQL 删除 entries 与 pressure samples 是分开的网络操作（`backend/src/db-postgres.js:181-192`），数据库本身不能保证相关行同步清理。
- 根本原因：schema 未表达实体关系和业务不变量，且 service role 可对全表执行 DML，约束责任集中在 Express 路由。
- 涉及文件：`backend/migrations/001_initial.sql`、`backend/migrations/002_units.sql`；`backend/src/db-sqlite.js`、`backend/src/db-postgres.js`。
- 修改方案：在历史数据清理和迁移策略明确后补齐外键、索引与数值 CHECK；定义级联/保留策略；跨表操作使用事务并增加孤儿扫描。
- 修复状态：未修复；本轮不执行生产 schema 变更。
- 验证结果：静态 schema 证据确认；没有对真实 CloudBase 数据库执行查询或权限/约束变更。

### BACK-016：警情列表无服务端分页且存在 N+1 远程查询

- 严重程度：一般。
- 影响范围：警情和参战力量增长后的列表延迟、PostgREST 请求量、连接占用和冷启动；归档历史越多越明显。
- 复现步骤或证据：
  1. `backend/src/db-postgres.js:320-329` 先查询满足状态的全部 incidents，再在 Node 进程按单位过滤和排序，没有数据库 limit/offset。
  2. `backend/src/server.js:406-426,444-446` 对每条结果执行 `incidentView()`，其中再调用 `db.listIncidentForces(incident.id)`；归档无标题还会读取事件并回写建议标题，形成 per-incident 远程查询/写入。
  3. 本机代码审查确认该调用图；没有生产警情规模或 PostgREST latency 数据，不能量化阈值。
- 根本原因：列表接口把完整详情投影、标题补全和历史集合一次性耦合，PostgreSQL 适配器仍使用全量读取后应用层过滤。
- 涉及文件：`backend/src/server.js:406-446`；`backend/src/db-postgres.js:320-407`；`backend/src/db-sqlite.js:652-739`。
- 修改方案：列表使用服务端分页、字段投影和按单位过滤；forces 使用批量查询/聚合，详情按需加载；建议标题改为后台任务；制定 incident/event 留存策略。
- 修复状态：未修复。
- 验证结果：静态控制流确认；没有 CloudBase 远程请求量、响应分位数或大数据集压测。

### BACK-018：CloudBase 迁移无版本记录、校验和和整体事务

- 严重程度：一般。
- 影响范围：CloudBase PostgreSQL 初始化/升级；网络中断或单条 DDL 失败后可能留下半套 schema，重跑和回滚缺少可追踪状态。
- 复现步骤或证据：
  1. `backend/scripts/migrate-cloudbase.js:37-50` 按文件名扫描 SQL，拆成 statements 后逐条调用 `database.executePGSql({ Sql: statement })`。
  2. `:54-57` 失败时只设置进程退出码，既没有 `schema_migrations` 记录、版本/校验和，也没有将此前成功的语句回滚。
  3. 本机执行 `npm run db:migrate` 在缺少 `CLOUDBASE_ENV_ID/CLOUDBASE_SECRET_ID/CLOUDBASE_SECRET_KEY` 时按预期前置失败；不能把该失败当成迁移正确性的证明。
- 根本原因：将文件排序代替迁移状态、将逐语句成功代替整体成功；CloudBase 执行接口没有在脚本层被组织成可恢复迁移流程。
- 涉及文件：`backend/scripts/migrate-cloudbase.js`；`backend/migrations/001_initial.sql`、`002_units.sql`、`003_entry_calc_params.sql`。
- 修改方案：引入迁移记录表、版本/校验和与向前升级策略；在 CloudBase 能力允许时使用事务，否则拆分可恢复阶段并记录已应用语句/版本；应用启动前做 schema 版本检查。
- 修复状态：未修复；本轮未连接真实数据库或执行 DDL。
- 验证结果：脚本静态证据确认；真实 CloudBase 失败注入、部分提交和重跑恢复无法本机验证。

## 3. R2-QA-002 本次修复与回归验收

- 严重程度：严重；原问题是多人压力文本重试成功后，输出 `people` 已更新，但 `guardrailIntent/guardrailAction` 仍读取首次 `parsed` 快照。
- 修改文件（本次代码/测试写集）：
  - `backend/src/parse.js:199-228`：先构造带规范化人员列表的 `finalParsed`；重试找回更多人员时以重试响应和最终 `people` 更新它；两个 guardrail 及返回 `note` 使用最终对象。
  - `backend/test/parse.test.js:80-112`：新增回归用例。第一次 mock 返回空 `people` 且故意给出 `action=exit`，第二次返回张伟/李娜及 20/22MPa；断言调用两次、`intent=entry`、`action=enter`、人员顺序和压力值。
- 修复状态：已修复；没有修改其他源码或测试文件，没有回滚既有工作区改动。
- 验证结果：
  - `cd /Users/vavavoom/Documents/WatchDog/backend && NODE_ENV=test node --test test/parse.test.js`：退出码 0，`23/23` 通过。
  - `cd /Users/vavavoom/Documents/WatchDog/backend && npm test`：退出码 0，`109/109` 通过，`fail 0`。
  - `node --check src/parse.js`：通过；`git diff --check`：通过。
  - 回归输出确认：`calls=2`、`intent=entry`、`action=enter`、`people=[张伟(20), 李娜(22)]`。

## 4. CloudBase 边界与不可本机验证事项

### 多实例

- 业务状态幂等、警情创建队列、上游限流和聊天限流均至少有一部分进程内状态/检查；多个 CloudBase 容器不会共享 Node `Map` 或 `incidentCreationQueue`。
- 本机做过两个独立进程的认证限流尝试：轮换/分发请求后可分别命中各自进程的计数窗口（结果为 12 次请求中 `[403 × 10, 429, 429]` 的实例分散表现），这只能证明本机进程隔离，不能证明 CloudBase 网关实际路由策略。
- 未能验证：两个真实服务实例同时创建同单位警情、同 op 进场/出场、同时归档、扩缩容期间请求路由及共享限流/事务语义。

### 迁移与数据库

- 本地 SQLite 单测和迁移测试通过，不等同于 CloudBase PostgreSQL schema、RLS、索引/唯一约束和 PostgREST 返回形状通过。
- `001_initial.sql` 启用多表 RLS，但没有对应 `CREATE POLICY`；同时向 `service_role` 授予全表 DML。该结论是纵深控制缺口，不在本轮新增编号，也没有对生产数据库作权限变更。
- 未能验证：真实 CloudBase SQL 执行权限、迁移部分失败后的数据库状态、回滚/重跑、RLS/service-role 实际访问和备份恢复。

### 鉴权边界

- 当前 `API_TOKEN` 中间件在 `backend/src/server.js:96-101` 对 `/api/auth/verify` 放行；认证处理器依靠单位名称/验证码建立设备档案。若客户端/部署契约要求认证请求也携带 API token，则该入口仍是边界不一致项；本轮不擅自改变产品规则。
- 生产启动已对缺失 `API_TOKEN`、生产 SQLite 回退和关闭单位认证做 fail-fast 检查（`backend/src/server.js:21-30`、`backend/src/db.js:1-7`），但这些只证明进程启动配置检查，不证明 CloudBase 运行时最终变量已正确注入。
- 未能验证：真实网关是否覆盖/改写 `X-Forwarded-For`，线上 API token/unit code 的轮换，生产设备会话，CloudBase service role 的最小权限及真实日志脱敏。

## 5. 验证记录与下一步

| 项目 | 结果 |
|---|---|
| parse 定向测试 | 通过，23/23 |
| backend 全量测试 | 通过，109/109 |
| parse 语法检查 | 通过 |
| 差异空白检查 | 通过 |
| 正式 CloudBase 部署 | 未执行；`./deploy/deploy.sh` 因缺少 `CLOUDBASE_ENV_ID/CLOUDBASE_ENV` 退出码 1，未发生线上变更 |
| CloudBase 真实迁移/多实例/鉴权 | 未验证，需具备隔离预生产权限和可回收测试数据后执行 |

建议主 Agent 下一轮按严重程度先处理 `BACK-003/004/006/009/012`，每项补充跨进程/数据库故障注入回归，再处理 `BACK-015/016/018` 的 schema、查询和迁移治理；在预生产完成 CloudBase contract/multi-instance smoke 后，才可关闭本轮“不可验证”项。
