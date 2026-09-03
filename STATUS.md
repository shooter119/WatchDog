# 安全员助手 WatchDog — 项目状态

消防救援现场安全管控 App：安全员通过语音登记进退场与气瓶压力，系统计算剩余可用时间，并在多台设备间同步同一份警情档案。

## 当前状态

| 模块 | 状态 |
| --- | --- |
| 后端 | ✅ Express + 标准 PostgreSQL 17；业务数据、永久审计和实时 Outbox 同事务提交，LISTEN/NOTIFY 唤醒多实例 WebSocket；单位隔离、版本冲突、幂等和离线补传已实现 |
| App | ✅ Flutter；默认进入语音处置页，支持警情选择/新建、改名、参战力量维护和归档复盘入口 |
| 归档复盘 | ✅ 12 小时无业务活动自动归档；归档列表可改名，详情展示参战力量快照和晚到早事件时间线 |
| 离线现场操作 | ✅ 进退场、压力复核和随手记使用本地 SQLite 队列，重启后保留，恢复网络后按操作 ID 幂等补传 |
| 后端测试 | ✅ `npm test`：166 个用例通过（含两实例 WebSocket 验收） |
| App 检查 | ✅ `flutter analyze` 通过，`flutter test`：233 个用例通过 |
| Android | ✅ 集中开发 Android，正式签名链路已配置 |
| iOS | ⏸ 暂缓 |

## 核心架构

```
backend/
  src/server.js          REST API、实时现场操作、事件流、归档和审计
  src/db.js              PostgreSQL 运行时入口（SQLite 仅保留旧数据兼容单测）
  migrations/            标准 PostgreSQL 基线迁移，带事务、校验和和 advisory lock
  src/postgres-store.js  参数化 PostgreSQL 仓储、事务上下文和 LISTEN/NOTIFY
  src/db-postgres.js     业务仓储、永久审计事件和事务 Outbox
  sync_events             单位/警情实时流，保留 7 天并支持游标补拉
  src/asr.js             豆包 Seed-ASR WebSocket 客户端
  src/parse.js           DeepSeek 语义解析和防误判规则
  src/calc.js            可用时间 = 容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
  test/                  node:test 单元与 API 验收测试
app/
  lib/pages/             语音处置、看板、火场日志、辅助、设置、归档警情、详情复盘
  lib/api/api_client.dart REST、bootstrap/checkpoint/events 和统一鉴权请求头
  lib/services/realtime_sync_client.dart 单设备 WebSocket、鉴权和心跳
  lib/services/sync_coordinator.dart bootstrap、重连、补拉和 30 秒校准
  lib/services/sync_reducer.dart 事件去重、游标连续性和词库快照转换
  lib/state/app_controller.dart 实时同步、当前警情、现场数据和离线队列调度
  lib/services/offline_queue.dart 本地 SQLite 现场操作队列
  lib/services/diagnostic_log_service.dart 全局异常捕获、本地滚动诊断日志和联网补传
```

## 警情档案规则

- 内部主键为 UUID；可读编号按年月日时分生成，同一分钟自动追加 `-2`、`-3`。
- App 启动优先恢复上次仍活跃的警情；没有当前警情时以模糊遮罩浮层强制选择活跃警情或“新建警情”，完成前锁定底部导航和语音入口，不自动加入唯一警情。
- 新建、改名、参战力量管理和手动归档要求设备已填写真实姓名；操作记录操作者、设备、时间及前后值。
- 进退场、压力复核、随手记和参战力量变化刷新活动时间；改名、查看、问答和设置同步不刷新活动时间。
- 「辅助」是独立的设备级 AI 工具：未创建警情也可使用，聊天历史仅保存在本机，不写入云端警情档案；整段警情简报会自动进入现场研判模式，主动输出风险、处置要点和待核实信息；首次安装即加载内置消防员名单和专业热词。
- 连续 12 小时无业务活动自动归档；归档时保留未确认离场人数，不虚构出场时间。
- 归档现场数据只读；名称只能在归档列表修改。详情页展示参战力量快照和完整事件时间线。
- 事件使用 `client_op_id` 幂等；并发改名或编辑参战力量使用版本号，冲突返回 `409 VERSION_CONFLICT`。
- 单位流承载警情摘要、名单和热词变化；警情流承载进退场、压力、随手记和参战力量变化。游标统一使用十进制字符串。
- 已认证普通成员可以新增姓名和专业热词；内置词条不可删除，退出单位或会话失效时清空本地单位词库。

## 主要接口

- `GET/POST /api/incidents`、`GET/PATCH /api/incidents/:id`
- `POST /api/incidents/:id/archive`
- `GET/POST/PATCH/DELETE /api/incidents/:id/forces`
- `GET /api/sync/bootstrap?incident_id=<可选>`、`GET /api/sync/checkpoint?incident_id=<可选>`
- `GET /api/sync/events`、`WS /api/realtime`
- `GET/POST /api/stations`
- `GET /api/incidents/:id/timeline`
- `POST /api/incidents/:id/offline-operations`
- `GET/PUT /api/profile`
- 现场请求统一使用 `X-Incident-Id`、`X-Device-Id`、`X-Op-Id`；新版认证使用短期会话和单位成员身份。

## 运行和验证

```bash
(cd backend && npm test)
(cd app && flutter analyze)
(cd app && flutter test)
(cd backend && node src/postgres-migrator.js)
(cd app && flutter build apk --debug --dart-define=WATCHDOG_API_BASE_URL=http://10.0.2.2:3000)
```

本地开发使用 `postgresql:///watchdog_dev` / `postgresql:///watchdog_test`；Android 模拟器通过 `http://10.0.2.2:3000` 访问宿主机。部署平台需支持标准 PostgreSQL 17 与长连接，密钥、签名文件和生产数据不入库。
