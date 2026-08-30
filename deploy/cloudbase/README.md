# CloudBase PG 模式部署

WatchDog 后端部署为腾讯云 CloudBase 云托管服务，业务数据使用 CloudBase PG 模式 PostgreSQL。生产运行时只通过 PostgREST + `service_role` API Key 访问数据库，不把数据库密钥放进 App。

## 1. 创建环境和数据库

1. 在 CloudBase 控制台新建环境，数据库类型选择 PostgreSQL/PG 模式。PG 模式环境需要新建，不能把传统环境直接升级。
2. 记录环境 ID，并创建后端使用的 API Key。该 Key 必须对应 `service_role`，只配置在云托管环境变量中。
3. 在本地配置腾讯云 SecretId/SecretKey，执行版本化数据库迁移：

```bash
cd backend
CLOUDBASE_ENV_ID=<pg-env-id> \
CLOUDBASE_SECRET_ID=<secret-id> \
CLOUDBASE_SECRET_KEY=<secret-key> \
npm run db:migrate
```

迁移脚本只执行 `backend/migrations/` 中的 DDL，不读取、不导入历史 SQLite 数据。迁移脚本会在 PostgreSQL 中记录文件版本与 SHA-256，重复执行时校验和不一致会中止。默认消防员、热词和消防站由服务首次启动时幂等初始化。`002_units.sql` 只新增单位表和可空归属字段，不再写入固定验证码；测试环境可通过 `WATCHDOG_SEED_UNIT_*` 显式预置单位，生产环境必须配置实际单位参数，不会把既有警情改归属到该单位。

## 2. 创建云托管服务

在 CloudBase 控制台创建云托管服务。当前已部署服务名为 `watchdog-api-prod`，服务直连地址为：

```text
https://watchdog-api-prod-294307-10-1351750301.sh.run.tcloudbase.com
```

为避免 App 直接依赖云托管实例域名，在 CloudBase「HTTP 网关」中为默认网关域名配置根路径 `/`，关联资源选择 `watchdog-api-prod`，关闭路径透传。当前 App 使用的网关地址为：

```text
https://watchdog-prod-d6gch930m378d9a16-1351750301.ap-shanghai.app.tcloudbase.com
```

创建或更新服务时：

- 部署入口：仓库根目录的 `deploy/deploy.sh`
- 构建方式：脚本生成临时部署包，使用 `backend/Dockerfile`，并把 `deploy/models/` 一并放入容器的 `/models/`
- 服务端口：`3000`
- 建议最小实例数：`1`；最大实例数按现场设备数量设置
- 健康检查：`GET /api/health`

配置以下运行时环境变量：

```text
WATCHDOG_DB_DRIVER=cloudbase
CLOUDBASE_ENV_ID=<pg-env-id>
CLOUDBASE_API_KEY=<service-role-api-key>
CLOUDBASE_REST_TIMEOUT_MS=10000
CLOUDBASE_REST_MAX_RETRIES=2
# App 使用单位名称 + 单位验证码完成单位级认证；不要求一线人员填写 API_TOKEN。
# API_TOKEN 如仍配置，仅作为旧环境兼容变量，不参与 App 认证。

# 认证升级：完成 004 迁移、成员名单配置并发布支持会话的 App 后才启用
WATCHDOG_SESSION_AUTH_REQUIRED=0
WATCHDOG_MEMBER_AUTH_REQUIRED=0
WATCHDOG_SESSION_TTL_MS=28800000
WATCHDOG_SEED_UNIT_MEMBERS='[{"real_name":"管理员","role":"manager"}]'

# 完成 005_operation_ledger.sql 与 006_integrity_constraints.sql 迁移并验证后启用
WATCHDOG_OPERATION_LEDGER_ENABLED=0
# 完成 007_atomic_write_functions.sql 与 008_atomic_rpc_conflict_index.sql（关键写入/事件复合 RPC 及其冲突目标索引）迁移并通过真实数据库故障注入验证后启用
WATCHDOG_ATOMIC_OPS_ENABLED=0

# 测试/演示阶段预置单位（可选；生产环境必须替换为实际单位参数）
WATCHDOG_SEED_UNIT_ID=longyou-county-fire-rescue
WATCHDOG_SEED_UNIT_NAME=龙游县消防救援大队
WATCHDOG_SEED_UNIT_CODE=0570

VOLC_APP_KEY=<volc-app-key>
VOLC_ACCESS_TOKEN=<volc-access-token>
VOLC_RESOURCE_ID=volc.bigasr.sauc.duration

DEEPSEEK_API_KEY=<deepseek-api-key>
DEEPSEEK_BASE_URL=https://api.deepseek.com
WATCHDOG_LLM_ALLOWED_HOSTS=api.deepseek.com
DEEPSEEK_MODEL=deepseek-chat
DEEPSEEK_CHAT_MODEL=deepseek-v4-flash
CHAT_SEARCH_ENABLED=1
```

