# WatchDog 第五轮多 Agent 交叉复核与最终验收记录

日期：2026-08-28
范围：backend、app、数据库驱动、deploy、CI 流程、测试与构建产物。
组织方式：主 Agent 统筹后端与架构、Flutter 功能、UI/UX、安全隐私、测试质量、性能工程六组；各组先读项目约定和现状，再共享证据、去重并由主 Agent 统一修改顺序。所有本轮代码修复均未 commit/push/release。

## 一、工作组状态

| 工作组 | 状态 | 交叉复核结论 |
|---|---|---|
| 后端与架构 | 已完成本轮复核 | API、SQLite/PG、归档、分页、请求边界和部署健康检查已复核；身份/RBAC、PG 跨表事务和多实例竞态仍开放。 |
| Flutter App 功能 | 已完成本轮复核 | 离线投影、语音路由、告警重试、ASR 释放、批量导入、会话代次、不可见旧警情清理和问答语音日志终态已修复并回归。真机插件/生命周期仍需外部设备证据。 |
| UI/UX | 已完成本轮复核 | 压力录入、日志、设置、统计、问答和窄屏/大字体布局已修复；默认首屏设计冲突仍需产品决策。 |
| 安全与隐私 | 已完成代码复核 | 模型下载不再携带业务 Token，外部 URL 校验加强；身份、RBAC、可信 Host、发布者签名和隐私策略仍需架构/运维决策。 |
| 测试与质量 | 已完成本轮验收 | 后端 117/117、Flutter 196/196、analyze 0 issues；CI 门禁基线同步为 117/196。GitHub Actions 尚未由本地工作区触发。 |
| 性能与工程质量 | 已完成本轮复核 | 音频操作串行化、ASR 崩溃残留清理、日志持久化竞态已处理；轮询、N+1、监控和模型旧 generation 策略仍开放。 |

## 二、本轮问题台账（已去重）

以下每项均记录唯一编号、级别、影响、证据、根因、文件、方案、状态和验证；与前四轮重复的项目以关联编号注明，不重复计数。

### 已修复并验证

