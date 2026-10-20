# VPS 部署补充说明

## 警情导入临时存储

后端新增私有 `import-data:/app/data` 数据卷，用于最长24小时的待核对图片；不能通过Caddy对外发布该目录。Docker镜像预先将目录授权给node用户。正式应用、取消或过期后清理图片；正式资料与提取文字保存在PostgreSQL。若扩展多个后端实例，必须共享同一私有图片目录；不能让不同主机只共享数据库却使用互不相通的本地图片目录。

新增迁移由启动迁移器按文件顺序、校验和及事务锁执行，不修改旧迁移。上线前备份数据库并在本地验证迁移；本次代码修改不代表已部署。视觉识别复用 `DEEPSEEK_API_KEY`、`DEEPSEEK_BASE_URL` 与 `DEEPSEEK_CHAT_MODEL`，调用 `/responses`；部署前使用脱敏截图验证实际上游能力，不向普通日志输出图片、通报、电话或供应商原始错误体。


## 重点单位后台兼容部署

使用 `scripts/deploy-key-sites.sh --dry-run` 查看范围；实际执行要求干净已提交工作区，并重新通过后端252+、App351+与analyze零问题门禁。脚本只部署后端和管理端路由，不改版本、正式APK、tag、官网或OTA。

目标默认 `ali:/opt/watchdog`，可用 `WATCHDOG_DEPLOY_HOST` / `WATCHDOG_DEPLOY_ROOT` 指定。先备份私有源码配置并保留旧Docker镜像，校验Caddy并构建新镜像；构建成功后短暂停止后端，备份PostgreSQL自定义格式dump和容器 `/app/data`，验证dump目录可读取。旧容器没有持久卷时，将资料迁入 `vps_import-data`，不覆盖已有非空目标卷；后续部署继续使用已有卷。数据库、官网与Caddy容器不随backend重建。1.6GiB VPS将文档转换和上传并发限制为1，AI并发为1。

部署后等容器健康，再原地写入并重载Caddy；只将主域名 `/admin`、`/admin/*`、`/api/admin`、`/api/admin/*` 路由到backend，官网、OTA及旧API域名不变。`scripts/verify-key-sites.mjs` 检查公开登录壳、Cookie标志、Origin拒绝、未确认挑战状态、跨浏览器拒绝、私有资源匿名鉴权，并比较部署前后官网与OTA响应摘要。公网失败自动回切旧后端镜像和Caddy路由，保留增量表和私有卷。

私有备份在 `/opt/watchdog/backups/key-sites-<UTC时间>/`，目录700。包括 `database.dump`、`database.contents`、`private-data.tgz`、`app-data/`、`source-before.tgz`、`Caddyfile.before`、`old-image-id` 和 `rollback.sh`。手工回切运行 `bash <备份目录>/rollback.sh /opt/watchdog <备份目录>`，保留新私有卷和增量表，避免覆盖上线后的数据。只有确认需要完整时间点恢复时，才另行停后端并协调恢复数据库与同一份资料备份；不要日常回滚直接删表或用旧dump覆盖新数据。

匿名公网检查不能证明已授权手机扫码、真实资料试点或实机操作成功。首个平台管理员必须另行指定已有有效成员ID，初始化命令不自动选择单位admin。
