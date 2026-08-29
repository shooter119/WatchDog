# WatchDog 全面审核主问题台账与验收记录

审核日期：2026-08-27～2026-08-29
审核负责人：WatchDog 主 Agent  ；协作组：后端与架构、Flutter App 功能、UI/UX、安全与隐私、测试与质量、性能与工程质量。
范围：`app/`、`backend/`、`deploy/`、Android 构建与发布工作流、README/关于我们、测试配置及数据库迁移。
工作区策略：保留用户原有未提交改动；本轮不 commit、不 push、不发版。审核辅助材料均在本目录。

## 台账说明

各分组/轮次报告记录了每个发现的完整字段（影响范围、复现/证据、根因、文件、方案、状态、验证）；本表是主 Agent 的去重、修复状态和最终验证索引。分组报告是审查时点快照，若其中状态与本表不同，以本表为准。

状态含义：

- `已修复/待验收`：代码和回归证据已具备，仍需在最终命令/生产环境中复核的项目。
- `部分修复`：低风险部分已处理，但仍有明确缺口；不能作为最终通过依据。
- `待外部/产品决策`：当前代码无法在不发明身份模型、改变核心规则或获得生产权限的情况下安全闭合。
- `待处理`：问题有代码或逻辑证据，尚未修改。

## A. 后端与架构组

详见：[backend-architecture.md](backend-architecture.md)、[backend-cross-review.md](backend-cross-review.md)。

| 编号 | 级别 | 影响/证据 | 根因、文件与方案 | 当前状态与验证 |
|---|---|---|---|---|
| BACK-001 | 严重 | 历史 `unit_id=NULL` 记录可能跨单位可见。 | 读取路径未带租户过滤；`backend/src/server.js`、`db-sqlite.js`、`db-postgres.js` 改为按认证单位读取，历史数据不自动归属。 | 已修复读取边界；历史数据治理纳入主 Agent 自动整改队列，采用隔离和可审计认领，不自动归属。 |
| BACK-002 | 严重 | 固定验证码和认证暴力尝试会影响所有单位入口。 | 认证缺少限流且种子固定；加入 IP+单位限流，种子改为测试环境或显式配置。 | 已修复代码；后端 160/160、Token e2e 通过；真实生产凭据轮换待外部验收。 |
| BACK-003 | 严重 | 客户端可伪造设备/操作者标识。 | 服务端新增成员白名单、哈希会话、会话绑定设备/单位/角色；会话模式下忽略请求体和 header 自报身份，Flutter 已透传会话。 | 已修复；生产已启用严格会话/成员校验，95 名有效成员已落地；真实认证、登出烟测通过。 |
| BACK-004 | 严重 | 名单/热词等全局高影响删除接口缺少角色授权。 | 名单、热词、消防站写操作增加 manager/admin 门禁；日志清空接受管理角色或既有管理令牌。 | 已修复；生产会话/RBAC 开关已启用，成员白名单已落地；管理角色的设备级正式包操作仍纳入持续验收。 |
| BACK-005 | 严重 | Express 4 async 拒绝可能导致请求挂起。 | 路由未统一转发 Promise 错误；`server.js:forwardAsyncRouteErrors` 已包裹已注册 async route。 | 已修复；故障注入返回 JSON 500，后端全量通过。 |
| BACK-006 | 严重 | 业务状态写入与事件写入不是原子幂等，重试可能状态/时间线不一致。 | 关键 SQLite 写入已统一使用 `BEGIN IMMEDIATE`；PG 已加入 `007_atomic_write_functions.sql` 的事务 RPC；操作账本保存摘要、租约和安全结果引用。 | 生产迁移和开关已完成；真实 PostgreSQL 单链路烟测及幂等重放通过；双实例故障注入仍待专用演练环境。 |
| BACK-007 | 严重 | 离线补传 ID 跨警情/类型复用会吞操作。 | `server.js` 已拒绝跨警情/跨类型复用；离线每条操作建立账本并校验请求摘要，正文变化返回 409，不再吞掉重试。 | 已修复；生产原子操作和操作账本已启用，真实离线四类操作烟测通过；多实例压力仍待外部。 |
| BACK-008 | 严重 | 记录级气瓶容量丢失会导致压力复核倒计时错误。 | entries schema/DTO 未保存参数；新增 `cylinder_vol_l`、`consumption_lpm` 及 App DTO/离线 payload。 | 已修复；API、SQLite 迁移、计算回归通过。 |
| BACK-009 | 严重 | 多实例同时新建警情仍可能绕过冷却。 | SQLite 已在事务内完成冷却、编号、建档事件；PG 已准备带单位级 advisory lock 的 `watchdog_create_incident_with_event` RPC。 | 生产迁移、RPC 和开关已完成；真实创建/冷却单链路烟测通过；双实例并发仍待隔离压测。 |
| BACK-010 | 严重 | PostgreSQL 并发活动时间/自动归档可能出现旧值或重复事件。 | 两个 DB driver 已使用条件 `MAX/GREATEST` 活动时间更新和 `changed` 判定；归档、管理写入与事件已接入复合事务方法，PG RPC 已准备。 | 生产迁移、RPC 和归档烟测已通过；真实双实例并发胜者规则与重启恢复仍待外部演练。 |
| BACK-011 | 严重 | DB 初始化失败时健康检查误报 200。 | readiness 未进入 HTTP 响应；`server.js` 现在未就绪返回 503。 | 已修复健康语义；readiness 测试通过；自动恢复策略仍未实现。 |
| BACK-012 | 严重 | ASR/解析/聊天外部资源可被高频调用或高基数 key 占用内存；CloudBase HTTP 网关原先限频为“未设置”，多实例时仅靠进程内限流无法形成全局上限。 | 后端已按 IP+单位执行进程级限流，聊天桶有过期清理和容量上限；CloudBase 网关现配置资源维度总限频 100 QPS，后端保留 429/进程级止损并在隔离环境压测校准；客户端维度因套餐能力未启用。 | 生产网关资源维度配置已完成并由 `DescribeHTTPServiceRoute` 回读为 `QPSTotal=100`，配置后健康接口连续通过；多实例压力验证和阈值再校准仍待外部，详见 `round11-gateway-rate-limit-review.md`。 |
| BACK-013 | 严重 | 原文、姓名、解析和日志可放大数据库/上游成本。 | JSON 512KB、parse/chat/entry/name/raw、音频 15MiB、日志 100 条/单条 8KiB 均有限制；聊天历史先截断到 40 条；日志批量写入单次提交；`/api/chat` 也统一使用固定容量分钟限流器。 | 代码已修复；后端 161/161 通过，`node --check` 与线上部署/健康检查通过。全量容量压测仍待外部。 |
| BACK-014 | 严重 | ASR/解析正文进入普通成员可查询的操作日志。 | 服务端/App 日志对 `text/content/note/prompt/query/raw/error/stack` 等字段只保留长度和摘要；错误消息统一去除异常正文，账本只存安全结果引用；无冒号错误也统一使用固定脱敏占位符。 | 代码侧已进一步闭合并新增脱敏回归；技术日志与普通业务日志的最终角色分层、历史数据策略仍待外部验收。后端 161/161、线上部署和健康检查通过。 |
| BACK-015 | 一般 | 数据库缺少 FK/CHECK，路由代码承担全部一致性。 | PG `006_integrity_constraints.sql` 已加入关键数值 CHECK、父子 FK 和索引，采用 `NOT VALID` 兼容历史；SQLite 新库含 CHECK，旧库只做兼容迁移。迁移脚本按版本/校验和执行并拒绝已应用文件被篡改。 | 生产迁移已落地；迁移前扫描无新增违规数据，13 项约束已创建并保持 `NOT VALID` 以兼容 1 条历史孤立警情；待恢复点具备后执行正式 `VALIDATE`。 |
| BACK-016 | 一般 | 警情列表无分页并有 N+1 forces/归档写入。 | 服务端已增加有限分页、稳定排序、批量参战力量读取和响应头分页信息；App 分页聚合保持既有页面契约；历史数据不自动删除。 | 代码已修复；后端 160/160、App 214/214 通过。真实大数据量延迟与跨实例压测仍待外部。 |
| BACK-017 | 严重 | 自定义服务部署健康检查可能指错地址。 | 部署脚本曾固定 URL；`deploy/deploy.sh` 已支持 `WATCHDOG_HEALTH_URL`，并由本轮实际部署执行健康检查。 | 已修复并完成生产复验；CloudBase Deployment successful，`/api/health` 返回 `ok=true, ready=true, databaseReady=true, asrConfigured=true, llmConfigured=true`。 |
| BACK-018 | 一般 | 迁移无版本表/总事务，失败可留下半套 schema。 | `migrate-cloudbase.js` 已加入版本表、文件 SHA-256 校验、重复执行保护和 dollar-quoted SQL 解析；006/007 迁移按向前兼容方式准备。 | 已修复并在生产执行 001～009；版本记录、重复执行保护和迁移后对象回读通过。CloudBase 单条 API 调用级回滚/恢复能力仍需专用演练。 |
| BACK-019 | 一般 | 容器 root 运行且缺 HEALTHCHECK。 | Dockerfile 已添加非 root 用户和容器健康检查。 | 代码已修复；CloudBase 线上部署健康检查通过，但本机未安装 Docker/Podman，真实镜像构建/容器级启动证据仍待外部。 |
| BACK-020 | 优化 | SQLite/PG 的种子行为不一致。 | 各 driver 各自硬编码；已统一为测试环境或显式 `WATCHDOG_SEED_UNIT_*`，生产不默认写入 0570。 | 已修复；源码/迁移检查和后端测试通过。 |
| BACK-021 | 一般 | 部署脚本在模型目录缺失时仍继续部署，健康检查也未确认模型清单可访问，可能把不完整的端侧能力发布到线上。 | `deploy/deploy.sh` 改为缺少 `models/manifest.json` 时 fail-closed；部署后增加公开模型清单 HTTPS/JSON/字段检查，并固定 CloudBase CLI 版本。 | 已修复；`bash -n`、dry-run、CloudBase 正式部署和线上模型清单检查均通过。 |
| BACK-022 | 严重 | 合法 ASR 服务端响应曾被解析为空，语音页会把成功识别误报为“响应为空”。 | `backend/src/asr.js` 的 `parseFrame` 未跳过协议帧头后的外层 payload 长度字段，导致外层长度被误当成业务 JSON 长度；现已按外层长度截取 payload，再解析序列/业务 JSON，并为 `transcribe` 增加仅测试用的 WebSocket 工厂注入。 | 已修复；ASR 帧生命周期专项 6/6、解析器边界专项及后端全量 160/160 通过。 |

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
| BCR-008 | 一般 | SQLite/PG 分页参数接受负数或小数；SQLite 负 LIMIT 可退化为无界读取，增加资源压力。 | 两个 driver 增加有限正整数下限、取整和上限；`backend/test/db.test.js` 增加边界回归。 | 已修复；后端 160/160 通过。 |

