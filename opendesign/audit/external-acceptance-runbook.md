# WatchDog 外部验收执行手册

> 用途：在具备隔离 PostgreSQL、CloudBase 运维权限和 Android 真机后，按本手册补齐项目级验收证据。
>
> 安全边界：默认只在预生产或可恢复的测试环境执行。没有备份、回滚窗口、测试单位和测试数据时，不执行迁移、不打开生产开关、不做批量写入。

## 1. 执行前置条件

- [ ] 已确认本次使用的代码提交、App APK、后端镜像和迁移目录属于同一版本。
- [ ] 已取得隔离 CloudBase PostgreSQL 的 `CLOUDBASE_ENV_ID`、`CLOUDBASE_SECRET_ID`、`CLOUDBASE_SECRET_KEY`；密钥只通过环境变量或凭据管理器注入，不写入文件、日志或命令历史。
- [ ] 已完成数据库快照/备份，并记录备份标识、时间和恢复责任人。
- [ ] 已准备专用测试单位、成员、警情、设备和 `client_op_id`；不得使用真实现场数据做故障注入。
- [ ] 已准备两个可独立访问但连接同一 PostgreSQL 的后端实例，以及一台 Android 真机；记录实例标识和 App 包版本。
- [ ] 已确认生产会话/RBAC、操作账本和原子操作开关仍为关闭状态，直到本手册对应项目全部通过。

## 1.1 当前生产可用性门禁

- [ ] CloudBase `watchdog-api-prod` 服务状态为运行中，实例数量大于 0；不能只依据部署版本显示“正常”判断可用。
- [ ] 应用网关根路径和服务默认域名的 `/api/health` 均连续返回 200，且 `ready`、`databaseReady`、`asrConfigured`、`llmConfigured` 均为真。
- [ ] HTTP 网关默认 `/` 路由已按接口资源成本配置共享限频；记录资源维度阈值、客户端维度阈值（如套餐支持）和 429 压测结果。
- [ ] 服务恢复与网关限频配置均只在明确的运维变更窗口执行；变更前记录原状态，变更后记录实例数、健康结果和回退方式。

## 2. 迁移前只读检查

先在隔离数据库执行只读扫描，保存结果但不把真实数据复制到仓库：

```sql
-- 记录历史异常，确认重复非空操作号和孤儿引用均已处理或有明确豁免。
SELECT client_op_id, COUNT(*)
FROM public.incident_events
WHERE client_op_id IS NOT NULL
GROUP BY client_op_id
HAVING COUNT(*) > 1;

-- 记录待校验的 NULL 单位历史数据，不自动认领、不自动删除。
SELECT COUNT(*) FROM public.incidents WHERE unit_id IS NULL;
SELECT COUNT(*) FROM public.entries WHERE unit_id IS NULL;
```

检查结果必须包含：执行时间、数据库环境、行数摘要、异常处理决定和批准人。不要把现场姓名、验证码、Token 或完整现场文本写入验收记录。

## 3. 应用迁移与校验

在隔离环境执行：

```bash
cd backend
CLOUDBASE_ENV_ID=<isolated-pg-env-id> \
CLOUDBASE_SECRET_ID=<secret-id> \
CLOUDBASE_SECRET_KEY=<secret-key> \
npm run db:migrate
```

然后确认：

1. `public.schema_migrations` 包含 `001` 至当前版本，版本号无重复。
2. 每个版本的 SHA-256 与仓库对应迁移文件一致；修改过的迁移不得被静默跳过。
3. 重复执行迁移只输出“已应用，跳过”，不重复创建对象，不改变历史业务数据。
4. `008_atomic_rpc_conflict_index.sql` 已建立完整的 `incident_events(client_op_id)` 唯一索引，能够匹配 `007` 中的 `ON CONFLICT (client_op_id)`；迁移前重复非空值已得到处理决定。
5. `006` 的约束先按项目策略完成历史扫描，再单独执行 `VALIDATE CONSTRAINT`；验证失败时停止，不删除异常数据。

### 3.1 国内 OTA Storage 验收

在执行完整迁移后，单独确认 `watchdog-ota` bucket 和公开对象入口；不要把云托管服务的 `/ota/*` 兼容地址当作 Storage bucket：

1. 只读列出当前环境 bucket，确认存在 `watchdog-ota`、`public=true`，文件大小上限为 160 MiB，允许 JSON 和 Android APK MIME 类型。
2. 通过 `009_ota_public_bucket.sql` 的迁移记录和 `pg_policies` 查询确认 `storage.objects` 存在 `watchdog_ota_public_read`，只允许读取 `bucket_id = 'watchdog-ota'` 的对象；已有同名非公开 bucket 时停止并人工复核。
3. 请求
   `https://<env-id>.api.tcloudbasegateway.com/v1/storages/object/public/watchdog-ota/latest.json`。
   在尚未上传清单时可以返回对象不存在，但不得返回 `STORAGE_BUCKET_NOT_FOUND`；上传测试清单后必须能匿名读取，且响应内容与上传字节一致。
