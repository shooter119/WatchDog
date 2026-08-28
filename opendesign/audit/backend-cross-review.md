# WatchDog 后端最新改动交叉复核

复核日期：2026-08-27
复核对象：当前工作区未提交的最新后端、迁移、容器与部署相关改动
复核方式：只读静态交叉审查、现有后端测试、临时目录最小运行复现；未修改源码、测试、迁移或部署配置。
与上一轮台账的关系：仅记录本轮新确认的问题或最新修复引入/暴露的缺口；与 `backend-architecture.md` 重复的问题在“既有问题对照”中列出，不重复计数。

## 复核结论

本轮新增或确认的修复不完整问题共 7 项：阻断 0 项、严重 5 项、一般 2 项。重点风险集中在：

- 旧 SQLite 数据库在进入兼容迁移前就会因 `scene` 索引失败，服务无法启动；即使绕过该顺序，重建表仍会丢失最新计算字段。
- `/api/auth/verify` 明确绕过 `API_TOKEN`，与 App/部署文档要求输入令牌的契约不一致；新增认证失败限流又可被伪造设备 ID 逐次绕过。
- 新建警情入口只处理同一 `client_op_id` 的 `incident_created` 事件；复用已用于笔记/进场等事件的 ID 会创建没有建档事件的孤儿警情。
- 输入长度加固未覆盖警情内进场记录的 PATCH 改名接口；实测可持久化 100,000 字姓名。

后端基线：在 `backend/` 执行 `npm test`，102 个用例通过、0 失败。测试通过不覆盖真实 CloudBase PostgreSQL、旧 SQLite 文件升级、多实例并发及生产认证配置。

## 新问题台账

### BCR-001｜严重｜SQLite 旧库在兼容迁移前因 `scene` 索引失败，无法启动升级

- 严重程度：严重
- 影响范围：从早期版本升级的本地 SQLite 数据库、使用 SQLite 做维护/恢复的环境；服务在读取旧数据前直接启动失败，后续迁移代码无法执行。
- 复现步骤或证据：
  1. `backend/src/db-sqlite.js:29-45` 的初始化 DDL 对已有 `entries` 表执行 `CREATE INDEX IF NOT EXISTS idx_entries_scene ON entries(scene, entry_at)`。
  2. 旧版 `entries` 表可能没有 `scene` 列；而兼容检测与重建逻辑直到 `backend/src/db-sqlite.js:166-217,258-293` 才执行，顺序晚于该索引创建。
  3. 最小运行复现（临时目录，不入库）：创建仅含旧版字段、没有 `scene` 的 `entries` 表后加载 `db-sqlite`，Node 抛出 `ERR_SQLITE_ERROR: no such column: scene`，没有到达 `migrateLegacyIncidentRows()` 或 `ALTER TABLE ... RENAME` 分支。
- 根本原因：对既有表执行依赖新列的索引/初始化 DDL，没有先判断并完成旧表迁移；`IF NOT EXISTS` 只避免索引名重复，不能避免索引表达式引用不存在的列。
- 涉及文件：`backend/src/db-sqlite.js:20-45,166-217,258-293`。
- 建议修改方案：把旧库结构探测/重建放到任何依赖新列的索引创建之前；迁移步骤完成后再创建索引，并用没有 `scene`、缺少新增列、含历史数据的真实旧库快照做升级回归。
- 修复状态：审查阶段=待修复
- 验证结果：审查阶段=待验证（当前版本已由临时旧库复现启动失败；修复后尚未验证）。

### BCR-002｜严重｜SQLite 旧库 `entries` 重建定义遗漏新增计算字段，升级后写入仍会缺列

- 严重程度：严重
- 影响范围：旧 SQLite 数据库的进场、压力复核、实测耗气率保存和倒计时计算；会在迁移后首次写入/复核时返回数据库错误，或丢失历史计算字段。
- 复现步骤或证据：
  1. `backend/src/db-sqlite.js:229-238` 先为已有表增加 `consumption_actual_lpm`、`cylinder_vol_l`、`consumption_lpm`。
  2. 旧表无 `scene` 时，`backend/src/db-sqlite.js:263-277` 随后重建 `entries`，但新表定义只有 `raw_text`、`created_at` 等旧字段，没有上述三个列，复制语句也没有复制它们。
  3. 当前运行代码 `backend/src/db-sqlite.js:391-394` 的 `createEntry` 已无条件写入 `cylinder_vol_l`、`consumption_lpm`；`backend/src/db-sqlite.js:414-417` 的 `updateEntry` 已写入 `consumption_actual_lpm`。因此一旦 BCR-001 的顺序问题被修正并进入该重建分支，后续调用会命中 `no such column`。
  4. 当前最小旧库复现先被 BCR-001 的索引错误阻断，未声称已完成该条件分支的运行验证；以上结论由迁移前后 DDL 与写入 SQL 的列集合直接确认。
