# WatchDog 后端与架构组只读审查

审查日期：2026-08-27
审查对象：当前工作树（含审查开始前已存在的未提交改动）
审查方式：只读静态审查、现有测试、临时目录上的最小运行复现；未修改源码、测试或部署配置。

## 基线结果

- `backend/` 下 `npm test`：102 个用例通过，0 失败。
- `backend/src/*.js` 关键文件：`node --check` 通过。
- `deploy/deploy.sh`：`bash -n` 通过；`CLOUDBASE_ENV_ID=audit-dry-run deploy/deploy.sh --dry-run` 能生成部署包并打印部署命令，未调用 CloudBase。
- 测试通过不代表生产 PostgreSQL、多实例并发、真实 CloudBase 迁移和真实上游 ASR/LLM 已验证；对应未验证项见文末。

## 问题总览

本轮记录 20 项问题：阻断 0 项、严重 15 项、一般 4 项、优化 1 项。

## 问题台账

### BACK-001：未归属历史警情对所有单位开放，破坏单位隔离

- 严重程度：严重
- 影响范围：多单位部署中的警情列表、警情详情、时间线、参战力量、进退场、随手记和操作日志；历史 `unit_id IS NULL` 数据可能被其他单位读取或写入。
- 复现步骤或证据：
  1. `backend/src/server.js:123-129` 的 `incidentForRequest` 只有在 `incident.unit_id` 非空且不相等时才拒绝；`unit_id` 为空的记录直接放行。
  2. `backend/src/server.js:289-294` 使用按单位列警情接口，但实际筛选委托给数据库适配器。
  3. PostgreSQL 适配器 `backend/src/db-postgres.js:320-329` 用 `!row.unit_id || row.unit_id === unitId`，SQLite 适配器 `backend/src/db-sqlite.js:625-629`、`652-669` 也用 `unit_id = ? OR unit_id IS NULL`。
  4. 临时数据库复现：创建一条 `unit_id=NULL` 的 `legacy-null-unit`，分别用单位 A 和单位 B 的合法认证头请求 `/api/incidents`，两次结果均包含该警情（`legacyVisibleToUnitA=true`、`legacyVisibleToUnitB=true`）。
- 根本原因：为兼容旧数据而把“未归属”解释为“所有单位可见”，但没有建立隔离的 legacy 命名空间、管理员迁移流程或只读边界；同一放行逻辑也覆盖详情和写接口。
- 涉及文件：`backend/src/server.js:123-129,289-294`；`backend/src/db-postgres.js:320-329`；`backend/src/db-sqlite.js:625-629,652-669`；`backend/migrations/002_units.sql:12-18`。
- 建议修改方案：普通单位请求对 `unit_id IS NULL` 一律不可见、不可写；为历史数据建立明确的迁移归属或独立 legacy 租户，并增加管理员专用读取接口；所有按 ID 的读写查询在数据层也带上单位条件，避免只依赖路由层检查。
- 修复状态：待修复
- 验证结果：待验证

### BACK-002：生产迁移固定写入公开的单位验证码，且认证接口无暴力破解防护

- 严重程度：严重
- 影响范围：单位认证、所有业务 API 的入口保护；部署过 `002_units.sql` 的生产数据库默认存在已写入仓库和 README 的 `0570` 凭据。
- 复现步骤或证据：
  1. `backend/migrations/002_units.sql:23-26` 每次执行迁移都会插入 `longyou-county-fire-rescue / 龙游县消防救援大队 / 0570`，仅按 `id` 冲突忽略；没有环境判断或首次部署时强制替换逻辑。
  2. `deploy/cloudbase/README.md:43-56` 把该单位和验证码放在生产运行变量/部署说明附近，但迁移中的值并不受这些运行变量控制。
  3. `backend/src/server.js:245-257` 的 `/api/auth/verify` 没有按 IP、设备、单位或时间窗限流/锁定；错误验证码可以无限次尝试。
  4. `backend/src/server.js:74-81` 在 `API_TOKEN` 为空时直接跳过共享 Token 校验，因此配置遗漏时只剩单位认证这一层；服务不会启动失败提醒。
- 根本原因：测试种子凭据进入版本化生产迁移，认证采用可重复提交的明文短验证码，没有一次性会话、轮换或失败退避；API Token 和单位认证均允许 fail-open。
- 涉及文件：`backend/migrations/002_units.sql:23-26`；`deploy/cloudbase/README.md:43-56`；`backend/src/server.js:21-24,74-81,245-257`；`backend/.env.example:42-49`。
- 建议修改方案：生产迁移不得写入固定测试凭据；单位凭据改为部署时安全注入并存储哈希，强制首次初始化/轮换；认证接口增加限流、失败退避和审计；生产启动时缺失 `API_TOKEN` 或单位初始化配置应 fail-fast，测试环境通过显式测试配置单独放行。
- 修复状态：待修复
- 验证结果：待验证