### 工程与安全交叉复核新增项

| 编号 | 级别 | 影响/证据 | 根因、文件与方案 | 当前状态与验证 |
|---|---|---|---|---|
| LOG-SEC-001 | 一般 | 普通成员可查询的服务端操作日志仍可能包含姓名、压力或作者原文；`server.js` 的 `sanitizeLogData` 原先只识别正文/令牌字段，`logs.test.js` 曾直接断言 `name` 与 `pressureMpa` 原值。 | `backend/src/server.js` 扩展敏感字段白名单，姓名/作者使用长度与摘要，压力/人员等非字符串值使用 `[REDACTED]`；重复进场日志消息移除姓名。 | 已修复；日志回归覆盖姓名、压力和作者，后端 160/160 通过。 |
| PERF-RATE-001 | 一般 | ASR/解析/聊天限流按来源和单位构造高基数 key；旧聊天 Map 只在超过 10000 条后粗略清理，同一分钟大量新来源仍可能造成不必要的内存压力。 | `backend/src/rate-limiter.js` 的固定容量分钟限流器统一供 ASR、解析和聊天使用，过期清理后按最近使用时间淘汰，聊天仍保持每分钟 10 次配额。 | 已修复；固定容量、分钟重置和配额回归通过，后端 161/161，线上部署和健康检查通过。 |
| DEPLOY-001 | 一般 | 部署脚本原先只检查远端 manifest 顶层字段，可能放过清单正确但模型文件缺失、大小或 SHA-256 错误的部署包。 | 新增 `deploy/verify-model-manifest.js`；部署前校验本地/临时包每个资源，部署后比较远端清单并逐个下载校验大小和 SHA-256。 | 已修复；本地清单、dry-run、正式部署及线上 6 个资源逐项校验通过。 |
| DEPLOY-002 | 严重 | CloudBase 服务曾显示“已暂停”、实例数为 0，应用网关和服务默认域名均返回 HTTP 503。 | 通过项目既定部署脚本重新部署当前已验证代码，生成部署 031；恢复后连续验证服务状态、健康接口、模型清单和关键鉴权边界。 | 服务可用性阻断已解除：CLI 状态为 `normal`，部署 031 为正常/100% 流量，健康与模型清单连续检查通过；转入持续观察，详见 `round10-deploy-status-review.md`。 |
| ASR-CACHE-001 | 优化 | `/models` 对 `manifest.json` 也使用一年 `immutable` 缓存，清单更新后可能被中间缓存长期保留。 | `backend/src/server.js` 对 manifest 覆盖为 `Cache-Control: no-cache, must-revalidate`，模型二进制继续长期缓存。 | 已修复；后端静态语法/回归通过，线上清单回读正常。 |
| CI-SEC-001 | 优化 | Release workflow 的 checkout 默认持久化 GitHub 凭据，构建链路被依赖污染时写权限暴露面扩大。 | `.github/workflows/release.yml` 设置 `persist-credentials: false`；发布仍仅由显式 Release/OTA 步骤使用受控令牌。 | 已修复；Actions YAML 解析和静态复核通过，下一次新 tag 实跑仍纳入定期验收。 |
| CI-OTA-001 | 严重 | 国内 OTA 所需四个 GitHub Secrets 缺失时会阻断发布；原 workflow 先创建 GitHub Release、后执行 OTA，可能形成半完成版本。 | `.github/workflows/release.yml` 已改为先完成 OTA 上传/远端校验，再创建 GitHub Release；已配置独立、有期限的四项 OTA Secrets，不复用后端运行时凭据。 | 配置前置已闭合；待新的递增 tag 实跑，确认上传与校验成功后才创建 Release。 |
| CI-OTA-002 | 严重 | App 与发布工作流曾把 OTA 地址误指向云托管网关 `/ota`；正确 PG Storage 入口在首次清单上传前返回 404。 | 将 App/Release 统一改为 CloudBase PG Storage `.../v1/storages/object/public/{bucket}/{object}`；后端保留严格白名单的 `/ota/*` 兼容重定向；`009_ota_public_bucket.sql` 创建 `watchdog-ota` 公开读 bucket 和 RLS；发布前动态注入同一公开对象 URL。 | bucket/策略已落地，Secrets 已配置；当前 404 仅表示尚无首个 `latest.json`，待新 tag 实跑完成 APK、清单和公开回读。 |

### 第六轮数据库交叉复核新增项