- 根本原因：新增字段只补在普通 `ALTER TABLE` 路径和新库 DDL 中，没有同步到兼容重建表的完整 schema。
- 涉及文件：`backend/src/db-sqlite.js:229-238,258-293,391-417`；相关 PostgreSQL 增量迁移为 `backend/migrations/003_entry_calc_params.sql:1-3`。
- 建议修改方案：抽取单一的 `entries` 目标 schema，供新建表和重建表共同使用；重建时保留/回填所有现有列，并增加从无 `scene` 旧库升级后执行进场、压力复核、出场的回归测试。
- 修复状态：审查阶段=待修复
- 验证结果：审查阶段=待验证（当前版本已确认 DDL/写入列不一致；因 BCR-001 先失败，条件分支尚未运行验证）。

### BCR-003｜严重｜单位认证入口绕过 `API_TOKEN`，令牌输入在认证请求中不参与校验

- 严重程度：严重
- 影响范围：认证入口、单位验证码暴力尝试、设备档案写入和 API_TOKEN 的访问边界；调用方可不持有 API_TOKEN，仅凭单位名称/验证码访问认证入口并写入设备档案。App 若输入错误 API_TOKEN，认证接口仍返回成功，但后续业务请求才失败，造成认证状态与实际会话不一致。
- 复现步骤或证据：
  1. `backend/src/server.js:96-101` 的 Token 中间件对 `req.path === '/api/auth/verify'` 直接 `next()`，不比较 `X-Api-Token`。
  2. `backend/src/server.js:330-348` 的认证处理器也没有读取或验证 API_TOKEN；有效单位码即可调用 `db.findUnit()` 并保存设备档案。
  3. 客户端仍在 `app/lib/api/api_client.dart:731-749` 发送用户输入的 `X-Api-Token`；部署说明 `deploy/cloudbase/README.md:82` 也要求首次认证输入运行时 API_TOKEN。
  4. 临时 HTTP 子进程复现：服务配置 `API_TOKEN=expected-token`、单位认证开启，向 `/api/auth/verify` 发送 `X-Api-Token: wrong-token` 与正确单位码，响应仍为 `200`、`authenticated: true`。
- 根本原因：将首次单位认证设计成免 Token 的公共 bootstrap 入口，但客户端与运维契约仍把 API_TOKEN 当作认证必填项；两套入口策略没有统一。
- 涉及文件：`backend/src/server.js:96-101,330-348`；`app/lib/api/api_client.dart:731-749`；`deploy/cloudbase/README.md:82`。
- 建议修改方案：若 API_TOKEN 是所有业务入口的共享访问门槛，则认证路由也必须验证它；若产品确实需要公共 bootstrap，则应明确移除该请求对 API_TOKEN 的伪必填，并为公共入口设计独立、短时、可撤销的注册/认证保护，不能同时保留两套互相矛盾的契约。
- 修复状态：审查阶段=待修复
- 验证结果：审查阶段=待验证（当前版本已复现错误令牌得到 200；修复后尚未验证）。

### BCR-004｜严重｜认证失败限流以客户端可伪造的 `X-Device-Id` 为主键，可逐请求绕过

- 严重程度：严重
- 影响范围：单位验证码防暴力破解、认证接口资源消耗和所有单位业务数据的入口保护；攻击者可在每次失败尝试时换一个设备 ID，使同一来源不触发 5 次/分钟限制。
- 复现步骤或证据：
  1. `backend/src/server.js:301-328` 对失败认证计数，限制键由 `backend/src/server.js:305-307` 生成：优先采用 `deviceKey(req)`，否则才使用 `req.ip`。
  2. `backend/src/server.js:140-142` 的 `deviceKey` 完全取自请求头，调用方可任意生成不同值；单位名称也由请求体提供，形成可控高基数键。
  3. 临时 HTTP 子进程复现：连续发送 6 次错误单位码，每次使用不同 `X-Device-Id`，响应状态为 `[403,403,403,403,403,403]`，没有出现第 6 次应有的 `429`。