### BACK-003：设备和操作者身份完全由客户端请求头/请求体自报，无法证明身份或防止冒用

- 严重程度：严重
- 影响范围：审计归因、实名发布、设备设置、限流、警情管理、离线补传；持有单位认证信息的调用方可伪造任意设备和操作者姓名。
- 复现步骤或证据：
  1. `backend/src/server.js:119-121` 直接接受并截断 `X-Device-Id`，没有签名、格式校验或与认证会话绑定。
  2. `backend/src/server.js:146-151` 优先信任请求体 `actor_name`、`X-Actor-Name`、`X-Actor-Name-B64`，只有没有提交值时才读取设备档案。
  3. `backend/src/server.js:1149-1158` 对随手记也明确优先接受请求体 `author`；测试 `backend/test/notes.test.js:135-163` 证明任意提交作者名会被保存。
  4. `backend/src/server.js:256-257,630-635` 将客户端提供的设备标识用于档案和实名保存；没有服务端签发的会话/成员身份或角色。
- 根本原因：`X-Device-Id` 被当作身份而非不可信关联字段，单位验证码只在请求级校验，不产生会话；操作者姓名是可篡改的展示字段。
- 涉及文件：`backend/src/server.js:98-113,119-121,146-151,245-257,630-635,1149-1158`；`backend/test/notes.test.js:135-163`。
- 建议修改方案：认证成功后签发短期、可撤销且绑定单位/设备的服务端会话；服务端从会话确定成员身份，作者名只能来自服务端档案；把设备 ID 作为关联元数据而非认证凭据，并对身份变更和会话轮换留审计记录。
- 修复状态：待修复
- 验证结果：待验证

### BACK-004：高影响删除/修改接口没有角色或实名管理授权

- 严重程度：严重
- 影响范围：操作日志审计证据、全局消防员名单、全局热词、警情随手记；任一通过当前单位认证的设备均可执行部分破坏性操作。
- 复现步骤或证据：
  1. `backend/src/server.js:153-169` 定义了 `management` 实名闸门，但全文件没有路由传入 `{ management: true }`。
  2. `backend/src/server.js:1097-1100`、`1118-1121` 的名单/热词删除路由没有操作者校验。
  3. `backend/src/server.js:1211-1228` 删除随手记只校验警情和活动状态，不校验实名或角色。
  4. `backend/src/server.js:1324-1332` 可按警情或 `op_id` 清空操作日志，且没有实名/角色检查；该日志包含服务端埋点和客户端诊断记录。
  5. `backend/test/logs.test.js:104-109` 证明普通测试请求即可清空当前警情全部日志。
- 根本原因：认证、成员身份和管理授权没有分层；部分路由手动检查实名，部分路由未检查，已定义的统一管理闸门未被使用。
- 涉及文件：`backend/src/server.js:153-169,1097-1100,1118-1121,1211-1228,1324-1332`；`backend/test/logs.test.js:104-109`。
- 建议修改方案：定义只读成员、现场操作员、警情管理员等最小角色；删除日志应默认禁用或仅允许受控维护接口，至少要求管理角色、二次确认和审计；所有名单/热词/笔记删除统一走授权中间件并增加负向测试。
- 修复状态：待修复
- 验证结果：待验证

### BACK-005：多个 Express 4 异步路由未把数据库异常交给错误处理中间件

- 严重程度：严重
- 影响范围：生产 PostgreSQL 网络故障、超时、权限错误时，部分请求会挂起并产生未处理 Promise rejection，影响服务稳定性。
- 复现步骤或证据：
  1. `backend/package.json:16-18` 使用 Express 4；Express 4 不会自动把 `async` handler 返回的 rejected Promise 传给 `next`。
  2. 以下路由直接 `await` 数据库调用但没有 `try/catch` 或 async wrapper：`backend/src/server.js:618`、`630-635`、`901-906`、`1081`、`1102`、`1130-1139`、`1237-1242`、`1311-1322`、`1324-1332`。
  3. 最小运行复现中将 `db.listFirefighters` 替换为抛出 `simulated database outage` 的 Promise，请求 `/api/firefighters` 在 300ms 内超时，同时进程收到 `unhandledRejection: simulated database outage`；统一错误处理中间件没有收到该异常。