详见：[round6-db-review.md](round6-db-review.md)。本轮只自动闭合可在本地稳定复现且不改变业务规则的数据库问题；真实 PostgreSQL、并发和恢复证据仍单独保留。

| 编号 | 级别 | 影响范围与证据 | 根本原因、涉及文件与修改方案 | 修复状态与验证 |
|---|---|---|---|---|
| DB-LOCAL-001 | 严重 | SQLite 旧库每次启动都把已有 UUID `scene` 当成旧标识，新建重复警情并改写历史记录；两次启动复现警情数由 1 增至 2。 | `backend/src/db-sqlite.js` 的兼容迁移缺少“对应 incident 已存在则跳过”判断。现按现有警情 ID 幂等跳过，并新增两次启动回归。 | 已修复；重复启动保持 1 条警情且 `scene` 不变，后端 160/160。 |
| DB-LOCAL-002 | 严重 | `007_atomic_write_functions.sql` 的 11 处 `ON CONFLICT (client_op_id)` 与 `001` 的部分唯一索引无法匹配，真实 PG 调用原子 RPC 可能失败。 | 不原地修改既有迁移；新增 `backend/migrations/008_atomic_rpc_conflict_index.sql` 建立可匹配的完整唯一索引，并补迁移静态回归。 | 代码/迁移方案已修复；静态回归通过，真实 PostgreSQL 迁移和 RPC 调用仍待外部验收。 |
| DB-LOCAL-003 | 一般 | 旧 SQLite 警情迁移先写入新警情、再批量改写历史行；中途失败可能留下半迁移状态。 | `migrateLegacyIncidentRows()` 原先没有事务边界。现使用既有 `BEGIN IMMEDIATE` 事务，失败自动回滚，并新增故障注入回归。 | 已修复；注入更新失败时新警情和历史 `scene` 均回滚，后端 160/160。 |
| DB-LOCAL-004 | 严重 | 原子 RPC 开关若脱离操作账本单独启用，重试可能重复创建业务记录或推进版本。 | `backend/src/server.js` 新增启动依赖校验：原子 RPC 必须与操作账本同时启用；新增子进程启动回归和部署文档说明。 | 已修复；配置回归通过，后端 160/160、部署健康检查通过。 |
| DB-EXT-001 | 严重 | 生产 PG 的 RLS 策略/约束实际效果需要迁移后确认，历史数据中存在 1 条孤立单位警情。 | 已执行 `001`～`009` 幂等迁移；保留 `NOT VALID` 约束兼容历史，先完成新写入阻断和真实读写烟测，待恢复点具备后再执行 `VALIDATE CONSTRAINT` 与历史数据治理。 | 生产迁移记录、会话/RBAC/操作账本/原子 RPC、约束和 OTA 策略均已回读；迁移前负值/异常/重复操作 ID 扫描均为 0，真实认证和原子写烟测通过；正式约束验证与孤立历史数据治理仍待恢复点。 |
| DB-EXT-002 | 严重 | 多实例迁移互斥、跨表 RPC 原子性和并发冷却仍需真实多实例验证。 | 生产已启用原子 RPC 与操作账本，保留应用回滚并不删除迁移对象；在可控演练环境使用两个服务实例进行并发、断点和重启测试。 | 生产 PostgreSQL 单链路真实烟测覆盖创建、幂等重放、改名、离线四类操作和归档并通过；CloudBase 当前生产配置为 1 个最小实例，双实例压力/故障注入仍待隔离演练，不能用单链路结果替代。 |
| DB-EXT-003 | 一般 | 生产数据库备份、恢复点和重启扩容后的连续性尚未演练。 | 由运维在隔离环境执行备份恢复和重启/扩容读写演练，记录恢复点与数据连续性，不覆盖生产原库。 | 已通过 CloudBase 控制台确认当前共享集群暂不提供备份能力；CLI 只读复核未改变该结论，且当前可见其他环境无 PG 实例，需升级到支持备份的集群或提供隔离快照后继续。 |

## B. Flutter App 功能组

详见：[flutter-function.md](flutter-function.md)。

| 编号 | 级别 | 影响/根因/文件 | 当前状态与验证 |
|---|---|---|---|
| FLT-001 | 严重 | 长按松手早于异步录音启动；Home/Chat 增加请求代际、占用与取消检查。 | 已修复；Flutter 214/214。 |
| FLT-002 | 严重 | 离线压力/出场本地列表不更新；`AppController` 即时替换/标记。 | 已修复；压力复核还会投影记录级倒计时；离线专项与 Flutter 214/214 通过。 |
| FLT-003 | 严重 | 单条气瓶参数离线/复核丢失；Entry、payload、后端字段补齐。 | 已修复；后端计算回归与 Flutter 通过。 |
| FLT-004 | 严重 | 认证失效不回门禁；结构化 `ApiException` 处理 UNIT/API_TOKEN 失败。 | 已修复代码；Flutter 全量通过，真实失效会话待集成环境。 |
| FLT-005 | 严重 | APK 固化 API token；设置默认空值，认证浮层显式输入并做受保护探测。 | 已修复；Token e2e/Widget 通过。 |
| FLT-006 | 严重 | 离线队列切单位后可能用新身份补传旧警情；`OfflineQueue.drain` 增加允许警情集合。 | 已修复发送边界；队列真实设备切换集成测试待补。 |
| FLT-007 | 严重 | 阈值/计算参数可为负或 0；Settings 常量、setter、页面整体校验补齐。 | 已修复；新增校验测试通过。 |
| FLT-008 | 一般 | 保存期间第二次编辑被丢；加入 queued save。 | 已修复代码；全量 Flutter 通过。 |
| FLT-009 | 一般 | 共享 ApiClient 取消可能影响其他请求。 | 已闭合；认证重试改用独立临时 client，不再关闭共享请求池；详见 FLT-023 并发回归。 |
| FLT-010 | 一般 | 非 JSON 网关错误会泄露 FormatException；ApiClient 所有响应入口统一 `_decodeJson`。 | 已修复；analyze/test 通过。 |
| FLT-011 | 一般 | 自动记日志失败仍跳日志页；仅成功后导航。 | 已修复；Flutter 全量通过。 |
| FLT-012 | 一般 | 详情出场主请求异常边界不完整；拆分主状态与后置日志错误反馈。 | 已修复；Flutter 全量通过。 |
| FLT-013 | 严重 | AlarmService init 失败后不可重试；成功后才置 `_inited`。 | 已修复代码；插件真实失败待设备验证。 |
| FLT-014 | 严重 | 通知调度失败仍标成功；成功后才写 `_scheduled`。 | 已修复；Flutter 全量通过。 |
| FLT-015 | 一般 | 本地 ASR 下载无连接/流读取超时；加入 60 秒 timeout 与 160MB 上限。 | 已修复；模型网络实测待外部环境。 |
| FLT-016 | 严重 | 关闭云 ASR 未等待模型检查；异步 toggle 现先检查/下载，成功才保存。 | 已修复代码；analyze/test 通过。 |
| FLT-017 | 一般 | 自定义服务器仍使用编译期模型地址；`LocalAsrService` 现按构造参数 > `WATCHDOG_MODEL_BASE_URL` > 运行时 `Settings.serverUrl/models` 解析模型源；新增生命周期回归覆盖自定义服务器。 | 已修复；定向测试通过，全量 Flutter 214/214、analyze 0 issues。 |
| FLT-018 | 一般 | Chat 历史加载/发送/清空可能并发覆盖；`chat_page.dart` 增加历史代际/清空屏障，`chat_history.dart` 增加串行 mutation queue，持久化不阻塞 UI。 | 已修复；页面/持久化并发回归通过，全量 Flutter 214/214。 |
| FLT-019 | 优化 | 语音问答空转写或页面销毁操作日志未结束；异常分支已有 `transcribe_error` 终态，`ChatPage.finishRecording()` 与 `dispose()` 已补齐 `op_end`。 | 已修复；定向回归通过，全量 Flutter 214/214。 |
| FLT-020 | 优化 | 实名字段同步白名单但不上传/应用；已补 `real_name`。 | 已修复；后端用户设置测试通过。 |
| FLT-021 | 优化 | release 缺签名文件静默 debug；CI 现在 fail-fast 并做签名指纹校验。 | 已修复；本机 APK 与 GitHub Actions 均通过正式签名校验，最新 Build & Release APK 成功。 |
| FLT-022 | 一般 | 引入系统安全存储依赖后，Android release 编译 SDK 仍停留在 36，正式构建无法完成；`flutter_secure_storage` 要求 compile SDK 37，`app/android/app/build.gradle.kts` 已显式提升到 37，未改变 min/target SDK。 | 已修复；arm64 release 构建成功，`apksigner` v2 校验通过。 |
| FLT-023 | 一般 | 认证重试曾关闭共享 HTTP 客户端，可能中断同时进行的警情同步或日志请求；`ApiClient._withTransientRetry` 改为每次认证重试使用独立客户端，结束后回收；`dispose` 同时关闭临时客户端；新增并发回归。 | 已修复；定向并发测试通过，全量 Flutter 214/214、analyze 0 issues。 |
| FLT-024 | 一般 | 出场接口异常分支未保留服务端错误码，且网关返回 HTML 时可能直接暴露解析异常。 | `ApiClient.markExited` 统一使用 `_decodeJson` 与 `_apiException`，保留 HTTP 状态/服务端 code，并对非 JSON 响应返回结构化 `INVALID_JSON`；新增两项 ApiClient 回归。 | 已修复；定向测试与全量 Flutter 214/214、analyze 0 issues。 |
| FLT-025 | 一般 | 名单/热词接口返回新数据后，管理页未监听 Controller，添加或删除成功但页面继续显示旧列表。 | `app/lib/pages/roster_page.dart` 的页面 body 增加 `AnimatedBuilder(animation: controller)`，使名单、热词数量和列表随 Controller 状态更新；新增管理页加载/添加/删除回归。 | 已修复；管理页回归、全量 Flutter 214/214 与 analyze 0 issues 通过。 |
| FLT-026 | 一般 | 切换或退出警情后，前台保活服务可能继续使用旧警情 ID 轮询；无警情时也可能继续常驻，造成旧现场通知和无效耗电。 | `app/lib/services/foreground_keep_alive.dart` 的 `start()` 在配置写入完成后向已运行服务发送非敏感刷新信号；服务 isolate 重读持久化上下文并以代际校验丢弃旧请求；`app/lib/state/app_controller.dart` 仅在已认证且已有当前警情时启动，退出/归档或无警情时停止；后台值守开关偏好保持不变。 | 已修复代码；新增警情切换、旧请求防回写、无警情启动条件和自恢复旧警情拦截回归，Flutter 223/223、analyze 0 issues。真实 Android 前台服务、进程恢复和通知生命周期仍待外部验收。 |