| 编号 | 级别 | 影响范围 | 复现步骤或证据 | 根本原因 | 涉及文件 | 修改方案 | 修复状态 | 验证结果 |
|---|---|---|---|---|---|---|---|---|
| WD-APP-FUNC-02 | 严重 | 语音明确说出场时会错误追加进场人员确认项。 | Widget 回归：具体出场指令不产生 entry confirmation row。 | HomePage 先把识别姓名追加到待确认列表，再按 intent 路由。 | `app/lib/pages/home_page.dart`、`app/test/widget_test.dart` | 先处理 exit intent，再执行进场人员追加。 | 已修复 | 定向 Widget 测试和 Flutter 全量通过。 |
| WD-APP-FUNC-03 / WD-APP-R5-001 | 严重 | 离线新增压力、出场、日志可能被旧服务端快照覆盖，用户看到错误状态。 | 构造“本地队列存在操作、服务端仍为旧快照”的控制器测试。 | 同步只应用服务端快照，没有把尚未成功上传的本地操作投影回当前 incident。 | `app/lib/services/offline_queue.dart`、`app/lib/state/app_controller.dart`、`app/test/app_controller_offline_test.dart` | 按队列数据库顺序读取当前 incident 的 pending 操作，使用纯投影函数重放 entry/pressure/exit/note。 | 已修复 | 离线回归通过；坏 payload 逐行隔离，Flutter 192/192。 |
| WD-APP-FUNC-04 | 严重 | 告警初始化一次失败后永久不再重试，可能漏告警。 | 注入 init 异常后再次进入可用路径，原实现不再调用 init。 | `_alarmReady` 只在成功后置位，但没有失败后的重试闸门/触发点。 | `app/lib/state/app_controller.dart`、告警相关测试 | 增加可重入的初始化 retry gate，并在成功同步/需要告警时重新尝试。 | 已修复 | 定向生命周期/告警回归及全量 Flutter 通过。 |
| WD-APP-FUNC-05 | 一般 | 设置或名单加载失败可能关闭共享 API 连接池，影响其他请求。 | 设置异常路径调用共享 client 的 `cancelRequests()`。 | 局部错误处理误把共享核心客户端当作本次请求专属资源。 | `app/lib/state/app_controller.dart` | 删除共享池取消动作，仅保留本次错误状态和后续重试。 | 已修复 | 定向失败恢复测试、Flutter 全量通过。 |
| WD-APP-FUNC-06 | 一般 | 同步后的 ASR 开关默认值与设置 getter 不一致。 | 空设置映射的 `asrEnabled` 为 false，而 getter 默认 true。 | `toSyncMap()` 使用了错误的默认常量。 | `app/lib/services/settings.dart`、`app/test/settings_validation_test.dart` | 统一为空值使用 true，并补充回归。 | 已修复 | 设置回归通过。 |
| WD-APP-FUNC-08 | 优化 | 录音振幅流把负 dBFS 直接 clamp 到 0，无法反映正常语音强度。 | dBFS 输入为 -60/-30/-3/0 时原逻辑均可能落到错误区间。 | 录音插件输出为 dBFS，UI 需要先转换为线性显示比例。 | `app/lib/services/audio_service.dart`、`app/test/audio_service_test.dart` | 新增有限值安全的 `[-60,0] dBFS -> [0,1]` 映射并保留噪声底。 | 已修复 | 音频定向测试、Flutter 全量通过。 |
| WD-APP-FUNC-09 | 一般 | 页面退出或模型切换时 ASR native 资源可能与下载/初始化并发释放。 | 复核发现 dispose 不等待活动下载、初始化和转写队列。 | 生命周期清理没有 single-flight 和资源顺序约束。 | `app/lib/services/local_asr_service.dart`、`app/test/local_asr_service_test.dart` | dispose single-flight；标记 disposed，等待下载/初始化/转写队列后释放 native 资源。 | 已修复 | ASR 生命周期/清理回归及 Flutter 全量通过；真实设备强杀仍待外部。 |
| WD-APP-FUNC-10 | 一般 | 名单批量导入把网络/服务器错误误报成“重复”，用户无法知道哪些条目需要重试。 | `addFirefighter` 原先只返回异常，导入层统一按 duplicate 处理。 | 201/409/其他失败没有结构化区分。 | `app/lib/api/api_client.dart`、`app/lib/pages/roster_page.dart`、`app/test/api_client_test.dart` | 返回 inserted/duplicate 语义；批量导入分别统计成功、重复和可重试失败。 | 已修复 | 201/409 API 回归与 Flutter 全量通过。 |
| OPLOG-R5-001 | 严重 | 特定 widget 测试组合中清空操作日志会一直等待；生产中可能表现为清空不返回。 | `操作日志入口可进入日志页 | OpLogPage.*` 组合测试曾挂起，定位到 mock prefs 替换期间的异步写尾。 | 持久化队列绑定旧 SharedPreferences 实例，测试替换 mock 实例后旧 Future 永不完成。 | `app/lib/services/op_log_service.dart`、`app/test/op_log_service_test.dart` | 单飞初始化、缓存当前 prefs；实例变化时重置队列，并让每个持久化快照绑定当时实例。 | 已修复 | 原挂起组合、OpLog 定向测试及 Flutter 192/192 通过。 |
| PE-R5-001 | 一般 | 录音 start/stop/dispose 并发时可能重复访问插件或留下临时文件，影响稳定性和电量。 | 生命周期复核覆盖 permission 延迟、start 失败和 stop/dispose 重入。 | AudioService 原操作没有统一串行尾，异常回滚不完整。 | `app/lib/services/audio_service.dart`、相关 App 生命周期测试 | 增加 `_operationTail` 串行化、disposed 闸门和启动失败回滚清理。 | 已修复 | 音频/生命周期定向测试与全量 Flutter 通过；真机插件行为待外部。 |
| BACK-R5-001 | 一般 | 超长操作 ID 可造成日志/幂等键资源滥用，并与客户端边界不一致。 | 带超过 64 字符 `X-Op-Id` 请求原先可进入业务处理。 | 服务端仅在部分业务层使用 ID，缺少统一入口限制。 | `backend/src/server.js`、`backend/test/api.test.js` | 中间件统一拒绝超过 64 字符，返回 `OP_ID_TOO_LONG`。 | 已修复 | 后端回归通过，117/117。 |
| BACK-R5-002 | 严重 | 重复手工归档会重复写 `incident_archived` 事件，污染操作日志。 | 对同一 incident 连续调用 archive，旧逻辑每次都追加事件。 | 路由没有使用归档 UPDATE 的 changed 元数据。 | `backend/src/server.js`、`backend/src/db-sqlite.js`、`backend/test/incidents.test.js` | 仅在 `archiveIncident(...).changed` 为真时追加事件。 | 已修复 SQLite 路径 | 重复归档回归通过；PG 跨表原子闭环仍见 BACK-006。 |
| BACK-R5-003 | 一般 | 自动归档返回值可能把扫描行数当作实际归档数，导致运维统计错误。 | 过期列表中含已归档/并发变更行时返回值偏大。 | 返回 `stale.length`，没有累计实际 changed 更新。 | `backend/src/db-sqlite.js`、`backend/src/db-postgres.js`、`backend/test/db.test.js` | 按成功 UPDATE/changed 计数并返回 `archivedCount`。 | 已修复 | SQLite/模拟 PG 回归、117/117 通过。 |
| BACK-R5-004 | 一般 | PostgreSQL 按单位列表可能全量读取后再 JS 过滤，`limit=1` 仍放大数据库和网络负载。 | PG repository 测试验证旧实现未把 unit/limit 下推。 | PostgREST 查询缺少 unit filter、状态排序和 limit 参数。 | `backend/src/db-postgres.js`、`backend/test/postgres-repository.test.js` | 将单位、状态排序、正整数上限下推到 PostgREST，同时保留 JS 合同排序/截断。 | 已修复 | PG repository 定向回归与 117/117 通过；真实 PG 线上计划仍待外部。 |
| SEC-R5-010 | 严重 | 从任意 HTTPS 模型地址下载时携带业务 API Token，可能向第三方泄露访问凭据。 | 静态检查发现模型下载请求设置 `X-Api-Token`；新增测试断言不携带。 | ASR 下载复用业务 API 鉴权参数，而模型资源不是业务 API。 | `app/lib/services/local_asr_service.dart`、`app/test/local_asr_service_test.dart` | 移除下载路径的 token 读取和 header。 | 已修复 | Flutter 定向/全量通过；发布者真实性仍见 SEC-R5-012。 |
| SEC-R5-011 | 严重 | 外部资源 URL 中的 userinfo/query/fragment 可能造成凭据混淆、签名参数泄露或不受控路由。 | CloudBase driver URL 解析回归覆盖 `user:pass@host`、query、fragment。 | 仅检查 scheme=https，没有限制 URL 结构。 | `backend/src/cloudbase-postgrest.js`、`backend/test/cloudbase-driver.test.js` | HTTPS URL 拒绝用户名、密码、query、fragment。 | 部分修复 | 结构校验回归、117/117 通过；可信 Host allowlist 仍需运维信任模型。 |
| QA-R5-001 | 一般 | 测试数量基线落后会允许新增测试被误删，无法形成质量门禁。 | 本轮实际运行后端 117、App 192，而文档/workflow 仍为后端 116。 | 新增后端回归后只更新了部分质量材料。 | `AGENTS.md`、`.github/workflows/quality.yml`、`.github/workflows/release.yml` | 全部基线统一为 backend 117 / App 192，并保留 skipped/todo=0 门禁。 | 已修复 | 本地实际计数通过；workflow YAML 和静态检查通过，GitHub Actions 实跑待外部。 |