- 根本原因：路由错误处理风格不一致，只有部分路由包裹 `try/catch`；生产适配器是异步 HTTP 数据库调用，异常不是同步抛出可由 Express 4 捕获的类型。
- 涉及文件：`backend/src/server.js:618-635,901-906,1081-1102,1130-1139,1237-1242,1311-1332`；`backend/package.json:16-18`。
- 建议修改方案：统一使用可靠的 async handler wrapper 或升级到明确支持 Promise handler 的 Express 版本；所有异步路由都经 `next` 进入统一错误处理，并增加数据库超时/拒绝的 HTTP 回归测试。
- 修复状态：待修复
- 验证结果：待验证

### BACK-006：`X-Op-Id` 只使事件插入幂等，不能使业务状态变更幂等

- 严重程度：严重
- 影响范围：网络重试、后台补传、进退场计数、出场时间、压力采样和时间线一致性。
- 复现步骤或证据：
  1. `backend/src/server.js:908-980` 创建进场记录时没有先按 `X-Op-Id` 查找既有业务结果，只在 `appendEvent` 时把同一 op 写入事件。
  2. `backend/src/server.js:1056-1073` 出场路由每次都先调用 `db.markExited`，随后才追加幂等事件；`backend/src/db-sqlite.js:393-396` 和 `backend/src/db-postgres.js:119-122` 的更新没有 `exited_at IS NULL` 条件。
  3. `backend/src/server.js:988-1048` 压力复核每次都新增压力采样并更新记录，也没有用 op 结果短路。
  4. 临时复现：同一 entry、同一 `X-Op-Id=exit-idem` 连续出场两次，第一次和第二次返回的 `exited_at` 不同，时间线仍只有 1 条 exit 事件。
- 根本原因：事件表上的去重与 `entries`/`pressure_samples`/`notes` 的状态写入不在同一原子操作内；路由把 op ID 只当作事件字段。
- 涉及文件：`backend/src/server.js:908-980,988-1048,1056-1073`；`backend/src/db-sqlite.js:393-396,749-767`；`backend/src/db-postgres.js:119-122,413-439`；`backend/migrations/001_initial.sql:95-108,149`。
- 建议修改方案：建立服务端操作结果表或数据库 RPC，以 `(单位/警情, 客户端操作 ID)` 唯一约束包住业务变更和事件写入；重复请求返回第一次完整结果；为请求体建立哈希，检测同一 op 被不同内容重用。
- 修复状态：待修复
- 验证结果：待验证

### BACK-007：离线补传按全局 `client_op_id` 去重，没有校验警情和操作类型

- 严重程度：严重
- 影响范围：离线进场、出场、压力复核、随手记的补传；同一 op ID 被复用或碰撞时，当前警情操作会被静默吞掉。
- 复现步骤或证据：
  1. `backend/src/server.js:422-432` 在处理 `/offline-operations` 时只调用 `db.getIncidentEventByClientOp(opId)`，发现任意警情已有该 ID 就直接返回 `accepted: true, duplicate: true`。
  2. 两个适配器均按全局字段查询：`backend/src/db-sqlite.js:749-752`、`backend/src/db-postgres.js:413-416`；迁移还建立了全局唯一索引 `backend/migrations/001_initial.sql:149`。
  3. 临时复现：先在 incident A 写入 `client_op_id=reused-op` 的 note，再向 incident B 补传同 ID 的 entry；接口返回 accepted duplicate，`entriesInB=0`，返回的 `event_id` 属于 incident A。
- 根本原因：幂等键查询缺少当前 `incident_id`、操作类型和请求内容绑定；重复被当成成功，而不是检测到跨警情冲突。
- 涉及文件：`backend/src/server.js:410-487`；`backend/src/db-sqlite.js:749-767`；`backend/src/db-postgres.js:413-439`；`backend/migrations/001_initial.sql:95-108,149`。
- 建议修改方案：校验重复事件必须属于当前警情且类型/请求哈希一致；不一致返回 409 并保留冲突审计；数据库约束和查询统一采用正确的租户/警情作用域，并把业务资源创建与事件插入放入同一事务/RPC。
- 修复状态：待修复
- 验证结果：待验证

### BACK-008：每条记录的自定义气瓶容量没有持久化，压力复核会按默认 6.8L 重算