## C. UI/UX 组

详见：[ui-ux.md](ui-ux.md)。UI-UX-001 是设计基线冲突，不能凭审查者偏好改动默认入口。

| 编号 | 级别 | 影响/证据与文件 | 当前状态与验收 |
|---|---|---|---|
| UI-UX-001 | 严重 | `main.dart` 当前默认语音页，旧设计资料要求看板页，测试也锁定语音页。 | 已完成产品基线决策：认证和警情选择完成后默认进入语音页；认证遮罩、警情上下文、入口/返回路径、测试与文档同步列为待办，暂不改源码。 |
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
| SEC-003 | 严重 | header/profile 可冒用操作者；缺身份会话模型。 | 已增加服务端成员白名单、短期会话、哈希存储、撤销和角色绑定；会话模式下服务端身份覆盖 header/profile。 | 已修复代码并通过严格模式回归；SharedPreferences 安全存储和生产切换仍在后续批次。 |
| SEC-004 | 严重 | legacy NULL 单位记录越权；请求读取已按 unit 过滤。 | 已修复读取边界；历史回填/处置待生产决策。 |
| SEC-005 | 严重 | 日志清空/伪造破坏审计；清空改管理 Token，条目设备字段不再受信。 | 会话模式下操作人/设备从服务端会话读取，日志清空增加角色门禁并保留管理令牌兼容。 | 已修复代码并通过严格模式回归；完整日志分层、不可抵赖审计和生产验收待后续批次。 |
| SEC-006 | 严重 | 0570 种子和认证无限试错；默认种子已移除，失败限流已加。 | 已修复代码；真实单位码轮换待运维验证。 |
| SEC-007 | 一般 | 语音/异常正文泄露到日志；本地/服务端操作日志摘要化。 | 新增服务端/App 敏感键脱敏、错误详情裁剪、诊断字段白名单和安全结果引用；批量日志继续按警情隔离；无冒号错误不再保留原文。 | 代码侧已进一步闭合，后端 161/161、诊断脱敏回归通过；历史日志清理和最终角色隔离仍待外部策略。 |
| SEC-008 | 一般 | 外部资源上限和限流不足；音频、模型、ASR/parse/chat 均有本地/单实例控制。 | 部分修复；多实例网关限流待外部配置。 |
| SEC-009 | 严重 | CloudBase REST 地址若为 HTTP 可能携带 service role；旧 App 自定义地址也可能绕过统一传输校验。 | 后端 CloudBase/DeepSeek 出站地址增加生产 HTTPS 主机白名单；所有上游请求禁止自动跟随重定向；配置通过 `WATCHDOG_LLM_ALLOWED_HOSTS`、`CLOUDBASE_REST_ALLOWED_HOSTS` 显式登记。 | 代码已修复；后端 160/160 与主机白名单回归通过。生产运行时 allowlist 配置和真实上游验证仍待部署环境。 |
| SEC-010 | 一般 | App 服务器地址可改为任意 HTTPS。 | App API/前台服务统一使用 `Settings.isSafeHttpUrl`；正式包只允许编译时登记的服务端点，开发/测试可通过显式 `WATCHDOG_ALLOW_CUSTOM_SERVER` 放宽；模型源单独校验。 | 代码已修复；Flutter analyze 0 issues、214/214 通过。正式签名包运行时验证仍待外部。 |
| SEC-011 | 一般 | Token、单位码、现场内容在 SharedPreferences 明文。 | API Token/session token/单位验证码已接入系统安全存储并保留旧版本兼容迁移；操作日志写入改为串行、当前事件循环合并；现场缓存加密和安全存储故障的真机策略仍需补齐。 | 部分修复；Flutter 214/214 通过。Android 真机安全存储、备份/恢复和业务缓存加密仍待外部。 |
| SEC-012 | 一般 | Android ID 稳定指纹可跨重装关联。 | 设备标识改为随机安装 ID，服务端会话仍绑定当前安装句柄；退出单位时清理前台服务中的令牌/单位/警情上下文。 | 代码已修复；Flutter 214/214 通过。Android 真机卸载重装与设备撤销验证仍待外部。 |
| SEC-013 | 一般 | 本地模型无签名/sha256 manifest。 | `deploy/models/manifest.json` 为当前模型文件提供版本、大小和 SHA-256；`app/lib/services/local_asr_service.dart` 下载前读取并校验清单，下载后逐文件校验、写入完整性快照，启动/启用本地 ASR 前复核缓存，仍使用 staging + 原子 active 切换。 | 哈希清单与缓存复核已实现；Flutter analyze 0 issues、定向 ASR/生命周期回归通过。签名清单、公钥/私钥发布链路及 Android 真机验证仍待外部，不能宣告项目级闭合。 |
| SEC-014 | 严重 | GitHub Action tag 可变，发布签名依赖 secrets。 | 代码级供应链风险已闭合；仓库已启用 `main` 分支保护、`v*` tag 删除/强制更新保护和 Actions SHA 固定，发布权限与签名 secrets 仍按最小权限定期审计。 | 已闭合；`main` 必须 PR+1 名评审并通过 `backend`/`app` 检查，禁止强推/删除；Ruleset `Protect published version tags` 为 active；Actions `sha_pinning_required=true`；最新 Actions 与 Release 均成功。 |
| SEC-015 | 严重 | 生产 DB driver 缺失时静默 SQLite；`db.js` 现在生产只允许 PostgreSQL/CloudBase。 | 已采纳生产 fail-fast、readiness 阻断、迁移预检、重启扩容和备份恢复演练方案。 | 方案已采纳，待实施/生产验证；代码级保护和单测已通过，真实持久化仍待 CloudBase。 |
| SEC-016 | 优化 | RLS 开启但无租户策略，service_role 全表 DML。 | 已采纳服务端会话租户上下文、受限运行时角色/ RPC、单位范围 RLS 和全局表分离方案；RLS 不作为唯一防线。 | 方案已采纳，待实施；需 CloudBase 真实 PostgreSQL/角色权限证据。 |
| SEC-017 | 一般 | 本机忽略的 env/key 文件权限曾未验证。 | 已修复本机工作区权限：`backend/.env`、`app/android/key.properties`、keystore 均收紧为 `0600`；未入库扫描通过。生产主机/CI secret 权限仍需运维平台验收。 |
| SEC-018 | 严重 | CloudBase CLI/控制台服务详情会把部分运行时环境变量原样显示，存在 API/业务密钥进入终端、截图或操作记录的风险。 | 本轮通过 CloudBase 控制台实测确认该显示行为；后续只允许使用字段过滤后的状态查询，禁止在汇报和仓库保存任何值。API Token、上游服务密钥和 CloudBase service key 轮换会影响现有客户端和线上服务，需要运维按顺序轮换并做健康/关键链路验收。 | 已确认外部运维处置项；本轮未复制具体值、未写入仓库，未执行可能造成线上中断的轮换操作，详见 round9-production-pg-readonly-review.md。 |
| SEC-019 | 一般 | 严格会话认证下，认证中间件能识别大小写混合的 `Bearer`，但登出接口原先大小写敏感；客户端登出可能返回成功而未撤销会话。 | `backend/src/server.js` 新增 `sessionTokenFromRequest`，认证校验和登出统一使用大小写不敏感的 Bearer 解析；`backend/test/session-auth.e2e.test.js` 增加混合大小写登出后旧会话失效回归。 | 已修复；后端 160/160 通过。 |
| SEC-020 | 一般 | 前台服务插件的数据区底层使用 SharedPreferences，原实现会把 API Token、会话令牌和单位验证码明文落盘；安全存储失败时也会回退写入明文。 | `app/lib/services/foreground_keep_alive.dart` 改为令牌/会话/单位验证码只进 `SecureStore`，服务 isolate 从安全存储读取并清理旧插件键；`secure_store.dart` 在 Android/iOS 原生存储失败时 fail-closed；Android 禁止备份和设备转移。 | 代码已修复；Flutter 214/214、analyze 0 issues。Keystore、备份恢复和前台服务 isolate 真机验证仍待外部。 |

