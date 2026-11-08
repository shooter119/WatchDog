# WatchDog Backend Core (`backend/src`)

## Overview
后端核心服务模块，基于 Node.js (Express + WebSocket + pg) 构建，为火场智控提供 REST API、实时 WebSocket 双向广播、基于豆包 Seed-ASR 的语音转写、基于 DeepSeek 的意图槽位解析、以及空呼气瓶可用时间动态测算。

## Interface
- **HTTP/WebSocket Server Entry**: [`server.js`](./server.js)
  - 导出的关键端点：
    - `GET /health`：健康检查
    - `POST /api/auth/login`：单位与个人认证，发放会话 Token
    - `GET /api/incidents/current` / `POST /api/incidents`：当前警情获取与创建
    - `POST /api/entries` / `PUT /api/entries/:id` / `DELETE /api/entries/:id`：进出场人员管理与压力复核（支持版本并发控制）
    - `POST /api/notes`：火场随手记与战术环节事件
    - `POST /api/chat`：辅助问答「水元素」（流式生成、危化品联网检索、视觉分析）
    - `GET /api/weather/route`：高德路况与目的地天气规划
    - `GET /api/maps` / `GET /api/maps/:unitId/:mapId/*`：重点单位正射影像瓦片服务
    - `GET /ws`：WebSocket 现场警情事件实时广播通道
- **PostgreSQL 仓储与事务**: [`postgres-store.js`](./postgres-store.js), [`db-postgres.js`](./db-postgres.js)
  - 核心接口：`withTransaction(callback)`, `query(sql, params)`, `createEventOutbox(...)`, `listenEvents(...)`
- **语义意图解析引擎**: [`parse.js`](./parse.js)
  - 核心接口：`parseVoiceIntent(text, context)`, `guardrailIntent(intent, text, roster)`
  - 意图类型：`entry` (进场), `exit` (退场/离场), `note` (随手记), `ask` (辅助问答), `ignore` (环境杂音/过滤)
- **空呼测算引擎**: [`calc.js`](./calc.js)
  - 核心接口：`calculateAvailableTime({ capacityLiters, pressureMpa, consumptionRate })`
  - 公式：`可用时间(min) = 容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)`
- **实时语音识别客户端**: [`asr.js`](./asr.js)
  - 核心接口：`createDoubaoAsrClient({ appId, token, cluster })`，支持热词动态注入
- **重点单位与危化品检索**: [`key-sites.js`](./key-sites.js), [`hazardous-chemicals.js`](./hazardous-chemicals.js)
- **子目录契约**:
  - [数据库迁移契约](../migrations/README.md)
  - [管理后台契约](../admin/README.md)
  - [组织种子契约](../seeds/README.md)

## Invariants
- `[server:authMiddleware]`：除 `/health`、公开登录、部分受限扫码轮询外，所有业务接口强制校验 `Authorization: Bearer <token>` 与 `X-Incident-Id`。
- `[entry-concurrency:checkEntryVersion]`：当开启 `WATCHDOG_ENTRY_VERSION_REQUIRED=1` 时，更新人员进退场与压力必须携带 `expected_version`，严格防范离线多设备覆盖冲突。
- `[calc:calculateAvailableTime]`：气瓶压力小于等于 0 时返回剩余可用时间 0；默认消耗率基准为 30 L/min，压力单位统一换算为 MPa。
- `[parse:guardrailIntent]`：宁记不错过——若语音被初步识别为杂音，但文本中命中现场在场名单或核心战术动作关键词，自动降级为 `note` 随手记。

## Side Effects
- 写入 PostgreSQL 业务表（`incidents`, `entries`, `notes`, `key_sites`）并触发 Outbox 事件生成与 `pg_notify`。
- 通过 WebSocket 向所有订阅同一警情频道（`incident:<id>`）的在线客户端单向或广播推送变动事件。
- 向豆包 Seed-ASR、DeepSeek AI 发起外部网络调用；调用高德地图 Web 服务 API。
- 在本地持久卷 `/app/data` 读写临时警情导入图片与切片瓦片。

## Verification
- Run: `npm test`（位于 `backend/` 根目录下，执行 node:test 全套测试）