- 严重程度：严重
- 影响范围：气瓶剩余时间、退出时间、压力复核和安全提醒；不同容量气瓶会得到错误倒计时。
- 复现步骤或证据：
  1. `backend/src/server.js:920-957` 接收 `volume_l` 并用它计算首次 `durationMin/exitAtMs`，但 `db.createEntry` 没有容量参数。
  2. `backend/migrations/001_initial.sql:4-17`、`backend/src/db-sqlite.js:29-40` 的 `entries` 表没有 `cylinder_vol_l` 列。
  3. `backend/src/server.js:1013-1025` 压力复核的实测耗气率和计算参数使用 `CFG.calc.cylinderVolL`，没有读取首次请求的自定义容量；离线压力复核 `backend/src/server.js:464-473` 同样只用默认参数。
  4. 临时复现：首次以 `volume_l=10, pressure_mpa=20` 创建，返回 25 分钟；随后压力复核到 10MPa 返回 9 分钟，而 10L、80L/min 的正确结果应为约 13 分钟。
- 根本原因：请求级计算参数没有成为 entry 的持久化领域字段，复核流程只能回落到全局默认配置。
- 涉及文件：`backend/src/server.js:908-960,1009-1033,464-473`；`backend/src/db-sqlite.js:29-40,383-410`；`backend/src/db-postgres.js:110-141`；`backend/migrations/001_initial.sql:4-17`。
- 建议修改方案：在 entries 中保存实际容量和实际消耗率来源；压力复核、离线补传、统计和返回值统一使用记录级参数；补充自定义容量的在线/离线回归测试。
- 修复状态：待修复
- 验证结果：待验证

### BACK-009：新建警情的冷却检查、编号生成和建档事件不是原子操作，多实例下会竞态

- 严重程度：严重
- 影响范围：CloudBase 多实例部署中的重复警情、错误的冷却提示、编号冲突、缺少建档事件和客户端拿到错误档案。
- 复现步骤或证据：
  1. `backend/src/server.js:305-331` 先查 op、再查最近警情、再创建 incident、最后追加 `incident_created`，整个流程没有事务或分布式锁。
  2. PostgreSQL `backend/src/db-postgres.js:291-305` 先循环查询可用编号，再单独插入；两个实例可同时选中同一编号。
  3. `backend/src/db-postgres.js:332-345` 的冷却查询和 `backend/src/db-postgres.js:300-305` 的写入之间没有数据库唯一业务闸门。代码注释 `server.js:311` 声称“串行执行”，但实现没有提供跨实例串行化。
  4. 同一 op 的两个并发请求都可能在 `backend/src/server.js:306` 查不到旧事件后各自创建 incident；后续事件唯一约束只会让事件去重，不能撤销已经创建的第二个 incident。
- 根本原因：检查-写入-事件没有数据库事务、唯一业务约束或分布式互斥；生产使用网络 PostgreSQL 时 `await` 会放大并发窗口。
- 涉及文件：`backend/src/server.js:300-332`；`backend/src/db-postgres.js:291-345`；`backend/src/db-sqlite.js:148-157,632-638`；`backend/migrations/001_initial.sql:79-93,95-108`。
- 建议修改方案：使用数据库事务/RPC 完成“同单位冷却闸门 + 建档 + 建档事件”，由数据库返回已存在结果；编号采用数据库序列/唯一冲突重试；增加多实例并发测试，禁止用应用层注释代替锁。
- 修复状态：待修复
- 验证结果：待验证

### BACK-010：PostgreSQL 的活动时间更新会丢失较新的并发值，自动归档还会重复写事件

- 严重程度：严重
- 影响范围：12 小时自动归档、现场活跃警情可见性、未离场人数和时间线；并发设备操作可能使警情被提前归档或产生重复归档事件。
- 复现步骤或证据：
  1. PostgreSQL `backend/src/db-postgres.js:372-377` 先读取当前 `last_activity_at`，在进程内计算 `Math.max`，随后无条件按 `id` 更新。两个请求 A/B 都读到旧值时，B 先写入较新时间、A 后写入较旧时间，A 可覆盖 B；SQLite 使用 SQL `MAX`（`backend/src/db-sqlite.js:702-706`），两种适配器行为不一致。
  2. `backend/src/db-postgres.js:395-405` 先查询 stale 列表，再逐条归档并追加没有 `client_op_id` 的 `incident_archived` 事件。多个实例或重入执行可各自看到同一 stale 行，并重复追加事件；`archiveIncident` 的条件更新结果为空时仍会重新读取已归档行并继续追加。
  3. `/api/incidents` 每次列表请求都会调用归档扫描（`backend/src/server.js:290-294`），进程启动后还会定时扫描（`backend/src/server.js:1347-1393`），扩大重入机会。