## 三、仍未闭合的问题与阻塞

这些不是可以安全凭空设计的低风险修补，已保留唯一编号、证据和下一步，不把项目级验收伪装成通过。

| 编号 | 级别 | 影响范围 | 证据 | 根本原因 | 涉及文件/系统 | 修改方案 | 修复状态 | 下一步验证 |
|---|---|---|---|---|---|---|---|---|
| BACK-003 / SEC-R5-001 | 严重 | 客户端可自报 `X-Unit-Id`/`X-Device-Id`/作者信息，存在跨单位读取或冒用设备画像的风险。 | 构造 synthetic victim profile 请求得到 HTTP 200；鉴权只证明 token，不证明主体。 | 缺少用户身份、设备注册、session 和 RBAC/RLS 模型。 | `backend/src/server.js`、`backend/src/db.js`、`backend/src/db-sqlite.js`、`backend/src/db-postgres.js`、App 设置/认证 | 需要产品与安全确认身份来源、管理员角色、设备绑定、迁移和兼容策略后设计并验证。 | 未闭合，阻塞项目级验收 | 先完成身份/RBAC 方案和预生产越权回归，再实施。 |
| BACK-004 / SEC-R5-002 | 严重 | 任一已认证客户端可修改全局名单、热词、站点或删除日志，无法区分普通操作员与管理员。 | 现有 API 测试证明普通认证请求可以 POST/DELETE roster 数据。 | 管理 API 未做角色授权，名单/热词为全局共享。 | `backend/src/server.js`、DB schema、App roster/settings | 需要定义管理员授权和审计策略；不能直接硬编码一个客户端 header。 | 未闭合，阻塞项目级验收 | 角色矩阵、服务端授权、越权测试。 |
| BACK-006 / BACK-009 / BACK-010 | 严重 | 状态写入与事件写入可能部分成功；多实例同时创建 incident 可能双 201；PG 归档事件缺少跨表原子事务。 | 注入事件失败可留下 entry；两进程 TOCTOU 并发均成功；SQLite 与 PG driver 能力不对称。 | 资源写入、事件、冷却和幂等没有统一数据库事务/唯一约束/RPC。 | `backend/src/db*.js`、migrations、CloudBase Postgres | 需要数据库/RPC 事务方案、唯一键/操作 ledger、迁移兼容和并发测试；存在核心架构变化，暂停自动大改。 | 未闭合，阻塞项目级验收 | 先确定 PG schema/RPC 与迁移策略，再做多实例压测和故障注入。 |
| BACK-012 / PE-018 | 严重 | 多实例部署下限流与监控按进程分散，攻击者可绕过单实例计数，故障也缺少统一指标。 | server 内 rate Map 为进程本地；未发现共享计数/指标后端。 | 缺少网关/Redis/平台限流和 metrics tracing 方案。 | `backend/src/server.js`、CloudBase/网关 | 需要运维选择共享限流与可观测性组件；不能在无外部资源授权下新增付费服务。 | 未闭合 | 预生产多实例验证、平台策略和告警阈值。 |
| UI-UX-001 | 一般 | 首次打开应用的默认入口在“看板”和“语音”之间存在产品基线冲突，影响核心入口可发现性。 | 旧 README/页面行为与 UI 复核对默认首页的期望不一致。 | 产品规则未明确，不是纯布局缺陷。 | `app/lib/main.dart`、导航/README | 需要产品确认默认页后再改入口并同步文档/关于我们。 | 未闭合，产品阻塞 | 确认默认入口、首启引导和深链回退规则。 |
| WD-APP-VERIFY-01 / WD-APP-VERIFY-02 | 严重 | 物理真机权限、录音、前台服务、本地 ASR、TalkBack、弱网和真实 sqflite 持久化仍未被证明；Android 模拟器已覆盖部分权限和核心流程。 | API 33 release 模拟器已完成通知/麦克风授权、单位认证、启用鉴权的隔离后端、建档、旧警情拒绝后的状态清理和单位归属复验；本地 ASR 模型未配置，未执行物理设备、弱网、TalkBack、进程杀和真实 sqflite 场景。 | 环境仍缺少物理设备、非生产模型与完整预生产会话。 | Android 设备、CloudBase 预生产、插件链路 | 需要授权/提供测试设备与非生产测试场景；不得把模拟器结果扩写成物理真机验收。 | 部分闭合，环境阻塞 | 按关键流程清单补做物理设备、弱网、进程杀、TalkBack 和真实数据库回归。 |
| SEC-R5-012 / PE-MODEL-001 | 一般 | OTA/ASR 模型可验证 HTTPS/大小，但未验证发布者签名；旧 ASR generation 可能长期占磁盘。 | 当前清理只处理 crash staging/pointer 残留，未定义旧 generation 保留和发布签名策略。 | 模型供应链信任与低存储策略没有明确规范。 | `app/lib/services/local_asr_service.dart`、模型发布链路 | 需要确定签名/哈希清单、密钥托管、保留数量和低存储行为后实现。 | 部分修复，策略阻塞 | 发布者签名设计、设备升级/回滚和低存储实测。 |
| WD-APP-FUNC-07 / WD-APP-FUNC-11 | 一般/优化 | API 切换后自动同步重跑语义仍不完全明确；录音大小只在 stop 后检查，超长录音会浪费内存/电量。 | 会话代次已防旧回写，但 API 刷新策略和录音最大时长没有产品容量参数。 | 网络切换策略和录音容量规则未定义。 | `app/lib/state/app_controller.dart`、`app/lib/services/audio_service.dart` | 需要明确 API 切换后的重试策略和最大录音时长/容量；再做低风险实现。 | 部分处理，产品参数阻塞 | 弱网/切换 API 设备回归，确认录音容量。 |
| PE-004 / PE-006 / PE-007 / PE-010 / PE-013 | 一般/优化 | 双轮询、每秒大树重建、同步 N+1、日志整尾写入和逐条 DB insert 可能增加 CPU、网络、存储和电量。 | 代码结构复核发现主 isolate/前台服务均有轮询；同步和日志路径存在批量化空间。 | 当前保活可靠性与性能目标没有统一基准，贸然删除轮询会改变业务可靠性。 | `app/lib/state/app_controller.dart`、`foreground_keep_alive.dart`、日志/DB driver | 先采集启动、轮询、内存、电量、DB/网络指标，再做架构级批量/退避改造。 | 未闭合，性能基准阻塞 | 真机 profile、CloudBase 指标和容量目标确认后实施。 |

