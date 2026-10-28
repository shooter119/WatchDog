# VPS 部署补充说明

## 警情导入临时存储

后端新增私有 `import-data:/app/data` 数据卷，用于最长24小时的待核对图片；不能通过Caddy对外发布该目录。Docker镜像预先将目录授权给node用户。正式应用、取消或过期后清理图片；正式资料与提取文字保存在PostgreSQL。若扩展多个后端实例，必须共享同一私有图片目录；不能让不同主机只共享数据库却使用互不相通的本地图片目录。

新增迁移由启动迁移器按文件顺序、校验和及事务锁执行，不修改旧迁移。上线前备份数据库并在本地验证迁移；本次代码修改不代表已部署。视觉识别复用 `DEEPSEEK_API_KEY`、`DEEPSEEK_BASE_URL` 与 `DEEPSEEK_CHAT_MODEL`，调用 `/responses`；部署前使用脱敏截图验证实际上游能力，不向普通日志输出图片、通报、电话或供应商原始错误体。


## 重点单位后台兼容部署

使用 `scripts/deploy-key-sites.sh --dry-run` 查看范围；实际执行要求干净已提交工作区，并重新通过后端253+、App353+与analyze零问题门禁。脚本只部署后端和管理端路由，不改版本、正式APK、tag、官网或OTA。

目标默认 `ali:/opt/watchdog`，可用 `WATCHDOG_DEPLOY_HOST` / `WATCHDOG_DEPLOY_ROOT` 指定。先备份私有源码配置并保留旧Docker镜像，校验Caddy并构建新镜像；构建成功后短暂停止后端，备份PostgreSQL自定义格式dump和容器 `/app/data`，验证dump目录可读取。旧容器没有持久卷时，将资料迁入 `vps_import-data`，不覆盖已有非空目标卷；后续部署继续使用已有卷。数据库、官网与Caddy容器不随backend重建。1.6GiB VPS将文档转换和上传并发限制为1，AI并发为1。

部署后等容器健康，再原地写入并重载Caddy；若Caddy原有单文件挂载的inode已与宿主机不一致，仅重建Caddy刷新挂载（短暂代理重连）；一致时使用原地重载。只将主域名 `/admin`、`/admin/*`、`/api/admin`、`/api/admin/*` 路由到backend，官网、OTA及旧API域名不变。`scripts/verify-key-sites.mjs` 检查公开登录壳、Cookie标志、Origin拒绝、未确认挑战状态、跨浏览器拒绝、私有资源匿名鉴权，并比较部署前后官网与OTA响应摘要。公网失败自动回切旧后端镜像和Caddy路由，保留增量表和私有卷。远端任务先保存为独立脚本文件，再以空标准输入执行；备份命令不能消耗后续控制脚本，未到达完成标记的正常退出或信号也触发回切保护。

私有备份在 `/opt/watchdog/backups/key-sites-<UTC时间>/`，目录700。包括 `database.dump`、`database.contents`、`private-data.tgz`、`app-data/`、`source-before.tgz`、`Caddyfile.before`、`old-image-id` 和 `rollback.sh`。手工回切运行 `bash <备份目录>/rollback.sh /opt/watchdog <备份目录>`，保留新私有卷和增量表，避免覆盖上线后的数据。只有确认需要完整时间点恢复时，才另行停后端并协调恢复数据库与同一份资料备份；不要日常回滚直接删表或用旧dump覆盖新数据。

匿名公网检查不能证明已授权手机扫码、真实资料试点或实机操作成功。首个平台管理员已按用户指定的已有有效成员完成私有初始化；初始化命令不自动选择单位admin，实际扫码仍待设备验收。

国内VPS构建通过 `DEBIAN_MIRROR=https://mirrors.aliyun.com` 使用HTTPS软件镜像；默认Docker构建仍采用Debian官方HTTPS源。Node slim未预装系统CA时，以Node内置公共根证书建立HTTPS信任，再安装Debian `ca-certificates`；不关闭TLS校验或APT包签名校验。

2026-10-20 已完成资料后台部署与匿名公网验收，当前有效备份为 `/opt/watchdog/backups/key-sites-20261020T013238Z/`。授权手机扫码、真实资料试点与Android实机尚未完成，详见 [验收记录](ADMIN-ACCEPTANCE.md)。

2026-10-21 后端再次部署（提交 `b748553`，含登录失败分级、近似姓名建议、待审 `in_roster` 标记），备份 `/opt/watchdog/backups/key-sites-20261021T140708Z/`；本机缺 LibreOffice 转换器导致 `key-sites` 14 条用例必然失败，发版门禁改为"失败项必须全部落在已知环境失败集合内"，并已同步修正 `scripts/release.sh` 的公网校验重试。同日发布 App `1.11.0+93`：OTA 清单、APK（72,508,497 字节，SHA-256 `233286135dbf430257946f0a86260adeb6a29721ae1c0badb3889b4d7070fb68`）、官网版本与下载链接均已核对；用旧版 `1.10.0+2092` 实机确认能识别到 `v1.11.0+93`。

2026-10-28 核对并补齐三处只落在文档上的说法：（1）上面那条"门禁按已知环境失败集合放行"当时并未在脚本里实现，现在 `scripts/release.sh` 的 `backend_gate_verdict` 已落地——只有 `command -v soffice` 为空、失败用例与 14 条固定清单逐条一致、且失败全部落在 `test/key-sites.test.js` 与 `test/key-site-ai.test.js` 时才放行，任一不满足即判真实失败；（2）本机补装 `soffice`（LibreOffice 26.8.1）与 `poppler`（`pdfinfo`/`pdftoppm`），后端测试从 279/293 变为 **293/293 全绿**，装齐转换器后门禁自动恢复严格（fail 0）；（3）新增 `scripts/backup-pull.sh` 做异地备份，把 `pg_dump -Fc`、后端 `/app/data` 私有卷和 `ota/latest.json` 打成一个包拉到仓库之外的 `~/WatchDog-backups`，双向 sha256 比对并就地校验成员，已验证首份副本可被 `pg_restore --list` 正常读取（239 个 TOC 条目）。