## E. 测试与质量组

详见：[testing-quality.md](testing-quality.md)、[quality-cross-review.md](quality-cross-review.md)。

| 编号 | 级别 | 影响/证据 | 当前状态与验证 |
|---|---|---|---|
| TQ-001 | 一般 | `AGENTS.md` 与 CI 测试数量基线曾滞后于实际用例；若基线不随新增用例提高，后续误删新增测试仍可能通过。 | 已修复；`.github/workflows/quality.yml` 与 `.github/workflows/release.yml` 的最低基线已同步为后端 161、App 223，并继续拒绝 skipped/todo；YAML 解析和本机后端 161/161、App 223/223 门禁验证通过。 |
| TQ-002 | 严重 | 发布前曾不运行质量门禁；已新增 quality workflow，并在 release 中重复 backend/npm 与 Flutter analyze/test。 | 已修复；最新 Quality Checks 与 Build & Release APK Actions 均成功，仓库保护已按 SEC-014 完成。 |
| TQ-003 | 一般 | ASR/parse HTTP 边界覆盖不足。 | 已补充 ASR WebSocket 帧生命周期、服务端错误/超时/空结果、DeepSeek/Responses API 非 2xx/空响应/响应形状/重定向和超时信号边界回归。 | 本地代码级缺口已闭合；后端 160/160 通过。真实供应商联调仍待外部凭据和运行时环境。 |
| TQ-004 | 严重 | App 真同步/离线队列被替身绕开。 | 逻辑已修复，真实网络/断网集成仍待设备与环境。 |
| TQ-005 | 严重 | 真实录音、权限、本地 ASR 模型未覆盖。 | 待外部 Android 设备集成验证。 |
| TQ-006 | 严重 | 真正报警/TTS/前台保活插件未覆盖。 | 阈值校验和服务失败重试已有单测；插件行为待设备。 |
| TQ-007 | 一般 | ApiClient 传输层边界历史覆盖不足。 | 已补充独立本地 HTTP fixture，覆盖成功响应结构、分页、并发认证、服务端错误码、出场错误和非 JSON 网关响应。 | 已修复；相关回归与 Flutter 全量 214/214 通过。 |
| TQ-008 | 严重 | PG/PostgREST 真实迁移与契约未验证。 | fake repository 和 schema 已过；CloudBase 凭据/环境阻塞。 |
| TQ-009 | 一般 | 管理端点/归档页面边界不足。 | 后端管理员门禁、归档接口幂等与页面加载/改名/管理操作均已覆盖。 | 已修复；后端 160/160、管理页面回归及 Flutter 全量 214/214 通过。 |
| TQ-010 | 优化 | 测试依赖墙钟/固定尺寸/pumpAndSettle，可能脆弱。 | 本轮已修复日志可视性断言；其余待逐步稳定。 |
| TQ-011 | 优化 | 无覆盖率产物/最低门槛。 | 待工程决策。 |
| TQ-012 | 一般 | 发布流水线可并行推进旧 tag，且 OTA CLI 未固定版本，存在旧版本覆盖国内 `latest.json` 或部署参数漂移风险。 | release workflow 增加串行并发组、发布前 `versionCode` 单调递增检查，并固定 `@cloudbase/cli@3.8.1`；部署脚本复用同一固定版本。 | 已修复配置；本地 YAML/脚本静态检查通过，下一次正式发布时需由 Actions 实跑复核。 |

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
| PE-001 | 一般 | 录音无时长上限且有内存复制；当前仅有 15MB 客户端/服务端大小上限。按 16kHz、单声道、16-bit WAV 计算，约可持续 8 分钟后才触发文件超限。 | `app/lib/services/audio_service.dart` 的 15MB 检查继续保留；`home_page.dart` 与 `chat_page.dart` 增加统一 60 秒计时、50 秒警告和到点自动停止，自动停止复用原有转写/解析/问答链路。 | 代码已修复；新增首页/辅助页边界回归，当前 Flutter 223/223、analyze 0 issues。真实录音、系统调度和权限行为仍待 Android 真机验收。 |
| PE-002 | 一般 | stop 异常临时 WAV 泄漏；AudioService finally 清理。 | 已修复；Flutter 全量通过。 |
| PE-003 | 一般 | 页面卸载时活动录音可能遗留；dispose 释放。 | 已修复代码；真机生命周期待外部。 |
| PE-004 | 一般 | 主 isolate/前台服务原先同时以 5 秒频率轮询并持有唤醒锁，重复拉取看板数据；主 isolate 成功同步后向服务 isolate 发送摘要时间、人数和最早到期时间，服务在 8 秒新鲜窗口内跳过重复网络请求，主同步停顿后恢复后台兜底拉取。 | 代码已修复重复网络拉取；Flutter 全量 214/214。真实后台生命周期、电量和网络流量仍待 Android 真机测量。 |
| PE-005 | 一般 | 前台回调重叠；加入 in-flight 闸门。 | 已修复代码；Flutter/静态检查通过。 |
| PE-006 | 优化 | 每秒 tick 原先通过根 `ChangeNotifier` 广播，导致所有 Tab 页面树跟随重建；已拆分 `AppController.clockTick`，根页面只响应业务状态，Home/Board/EntryDetail 仅局部监听倒计时，告警检查行为保持不变。 | 代码已修复；Flutter 全量 214/214、analyze 0 issues。 |
| PE-007 | 一般 | 同步列表触发归档写和 N+1 forces；已加入服务端有限分页、稳定排序和批量参战力量投影，并保留单位/状态边界；真实查询计划和大数据延迟仍需压测。 | 代码已修复；后端分页/批量回归与 Flutter 214/214 通过。 |
| PE-008 | 一般 | 操作日志上传会清空上传期间新日志。 | 已修复为快照删除；Flutter 全量通过。 |
| PE-009 | 一般 | 诊断上传会删掉上传期间新 pending。 | 已修复为快照/仅删已上传 op；Flutter 全量通过。 |
| PE-010 | 一般 | 每条操作日志完整写 SharedPreferences；本地日志改为当前事件循环合并序列化、尾部串行写入，并在退出单位/清空时显式落盘；应用级加密存储仍属 SEC-011 外部项。 | 代码已修复当前写放大；Flutter 214/214 通过。 |
| PE-011 | 一般 | chat rate Map 高基数无过期；已清理并改 key。 | 已修复单实例内存生命周期；多实例限流待网关。 |
| PE-012 | 一般 | SSE 客户端断开未取消 DeepSeek 上游。 | 已修复；`server.js` 绑定下游生命周期并取消上游 fetch/reader；SSE 断连回归通过。 |
| PE-013 | 优化 | 服务端日志逐条写 DB；服务端批量日志接口使用单次事务/数组写入，保留单条回退兼容；真实高并发吞吐仍待压测。 | 代码已修复；后端 160/160 通过。 |
| PE-014 | 一般 | 模型下载无超时；已加连接/流读取 timeout 与尺寸上限。 | 已修复代码；真实网络待外部。 |
| PE-015 | 严重 | 告警 Future 异常可能卡 looping；AlarmService/controller 安全包装。 | 已修复代码；插件实测待设备。 |
| PE-016 | 一般 | arm64 标识与实际 APK ABI 不符，且 split-per-abi 会让 APK 内 versionCode 与 tag 后缀产生偏移。 | release workflow 改为只构建目标平台 arm64 的单 APK，并保留解包 ABI 检查；APK 内 versionCode 与 tag/OTA 清单保持一致。 |
| PE-017 | 优化 | 依赖有 discontinued/落后版本；本次只读扫描显示 Flutter 有 12 个锁定旧版本、7 个受约束版本。 | 后端 `npm audit --omit=dev --audit-level=high` 为 0 vulnerabilities；Flutter 依赖升级保留到维护窗口，逐项升级并跑完整 Android/插件回归，不在本轮擅自升级。 |
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
| PE-MODEL-001 | 一般 | 进程被杀或重复更新后 ASR 旧 generation 可能残留并占用磁盘；低存储下载还可能影响现场可用性。 | 下载前清理崩溃遗留 `.staging` 与 `.active.*.part`；新 generation 激活后等待识别队列空闲，仅删除不再被当前识别器/降噪器引用的旧 generation，保留 active 与仍在使用的集合；新增下载前和逐文件可用空间检查，低存储明确提示、提供系统存储入口和联网识别降级，不自动删除当前模型或用户数据。 | 已修复代码；新增低存储预检、旧 active 保留、平台存储能力不可用降级回归；当前 Flutter 223/223、analyze 0 issues。真实 Android 低存储与系统设置跳转仍待外部验收。 |
| PE-019 | 一般 | OTA 下载只校验 SHA-256，若清单大小与响应体不一致或响应无界，可能持续占用应用存储。 | `app/lib/services/update_service.dart` 增加 160MB 上限、清单大小上限、响应 `Content-Length` 预检、流式累计上限和下载后精确字节数校验；增加超限/截断回归。 | 已修复；相关测试与 Flutter 全量 214/214 通过。 |

