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

迁移脚本只执行 `backend/migrations/` 中的 DDL，不读取、不导入旧 ByteVirt SQLite 数据。默认消防员、热词和消防站由服务首次启动时幂等初始化。

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

- 源码目录：`backend/`
- 构建方式：使用 `backend/Dockerfile`
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
API_TOKEN=<random-api-token>

VOLC_APP_KEY=<volc-app-key>
VOLC_ACCESS_TOKEN=<volc-access-token>
VOLC_RESOURCE_ID=volc.bigasr.sauc.duration

DEEPSEEK_API_KEY=<deepseek-api-key>
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-chat
DEEPSEEK_CHAT_MODEL=deepseek-v4-flash
CHAT_SEARCH_ENABLED=1
```

计算参数按 `backend/.env.example` 配置。不要把 `CLOUDBASE_SECRET_ID`、`CLOUDBASE_SECRET_KEY` 或 `CLOUDBASE_API_KEY` 写入仓库或 APK。

## 3. 验证

先访问 CloudBase HTTP 网关地址：

```text
GET /api/health
GET /api/config
```

再验证新建警情、进场、出场、压力复核、随手记、操作日志、名单热词、辅助问答和语音转写。重启云托管实例后确认数据仍存在。

验证完成后，将该 HTTPS 网关地址配置为 App 的默认服务器地址。当前 App 已内置上述地址；也可以通过 `WATCHDOG_API_BASE_URL` 覆盖。旧 ByteVirt 地址仍可通过 App 设置页手动切回，但不再作为 CloudBase 数据库的数据源。

正式构建 APK 时注入 CloudBase 服务地址：

```bash
cd app
flutter build apk --release --dart-define=WATCHDOG_API_BASE_URL=https://<cloudbase-service-url>
```