- 根本原因：把不可信设备标识当作认证限流的稳定身份，且没有把 IP/网关真实来源、单位、账号/验证码组合成不可由客户端单独轮换的共享限流维度。
- 涉及文件：`backend/src/server.js:140-142,301-328`；相关认证入口为 `backend/src/server.js:330-348`。
- 建议修改方案：在可信网关或服务端按真实来源 IP、单位标识、设备注册身份和时间窗做组合限流/退避；客户端设备 ID 只能作为辅助维度，不能作为唯一或优先维度；补充轮换设备 ID、并发失败和多实例共享限流测试。
- 修复状态：审查阶段=待修复
- 验证结果：审查阶段=待验证（当前版本已复现轮换设备 ID 绕过；修复后尚未验证）。

### BCR-005｜严重｜新建警情未对任意既有 `client_op_id` 做冲突检查，会创建无建档事件的孤儿警情

- 严重程度：严重
- 影响范围：警情创建、事件时间线、跨警情幂等和重试恢复；一个已用于 note/entry/exit 等事件的操作 ID 被误用于新建警情时，接口返回新警情成功，但该警情没有 `incident_created` 事件，`client_op_id` 实际仍归属于旧警情。
- 复现步骤或证据：
  1. `backend/src/server.js:393-433` 的新建入口只在 `previous?.type === 'incident_created'` 时检查已有操作；如果同一 ID 对应 note、entry 或其他事件，则继续创建新 incident。
  2. 新建流程随后调用 `db.appendIncidentEvent()`。SQLite `backend/src/db-sqlite.js:768-790`、PostgreSQL `backend/src/db-postgres.js:429-449` 都按全局 `client_op_id` 先返回既有事件；数据库唯一索引见 `backend/migrations/001_initial.sql:149-151`。
  3. 临时 HTTP 子进程复现：先在警情 A 用 `reused-op` 写 note，再归档 A，随后用同一 `X-Op-Id` 新建警情 B；响应为 `201`，但 B 的 timeline `events` 为空，已返回的 B 没有 `incident_created` 事件。
- 根本原因：创建入口没有目标警情可供 `ensureOperationScope` 校验，因而只特判一种事件类型；数据层又对全局 ID 进行无条件幂等返回，未把“冲突”与“重复成功”区分开。
- 涉及文件：`backend/src/server.js:393-433`；`backend/src/db-sqlite.js:763-790`；`backend/src/db-postgres.js:424-449`；`backend/migrations/001_initial.sql:97-110,149-151`。
- 建议修改方案：创建前按 `(unit_id, client_op_id)` 查询所有既有操作；只允许内容/类型一致的创建重试返回原始结果，任何其他事件类型或警情归属都返回 409；将 incident、`incident_created` 事件和操作结果放入同一事务/RPC，防止孤儿警情。
- 修复状态：审查阶段=待修复
- 验证结果：审查阶段=待验证（当前版本已复现 201 + 空时间线；修复后尚未验证）。

### BCR-006｜一般｜进场记录 PATCH 改名未沿用新增的姓名长度上限

- 严重程度：一般
- 影响范围：entries、事件时间线和操作日志的持久化体积；可用单次 512KB JSON 请求把超长姓名写入 entry，并在压力事件/日志链路中重复传播。
- 复现步骤或证据：
  1. POST 入口已经在 `backend/src/server.js:1059-1065` 对姓名限制 64 字，但 PATCH 入口 `backend/src/server.js:1141-1152` 仅执行 `String(name).trim()`，没有长度检查。
  2. 临时 HTTP 子进程复现：创建一条进场记录后 PATCH `name` 为 100,000 个字符，响应为 `200`，返回值 `name.length=100000`。
  3. `backend/src/server.js:1199-1207` 会把更新后的姓名放入 pressure 事件 payload；因此该输入不只进入 entries，还可能进入事件 JSON。
- 根本原因：输入校验按路由复制，新增 POST 校验没有抽成 entry 级共享 schema，导致同一字段的创建与修改契约不一致。
- 涉及文件：`backend/src/server.js:1052-1065,1141-1152,1199-1207`；数据层持久化见 `backend/src/db-sqlite.js:413-418`、`backend/src/db-postgres.js:132-141`。
- 建议修改方案：抽取统一的 entry/name 校验函数并在 POST、PATCH、离线补传入口复用；明确按字符数和字节数的上限，对超限请求返回 400；增加 PATCH 和离线路径的边界测试。
- 修复状态：审查阶段=待修复
- 验证结果：审查阶段=待验证（当前版本已复现 100,000 字姓名被接受；修复后尚未验证）。