### 恢复后的续审新增项

| 编号 | 级别 | 影响/证据 | 根因、文件与方案 | 当前状态与验证 |
|---|---|---|---|---|
| WD-APP-R6-001 | 严重 | 已保存警情因单位切换、服务端撤销或权限收紧而不可见时，App 曾继续展示旧警情快照，存在跨单位误呈现/信息残留风险。 | `app/lib/state/app_controller.dart` 异常分支未处理 `INCIDENT_NOT_FOUND`；现已清除当前警情、entries/notes/forces，停止保活/告警调度，并新增 `app/test/app_controller_offline_test.dart` 回归。 | 已修复；定向与全量 Flutter 196/196、analyze 0 issues；API 33 模拟器修复前后 UI 对比和隔离后端单位归属新建警情通过。 |
| FLT-017（续审闭合） | 一般 | 自定义服务器仍使用编译期模型地址。 | `LocalAsrService` 现按构造参数 > `WATCHDOG_MODEL_BASE_URL` > 运行时 `Settings.serverUrl/models` 解析模型源；新增自部署服务器回归。 | 已修复；定向与全量 Flutter 196/196、analyze 0 issues。 |
| FLT-019（续审闭合） | 优化 | 辅助页空转写或页面销毁后操作日志曾缺少 `op_end`。 | `ChatPage.finishRecording()` 与 `dispose()` 现对空转写写入 `op_end(outcome=no_speech)`，对页面销毁写入 `op_end(outcome=page_disposed)`；新增两个 Widget 回归。 | 已修复；定向回归通过；全量 Flutter 196/196、analyze 0 issues。 |

### 本轮继续施工（2026-08-28～2026-08-29）

| 编号 | 级别 | 影响范围与证据 | 根本原因、涉及文件与修改方案 | 修复状态与验证 |
|---|---|---|---|---|
| SEC-009-R1 | 严重 | 后端运行时配置可以把携带 API/service role 的请求指向未登记 HTTPS 主机；默认 `fetch` 还会自动跟随重定向。 | 出站地址只有协议级校验，缺少目标主机边界。新增 `backend/src/network-policy.js`，服务端校验 DeepSeek 默认/显式主机白名单，CloudBase 校验环境派生主机或显式白名单，DeepSeek/CloudBase 请求均设置 `redirect: 'error'`；同步 `.env.example` 与部署说明。 | 代码已修复；主机白名单、CloudBase 环境匹配和配置冲突回归通过，后端 160/160。生产运行时配置和真实上游重定向验证仍待部署环境。 |
| SEC-010-R1 | 一般 | 正式 App 可将业务 Token、单位码和设备信息发送到用户改写的任意 HTTPS 地址。 | App 仅在保存时做 HTTPS/本机校验，正式包没有编译时目标边界。`Settings` 增加正式包端点锁定和显式开发开关，`ApiClient` 统一调用同一校验，模型下载使用独立可信地址校验。 | 代码已修复；Flutter analyze 0 issues、全量 200/200 通过。正式签名 APK 的运行时拒绝验证仍待外部。 |
| PE-010-R1 | 一般 | 操作日志高频记录会反复序列化完整日志快照并写入 SharedPreferences；本轮延迟定时器还造成测试收口遗留 timer。 | 持久化没有事件循环级合并且使用延迟 Timer。`op_log_service.dart` 改为微任务合并、尾部串行写入，并在清空/退出单位时显式落盘；不改变日志内容和上传契约。 | 已修复；专项回归通过，Flutter 全量 200/200；未发现待处理 timer。 |

