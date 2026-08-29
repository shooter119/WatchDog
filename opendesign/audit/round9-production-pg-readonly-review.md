# 第九轮：生产 PostgreSQL 只读状态复核

日期：2026-08-29

## 复核范围

通过已登录的 CloudBase 新版 PostgreSQL 管理界面，对环境
`watchdog-prod-d6gch930m378d9a16` 做只读查询；未执行迁移、DDL、DML、权限修改或数据导出。

## DB-EXT-001 / DB-EXT-002：项目迁移、RLS 与原子 RPC 尚未落地

- 唯一编号：`DB-EXT-001`、`DB-EXT-002`
- 严重程度：严重
- 影响范围：单位隔离、认证会话、操作账本、RLS、约束、原子写入、幂等重试和多实例一致性。
- 复现步骤或证据：
  1. 执行 `SELECT version, checksum, applied_at FROM public.schema_migrations ORDER BY version;`，数据库返回 `relation "public.schema_migrations" does not exist`。
  2. 执行 `SELECT routine_schema, routine_name FROM information_schema.routines WHERE routine_schema = 'public' AND routine_name LIKE 'watchdog_%';`，查询成功但无返回数据，说明项目的 `watchdog_*` 原子 RPC 尚未创建。
  3. 执行 `SELECT schemaname, tablename, policyname, roles, cmd FROM pg_policies WHERE schemaname IN ('public', 'storage');`，查询成功但无返回数据，说明当前未发现项目或 Storage RLS policy。
  4. 关键表查询显示 `public` 中有 `units`、`incidents`、`incident_events`，但没有 `auth_sessions`、`unit_members`、`operation_ledger`、`schema_migrations`；业务表已有 `unit_id`、`client_op_id` 等部分字段，属于基础结构已存在但版本化升级未完成的状态。
  5. 只读取数量摘要得到 `units=1`、`incidents=15`、`incident_events=126`，未读取姓名、验证码、Token 或现场正文。
- 根本原因：生产环境当前使用的是早期/部分数据库结构，项目 `001` 至当前迁移没有通过版本化迁移流程完整应用；后端代码已经准备了新迁移和 RPC，但不能以代码文件替代数据库实际状态。
- 涉及文件：`backend/migrations/001_*.sql` 至 `009_ota_public_bucket.sql`、`backend/scripts/migrate-cloudbase.js`、`deploy/cloudbase/README.md`、`opendesign/audit/external-acceptance-runbook.md`。
- 修改方案：先取得可恢复快照或建立隔离预生产数据库，做迁移前重复操作号、孤儿引用和 NULL 单位数据扫描；随后按版本顺序执行迁移并校验 checksum，再验证 RLS、约束、RPC、双实例并发、故障注入和回滚。未完成这些步骤前保持原子操作、会话/RBAC 生产开关关闭。
- 修复状态：已确认真实生产外部阻塞；未执行任何写入。不能通过本地 SQLite、模拟 PostgREST 或静态 SQL 文件关闭该问题。
- 验证结果：CloudBase SQL 编辑器只读查询成功；上述缺失对象和业务数据量摘要均为线上实测结果；控制台 PostgreSQL 迁移页面显示应通过 CloudBase CLI/迁移流程执行迁移。

## DB-EXT-003：共享集群没有数据库备份能力

- 唯一编号：`DB-EXT-003`
- 严重程度：一般
- 影响范围：生产迁移前恢复点、迁移失败后的安全回退和备份恢复验收。
- 复现步骤或证据：在新版 CloudBase PostgreSQL 管理界面的“备份”页面，控制台显示“当前共享集群暂不提供相关能力，可以升级至独享集群启用能力”。
- 根本原因：当前环境为共享集群，平台不提供项目所需的数据库备份/恢复管理能力。
- 涉及文件/平台：CloudBase 生产环境；外部验收手册和 `deploy/cloudbase/README.md`。
- 修改方案：不在没有恢复点的生产数据库执行会改变业务结构或权限的迁移；由运维选择升级至支持备份的独享集群，或提供隔离预生产和可验证快照后再继续。
- 修复状态：外部阻塞，未执行升级或付费操作。
- 验证结果：控制台页面实测确认；没有读取或保存任何业务正文。