### BCR-007｜一般｜单位验证码及认证请求头缺少字段级长度上限

- 严重程度：一般
- 影响范围：公共单位认证入口、数据库查询资源和认证限流键内存；单个认证请求可在 512KB JSON 上限内携带异常长的 `unit_code`，认证业务没有对其格式/长度做快速拒绝。
- 复现步骤或证据：
  1. 全局 JSON body 上限为 `backend/src/server.js:67-69` 的 512KB。
  2. `/api/auth/verify` 仅对 `unit_name`、`real_name` 做截断，`backend/src/server.js:330-344` 对 `unit_code` 只 `String(...).trim()` 后直接查询。
  3. 已认证业务中 `backend/src/server.js:121-127` 对 `X-Unit-Code` 也没有长度截断或格式校验；与 `unit_name`/`real_name` 的字段级限制不对称。
- 根本原因：认证输入采用逐字段手写转换，未定义单位 ID、单位码、姓名的统一 schema；总 body 限制被当成字段校验的替代。
- 涉及文件：`backend/src/server.js:67-69,121-127,330-344`；客户端输入提示为 `app/lib/pages/incident_selection_overlay.dart:224-238`。
- 建议修改方案：为 `unit_id`、`unit_code`、`unit_name` 和 `real_name` 定义严格长度/字符集/格式规则；在认证限流和数据库查询前拒绝超限值；客户端限制只作 UX，服务端必须独立校验。
- 修复状态：审查阶段=待修复
- 验证结果：审查阶段=待验证（静态确认字段缺少上限；未将异常大请求发送到真实 CloudBase）。

## 重点复核结果（不重复计入新问题）

| 复核项 | 当前判断 | 证据与说明 |
|---|---|---|
| 单位隔离 | 该路径未发现本轮新增的读取越权回归；但列表请求有跨单位自动归档副作用 | `backend/src/server.js:144-150,381-385` 与两个驱动的 `getIncident/listIncidents` 已使用精确 `unit_id`；不过 `GET /api/incidents` 在返回当前单位列表前无条件调用 `db.archiveStaleIncidents()`，该全局扫描/归档见 `backend/src/db-postgres.js:401-417`、`backend/src/db-sqlite.js:732-753`，会由单位 A 的请求改变单位 B 的陈旧警情状态。该风险属于上一轮自动归档并发/职责问题的单位化副作用，未另列为新编号。 |
| API_TOKEN / 认证入口 | 生产缺失 Token 的启动 fail-fast 已加入；入口绕过和限流绕过分别见 BCR-003/BCR-004 | `backend/src/server.js:21-30`；已有 Token 正确/错误用例为 `backend/test/token.e2e.test.js:9-63`，但没有错误 Token 调用 `/api/auth/verify` 的负向断言。 |
| 跨警情 `client_op_id` | 离线补传的跨警情返回已改为 409/逐条拒绝；新建警情入口仍有 BCR-005，且同警情不同操作类型的业务状态原子幂等仍是既有 BACK-006/BACK-007 | 离线逻辑见 `backend/src/server.js:518-613`；数据库仍为全局唯一 `client_op_id`，不能仅靠事件去重包住 entries/notes 状态。 |
| 输入长度 | parse/chat/note/POST entry/log message 等本轮已有上限；PATCH entry 和认证字段仍有缺口 | `backend/src/server.js:816-840,937-945,1059-1065,1304-1312,1453-1468`；缺口见 BCR-006/BCR-007。离线 `payload.raw_text` 未限制的问题已在上一轮 `BACK-013` 记录，本轮不重复编号。 |
| 异步异常包装 | 未发现本轮新增回归，当前包装对已注册 async route 有效 | `backend/src/server.js:1505-1518` 在全部 API 路由注册后包裹 async route；临时将 `db.listFirefighters` 改为 rejected Promise，请求 `/api/firefighters` 返回 500 JSON，未出现挂起。数据库 readiness 中间件本身有显式 `try`/受控 promise，不纳入新问题。 |
| 双驱动与迁移 | 现行新库字段大体对齐；旧 SQLite 迁移有 BCR-001/BCR-002，种子配置/迁移不一致为既有问题 | `backend/src/db-postgres.js:110-147` 与 `backend/src/db-sqlite.js:391-425` 支持新计算字段；PG 增量字段在 `backend/migrations/003_entry_calc_params.sql:1-3`。`WATCHDOG_SEED_UNIT_*` 与固定迁移种子仍有 `BACK-002/BACK-020`，迁移脚本无版本记录/整体事务仍有 `BACK-018`，本轮不重复编号。 |

