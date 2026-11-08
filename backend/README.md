# WatchDog Backend Subsystem Blueprint (`backend`)

## Overview
WatchDog 后端服务子系统，负责火场智控的全部业务状态持久化、多端协同事件同步、AI 语音与意图解析、外部能力代理（气象路况、重点单位、危化品知识库）以及组织权限管控。技术栈采用 Node.js (Node 20+)、Express、WebSocket (ws) 与 PostgreSQL 17。

## Subdirectories & Boundaries
- [`src/`](./src/README.md): 核心服务端源码（REST API、WebSocket、DeepSeek 语义解析、Seed-ASR 流式识别、气瓶计算公式与 PostgreSQL 事务仓储）。
- [`migrations/`](./migrations/README.md): 数据库架构迁移脚本，包含标准基线与递增 SQL 迁移。
- [`admin/`](./admin/README.md): 重点单位与全景图资料管理后台静态 SPA 及控制器。
- [`seeds/`](./seeds/README.md): 组织架构脱敏示例种子与环境变量注入规范。

## Global Invariants
- `[auth:bearer-token]`：除 `/health` 及公开认证接口外，所有请求必须携带基于 HMAC 签名的有效 Bearer Token。
- `[data:tenant-isolation]`：全部业务表均严格以 `unit_id` 进行多租户逻辑隔离，跨单位请求一律拦截。
- `[concurrency:outbox-event]`：所有对警情状态（进出场、随手记、力量编制）的关键写操作，必须与 Outbox 事件在同一数据库事务中原子提交，并通过 PostgreSQL LISTEN/NOTIFY 触发实时广播。
- `[safety:safe-mode]`：严禁在生产或代码库中泄露真实队站人名或单位验证码，测试用例强制使用虚拟占位符。

## Global Side Effects
- 维护 PostgreSQL 连接池，并在启动时基于 Advisory Lock 执行前向兼容数据库迁移。
- 与豆包 Seed-ASR 和 DeepSeek API 建立长连接/HTTP 外部通信。
- 维护本地持久卷 `/app/data` 存储导入资料图片与正射影像切片。

## Subsystem Verification
- Run: `npm test`（位于 `backend/` 下，CI 门禁基线 300+ 用例，本地严格 322/322 全绿）