## G. 交叉复核结论

- 后端交叉复核执行了旧 SQLite 启动迁移、错误 Token、轮换设备限流、跨类型操作 ID、超长 PATCH、async 数据库异常和分页边界复现；8 项新增问题均已修复并由后端测试回归。
- 质量交叉复核覆盖认证 Token 持久化时序、录音启动失败/重入、设置整体校验、Bearer/嵌套日志脱敏、发布质量门禁和版本一致性；8 项新增问题均完成代码修复或明确记录外部验收边界。
- 第二轮质量/UI 交叉复核闭合 ApiClient 响应结构、多人解析最终快照、离线状态投影、坏 payload 隔离、ASR 集合原子切换、测试数量门禁及 UI-UX-003～009；均有专项回归或静态搜索证据。
- 主 Agent 复核发现并处理了发布 APK 实际 ABI 与 workflow 门禁不匹配、单位 A 查询归档单位 B 警情、切换单位后离线队列发送边界、生产固定 0570 种子、API_TOKEN 失效回门禁、ApiClient 非 JSON 错误等补充问题。
- 第三轮交叉复核闭合 SSE 下游断开、上游错误脱敏、问答历史竞态、同步反馈时序、重复无障碍语义、看板大字体溢出、CloudBase HTTPS、本机 secret 权限和 CI 超时；剩余身份/RBAC、真实环境与设备项保持外部阻塞。
- 第四轮复核闭合 SQLite 重复归档状态保护、App 启动/刷新/ASR/前台服务竞态、页面即时重试、日志/统计窄屏大字体布局，以及测试平台隔离和 skipped/todo 门禁；恢复后的续审又闭合了 WD-APP-R6-001；性能指标、身份模型、PG 跨实例事务、物理 Android/Actions 仍需外部证据。
- 第五轮交叉复核发现并闭合服务端日志敏感字段、高基数限流、部署模型逐文件校验、manifest 缓存陈旧风险和 Release checkout 凭据持久化；同时发现 `FLT-026` 前台保活切换警情上下文问题，因直接影响后台通知与耗电，保留给用户确认使用路径后实施。
- 第六轮数据库交叉复核发现 SQLite 旧库迁移重复建档、旧库迁移非事务，以及原子 RPC 冲突目标与部分唯一索引不匹配；续审又闭合原子 RPC 开关依赖保护；`DB-LOCAL-001`～`DB-LOCAL-004` 已完成代码和回归修复，新增 008 号 PostgreSQL 向前迁移；真实 PG/RLS、多实例和备份恢复仍待外部证据。

## H. 最终验证记录

| 验证项 | 结果 | 证据 |
|---|---|---|
| 后端测试 | 通过：161/161，0 失败 | `cd backend && npm test` |
| Flutter 静态分析 | 通过：0 issues | `cd app && flutter analyze` |
| Flutter 测试 | 通过：223/223，0 失败，skipped=0 | `cd app && flutter test` |
| Android release 构建 | 通过 | `flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub`；最终构建成功 |
| APK ABI/签名 | 通过 | 当前工作区重建 APK 仅含 `lib/arm64-v8a/`，47.4MB；`apksigner verify` v2=true、1 signer，证书 SHA-256：`0676114be5b9eb9d4448cb849d9b938b278214bb81de04a5debcde5eaf270668`；当前工作区 APK SHA-256：`338ae23c78223b69797e7f583a2420c41c6140681aaa35ee6596bbde3df623cb`。 |
| 已发布 Release 资产 | 通过 | `v1.2.1+49` 公开 arm64 APK 实际 SHA-256：`0cf29e20ca8afcdb0849dd211519bf0ce04a787514afde40bae82d321001b4aa`，与 Release 正文 `SHA256:` 完全一致；v2=true、1 signer。 |
| 部署包 dry-run | 通过 | `deploy/deploy.sh --dry-run` 能生成临时包并包含 backend/src 与 models |
| 生产部署 | 通过 | 最新后端/部署改动已再次执行 `CLOUDBASE_ENV_ID=watchdog-prod-d6gch930m378d9a16 ./deploy/deploy.sh`；CloudBase 返回 Deployment successful，健康检查 `ok=true, ready=true, databaseReady=true, asrConfigured=true, llmConfigured=true`，模型清单和 6 个远端资源逐项校验通过。 |
| 生产网关共享限频 | 部分通过 | CloudBase `DescribeHTTPServiceRoute` 回读默认 `/` 路由 `QPSPolicy.QPSTotal=100`，配置后健康接口连续通过；客户端维度因套餐能力未启用，多实例突发流量/429 校准仍待隔离环境。 |
| 线上模型清单与资源 | 通过 | 公开 `/models/manifest.json` 回读与仓库清单字节级一致；6 个模型资源逐个下载并与清单大小/SHA-256 全部匹配；manifest 响应为 `Cache-Control: no-cache, must-revalidate`。 |
| 生产未授权边界 | 通过 | 未带 `X-Api-Token` 请求 `/api/config` 返回 HTTP 401、`API_TOKEN_INVALID`；未使用真实令牌做业务写操作。 |
| GitHub Actions | 通过 | 最新 Quality Checks 与 Build & Release APK 均为 success；正式 Release `v1.2.1+49` 已上传 arm64 APK，tag 与 `main` 指向同一提交。 |
| GitHub 仓库保护 | 通过 | `main` 已启用保护：必须 Pull Request、至少 1 名评审、`backend`/`app` 检查通过，禁止强推和删除；Ruleset 已保护 `v*` tag 的删除与强制更新。 |
| Actions SHA 固定 | 通过 | GitHub 仓库 API `sha_pinning_required=true`；当前 workflow 中所有第三方 Action 均使用提交 SHA。 |
| Android 设备验证 | 部分通过 | 实体设备 `PKX110`（Android 16/API 36）已完成隔离真机认证、通知权限、警情创建/命名、默认进入语音页、麦克风授权与实际录音、ASR 不可用提示、权限拒绝和系统设置跳转；未向生产数据库写入。前台服务/进程恢复/低存储/TalkBack/TTS/耗电和厂商后台策略因设备再次锁屏仍待外部，详见 `round17-android-device-review.md`。 |
| README/关于我们 | 已同步 | 认证、单位种子、生产不默认 0570、端侧模型完整性校验及低存储保护的描述已同步；版本未发版未改。 |
| 密钥/临时文件 | 通过（仓库级） | `git diff --check` 通过；tracked 文件未发现 `.env`、`key.properties`、keystore 或调试脚本匹配项；release 构建产物位于 ignored build 目录；本机 `.env`、`key.properties`、keystore 均为 `0600`。主机上未验证的生产文件权限仍属运维边界。 |
| 本轮继续施工门禁 | 通过 | 后端 `node --check` 通过，`npm test` 为 161/161；App `flutter analyze` 为 0 issues，`flutter test` 为 223/223；新增录音 60 秒上限/50 秒提示/自动停止、低存储模型保护、平台存储能力降级、前台值守警情切换/旧请求防回写/无警情停止/自恢复旧警情拦截、ASR WebSocket 帧生命周期、DeepSeek/Responses API 错误边界、模型 manifest/哈希校验、缓存复核、清单格式/路径/重定向边界、OTA 大小上限、出站主机/IP 白名单、重定向禁止、App 正式包地址锁定、令牌安全存储/前台服务隔离、Android 备份禁用、日志微任务合并、认证重试并发和双轮询摘要协调、ApiClient 错误响应、名单管理页面状态更新、日志敏感字段和高基数限流、SQLite 旧库幂等/事务和原子 RPC 冲突目标、原子 RPC 开关依赖保护、OTA 公开对象重定向与迁移契约回归均通过。 |
| 第十四轮门禁与卫生复核 | 通过 | `opendesign/audit/round14-local-gate-review.md`：后端 161/161、Flutter analyze 0 issues、Flutter 223/223；workflow YAML、`git diff --check`、审计目录敏感值扫描和线上健康/模型清单回读通过；GitHub 授权有效，OTA 专用 Secrets 仍缺失。 |
| 第十六/十七轮 Android 复核 | 部分通过 | 第十六轮完成 arm64 release 包级核对；第十七轮使用独立本地 Debug 包完成认证、警情创建/命名、默认语音页、通知/麦克风权限、实际录音、ASR 降级和拒绝权限设置跳转。未向生产写入；前台服务、进程恢复、低存储、TalkBack、TTS、耗电及厂商后台策略仍待解锁后的场景验证。 |
| 依赖安全扫描 | 通过/待维护 | 后端生产依赖无高风险 audit 报告；Flutter 依赖存在可升级项，但未发现本扫描可直接证明的安全漏洞，升级留待维护窗口。 |