- 根本原因：活动时间没有数据库原子 `GREATEST/MAX` 更新，归档扫描没有“只成功归档者写事件”的返回语义，也没有分布式锁或唯一自动归档事件。
- 涉及文件：`backend/src/db-postgres.js:372-407`；`backend/src/db-sqlite.js:702-738`；`backend/src/server.js:290-294,1347-1393`。
- 建议修改方案：PostgreSQL 使用 `SET last_activity_at = GREATEST(last_activity_at, $at)` 的条件更新；归档采用带状态条件的单条更新并仅由获得更新行的调用方写事件，或使用数据库函数/锁；扫描任务集中化并增加重复执行回归测试。
- 修复状态：待修复
- 验证结果：待验证

### BACK-011：数据库初始化失败后服务不会自愈，且健康检查仍返回 HTTP 200

- 严重程度：严重
- 影响范围：CloudBase/Cloud Run 实例生命周期、自动重启和上线判定；数据库不可用时平台可能认为服务健康而不重启。
- 复现步骤或证据：
  1. `backend/src/db-postgres.js:55-87` 只在模块加载时执行一次 `initialize()`；`backend/src/database-readiness.js:14-25` 记录失败但没有重试机制。
  2. `backend/src/server.js:85-93` 对业务请求返回 `503`，但 `backend/src/server.js:225-233` 的 `/api/health` 无论 `ready/databaseReady` 是否为 false 都返回 `ok:true` 和 HTTP 200。
  3. 用拒绝所有数据库 fetch 的临时驱动启动服务，等待初始化失败后请求 `/api/health`，实际返回 `status=200, {ok:true, ready:false, databaseReady:false}`；`deploy/deploy.sh:79-80` 的 `curl --fail` 因此不会失败。
- 根本原因：为了避免冷启动期间探活失败而让健康接口始终 200，但没有区分“正在初始化”和“初始化永久失败”，也没有失败后的重试/退出策略。
- 涉及文件：`backend/src/db-postgres.js:55-87`；`backend/src/database-readiness.js:6-47`；`backend/src/server.js:85-93,225-233`；`deploy/deploy.sh:79-80`。
- 建议修改方案：探活区分 startup/readiness/liveness；初始化失败在有限重试后让 liveness 失败或安全退出触发平台重启；部署健康检查必须验证数据库 readiness，而非只验证 HTTP 进程存活。
- 修复状态：待修复
- 验证结果：待验证

### BACK-012：昂贵上游接口缺少统一限流，聊天限流器可被伪造设备 ID 绕过并无限增长

- 严重程度：严重
- 影响范围：ASR/LLM 成本、上游配额、服务 CPU/内存和可用性；合法单位凭据或泄露的 API Token 可发起大量转写/解析请求。
- 复现步骤或证据：
  1. `backend/src/server.js:637-684` 的 `/api/transcribe` 和 `686-709` 的 `/api/parse` 没有 IP、设备、单位或全局速率/并发上限；仅有音频体积和 JSON 总体积限制。
  2. 聊天只使用进程内 Map：`backend/src/server.js:768-801`；`X-Device-Id` 来自 `backend/src/server.js:119-121`，调用方可以每次换一个值绕过单 key 的 10 次/分钟限制。
  3. `chatRateBuckets` 从不清理旧 key；每个新设备 ID 都永久保留到进程重启，持续轮换请求会造成内存增长。多实例时每个实例还有独立额度，限流不一致。
- 根本原因：限流没有下沉到共享存储/网关，也没有并发舱壁和 key 生命周期；把客户端自报 ID 当作可靠限流身份。
- 涉及文件：`backend/src/server.js:119-121,637-709,768-801`；`backend/src/asr.js:124-239`；`backend/src/parse.js:42-74,231-355`。
- 建议修改方案：在网关/共享存储按单位、会话、设备和 IP 实施滑动窗口及并发限制；对 ASR/parse/chat 分别配置超时、队列和预算；聊天桶按时间清理并设置最大 key 数，不能依赖客户端可伪造 ID。
- 修复状态：待修复
- 验证结果：待验证

### BACK-013：进场记录和解析输入缺少字段级长度/类型上限，用户输入可放大数据库和上游成本

- 严重程度：严重
- 影响范围：数据库容量、PostgreSQL 网络 payload、LLM token 成本、日志容量和请求延迟。
- 复现步骤或证据：
  1. `backend/src/server.js:49` 只设置 JSON body 总上限 5MB；`686-704` 对 `/api/parse` 的 `text` 只检查非空，没有字符长度上限，随后原样写入日志并发送 DeepSeek。
  2. `backend/src/server.js:914-960` 对 entry 的 `name`、`source`、`raw_text` 没有字段长度限制；`raw_text` 还被同时写入 entries（`backend/src/db-postgres.js:110-117` / `backend/src/db-sqlite.js:383-390`）和服务端操作日志（`server.js:961-970`）。
  3. 离线 entry `backend/src/server.js:444-455` 也接受 `payload.raw_text`，没有单条大小限制。
