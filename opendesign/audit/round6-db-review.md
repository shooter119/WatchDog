# WatchDog 第六轮数据库交叉复核记录

复核日期：2026-08-29
复核小组：后端与架构组、测试与质量组、安全与隐私组、性能与工程质量组
范围：SQLite 启动兼容迁移、PostgreSQL 原子 RPC 迁移、迁移失败恢复和外部验收边界。

## 复核规则

只登记可以由代码、测试、运行结果或明确的数据库逻辑证据支持的问题。涉及生产 PostgreSQL 的项目不使用 SQLite 或模拟仓储结果替代；没有迁移凭据、备份和隔离环境时不执行生产数据操作，不打开功能开关。

## DB-LOCAL-001：SQLite 旧库重复创建警情

- 级别：严重
- 影响范围：使用旧版 SQLite 数据启动后，历史警情可能在每次启动时增加一份，原记录的 `scene` 还会被再次改写，导致警情列表和历史关联逐步失真。
- 复现步骤/证据：在临时数据目录建立带 `scene='legacy-scene'` 的旧版 `entries` 表；第一次加载 `db-sqlite.js` 后得到 1 条警情；再次启动时，旧迁移把第一次生成的 UUID 继续当作旧 scene，再生成第 2 条警情。
- 根本原因：`migrateLegacyIncidentRows()` 只扫描 scene，没有先判断该 scene 是否已经是现有 `incidents.id`。
- 涉及文件：`backend/src/db-sqlite.js`、`backend/test/sqlite-migration.test.js`。
- 修改方案：迁移新警情前按 `incidents.id` 检查；已存在的 scene 视为已迁移并跳过；新建警情和历史 scene 改写保持在同一事务中。
- 修复状态：已修复。
- 验证结果：新增“两次启动警情数和 scene 不变”回归通过。

## DB-LOCAL-002：原子 RPC 冲突目标缺少可匹配索引

- 级别：严重
- 影响范围：`007_atomic_write_functions.sql` 的 11 个事件写入函数使用 `ON CONFLICT (client_op_id)`；现有 `001_initial.sql` 只有带 `WHERE client_op_id IS NOT NULL` 的部分唯一索引，真实 PostgreSQL 可能无法解析该冲突目标，导致原子 RPC 调用失败。
- 复现步骤/证据：静态读取 `007_atomic_write_functions.sql` 得到 11 处冲突目标；读取 `001_initial.sql` 确认现有索引带部分谓词。PostgreSQL 的 `ON CONFLICT (column)` 需要能够匹配唯一约束或适用的唯一索引。
- 根本原因：RPC 迁移编写时只考虑了非空值唯一性，没有同步提供无谓词的可匹配唯一索引。
- 涉及文件：`backend/migrations/001_initial.sql`、`backend/migrations/007_atomic_write_functions.sql`、`backend/migrations/008_atomic_rpc_conflict_index.sql`、`backend/test/migration-script.test.js`。
- 修改方案：不原地修改既有迁移文件，新增 008 号向前兼容迁移，在 `incident_events(client_op_id)` 上建立完整唯一索引。PostgreSQL 唯一索引允许多个 NULL，因此不改变无操作号事件的行为；生产执行前仍需做重复非空值预检。
- 修复状态：代码/迁移方案已修复，真实 PostgreSQL 尚未验收。
- 验证结果：迁移静态回归通过；没有生产 PG 凭据，未执行真实 DDL 或 RPC。

## DB-LOCAL-003：旧库兼容迁移缺少事务边界

- 级别：一般
- 影响范围：旧库迁移在创建新警情后批量改写历史行时失败，可能留下新警情已存在但历史数据仍指向旧 scene 的半迁移状态。
- 复现步骤/证据：为旧版 entries 表安装一个仅拒绝 scene 更新的 SQLite trigger；注入迁移更新失败。事务修复前，插入的 incident 会保留；事务修复后，incident 数为 0，历史 scene 仍为原值。
- 根本原因：兼容迁移的插入、历史行更新和旧表清理由多个独立语句组成，原先没有 `BEGIN IMMEDIATE`/回滚保护。
- 涉及文件：`backend/src/db-sqlite.js`、`backend/test/sqlite-migration.test.js`。
- 修改方案：复用现有 SQLite `transaction()` helper，将整个 `migrateLegacyIncidentRows()` 包入一笔事务；任何异常自动 rollback。
- 修复状态：已修复。
- 验证结果：故障注入回归通过，后端全量测试 159/159 通过。