## 四、最终验证记录

| 验证项 | 结果 | 证据 |
|---|---|---|
| 后端测试 | 通过：117/117，0 失败、0 skipped、0 todo | `cd backend && npm test` |
| Flutter 静态分析 | 通过：0 issues | `cd app && flutter analyze` |
| Flutter 测试 | 通过：196/196，0 失败、0 skipped | `cd app && flutter test --reporter json`；可见 `testDone=196` |
| Flutter 定向回归 | 通过 | 离线控制器、音频、API、ASR、日志、生命周期相关测试全部通过 |
| Android release 构建 | 通过 | `flutter build apk --release --split-per-abi --no-pub`；arm64 47.3MB |
| APK ABI/签名 | 通过 | `1.2.1+49` 发布候选 arm64 APK 仅含 `lib/arm64-v8a/`；apksigner v2=true、1 signer；证书 SHA-256 `0676114be5b9eb9d4448cb849d9b938b278214bb81de04a5debcde5eaf270668`；APK SHA-256 `bb78090cd2b7983b43ee026f268f345f24441f02422143404242e57f13592d9a` |
| 部署包 | 通过 | `./deploy/deploy.sh --dry-run` 包含 backend/src 与 models |
| 线上部署 | 通过 | 按 AGENTS.md 执行 `CLOUDBASE_ENV_ID=watchdog-prod-d6gch930m378d9a16 ./deploy/deploy.sh`；CloudBase `Deployment successful`，health `ok=true, ready=true, databaseReady=true, asrConfigured=true, llmConfigured=true` |
| 生产未授权边界 | 通过 | 未带 Token 请求 `/api/config` 返回 HTTP 401、`API_TOKEN_INVALID`；未用真实 token 做业务写操作 |
| 静态/清洁检查 | 通过 | `git diff --check`、Node syntax check、`bash -n deploy/deploy.sh`、workflow YAML 解析、mutable action ref 检查、tracked secret 扫描通过 |
| README/关于我们 | 已核查 | 本轮仅内部正确性/稳健性修复，无品牌、功能、架构或入口变更；README 与 `about_page.dart` 无需新增同步 |