- 根本原因：只做了请求级 body 限制，没有针对高频/持久化/上游字段做 schema 校验；原始语音文本在多个存储位置重复保存。
- 涉及文件：`backend/src/server.js:49,686-709,908-970,410-487`；`backend/src/db-postgres.js:110-117,191-195`；`backend/src/db-sqlite.js:383-390,477-482`。
- 建议修改方案：引入统一请求 schema；为姓名、来源、raw text、解析文本分别设小而明确的字符/字节上限，拒绝而不是截断关键业务字段；对 LLM 请求设置 token/并发预算，并避免原文在 entry 与日志重复存储。
- 修复状态：待修复
- 验证结果：待验证

### BACK-014：ASR/解析原文及识别结果持久化进操作日志，且普通警情成员可查询

- 严重程度：严重
- 影响范围：消防员姓名、现场语音转写、压力/警情内容、LLM 结构化结果和可能的敏感现场信息；日志保留期内扩大了可读取副本。
- 复现步骤或证据：
  1. `backend/src/server.js:672` 把完整 ASR `text` 放进 `asr_done` 日志；`686-704` 把完整解析输入和结果放入 `parse_req/parse_done`；`961-970` 将 entry 的 `raw_text` 放入日志数据。
  2. `backend/src/server.js:191-215` 的 `logOp` 把数据写进数据库，`backend/src/db-sqlite.js:477-482` / `db-postgres.js:191-195` 序列化保存。
  3. `backend/src/server.js:1310-1321` 向当前警情的普通 API 调用方返回日志数据；`backend/src/server.js:1361-1369` 默认保留 30 天。
- 根本原因：诊断链路直接复用业务原文，没有敏感字段分级、脱敏、最小化或按角色控制；日志查询和现场业务权限相同。
- 涉及文件：`backend/src/server.js:672-704,961-970,1310-1321,1361-1369`；`backend/src/db-sqlite.js:477-509`；`backend/src/db-postgres.js:191-205`。
- 建议修改方案：默认只记录长度、哈希、错误码和必要摘要；原文单独加密/短期留存并严格限权，或完全不入云端日志；日志接口与现场数据分离授权，补充脱敏和留存期测试。
- 修复状态：待修复
- 验证结果：待验证

### BACK-015：数据库没有外键和关键业务约束，数据一致性依赖路由代码

- 严重程度：一般
- 影响范围：迁移/维护脚本、未来新接口、PostgREST service_role 操作和清理任务；可能出现孤儿事件、孤儿参战力量、压力采样与 entry 不一致。
- 复现步骤或证据：
  1. `backend/migrations/001_initial.sql:95-129` 的 `incident_events.incident_id`、`incident_forces.incident_id`、`pressure_samples.entry_id` 都是普通 `TEXT`，没有 `REFERENCES`。
  2. `backend/migrations/001_initial.sql:4-17,118-129` 也没有压力范围、耗气率范围或计数非负等数据库 CHECK 约束；SQLite 对应表定义 `backend/src/db-sqlite.js:29-41,81-89,123-137` 同样如此。
  3. `backend/src/db-postgres.js:181-189`、`backend/src/db-sqlite.js:462-475` 分开删除 entries 和 pressure_samples，事件不会随 entry 清理；一致性完全依赖应用调用顺序。
- 根本原因：schema 只表达了部分状态枚举和唯一键，没有表达实体关系与安全数值不变量；数据层接口也允许直接按 ID 操作。
- 涉及文件：`backend/migrations/001_initial.sql:4-17,52-69,79-129`；`backend/src/db-sqlite.js:29-41,81-89,123-139`；`backend/src/db-postgres.js:181-189`。
- 建议修改方案：在可接受的历史迁移策略下补齐外键、索引和数值 CHECK；明确 purge 时的级联/保留策略；将跨表写入放入事务或数据库函数，并用孤儿扫描作为维护检查。
- 修复状态：待修复
- 验证结果：待验证

### BACK-016：警情列表无分页且存在 N+1 远程查询/写入，历史档案也没有清理边界