## DB-LOCAL-004：原子 RPC 开关缺少操作账本依赖保护

- 级别：严重
- 影响范围：若仅设置 `WATCHDOG_ATOMIC_OPS_ENABLED=1` 而未设置 `WATCHDOG_OPERATION_LEDGER_ENABLED=1`，服务会直接调用原子 RPC，但请求前没有操作账本的重复/冲突保护；同一重试可能重复创建业务记录或重复推进版本。
- 复现步骤/证据：读取 `backend/src/db-postgres.js` 可见原子 RPC 由独立环境变量控制；读取 `backend/src/server.js` 可见操作账本由另一开关控制，原先没有启动依赖校验。部署文档虽要求先完成 005 迁移，但配置错误仍可使服务启动。
- 根本原因：两个分阶段能力开关没有在运行时形成 fail-fast 依赖关系。
- 涉及文件：`backend/src/server.js`、`backend/test/runtime-config.test.js`、`deploy/cloudbase/README.md`。
- 修改方案：启动时强制 `WATCHDOG_ATOMIC_OPS_ENABLED=1` 必须同时启用操作账本；不满足时拒绝启动，避免带着不安全组合进入服务流量。
- 修复状态：已修复。
- 验证结果：新增启动配置回归通过；随后执行后端全量测试和部署健康检查。

## 外部数据库验收项

### DB-EXT-001：生产 PG 的 RLS 与历史约束效果未验证

- 级别：严重
- 影响范围：`004`/`005`/`006` 迁移涉及会话、操作账本、RLS 和约束；当前证据来自 SQL 文件、fake PostgREST 和本地仓储，不能证明 CloudBase PostgreSQL 中的角色、RLS、历史异常和 `VALIDATE CONSTRAINT` 行为。
- 根本原因：当前环境没有 CloudBase PostgreSQL 迁移凭据和预生产数据库。
- 涉及文件：`backend/migrations/004_auth_sessions_and_members.sql`、`005_operation_ledger.sql`、`006_integrity_constraints.sql`、`backend/scripts/migrate-cloudbase.js`。
- 修改方案：先备份/只读扫描，再在隔离 PG 执行迁移；验证普通角色的跨单位读写、RLS、约束验证和旧版本兼容，最后才评估生产开关。
- 修复状态：待外部。
- 验证结果：本轮未执行生产迁移或写入。

### DB-EXT-002：多实例迁移与 RPC 并发未验证

- 级别：严重
- 影响范围：迁移脚本的跨调用事务能力、并发迁移互斥、原子 RPC、建档冷却和自动归档竞态仍可能在真实多实例环境中暴露。
- 根本原因：CloudBase ExecutePGSql 的跨调用事务/锁行为和真实服务多实例环境未获得验证。
- 涉及文件：`backend/scripts/migrate-cloudbase.js`、`backend/src/db-postgres.js`、`backend/migrations/007_atomic_write_functions.sql`、`008_atomic_rpc_conflict_index.sql`。
- 修改方案：在预生产使用双实例并发、断点故障注入、重复提交和旧后端兼容测试；确认迁移锁、RPC 事务、唯一索引和事件幂等后再开关灰度。
- 修复状态：待外部。
- 验证结果：当前无可用多实例 PG 环境，不能用本地模拟替代。

### DB-EXT-003：备份恢复和重启扩容连续性未验证

- 级别：一般
- 影响范围：生产数据库的备份可恢复性、恢复点记录、服务重启/扩容后的数据连续性尚未有运行证据。
- 根本原因：当前环境没有生产备份权限或隔离恢复环境。
- 涉及文件：部署运行时配置、`deploy/cloudbase/README.md`、数据库运维流程。
- 修改方案：由运维在隔离环境执行备份恢复、迁移后重启和扩容读写演练，记录恢复点、数据校验和回滚方式，不覆盖生产原库。
- 修复状态：待外部。
- 验证结果：本轮未执行不可逆或生产恢复操作。

## 本轮验证记录

- 针对性数据库回归：159/159 通过。
- 迁移文件静态检查：007 的 11 个冲突目标均有 008 的完整唯一索引覆盖。
- 未执行：真实 PostgreSQL 迁移、生产数据扫描、RLS 验证、双实例并发、备份恢复。
- 结论：DB-LOCAL-001、DB-LOCAL-003 和 DB-LOCAL-004 已闭合；DB-LOCAL-002 代码/迁移层已闭合但必须经过真实 PG 验收；DB-EXT-001～003 保持外部待验收。