## I. 当前验收判定

代码级回归验收通过：核心后端/App 测试、分析、构建、UI 边界和已复现缺陷修复均有证据，当前运行时测试为后端 161、App 223，未减少；第十轮发现的生产服务暂停已通过部署 030 恢复，健康与模型清单连续检查通过。

整轮项目验收尚未宣告完成，原因是以下项目不是主 Agent 可以安全猜测或本机完成的外部阻塞；本轮发布操作已获用户明确授权，且不改变这些未闭合的项目级验收边界：

1. 生产会话/RBAC 的成员名单、角色配置和开关已落地并通过真实认证/登出烟测；管理角色设备级正式包操作仍需持续验收。
2. BACK-006/BACK-009/BACK-010 的跨表原子幂等已通过生产 PostgreSQL 单链路烟测；多实例冷却、故障注入和备份恢复仍需专用演练证据。
3. SEC-009/SEC-010 的生产 allowlist 与正式签名包运行时边界还需部署配置和真实 APK 验证；代码级回归已通过。
4. SEC-011/SEC-012、模型完整性和性能项仍需 Android 真机验证，包括安全存储、备份恢复、卸载重装、低存储、录音插件、本地 ASR、通知/前台服务、TalkBack 和弱网；本轮已完成隔离认证、警情创建/命名、默认语音页、通知/麦克风权限、实际录音、ASR 降级及拒绝权限设置跳转，模型签名清单与发布私钥链路仍需外部发布环境接入。
5. `FLT-026` 的前台保活警情切换/退出行为已确认使用规则：切换立即刷新，退出/归档停止，无警情不启动并保留开关偏好；代码级时序回归已通过，仍待 Android 生命周期验收。
6. `CI-OTA-001` 的四个国内 OTA GitHub Secrets 已配置为独立、有期限密钥；仍需用新的递增 tag 实跑，确认 OTA 与 Release 资产一致。
7. `CI-OTA-002` 的 CloudBase PG Storage `watchdog-ota` bucket、公开读策略已落地；当前 `latest.json` HTTP 404 仅表示尚未进行首次上传，旧 `/ota/*` 兼容入口已部署复验，详见 `round8-ota-public-url-review.md`。
8. `DB-EXT-003`：当前共享集群没有备份能力，生产备份/恢复点和重启扩容连续性仍需升级到支持备份的集群或提供隔离快照后演练；不以生产破坏性操作代替。
9. `DEPLOY-002` 已通过部署 031 和连续 HTTPS 检查恢复：服务状态为 `normal`，100% 流量，健康与模型清单均通过；转入持续观察，不再阻断后续发布验收，详见 `round10-deploy-status-review.md`。

在上述外部条件满足前，本台账不把“全部外部验收”标记为完成；但生产发布前置已经具备。当前仍保留的外部持续项是双实例限流/并发与故障恢复、备份恢复、正式包解锁后的系统级 Android 验收，以及首次 OTA tag 实跑；这些不以猜测或破坏性生产操作替代。用户已确定认证和警情选择后默认进入语音页，后续只按该基线做实现复核和设备验收，不再重新讨论入口。

外部验收执行步骤已统一收录于：[external-acceptance-runbook.md](external-acceptance-runbook.md)。

## J. 剩余问题归类与执行授权

用户已明确：不直接影响界面、页面流程、用户操作方式或产品体验的事项，由主 Agent 直接制定方案、实施、测试和验收，不再逐条询问技术细节；只有前端体验和使用逻辑中的产品取舍才单独汇报。

完整分类、统一方案和执行顺序见：[remaining-issues-classification.md](remaining-issues-classification.md)。

### 主 Agent 自动整改队列

- 身份/RBAC/单位隔离：`BACK-001`、`BACK-003`、`BACK-004`、`SEC-003`、`SEC-004`、`SEC-005`。
- 数据库一致性/迁移/RLS/生产持久化：`BACK-006`、`BACK-007`、`BACK-009`、`BACK-010`、`BACK-015`、`BACK-018`、`SEC-015`、`SEC-016`、`TQ-008`、`DB-LOCAL-001`～`DB-LOCAL-004`、`DB-EXT-001`～`DB-EXT-003`。
- 限流/输入资源/隐私日志：`BACK-002`、`BACK-012`、`BACK-013`、`BACK-014`、`SEC-006`、`SEC-007`、`SEC-008`、`PE-018`。
- 出站目标/设备标识/本地存储/模型完整性/生产密钥暴露：`SEC-009`～`SEC-013`、`SEC-017`、`SEC-018`。
- 查询/轮询/内存/工程效率：`BACK-016`、`PE-004`、`PE-006`、`PE-007`、`PE-010`、`PE-011`、`PE-013`、`PE-017`、`PE-MODEL-001`。
- 发布/容器/仓库权限/线上可用性：`BACK-017`、`BACK-019`、`BACK-021`、`TQ-001`、`TQ-002`、`TQ-012`、`PE-R3-001`、`FLT-021`、`DEPLOY-002`；`SEC-014` 已闭合并转入定期审计。
- 测试和真实环境验证：`TQ-003`～`TQ-011`、`FLT-004`、`FLT-006`、`FLT-009`、`FLT-013`、`FLT-015`、`PE-003`、`PE-014`、`PE-015`，以及已修复项目的设备级验证。

### 前端/体验汇报队列

- `UI-UX-001` 默认语音页已由用户确认，按既定方案实施，不再重新讨论入口。
- `FLT-026` 前台保活服务在切换/退出警情时的上下文刷新与停止行为，使用规则已确认；代码已实施并通过时序回归，仍待设备验收。
- `PE-001` 录音时长上限及超限提示已实施并通过代码级回归；真实录音、权限和系统生命周期仍待 Android 真机验收。
- `PE-MODEL-001` 低存储时不自动删除当前模型或用户数据；空间不足提示提供系统存储设置和联网识别降级，代码已实施并通过 Flutter 回归，真机低存储与系统设置行为仍待外部验收。
- `UI-UX-010` 暂无运行时缺陷证据，继续保持建议项，不阻塞验收。