- 严重程度：一般
- 影响范围：警情数量增长后的列表延迟、PostgREST 请求量、数据库连接/上游限流和冷启动；归档列表越大越明显。
- 复现步骤或证据：
  1. `backend/src/db-postgres.js:320-329` 读取满足状态的全部 incidents，再在 Node 中按单位过滤和排序，没有 limit/offset。
  2. `backend/src/server.js:268-277` 的 `incidentView` 每条警情读取参战力量；无标题归档还会读取事件并更新 suggested title；`server.js:290-294` 用 `Promise.all` 对全量结果执行。
  3. `backend/src/db-postgres.js:395-407` 和 `backend/src/server.js:1347-1393` 只清理 logs/notes/chat/已出场 entry，没有 incidents/incident_events 的归档保留或分页策略。
- 根本原因：列表 API 与详情投影耦合，历史档案作为无限增长集合返回；PostgreSQL 适配器为了兼容 NULL 单位选择了应用层全量过滤。
- 涉及文件：`backend/src/server.js:268-294`；`backend/src/db-postgres.js:320-329,395-407`；`backend/src/db-sqlite.js:652-680,723-739`。
- 建议修改方案：列表接口使用服务端分页和字段投影，详情按需加载 forces/timeline；标题生成改为一次性后台任务或批量查询；制定事件/档案留存策略，避免全量扫描。
- 修复状态：待修复
- 验证结果：待验证

### BACK-017：部署后的健康检查固定指向当前生产 URL，无法验证自定义目标

- 严重程度：严重
- 影响范围：换环境、换服务名、预发布或灾备部署；脚本可能部署到 A 服务后检查旧的生产 B 服务，并错误输出部署成功。
- 复现步骤或证据：
  1. `deploy/deploy.sh:10-13` 允许 `CLOUDBASE_ENV_ID`、`CLOUDBASE_SERVICE_NAME` 覆盖，但 `HEALTH_URL` 默认固定为 `watchdog-prod-d6gch930m378d9a16-1351750301.ap-shanghai.app.tcloudbase.com/api/health`。
  2. `deploy/deploy.sh:70-77` 使用可变的环境/服务部署，`79-82` 却只 curl 固定 URL；除非额外设置 `WATCHDOG_HEALTH_URL`，目标没有自动关联。
  3. 当前 dry-run 能成功构建临时部署包并打印服务名 `watchdog-api-prod`，但脚本本身没有验证该临时目标与固定健康地址的关系。
- 根本原因：健康 URL 是硬编码默认值，部署目标和验证目标使用两套独立配置，没有服务返回地址解析或显式一致性校验。
- 涉及文件：`deploy/deploy.sh:7-13,51-57,69-82`；`backend/cloudbaserc.json:4-7`；`deploy/cloudbase/README.md:21-41`。
- 建议修改方案：从 CloudBase 部署结果解析服务地址，或要求 dry-run/正式部署显式传入与环境绑定的 `WATCHDOG_HEALTH_URL`；健康检查同时带 API/数据库 readiness 检查，目标不一致时让脚本失败。
- 修复状态：待修复
- 验证结果：待验证

### BACK-018：迁移脚本逐条执行，无迁移版本记录或整体事务，失败后可能留下半套 schema

- 严重程度：一般
- 影响范围：CloudBase PostgreSQL 初始化和后续升级；网络中断、权限错误或单条 DDL 失败后，重跑/人工判断成本高，部分结构可能已生效。
- 复现步骤或证据：
  1. `backend/scripts/migrate-cloudbase.js:37-50` 每次扫描全部 SQL 文件并逐条调用 `database.executePGSql({ Sql: statement })`，没有 `schema_migrations` 表、版本检查、校验和或事务包裹。
  2. 失败处理在 `backend/scripts/migrate-cloudbase.js:54-57` 只设置退出码，已经成功的前序语句不会回滚。
  3. 当前 SQL 多数使用 `IF NOT EXISTS`，因此现有两份迁移通常可重跑，但这不能保证后续新增迁移仍具备幂等性。
- 根本原因：把文件名排序当作迁移状态，把每条 DDL 的成功当作整体成功，没有持久化迁移状态和原子发布边界。
- 涉及文件：`backend/scripts/migrate-cloudbase.js:29-57`；`backend/migrations/001_initial.sql`；`backend/migrations/002_units.sql`。
- 建议修改方案：引入迁移记录表、版本/校验和和明确的向前升级策略；在 CloudBase 能力允许时用事务或可恢复的分阶段迁移；失败时输出已应用版本并阻止应用切换到不兼容 schema。
- 修复状态：待修复
- 验证结果：待验证

### BACK-019：容器默认以 root 运行，且 Dockerfile 没有容器级 HEALTHCHECK