## 五、续审复验记录（2026-08-28）

为避免只依赖上一轮缓存输出，本轮续审重新执行了强制门禁和只读线上检查：

- `backend/npm test`：117 tests、117 pass、0 fail、0 skipped、0 todo。
- `app/flutter analyze`：`No issues found!`。
- `app/flutter test --reporter json`：`visible_tests=196 skipped=0 non_success_test_events=0 done_success=True`。
- 线上 `/api/health`：`ok=true, ready=true, databaseReady=true, asrConfigured=true, llmConfigured=true`。
- 线上未授权 `/api/config`：HTTP 401，`API_TOKEN_INVALID`。
- 当前 arm64 APK SHA-256：`bb78090cd2b7983b43ee026f268f345f24441f02422143404242e57f13592d9a`；版本 `1.2.1+49`；签名 v2=true、1 signer，证书摘要与发布密钥一致。
- 工作区清洁度：`git diff --check` 通过；无 tracked `.env`、`key.properties`、keystore 或调试脚本。

### 续审新增缺陷

| 编号 | 级别 | 影响范围 | 复现步骤或证据 | 根本原因 | 涉及文件 | 修改方案 | 修复状态 | 验证结果 |
|---|---|---|---|---|---|---|---|---|
| WD-APP-R6-001 | 严重 | 已保存警情因单位切换、服务端撤销或权限收紧而不可见时，App 仍展示上一警情的人员、压力和随手记缓存，存在跨单位误呈现/信息残留风险。 | Android API 33 模拟器接入启用 `WATCHDOG_UNIT_AUTH_REQUIRED=1` 的隔离后端：保存的旧 `unit_id=null` 警情请求返回 404 `INCIDENT_NOT_FOUND`，日志连续出现 `GET /api/incidents/<id> 404`；修复前截图 `/tmp/watchdog-api33-unit-auth-recovery.png` 显示警情卡片仍在但连接状态为“同步失败”，修复后截图 `/tmp/watchdog-api33-stale-cleared-2.png` 显示“先选择一份警情”。 | `AppController._syncInternal` 的通用异常分支只更新 `syncError`，未清空 `currentIncident`、`entries`、`notes`、`forces`，也未停止旧警情保活/告警。 | `app/lib/state/app_controller.dart`、`app/test/app_controller_offline_test.dart` | 对明确的 `INCIDENT_NOT_FOUND` 清除本地警情选择、缓存快照、保活与告警调度，并保留活动警情列表供重新选择；新增控制器回归测试。 | 已修复 | 定向 Flutter 测试、全量 Flutter 196/196、API 33 模拟器旧卡片清除复验和单位绑定新建警情复验均通过；新建警情查询结果 `unit_id=test-unit`，见 `/tmp/watchdog-api33-unit-bound-incident.png`。 |
| FLT-017（续审闭合） | 一般 | 用户修改服务器地址后，本地 ASR 仍可能请求编译期默认模型源，导致自部署 API 与模型源不一致。 | 构造自定义 `server_url=https://self-hosted.example/firewatch`，调用未显式覆盖模型地址的 `LocalAsrService.downloadModel()`；回归请求全部命中 `/firewatch/models/`。 | ASR 服务在构造时固化 `Settings.defaultModelBaseUrl`，没有在下载时读取运行时服务器设置。 | `app/lib/services/settings.dart`、`app/lib/services/local_asr_service.dart`、`app/test/controller_service_lifecycle_test.dart` | 增加独立 dart-define 覆盖识别；无显式覆盖时在下载时解析当前 `Settings.serverUrl` 并追加 `/models`，保留构造参数覆盖和 HTTPS 校验。 | 已修复 | 定向生命周期测试、全量 Flutter 196/196 和 `flutter analyze` 0 issues 均通过。 |
| FLT-019（续审闭合） | 优化 | 辅助页语音空转写或页面销毁后操作日志缺少终态，影响故障排查和操作链路完整性。 | 注入空白转写，修复后同一 `op_id` 追加 `op_end(outcome=no_speech)`；录音中销毁页面追加 `op_end(outcome=page_disposed)`。 | 空转写分支和 `dispose()` 均遗漏统一 `_endOp()` 收尾。 | `app/lib/pages/chat_page.dart`、`app/test/widget_test.dart` | 空转写和页面销毁路径统一写入终态，区分 `no_speech`、`page_disposed` outcome。 | 已修复 | 两个定向 Widget 回归通过；全量 Flutter 196/196、`flutter analyze` 0 issues。 |

## 六、验收判定

代码级验收通过：后端与 Flutter 门禁、构建、签名/ABI、部署健康检查、未授权边界和本轮可复现缺陷均有证据，测试数量已更新为 backend 117 / App 196 且未减少。

项目级验收未通过，不能宣布本轮整体完成。阻塞项是身份/session/RBAC、PG 跨表原子幂等与多实例竞态、默认首屏产品决策、物理 Android/弱网/TalkBack/SQLite 验证，以及模型发布者真实性和性能基准；Android 模拟器已补充部分权限与核心流程证据，但不能替代物理设备和预生产验收。用户已明确授权本轮执行 `1.2.1+49` commit、push 和 release；后端部署是 `AGENTS.md` 明确要求的例外，已完成并通过线上健康检查。