## SEC-018：托管服务环境变量面板存在明文敏感值暴露风险

- 唯一编号：`SEC-018`
- 严重程度：严重
- 影响范围：生产 API Token、上游服务密钥、数据库/CloudBase 访问凭据及相关终端、操作记录和截图。
- 复现步骤或证据：在已登录 CloudBase 控制台打开 `watchdog-api-prod` 服务详情的“服务配置”，环境变量区域将部分敏感变量以明文呈现；本轮仅确认存在该显示行为，未复制、保存或在文档中记录任何具体值。
- 根本原因：平台服务详情页对运行时环境变量的展示边界不足，且现有服务配置中存在直接注入敏感变量的做法；一旦终端共享、录屏、截图或命令输出被留存，会扩大密钥暴露面。
- 涉及文件/平台：CloudBase `watchdog-api-prod` 服务配置、`deploy/deploy.sh`、`deploy/cloudbase/README.md`；代码仓库未写入任何具体值。
- 修改方案：由运维先在 CloudBase/上游服务完成影响评估和密钥轮换，确认新值已配置并通过健康检查、ASR/LLM 关键链路验证后，再废止旧值；后续所有控制台/CLI 核查使用字段过滤，禁止打印环境变量值，并将部署审计改为只记录变量名和状态。不得在未完成轮换验证前删除现有值，避免线上中断。
- 修复状态：已确认外部运维待办；本轮未修改生产配置、未轮换密钥、未复制具体值。
- 验证结果：CloudBase 服务详情页面实测确认显示行为；仓库扫描和本轮新增审计文件均未包含具体密钥值。

## 下一步

1. OTA `009` 迁移继续按用户要求保留待办，不执行。
2. PostgreSQL 迁移也暂不执行，直到具备恢复点或隔离预生产环境。
3. 可继续独立完成的工作是只读核对 CloudBase 运行配置、部署服务状态和 GitHub 发布保护；涉及创建密钥、升级套餐、权限变更或生产写入时停止并报告。

## DEPLOY-002：托管服务当前暂停且健康接口返回 503

- 唯一编号：`DEPLOY-002`
- 严重程度：严重
- 影响范围：线上 API 可达性、App 登录/同步、语音识别和后续发布验收。
- 复现步骤或证据：CloudBase“云托管/服务管理”列表显示 `watchdog-api-prod` 运行状态为“已暂停”；等待服务详情加载后，部署版本 027 显示“正常”、100% 流量、1 个实例。通过浏览器确认默认测试域名提示后，访问 `https://watchdog-prod-d6gch930m378d9a16-1351750301.ap-shanghai.app.tcloudbase.com/api/health` 得到 `503 Service Temporarily Unavailable`（nginx）。HTTP 网关页面同时显示 `/` 路由已开启并绑定 `watchdog-api-prod`。
- 根本原因：当前平台服务列表、部署版本/实例信息与默认网关实际响应，以及此前部署脚本成功/健康检查记录不一致；仅凭现有信息不能安全判断是服务暂停标记、实例实际状态、网关转发或平台状态延迟。
- 涉及文件/平台：CloudBase `watchdog-api-prod` 服务、HTTP 网关路由、`deploy/deploy.sh`。
- 修改方案：运维先在控制台核对暂停原因、部署版本、实例日志和服务事件；确认恢复方式后再启用/重启或重新部署。恢复后连续验证健康接口、网关路由、模型清单、401 鉴权边界及 App 关键链路；同时保留当前服务状态截图/时间戳，解释此前部署检查与当前 503 的差异。
- 修复状态：已确认外部运行状态阻塞；本轮未点击启用、重启、更新、删除或重新部署。
- 验证结果：控制台服务列表/详情和默认网关健康接口均已通过浏览器实测；没有执行生产写操作。