- 严重程度：一般
- 影响范围：容器逃逸后的权限边界、镜像运行时基线和本地编排/镜像扫描；Docker 层不能独立表达进程健康。
- 复现步骤或证据：
  1. `backend/Dockerfile:1-16` 只使用 `node:24-bookworm-slim`、复制源码并启动，没有创建非特权用户或 `USER` 指令，因此沿用基础镜像默认用户（通常为 root）。
  2. 同一文件没有 `HEALTHCHECK`；健康能力仅存在于 CloudBase 文档/外部脚本，直接运行镜像的编排器无法获得标准健康状态。
- 根本原因：镜像最小化只关注启动和端口，没有落实运行时降权和容器级健康契约。
- 涉及文件：`backend/Dockerfile:1-16`；`deploy/cloudbase/README.md:35-41`。
- 建议修改方案：使用内置非 root 用户运行，明确可写目录和模型读取权限；增加轻量 `/api/health` 或 readiness HEALTHCHECK，并避免在 HEALTHCHECK 中泄露密钥。
- 修复状态：待修复
- 验证结果：待验证

### BACK-020：SQLite 与 PostgreSQL 对种子单位配置的行为不一致

- 严重程度：优化
- 影响范围：本地生产化运行、集成测试和运维对 `WATCHDOG_SEED_UNIT_*` 的预期；同一组环境变量在两种驱动下得到不同单位/验证码。
- 复现步骤或证据：
  1. PostgreSQL 驱动 `backend/src/db-postgres.js:20-25,63-69` 使用 `WATCHDOG_SEED_UNIT_ID/NAME/CODE`。
  2. SQLite 驱动 `backend/src/db-sqlite.js:322-325` 无条件写入固定 `longyou-county-fire-rescue / 龙游县消防救援大队 / 0570`，不读取上述环境变量。
  3. 变量在 `backend/.env.example:46-49` 被公开为可配置项，但没有注明 SQLite 会忽略它。
- 根本原因：种子配置逻辑分别复制在两个适配器中，没有共享配置解析和跨驱动契约测试。
- 涉及文件：`backend/src/db-postgres.js:20-25,55-69`；`backend/src/db-sqlite.js:322-325`；`backend/.env.example:46-49`。
- 建议修改方案：抽取统一种子配置；若 SQLite 明确只用于测试，则删除其伪生产配置并在测试中显式注入；补充两种驱动的环境变量一致性测试。
- 修复状态：待修复
- 验证结果：待验证

## 已检查范围

- 服务与 API：`backend/src/server.js` 全文件，包括 CORS、模型静态资源、API Token、单位认证、警情、离线补传、参战力量、档案、ASR、解析、聊天、进退场、名单/热词、随手记、用户设置和日志。
- 数据访问层：`backend/src/db.js`、`db-sqlite.js`、`db-postgres.js`、`db-cloudbase.js`、`cloudbase-postgrest.js`、`database-readiness.js`、`logger.js`、`calc.js`。
- 依赖上游：`backend/src/asr.js`、`backend/src/parse.js`。
- 数据库迁移与脚本：`backend/migrations/001_initial.sql`、`002_units.sql`、`backend/scripts/migrate-cloudbase.js`。
- 测试：`backend/test/*.test.js` 全部执行；重点查看 API、数据库、日志、事件、PostgreSQL mock、Token、聊天、解析和 readiness 覆盖。
- 工程/部署：`backend/package.json`、`backend/Dockerfile`、`backend/cloudbaserc.json`、`backend/.dockerignore`、`backend/.env.example`、`deploy/deploy.sh`、`deploy/cloudbase/README.md`。
- 项目约定与产品架构背景：根目录 `AGENTS.md`、`README.md`；只用于确定审查边界和部署语义，未修改其内容。

## 未能验证事项

- 没有真实 CloudBase PostgreSQL 凭据和线上只读授权，未执行真实迁移、RLS/service_role 行为、PostgREST 返回格式、真实网络超时或多实例并发验证。
- 没有执行真实 CloudBase 部署、重启、扩缩容或线上健康检查；部署脚本只做了 dry-run，未触发外部状态变化。
- 未连接真实火山 ASR、DeepSeek API，未验证上游错误码、长响应、流式断开和费用/配额行为。
- 未对生产镜像执行构建、漏洞扫描、容器用户检查或编排器 HEALTHCHECK 验证。
- 未运行 Flutter/App 侧测试和手工流程；本报告仅覆盖用户指定的后端与部署范围。
- 工作区在审查开始前已存在未提交改动；本审查没有判断这些改动的作者或提交归属，也没有回退、提交或部署它们。