若设置 `WATCHDOG_ATOMIC_OPS_ENABLED=1` 却未同时设置
`WATCHDOG_OPERATION_LEDGER_ENABLED=1`，后端会直接拒绝启动，避免原子 RPC 在没有操作账本保护时被重试造成重复业务写入。

计算参数按 `backend/.env.example` 配置。不要把 `CLOUDBASE_SECRET_ID`、`CLOUDBASE_SECRET_KEY` 或 `CLOUDBASE_API_KEY` 写入仓库或 APK。

## 3. 版本发布与验证

国内 CloudBase OTA 暂不启用。正式 APK 由 GitHub Actions 在推送 `v*` tag 后构建，执行 arm64 ABI、版本号、正式签名和 SHA-256 校验，再创建 GitHub Release；App 的版本检查直接读取公开 GitHub Releases。发布只需要配置签名相关的四项 GitHub Actions Secrets，不需要国内 OTA 专用凭据。

先访问 CloudBase HTTP 网关地址：

```text
GET /api/health
GET /api/config
```

再验证新建警情、进场、出场、压力复核、随手记、操作日志、名单热词、辅助问答和语音转写。启用操作账本前先完成迁移前数据扫描；`006` 的约束暂以 `NOT VALID` 方式兼容历史异常，扫描无误后再单独执行 `VALIDATE CONSTRAINT`；`007` 的 RPC 覆盖建档、进场、出场、压力、随手记、归档和参战力量复合写入，`008` 为其 `client_op_id` 冲突目标补齐完整唯一索引。重启云托管实例后确认数据仍存在。

验证完成后，将该 HTTPS 网关地址配置为 App 的默认服务器地址。当前 App 已内置上述地址；也可以通过 `WATCHDOG_API_BASE_URL` 覆盖。首次安装时，启动认证浮层只需填写单位名称、姓名和单位验证码；认证成功后由服务器签发设备会话（启用会话认证时）并保存到系统安全存储。端侧 ASR 模型通过同一网关的 `/models/` 路径下载，也可以用 `WATCHDOG_MODEL_BASE_URL` 单独覆盖；该目录必须同时提供 `manifest.json`，App 会在下载和启用缓存前校验清单中的文件大小与 SHA-256，清单缺失或校验失败不会激活新模型。

生产后端会校验所有出站服务地址：DeepSeek 默认只允许 `api.deepseek.com`；如使用自建代理或兼容服务，必须同时把其主机写入 `WATCHDOG_LLM_ALLOWED_HOSTS`。CloudBase REST 默认必须匹配 `${CLOUDBASE_ENV_ID}.api.tcloudbasegateway.com`；如设置 `CLOUDBASE_REST_BASE_URL` 指向自定义地址，必须同时配置 `CLOUDBASE_REST_ALLOWED_HOSTS`。请求不跟随重定向，避免服务令牌被转发到未登记主机。

正式构建 APK 时注入 CloudBase 服务地址：

```bash
cd app
flutter build apk --release --dart-define=WATCHDOG_API_BASE_URL=https://<cloudbase-service-url>
```

正式包会把 `WATCHDOG_API_BASE_URL` 编译值作为唯一可信服务地址；不要在生产构建中设置
`WATCHDOG_ALLOW_CUSTOM_SERVER=true`。开发或测试确需切换服务时，再显式开启该开关，且地址仍必须使用 HTTPS（本机调试地址除外）。