## 既有问题对照

以下问题已在上一轮后端台账中存在，本轮仅确认其状态变化，不作为新增问题重复计数：

- `BACK-001` 的历史 `unit_id=NULL` 越权路径在当前两个驱动的按单位列表/详情路径已改为精确匹配；仍需真实数据回填/legacy 管理策略，不能据此宣称历史数据治理完成。
- `BACK-002` 的生产固定测试种子仍存在于 `backend/migrations/002_units.sql:23-26`；本轮虽然加入了失败计数，但 BCR-004 证明该限流实现可绕过。
- `BACK-005` 的 Express 4 async 路由挂起问题已由 `forwardAsyncRouteErrors` 覆盖当前已注册 route，并通过故障注入得到 500；生产 PostgreSQL 全路由故障注入仍未完成。
- `BACK-006/BACK-007` 的跨表状态与事件非原子、同警情不同类型复用 ID 问题仍未整体解决；BCR-005 是新建警情入口漏检后产生的具体孤儿记录场景。
- `BACK-008` 的新建/复核计算字段在新库路径已补齐，但旧 SQLite 重建路径触发 BCR-001/BCR-002。
- `BACK-010` 的 PostgreSQL 活动时间 `MAX`/条件归档事件逻辑已在代码中加入；没有真实多实例数据库验证，不能替代并发验收。
- `BACK-011` 的健康检查现在会在 readiness 未就绪时返回 503（`backend/src/server.js:280-289`），但初始化失败后的自动重试/进程恢复策略仍未解决。
- `BACK-013/BACK-018/BACK-020` 的离线原文长度、迁移版本/事务、双驱动固定种子差异仍按原台账处理。
- `BACK-019` 的 Docker 非 root 和容器级 HEALTHCHECK 已加入 `backend/Dockerfile:1-22`，尚未做真实镜像构建与运行检查。

## 已检查范围

- API 与中间件：`backend/src/server.js` 全文件，重点覆盖 CORS、`API_TOKEN`、单位认证、警情读写、离线补传、`client_op_id`、输入上限、错误处理中间件和 readiness。
- 数据访问层：`backend/src/db.js`、`backend/src/db-sqlite.js`、`backend/src/db-postgres.js`、`backend/src/cloudbase-postgrest.js`、`backend/src/database-readiness.js`。
- 数据库结构/迁移：`backend/migrations/001_initial.sql`、`002_units.sql`、`003_entry_calc_params.sql`；SQLite 启动建表、旧表重建和字段迁移逻辑；`backend/scripts/migrate-cloudbase.js`。
- 测试与配置：`backend/test/*.test.js`、`backend/package.json`、`backend/.env.example`。
- 容器与部署配置：`backend/Dockerfile`、`backend/cloudbaserc.json`、`deploy/deploy.sh`、`deploy/cloudbase/README.md`、`.dockerignore`。
- 只读验证：`backend/npm test`（102/102 通过）；错误令牌认证、认证限流轮换设备 ID、复用 op 创建孤儿警情、超长 PATCH 姓名、async 数据库异常均使用临时进程/临时目录复现；未触碰工作区源文件、测试和部署配置。

## 未能验证事项

- 没有 CloudBase PostgreSQL 真实凭据、只读数据库权限或生产运行时环境，未执行真实 RLS/service_role、PostgREST 返回格式、真实迁移和线上认证验证。
- 没有真实旧 SQLite 数据库快照；BCR-001 已用最小旧 schema 复现，BCR-002 的重建后写入路径因 BCR-001 先失败而未能运行到该分支。
- 没有进行多实例/多进程并发压测，无法验证 PostgreSQL 事务、冷却闸门、归档扫描和跨实例限流的最终行为。
- 没有执行真实 CloudBase 部署、容器构建、扩缩容、重启或生产健康检查；本轮只读复核不运行 `deploy/deploy.sh` 正式部署。
- 没有连接真实火山 ASR、DeepSeek 或生产网关，未验证上游超时、响应体、费用和真实 IP 透传。
- 未运行 Flutter analyze/test 或 Android 手工流程；App 文件仅用于核对认证入口与请求契约，不纳入本组测试结论。
