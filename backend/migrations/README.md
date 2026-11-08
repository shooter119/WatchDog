# WatchDog Database Migrations (`backend/migrations`)

## Overview
管理 PostgreSQL 数据库架构版本演进的迁移脚本集。所有 SQL 脚本遵循严格的升序数字编号、前向兼容与事务原子性，由后端启动时基于 advisory lock 自动执行。

## Interface
- **基线与增量脚本序列**:
  - `000_standard_baseline.sql`: 初始化核心表（`units`, `users`, `incidents`, `entries`, `notes`, `events_outbox` 等）
  - `001_force_quantity_known.sql` ~ `007_incident_observations.sql`: 参战力量与警情观察扩展
  - `008_admin_auth.sql` ~ `009_admin_member_revocation.sql`: 管理端扫码鉴权与成员状态审计
  - `010_key_sites.sql` ~ `012_incident_key_sites.sql`: 重点单位九大分项表结构、AI 分析、全景漫游与警情关联
  - `013_video_resources.sql`: 现场视频流与监控资源管理
  - `014_member_review_history.sql`: 队员入队审批生命周期
  - `015_multidevice_conflicts.sql`: 多设备登录冲突与版本控制字段
  - `016_org_scoped_stations.sql`: 组织专属消防站分区
  - `017_hazardous_chemicals.sql`: 危化品速查表与 UN 编号索引
- **迁移执行器**:
  - `backend/src/postgres-migrator.js`: 导出的 `runMigrations(pool, migrationsDir)` 函数

## Invariants
- `[postgres-migrator:runMigrations]`：每个迁移脚本必须在独立事务中执行；执行前获取 PostgreSQL Session-level Advisory Lock，防止多实例并发冲突。
- `[migration:idempotency]`：已执行过的迁移脚本校验和（SHA-256）记录于 `schema_migrations` 表；严禁对已发布的历史迁移脚本进行破坏性修改。
- 架构变更必须保证向后兼容，只允许新增列（允许默认值或 NULL）与新增表，严禁直接 DROP 正在被生产运行实例访问的列。

## Side Effects
- 在 PostgreSQL 实例中创建或修改 DDL 架构，更新 `schema_migrations` 记录。
- 生产容器启动阶段阻塞应用服务就绪直至迁移完毕。

## Verification
- Run: `npm test`（位于 `backend/` 下，会自动启动内存/临时 PostgreSQL 验证迁移完整执行）
