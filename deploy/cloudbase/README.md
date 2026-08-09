# CloudBase 云托管并行部署

这套配置用于把 WatchDog 后端作为第二套环境部署到腾讯云 CloudBase，验证完成前不切换 App，也不影响现有 ByteVirt 服务。

## 部署原则

- 先创建 CloudBase 服务，首次发布将流量设为 `0`，只用默认域名做验证。
- 现有 App 继续访问 `https://bytevirt.meiyou.xyz:8443`。
- CloudBase 只允许 `1` 个最大实例，避免 SQLite 在多个实例之间并发写入。
- SQLite 数据目录使用 CFS 挂载目录 `/mnt/cfs/watchdog`，不要使用容器临时目录。
- CloudBase 环境变量只在控制台配置，密钥不写入仓库。

## CloudBase 控制台配置

1. 创建 CloudBase 环境，准备同地域的 CFS 文件系统和挂载点。
2. 创建云托管服务，选择“本地代码”或代码仓库部署，源码目录选择 `backend/`。
3. 使用 `backend/Dockerfile` 构建，监听端口填写 `3000`。
4. 资源先设置为 `0.25 核 / 0.5 GiB`，最大实例数设为 `1`，最小实例数设为 `0`。
5. 在“存储挂载”中将 CFS 挂载到容器路径 `/mnt/cfs`，读写权限开启。
6. 配置以下环境变量：

```text
WATCHDOG_DATA_DIR=/mnt/cfs/watchdog
WATCHDOG_SQLITE_JOURNAL_MODE=DELETE
WATCHDOG_SQLITE_BUSY_TIMEOUT_MS=5000
PORT=3000
API_TOKEN=<与旧服务相同的访问令牌>
VOLC_APP_KEY=<豆包 App Key>
VOLC_ACCESS_TOKEN=<豆包 Access Token>
VOLC_RESOURCE_ID=volc.bigasr.sauc.duration
DEEPSEEK_API_KEY=<DeepSeek API Key>
DEEPSEEK_BASE_URL=https://api.deepseek.com
DEEPSEEK_MODEL=deepseek-chat
DEEPSEEK_CHAT_MODEL=deepseek-v4-flash
CHAT_SEARCH_ENABLED=1
```

计算参数环境变量按现有 `backend/.env.example` 配置；未设置时使用代码默认值。

## 上线前验证

先将版本流量保持为 `0`，使用 CloudBase 默认 HTTPS 域名访问：

```text
GET /api/health
GET /api/config
```

然后使用测试场景完成：新建警情、进场、出场、随手记、操作日志、问答和语音转写验证。确认 CFS 中已经生成 `watchdog/watchdog.db` 后，再将 CloudBase 流量切到 `100%`，并临时把测试 App 的服务器地址改为 CloudBase 域名验证。

## 正式切换

正式切换前先在旧服务上停止现场写入，导出并导入最新 SQLite 数据；确认 CloudBase 数据完整后，再把正式 App 的服务器地址改为 CloudBase 地址。旧 ByteVirt 服务保留至少一周，出现问题时可以把 App 地址改回旧地址。

迁移完成后再决定是否删除旧服务；本目录不会自动执行切换、停机或删除操作。
