# WatchDog 第十轮：数据库完整性约束迁移审查

审核日期：2026-08-29

## 问题记录

### BACK-015｜一般｜生产 PostgreSQL 尚未落地关键完整性约束

- 影响范围：entries、pressure_samples、incidents、incident_events、incident_forces、unit_members、auth_sessions 的数值范围、父子引用和后续写入一致性。
- 复现步骤或证据：
  1. 静态检查 `backend/migrations/006_integrity_constraints.sql`，确认约束覆盖压力、时长、气瓶容量、消耗率、参战力量计数及关键父子引用，并使用 `NOT VALID`。
  2. 静态检查 `backend/scripts/migrate-cloudbase.js`，确认迁移按文件版本执行，记录文件 SHA-256，已应用文件校验和变化会拒绝跳过。
  3. 通过 CloudBase PostgreSQL 管理界面只读查询，确认 `public.schema_migrations` 不存在，且生产中未发现该升级链路应创建的会话、操作账本和原子 RPC 对象；本轮未读取正文、姓名、验证码或 Token。
- 根本原因：生产数据库仍处于早期/部分结构，版本化迁移未在具备恢复能力的环境中执行；当前共享 PostgreSQL 环境没有可用备份能力，缺少预生产/隔离验证条件。
- 涉及文件：`backend/migrations/006_integrity_constraints.sql`、`backend/scripts/migrate-cloudbase.js`、`backend/migrations/001_initial.sql`～`009_ota_public_bucket.sql`。
- 修改方案：先取得可恢复快照或建立隔离预生产库；执行迁移前重复操作号、孤儿引用、NULL 单位和数值范围预检；按版本顺序迁移并校验 checksum；单独执行 `VALIDATE CONSTRAINT`；再做 RLS、角色、原子 RPC、多实例和旧客户端兼容验收。
- 修复状态：静态方案已复核；真实生产迁移未执行，外部阻塞待恢复点/预生产条件。
- 验证结果：迁移脚本测试、后端全量回归和线上健康检查均通过；静态检查不能替代真实 PostgreSQL DDL、约束验证和恢复演练。

## 安全边界

- 本轮只读查询生产 PostgreSQL，不执行 DDL/DML，不启用会话/RBAC、操作账本或原子 RPC 开关。
- 生产迁移、备份恢复和多实例并发继续归入外部验收队列，不因本轮静态检查而关闭 `DB-EXT-001`～`DB-EXT-003`。
