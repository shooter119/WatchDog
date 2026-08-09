# CloudBase 云托管并行部署

这套配置用于把 WatchDog 后端作为第二套环境部署到腾讯云 CloudBase，验证完成前不切换 App，也不影响现有 ByteVirt 服务。

## 部署原则

- 现有 App 继续访问 `https://bytevirt.meiyou.xyz:8443`。
- CloudBase 使用 PostgreSQL 保存业务数据，不使用容器临时磁盘，也不需要 CFS 存储挂载。
- CloudBase 云托管先保持在测试状态，验证通过后再切换 App 地址。
- CloudBase AI 通过 OpenAI 兼容接口调用；API Key 只配置在云托管环境变量中。
- 密钥不写入仓库，不把 `backend/.env` 打包上传。

## CloudBase 控制台配置

1. 确认环境已启用「SQL 型数据库 / PostgreSQL」，并在「AI → 生文模型」启用需要的模型（当前控制台已启用 `hy3`，代码默认使用它）。
2. 创建云托管服务，选择本地代码或代码仓库部署，源码目录选择 `backend/`。
3. 使用 `backend/Dockerfile` 构建，监听端口填写 `3000`。
4. 测试阶段资源建议设置为 `0.25 核 / 0.5 GiB`，最大实例数设为 `1`，最小实例数设为 `0`。
5. 在 CloudBase AI 快速开始页面创建并选择 API Key；同一个环境 API Key 可供 PostgreSQL 管理接口和 CloudBase AI 使用。
6. 配置以下环境变量：

```text
WATCHDOG_DB_DRIVER=cloudbase
CLOUDBASE_ENV_ID=watchdog-prod-d6gch930m378d9a16
CLOUDBASE_API_KEY=<CloudBase 环境 API Key>
# 首次部署设为 0；确认 PostgreSQL 表和索引已创建后，可设为 1 减少启动时的 DDL 请求
CLOUDBASE_SKIP_SCHEMA=1
CLOUDBASE_PG_TIMEOUT_MS=15000
PORT=3000
API_TOKEN=<与旧服务相同的访问令牌>
VOLC_APP_KEY=<豆包 App Key>
VOLC_ACCESS_TOKEN=<豆包 Access Token>
VOLC_RESOURCE_ID=volc.bigasr.sauc.duration

CLOUDBASE_AI_ENABLED=1
CLOUDBASE_AI_API_KEY=<CloudBase AI API Key；可与上面的环境 API Key 相同>
CLOUDBASE_AI_BASE_URL=https://watchdog-prod-d6gch930m378d9a16.api.tcloudbasegateway.com/v1/ai/cloudbase
CLOUDBASE_AI_MODEL=hy3
CLOUDBASE_AI_CHAT_MODEL=hy3
```

计算参数环境变量按现有 `backend/.env.example` 配置。若暂时不启用 CloudBase AI，可将 `CLOUDBASE_AI_ENABLED=0`，继续使用 `DEEPSEEK_API_KEY` 直连配置。

## 数据迁移

先从旧 ByteVirt 服务取得 SQLite 数据库备份，保存为本地文件，然后在本地执行：

```text
WATCHDOG_DB_DRIVER=cloudbase \
CLOUDBASE_ENV_ID=watchdog-prod-d6gch930m378d9a16 \
CLOUDBASE_API_KEY=<CloudBase API Key> \
WATCHDOG_SOURCE_DB=/path/to/watchdog.db \
npm run migrate:cloudbase
```

迁移脚本只追加缺失记录，不删除 CloudBase 数据，可以在切换前重复执行。正式切换前仍需在旧服务上暂停现场写入，做最后一次备份和迁移，避免切换窗口产生遗漏。

## 上线前验证

先不要修改 App 地址，使用 CloudBase 默认 HTTPS 域名访问：

```text
GET /api/health
GET /api/config
```

然后用测试场景完成：新建警情、进场、出场、随手记、操作日志、语义解析、辅助问答和语音转写验证。确认重启云托管实例后数据仍在，再考虑切换。

## 正式切换

正式切换时先在旧服务上停止现场写入，执行最后一次 SQLite 备份和迁移；确认 CloudBase 数据完整后，再把测试 App 或正式 App 的服务器地址改为 CloudBase 域名。旧 ByteVirt 服务保留至少一周，出现问题时可以把 App 地址改回旧地址。

本目录不会自动执行切换、停机或删除旧服务。