4. 为 GitHub Actions 配置 `CLOUDBASE_OTA_ENV_ID`、`CLOUDBASE_OTA_BUCKET_ID`、`CLOUDBASE_OTA_API_KEY_ID`、`CLOUDBASE_OTA_API_KEY`。API Key 只授予 OTA bucket 的最小写权限，值不得出现在命令历史、日志、构建产物或验收记录。
5. 使用新的递增 tag 实跑发布工作流，确认 workflow 先完成 OTA APK/`latest.json` 上传和远端 SHA-256、大小、版本校验，再创建 GitHub Release；对比 OTA APK 与 Release APK 的 SHA-256、文件大小、包版本号和 manifest `tagName`。

## 4. PostgreSQL/RLS/RPC 合同验收

使用专用测试单位和两个测试成员执行，记录 HTTP 状态、错误分类、数据库计数和事件计数，不记录 Token 或现场正文。

| 场景 | 预期结果 |
|---|---|
| 同一 `client_op_id`、同一请求摘要重复提交 | 返回第一次成功结果，只产生一条业务记录和一条事件 |
| 同一 `client_op_id`、请求摘要/警情/操作类型改变 | 返回 409，不新增业务记录或事件 |
| 两个单位使用相同 `client_op_id` | 单位隔离，互不复用结果 |
| 两个实例同时新建警情 | 单位冷却、编号和建档事件只成功一次，失败方得到可识别冲突 |
| 进场/出场/压力/随手记复合写入中途故障 | 业务状态和事件一起提交或一起回滚 |
| 归档并发提交 | 只有条件更新获胜的一方写归档事件，不重复写事件 |
| 较新和较旧活动时间乱序到达 | 最终活动时间不被较旧值覆盖 |
| 普通单位请求读取另一单位数据 | 无数据且无副作用 |
| 普通成员调用管理端点 | 403/业务拒绝，不改变数据 |
| 退出/撤销会话后继续调用 | 认证失败，不可读取或写入业务数据 |

RLS 验收必须分别记录普通运行角色、受限角色（如已配置）和 service role 的实际能力；RLS 不能替代 API 单位过滤、RPC 参数校验和会话授权。

## 5. 双实例、重启和恢复验收

1. 将两个后端实例连接同一数据库，使用独立连接同时执行新建警情、离线补传和归档场景；重复运行至少 30 轮，统计成功数、冲突数、业务记录数和事件数。
2. 在 RPC/迁移故障注入点中断调用，确认没有半成品状态；随后使用同一操作号重试，确认结果可重放且不会重复写入。
3. 重启单个实例，再重启全部实例，确认警情、事件、操作账本和成员状态仍可读写。
4. 从隔离备份恢复到另一数据库，执行最小读写和计数核对；记录恢复点、耗时、差异和回滚方式。
5. 只有上述记录通过评审后，才可在小范围灰度打开对应功能开关；打开前保留关闭开关的应用回滚方案。

## 6. Android 真机验收

使用正式签名 APK，确认 APK 包名、版本号、签名证书和内置服务地址符合发布记录：

- [ ] 首次认证、单位/姓名/验证码校验和错误重试。
- [ ] 认证及警情选择完成后进入语音页；返回键和深链不能绕过认证遮罩。
- [ ] 长按录音、权限拒绝、录音中断、断网、恢复网络和离线补传。
- [ ] 本地 ASR 清单校验、模型下载中断、旧模型保留和重新启用。
- [ ] 前台服务、通知、锁屏、切后台、应用重启和开机自启。
- [ ] 安全存储、退出单位、会话失效、卸载重装、系统备份/恢复；检查凭据不进入普通偏好和备份。
- [ ] 大字体、横屏、TalkBack、减少动效、低存储和不同网络条件下的关键页面。
- [ ] 切换警情时后台服务跟随新警情；退出/归档时按已确认的产品规则停止服务（对应 `FLT-026`）。

每个场景记录设备型号、Android 版本、APK SHA-256、步骤、实际结果和截图/日志位置。日志必须先脱敏，禁止提交 Token、验证码、姓名清单或完整现场内容。

## 7. 关闭条件

外部验收只有在以下证据均已归档到本目录后，才能把对应台账条目标记为“已关闭”：

- PostgreSQL 迁移版本/校验和、约束/RLS/RPC 结果；
- 双实例并发、故障注入、重启和备份恢复记录；
- CloudBase 服务配置和健康检查结果（只记录状态，不记录密钥）；
- Android 真机矩阵、APK 签名/哈希和关键流程结果；
- 失败项、重试次数、修复提交和重新验收结果。

任何一项只有静态代码、SQLite、模拟 PostgREST 或 Widget 测试证据时，仍保持“外部待验收”，不得提前关闭。
