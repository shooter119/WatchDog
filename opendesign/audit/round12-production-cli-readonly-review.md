# 第十二轮：CloudBase PostgreSQL CLI 只读复核

日期：2026-08-29

## DB-EXT-001 / DB-EXT-002 / DB-EXT-003 / CI-OTA-002

- 唯一编号：`DB-EXT-001`、`DB-EXT-002`、`DB-EXT-003`、`CI-OTA-002`
- 严重程度：严重（数据库迁移/RLS/RPC）；一般（备份与 OTA bucket 前置条件）
- 影响范围：生产会话/RBAC、单位隔离、操作账本、约束、原子写入、多实例一致性、OTA 对象发布和迁移回滚。
- 复现步骤或证据：
  1. 使用已登录本机 CloudBase CLI 执行 `tcb db pg migration list -e watchdog-prod-d6gch930m378d9a16 --remote-only --json`，远端迁移总数为 0，最新版本为空。
  2. 使用 `tcb db execute` 执行只读统计查询，结果为：升级表（`schema_migrations`、`auth_sessions`、`unit_members`、`operation_ledger`）0 个；`watchdog_*` 原子 RPC 0 个；`public`/`storage` RLS policy 0 个；`watchdog-ota` bucket 0 个。
  3. 本轮只执行 SELECT 和迁移列表查询，没有执行 DDL、DML、迁移、权限修改、bucket 创建或数据导出。
- 根本原因：生产 PostgreSQL 仍是基础结构，项目升级迁移没有应用；当前共享集群也没有已确认的恢复点/预生产条件，不能安全地在生产直接执行迁移。
- 涉及文件/平台：CloudBase PostgreSQL、`backend/migrations/004_*.sql` 至 `009_ota_public_bucket.sql`、`backend/scripts/migrate-cloudbase.js`、`opendesign/audit/external-acceptance-runbook.md`。
- 修改方案：先取得隔离预生产环境和可验证快照/恢复点，执行迁移前数据扫描，再按顺序应用迁移并验证约束、RLS、RPC、双实例并发和恢复；OTA bucket 也必须在相同安全前置条件下创建并做公开对象回读。相关生产开关继续保持关闭。
- 修复状态：外部阻塞已再次确认；本轮没有生产写入。
- 验证结果：CloudBase CLI 只读查询成功，输出仅包含对象数量和迁移状态，没有读取或保存姓名、验证码、Token、现场正文或密钥。

## 关联状态

服务健康检查 `databaseReady=true` 只证明当前后端能够连接基础数据库，不能证明上述升级对象已存在；因此不能据此关闭数据库迁移或 OTA 前置条件。
