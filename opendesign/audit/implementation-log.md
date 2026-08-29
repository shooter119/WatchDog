# WatchDog 整改施工记录

## 2026-08-29 续审：ApiClient 出场错误响应边界

### 发现与修复

- 台账编号：`FLT-024`，级别：一般；关联测试缺口 `TQ-007`。
- 复核发现 `ApiClient.markExited` 的异常分支没有解析服务端响应，因此丢失服务端错误码；网关返回 HTML 等非 JSON 响应时，错误边界也没有统一经过结构化解析。
- `app/lib/api/api_client.dart` 现统一使用 `_decodeJson` 与 `_apiException`，保留 HTTP 状态和服务端 `code`；非 JSON 响应统一返回 `INVALID_JSON`，避免向页面泄露底层解析异常。
- `app/test/api_client_test.dart` 新增出场错误码和非 JSON 网关错误回归，覆盖独立本地 HTTP fixture。

### 验证

- ApiClient 定向回归通过；完整 Flutter 测试为 214/214，`flutter analyze` 为 0 issues。

## 2026-08-29 续审：名单管理页状态更新

### 发现与修复

- 台账编号：`FLT-025`，级别：一般。
- 页面操作完成后，Controller 和接口数据已经变化，但 `RosterPage` 未监听 Controller，导致添加/删除后的可见列表和数量仍是旧快照。
- `app/lib/pages/roster_page.dart` 的 body 现监听 `AppController`；不改变接口、权限或业务规则，只修复状态变更后的重建。
- `app/test/management_pages_test.dart` 覆盖加载、添加和删除确认后的页面结果。

## 2026-08-29 续审：ASR WebSocket 帧解析与上游边界

### 发现与修复

- 台账编号：`BACK-022`，级别：严重；关联测试缺口 `TQ-003`。
- 新增协议夹具发现合法服务端响应被解析为空：`parseFrame` 直接从帧头后读取业务长度，没有先跳过 WebSocket 协议的外层 payload 长度。
- `backend/src/asr.js` 现按外层长度截取帧 payload，再解析可选序列、业务长度和 JSON；`transcribe` 保留生产默认 WebSocket 地址，并允许测试注入工厂，不改变线上调用契约。
- 新增 `backend/test/asr.test.js` 及 `parse.test.js` 的上游边界回归，覆盖成功/错误/空结果/超时/异常关闭、非 2xx、空响应、响应形状、重定向和超时信号。

### 验证

- ASR/parse 定向回归：34/34 通过。
- `cd backend && npm test`：154/154 通过，0 失败、0 skipped、0 todo。
- 真实豆包 ASR/DeepSeek 供应商联调仍需外部凭据和运行时环境，不能由本地替身替代。

## 2026-08-29 续审：日志、限流、模型清单与发布凭据边界

### 发现与修复

- `LOG-SEC-001`：服务端操作日志的敏感字段白名单遗漏姓名、作者、压力、人员等字段；现统一做长度/摘要或 `[REDACTED]` 处理，并移除重复进场日志消息中的姓名。
- `PERF-RATE-001`：ASR/解析的进程内限流 Map 原先只清理过期项，无法限制同一分钟高基数来源；新增固定容量 `MinuteRateLimiter`，按最近使用时间淘汰。
- `DEPLOY-001`：新增 `deploy/verify-model-manifest.js`，部署前校验本地和临时包逐文件大小/SHA-256，部署后逐文件下载复核远端资源。
- `ASR-CACHE-001`：模型二进制继续一年 immutable 缓存，`manifest.json` 改为 `no-cache, must-revalidate`，避免清单长期陈旧。
- `CI-SEC-001`：Release checkout 关闭 Git 凭据持久化，减少构建依赖链路的写权限暴露面。

### 验证

- `cd backend && npm test`：154/154 通过，0 失败、0 skipped、0 todo；限流和日志脱敏新增回归通过。
- `node deploy/verify-model-manifest.js local ...`、脚本语法检查及工作流 YAML 解析通过。
- 已完成上述正式 CloudBase 部署：Deployment successful；线上健康检查通过，manifest 返回 `no-cache, must-revalidate`，远端 6 个模型文件逐项大小与 SHA-256 校验通过；真实 GitHub Actions 新 tag 实跑保留为外部定期验收项。

## 2026-08-29 续审：前台保活警情上下文复核

### 新发现（使用逻辑待确认）

- 台账编号：`FLT-026`，级别：一般。
- 交叉复核确认：`ForegroundKeepAlive.start()` 在服务已运行时只保存新警情配置便返回；`WatchdogTaskHandler.onStart()` 之后不会自动重新读取配置，导致切换警情后后台任务仍持有旧 `_incidentId`，退出警情后也可能继续轮询旧现场。
- 证据文件：`app/lib/services/foreground_keep_alive.dart`、`app/lib/state/app_controller.dart`；当前测试只覆盖主 isolate 摘要新鲜度，未覆盖服务已运行状态下的警情切换/退出。
- 低风险方案：切换时通过非敏感配置变更信号让服务 isolate 重新从安全存储读取完整上下文；当前警情为空时明确停止服务；增加切换、退出和停止清理回归。该行为会直接影响后台通知和耗电，暂等待用户确认后施工。

### 用户确认

- 用户确认：切换警情时立即刷新后台服务上下文；退出或归档警情时立即停止服务；无当前警情时不启动服务；保留“后台值守”开关偏好，重新选择警情后自动恢复。
- 当前仍未修改源码；该项进入 App 施工和 Android 生命周期验收队列。

## 2026-08-29 续审：录音时长上限体验复核

- 台账编号：`PE-001`，级别：一般。
- `AudioService.stop()` 仅在录音结束后检查 15MB 文件大小；首页和辅助页的长按录音流程没有时长计时器、提前提醒或自动停止逻辑。
- 当前录音格式为 16kHz、单声道、16-bit WAV，15MB 约对应 8 分钟录音；超限时在松手后直接返回“录音过长，已拒绝处理”，会造成用户长时间操作后结果丢失。
- 该项直接影响录音操作和失败后的用户感受，暂不擅自决定时长与提示文案；已列入下一项产品使用逻辑讨论。

## 2026-08-29 续审：最终构建与静态复验

- `cd backend && npm test`：154/154 通过，0 失败、0 skipped、0 todo。
- `cd app && flutter analyze`：0 issues；`cd app && flutter test --reporter expanded`：214/214 通过，0 skipped。
- `flutter build apk --release --target-platform android-arm64 --split-per-abi --no-pub`：成功生成 47,380,932 字节 arm64 APK；`apksigner verify --verbose`：v2=true、1 signer。
- 当前工作区 APK SHA-256：`139d0ca2fa0a916712496e2c674b3a4d1dc5dda7a31301cbc42f12bb698c390e`；签名证书 SHA-256：`0676114be5b9eb9d4448cb849d9b938b278214bb81de04a5debcde5eaf270668`。
- `bash -n deploy/deploy.sh`、`./deploy/deploy.sh --dry-run`、Node 语法检查及 GitHub Actions YAML 解析均通过；线上 `/api/health` 和 `/models/manifest.json` 回读仍正常。
- ASR 后端修复后按 `AGENTS.md` 重新执行正式 CloudBase 部署：Deployment successful；线上 `/api/health` 返回 `ok=true, ready=true, databaseReady=true, asrConfigured=true, llmConfigured=true`，公开模型清单回读 6 个文件并与仓库清单一致。
- 本地 `deploy/models/manifest.json` 的 6 个资源逐个按清单核对字节大小和 SHA-256，结果全部匹配。

### 最终外部环境复核

- GitHub CLI 仍已授权 `shooter119`，最新 `Quality Checks` 与 `Build & Release APK` 均为 success；既有 `v1.2.1+49` Release 为正式版，未在本轮新增 commit、push 或发版。
- 当前主机 `adb devices` 无连接设备，`flutter devices --machine` 仅发现 macOS/Chrome，`emulator -list-avds` 无可用 AVD；因此 Android Keystore、录音/权限、前台服务、通知、TTS、TalkBack、锁屏、弱网、低存储和进程杀验收仍不能伪造为通过。
- 当前环境未提供 `CLOUDBASE_*`/PostgreSQL 迁移凭据，且未安装 Docker/Podman；因此不执行生产 PostgreSQL 迁移、备份恢复、双实例并发或镜像级容器验证，不打开生产会话/RBAC/原子操作开关。
- 结论：本机代码级门禁和线上健康检查通过；项目级验收继续保持“未通过（外部条件阻塞）”。

## 2026-08-29 续审：会话登出 Bearer 解析一致性

### 发现与修复

- 台账编号：`SEC-019`，级别：一般。
- 交叉复核发现认证中间件使用大小写不敏感的 `Bearer` 解析，而 `/api/auth/logout` 使用大小写敏感解析；混合大小写授权头会出现“登出成功但会话未撤销”。
- `backend/src/server.js` 新增 `sessionTokenFromRequest`，统一认证中间件和登出接口的会话令牌解析规则；不改变令牌格式、权限或业务路径。
- `backend/test/session-auth.e2e.test.js` 将登出回归改为混合大小写 `bEaReR`，并继续验证旧会话随后返回 `SESSION_INVALID`。

### 验证

- `cd backend && npm test`：140/140 通过，0 失败、0 skipped、0 todo。
- 修复已纳入 A1 身份/RBAC/单位隔离自动整改队列；部署前继续执行 dry-run 和健康检查。

## 2026-08-29 续审：端侧 ASR 模型完整性第一阶段

### 范围

- 台账编号：`SEC-013`。
- 目标：在不把任何私钥或真实凭据放入仓库的前提下，先闭合模型下载截断、缓存篡改和新旧集合切换的一致性风险。

### 已实施

- 新增 `deploy/models/manifest.json`，记录当前模型版本、6 个模型资源的字节大小和 SHA-256；实际值由仓库中的模型文件计算得到。
- `app/lib/services/local_asr_service.dart` 下载前通过 HTTPS 同源读取 manifest，限制清单大小、连接/读取超时并禁止重定向；清单版本、路径、文件列表和 SHA-256 格式均校验。
- 模型及降噪模型下载后逐文件校验大小和 SHA-256，随后写入 `.integrity.json` 快照和完成标记，最后才原子切换 `.active`；任何失败都会清理 staging 并保留旧 active。
- 本地 ASR 启动、启用检查和安装状态检查会复核完整性快照；缓存文件被替换、旧目录或未完成集合均拒绝使用。
- 未实现签名清单、公钥和私钥发布链路：私钥必须由外部 CI/发布密钥系统提供，不能猜测密钥格式或把密钥写入仓库；该部分继续作为外部发布验收项。

### 验证记录

- 新增 ASR 回归：清单哈希不匹配时拒绝激活并保留旧 active；缓存文件替换后安装检查失败。
- `cd app && flutter analyze`：0 issues。
- ASR 与控制器生命周期定向测试：14/14 通过。
- 测试夹具同步支持 manifest，覆盖自定义模型地址、运行时服务器地址和清单 HTTP 错误路径。

### 当前边界

- `deploy/` 发生资源变更，完整门禁通过后按 `AGENTS.md` 执行 dry-run、正式部署和公开 manifest 回读；部署只发布清单，不改变数据库规则。
- Android 真机下载、断网启动、低存储和正式包签名运行时验证，以及签名 manifest 的外部密钥接入仍未完成。

### 本阶段收口验证

- `cd backend && npm test`：140/140 通过；`cd app && flutter analyze`：0 issues；`cd app && flutter test`：214/214 通过，skipped=0。
- `deploy/deploy.sh --dry-run` 通过；正式 CloudBase 部署返回 Deployment successful，健康检查全部就绪；公开 `/models/manifest.json` 回读与仓库清单字节级一致。
- arm64 release APK 构建成功（47.3MB），`apksigner` v2=true、1 signer；当前工作区 APK SHA-256：`83d77c2b158347347dee4a8fd6a668b20b63e099fa840d4d067801f01a03dd21`。

## 2026-08-28 第一批：认证与身份边界

### 范围

- 台账编号：`BACK-001`、`BACK-003`、`BACK-004`、`SEC-003`、`SEC-004`、`SEC-005`。
- 关联路线：A1 身份/RBAC/单位隔离；客户端仅增加协议字段，不改变认证页面和操作路径。

### 已实施

- SQLite 与 CloudBase PostgreSQL 新增 `unit_members`、`auth_sessions` 结构及索引；新增 `004_auth_sessions_and_members.sql`。
- 单位成员准入支持显式部署配置 `WATCHDOG_SEED_UNIT_MEMBERS`，不从全局消防员名单自动推导。
- 服务端认证会话使用随机令牌，数据库只保存 SHA-256 哈希；支持 Bearer 和 `X-Session-Token`，服务端校验过期、撤销和单位绑定。
- 会话身份优先于请求体、请求头和设备档案，操作人和设备标识不能由调用方在会话模式下覆盖。
- 名单、热词、消防站写操作增加管理角色门禁；操作日志清空继续要求管理令牌或管理角色。
- Flutter 客户端增加会话令牌透传、持久化、退出清理和前台保活透传。

### 验证记录

- 后端原有基线：117/117 通过。
- 新增认证仓储和严格认证回归：2/2 通过；当前后端目标用例数为 119。
- `git diff --check` 已通过。
- 完整后端门禁已通过 120/120；Flutter 已通过 analyze 0 issues、test 198/198。
- CloudBase `watchdog-api-prod` 已部署，直连服务健康检查 200；网关首次检查出现 503，随后重试恢复 200，部署脚本最终成功。
- PG 迁移未执行：当前环境没有 `CLOUDBASE_SECRET_ID/CLOUDBASE_SECRET_KEY`，因此 `npm run db:migrate` 在凭据检查阶段停止；服务仍保持认证兼容开关关闭状态，未启用会话强制。

### 安全核查追加

- CloudBase 服务详情命令会原样输出运行时敏感环境变量；本轮未把任何值写入仓库。该行为登记为 `SEC-018`，后续核查必须使用字段过滤输出，并由运维完成密钥轮换评估。

### 分阶段上线说明

`WATCHDOG_SESSION_AUTH_REQUIRED`、`WATCHDOG_MEMBER_AUTH_REQUIRED` 默认关闭，作为数据库迁移与新版 App 的兼容窗口；完成 PG 迁移、成员名单配置并发布支持会话的 App 后，生产运行时必须同时设为 `1`。在开关开启前，不能把“生产会话强制”标记为已完成。

## 2026-08-28 第二批：数据库一致性、操作幂等与日志边界

### 范围

- 台账编号：`BACK-006`、`BACK-007`、`BACK-009`、`BACK-010`、`BACK-012`、`BACK-013`、`BACK-014`、`BACK-015`、`BACK-018`、`SEC-007`、`SEC-009`～`SEC-013` 的代码侧安全项、`PE-011`、`PE-013`。
- 关联路线：A2 数据一致性；A3 限流、输入资源和隐私日志；A4 设备标识与令牌存储；A5 查询和工程效率。

### 已实施

- `backend/src/db-sqlite.js` 的关键现场写入使用 `BEGIN IMMEDIATE` 复合事务；进场、出场、压力复核、随手记、警情归档、警情改名、参战力量和日志批量写入均有状态/事件成组提交路径。
- `backend/src/db-postgres.js` 增加与 PostgreSQL RPC 对齐的复合写入接口；`backend/migrations/007_atomic_write_functions.sql` 已准备关键 RPC，生产开关仍保持关闭。
- `operation_ledger` 保存单位+操作号、请求摘要、处理中租约和安全结果引用；离线补传逐条建立账本，同一操作号正文变化返回冲突。
- `backend/migrations/006_integrity_constraints.sql` 增加关键数值 CHECK、父子 FK 和索引，使用 `NOT VALID` 保留历史数据；迁移脚本增加版本与 SHA-256 校验。
- 服务端错误日志不再保存上游响应正文或异常堆栈，敏感字段只记录长度/摘要；聊天历史先限制为最近 40 条；日志批量上报使用单次数据库提交。
- App 设备标识改为随机安装 ID；退出单位时删除前台服务独立存储中的令牌、单位和警情数据；API Token 与 session token 接入系统安全存储，并保留旧版本兼容迁移。

### GitHub 外部复核（2026-08-29）

- GitHub CLI 授权状态正常，仓库为公开仓库，默认分支为 `main`。
- 最新 `Quality Checks` 与 `Build & Release APK` 均为 success；正式 Release `v1.2.1+49` 已上传 arm64 APK，tag 与 `main` 指向同一提交。
- GitHub API 返回 `Branch not protected`。该项不是本地代码可代替的证据，保留为 `SEC-014` 外部整改：启用 `main` 分支保护、Pull Request/评审门槛及 tag/Release 权限限制。
- 已按整改方案完成 GitHub 仓库策略配置：`main` 强制 Pull Request、至少 1 名评审、`backend`/`app` 检查通过，禁止管理员绕过、强制推送和删除；新增 active Ruleset `Protect published version tags`，保护 `v*` tag 禁止删除/强制更新；仓库 Actions `sha_pinning_required=true`。配置已通过 GitHub API 回读。

### 验证记录

- Node 语法检查通过；`cd backend && npm test` 当前 `140/140` 通过，较原始基线 117 未减少。
- 新增/覆盖：操作账本租约接管、跨类型/跨警情操作冲突、离线正文变更冲突、复合事务回滚、管理写入事件一致性、批量日志写入、异常日志脱敏和 `X-Request-Id`。
- App 已执行 `flutter pub get`，安全存储依赖解析通过；认证生命周期定向测试通过。完整 `flutter analyze`/`flutter test` 在本批 App 改动收口后为 0 issues、200/200 通过。

### 未闭合与外部边界

- CloudBase PostgreSQL 迁移尚未执行：当前环境缺少 `CLOUDBASE_SECRET_ID/CLOUDBASE_SECRET_KEY`；不能伪造迁移成功，也不能在没有备份和预生产验证时打开 `WATCHDOG_OPERATION_LEDGER_ENABLED`、`WATCHDOG_ATOMIC_OPS_ENABLED`。
- `SEC-018` 仍为外部运维项：CloudBase 服务详情命令可能输出运行时环境变量；本轮没有复制或写入任何值，后续检查只使用过滤后的状态输出，密钥轮换由运维评估。

## 2026-08-28～2026-08-29 续审：出站目标边界、日志持久化和分页收口

### 已实施

- 新增 `backend/src/network-policy.js`，统一解析严格的主机/端口允许列表，拒绝 URL、路径、通配符和凭据。
- 生产后端校验 DeepSeek 目标命中 `WATCHDOG_LLM_ALLOWED_HOSTS`，CloudBase REST 目标匹配当前环境派生主机或 `CLOUDBASE_REST_ALLOWED_HOSTS`；DeepSeek、CloudBase 请求和流式请求均禁止自动跟随重定向。
- App `Settings` 将正式包服务器地址锁定到编译时登记端点；开发/测试保留 HTTPS/本机地址，`ApiClient`、前台保活和本地模型下载统一经过目标校验；单位验证码与 API/session token 一并迁移到安全存储兼容层。
- 操作日志本地持久化改为当前事件循环内合并、尾部串行写入，显式清空/退出单位时强制落盘；修复延迟 Timer 导致 Flutter 测试收口失败的问题。
- 同步完成主台账中分页、批量日志、设备标识、安全存储和错误脱敏的当前状态更新；README/关于我们内容复核后无需新增用户功能说明，部署说明与环境变量示例已同步。

### 验证记录

- `cd backend && node --check ...` 通过；`npm test`：140/140，通过 0，失败 0，skipped 0，todo 0。
- `cd app && flutter analyze`：0 issues。
- `cd app && flutter test`：200/200，通过 0，skipped 0；此前受影响的离线压力、问答并发和日志持久化定向测试全部通过。
- 新增主机/IP 白名单、CloudBase 生产匹配、重定向选项、单位验证码安全存储兼容和日志合并回归均通过。
- 2026-08-29 按 `AGENTS.md` 重新执行 `deploy/deploy.sh --dry-run` 与正式部署；CloudBase 返回 Deployment successful，健康检查 `ok=true`、`ready=true`、`databaseReady=true`、`asrConfigured=true`、`llmConfigured=true`。
- 正式构建首次暴露 `flutter_secure_storage` 要求 compile SDK 37 而工程仍使用 36 的配置缺陷；已将 `app/android/app/build.gradle.kts` 显式调整为 `compileSdk = 37`，随后 arm64 release 构建成功，`apksigner` v2 校验通过、单签名者，APK SHA-256 为 `0dc6250bd47b9cb8915154dccaab80562518a97a8b31dbcf161a055c86512f4b`。
- 复核发现认证重试会关闭 `ApiClient` 共享客户端，存在中断并发同步的确定性风险；已改为认证重试使用独立客户端并在销毁时统一回收，新增“认证重试期间同步请求仍完成”回归用例，定向测试通过。
- 修正控制器中两处旧共享请求池重置调用，完整 Flutter 测试最终为 201/201；arm64 release APK 重新构建成功，v2 签名校验通过。
- 将每秒阈值检查从根 `ChangeNotifier` 广播拆为 `AppController.clockTick`，由倒计时相关页面局部监听，避免无关 Tab 每秒重建；新增通知隔离测试已通过。
- 双轮询收口：主 isolate 成功同步后向前台服务发送摘要时间、在场人数和最早到期时间；服务 isolate 在 8 秒新鲜窗口内跳过重复网络请求，主同步停止后继续后台兜底；新增前台服务摘要新鲜度测试。
- 本轮最终 Flutter 全量测试为 204/204，`flutter analyze` 为 0 issues；arm64 release APK 成功构建并通过 v2 签名校验，SHA-256 为 `7ca42e317656cfc442d242535b7ec6f684b8441cf46ffbdd7cd9d45e92b0c49f`。
- 外部环境复核：GitHub Actions/Release 已成功，但 `main` 分支未启用保护；本机 `flutter devices --machine` 仅有 macOS/Chrome，`adb devices` 无 Android 设备，真机验收继续保留为外部项。
- 发布资产复核：下载公开 Release `v1.2.1+49` 的 arm64 APK 后，实际 SHA-256 为 `0cf29e20ca8afcdb0849dd211519bf0ce04a787514afde40bae82d321001b4aa`，与 Release 正文完全一致，`apksigner` v2 校验通过且仅 1 个签名者；当前未提交工作区重建 APK 的 `7ca42e...` 差异仅反映构建来源不同。
- 依赖只读扫描：后端使用官方 npm registry 执行 `npm audit --omit=dev --audit-level=high`，结果为 0 vulnerabilities；Flutter `pub outdated` 显示 12 个锁定旧版本、7 个受约束版本。插件升级需要维护窗口和 Android 回归，本轮不自动升级。
- 工作区洁净复核：确认被 `.gitignore` 忽略的历史 `backend/asr-debug.js` 不属于业务代码后，已可恢复地移至 `/tmp/WatchDog-quarantine/asr-debug.js`，项目目录和 Git 跟踪范围均不再包含该调试脚本；未删除、未提交任何调试文件。
- 容器复核：本机未安装 Docker/Podman，无法执行镜像构建与容器级 HEALTHCHECK 验证；Dockerfile 的非 root 和 HEALTHCHECK 配置已静态复核，CloudBase 线上服务健康检查已通过，镜像级证据保留为外部项。

## 2026-08-29 续审：令牌落盘、OTA 大小边界、模型回收与发布防护

### 新增问题与处理

- `SEC-020`：确认 `flutter_foreground_task` 的持久化区不适合保存凭据，且原 `SecureStore` 在 Android/iOS 原生安全存储失败时会回退到 SharedPreferences。现已将 API Token、会话令牌和单位验证码改为只写 `SecureStore`，前台服务 isolate 从安全存储读取；升级后不读取旧插件明文键，并清理旧键。原生安全存储失败时 fail-closed，不新写明文副本。
- Android `AndroidManifest.xml` 增加 `allowBackup=false`、`fullBackupContent=false` 和 `data_extraction_rules.xml`，认证令牌、单位身份及现场缓存不参与云备份或设备转移。
- `PE-019`：OTA 下载增加 160MB 总上限、清单大小上限、响应 `Content-Length` 预检、流式累计上限和下载完成后的精确字节数校验；大小不符或超限不会进入安装器。新增截断和超限回归。
- `PE-MODEL-001`：本地 ASR 新集合激活后等待识别初始化和转写队列空闲，仅回收不再被当前识别器/降噪器引用的旧 generation；active 或仍被 native 资源使用的集合不删除。新增双 generation 回归。
- `BACK-021`：`deploy/deploy.sh` 对模型目录和 `manifest.json` 改为 fail-closed；部署后读取公开模型清单并校验 schema/modelVersion/files；部署 CLI 固定 `@cloudbase/cli@3.8.1`。
- `TQ-012`：release workflow 增加串行并发组、OTA 发布前的 `versionCode` 单调递增检查，并固定 CloudBase CLI 3.8.1；质量基线更新为后端 140、App 214。

### 本阶段验证

- OTA、ASR generation、前台服务相关定向测试：29/29 通过。
- `cd backend && npm test`：140/140 通过，0 失败、0 skipped、0 todo。
- `cd app && flutter analyze`：0 issues。
- `cd app && flutter test --reporter expanded`：214/214 通过。
- `bash -n deploy/deploy.sh` 与 `./deploy/deploy.sh --dry-run`：通过；dry-run 已确认部署包包含 backend/src、模型文件和 manifest。

### 当前边界

- Android Keystore、前台服务独立 isolate、备份/恢复和低存储清理必须用真实 Android 设备完成；当前本机仍无 Android 设备。
- 本阶段 deploy 脚本改动已在全量 App 验证后执行正式 CloudBase 部署和线上模型清单复验；不执行 PostgreSQL 迁移，不打开生产会话/RBAC 或原子操作开关。

### 线上复验结果

- 已完成正式 CloudBase 部署：Deployment successful；`/api/health` 返回 `ok=true`、`ready=true`、`databaseReady=true`、`asrConfigured=true`、`llmConfigured=true`。
- 已回读线上 `models/manifest.json`，与仓库清单字节级一致；6 个模型资源逐个下载后，大小和 SHA-256 均与清单一致。
- 线上复验未执行 PostgreSQL 迁移、生产会话/RBAC 或原子操作开关；这些仍需具备迁移凭据、备份和预生产环境后再验收。

### 未闭合边界

- 生产运行时 allowlist、会话/RBAC 开关、PG 迁移/RLS/RPC、双实例并发、备份恢复、正式签名 APK 运行时地址锁定和真实上游重定向仍需外部环境证据。
- 本次续审没有执行新的 commit、push 或发版；既有 `v1.2.1+49` Release 已完成只读复核，后端部署义务已完成并记录。CloudBase 迁移仍因缺少迁移凭据不执行。

## 2026-08-29 第六轮：SQLite 旧库迁移与原子 RPC 冲突目标

### 新增问题与处理

- `DB-LOCAL-001`：复现发现 SQLite 旧库第二次启动会把已经迁移成 UUID 的 `scene` 再次创建为新警情。`backend/src/db-sqlite.js` 现先按 `incidents.id` 判断已迁移 scene 并跳过；新增两次启动回归，警情数量和历史 scene 保持不变。
- `DB-LOCAL-002`：复核 `007_atomic_write_functions.sql` 的 11 处 `ON CONFLICT (client_op_id)` 与 `001` 的部分唯一索引不匹配。遵循既有迁移不可原地修改约定，新增 `008_atomic_rpc_conflict_index.sql` 建立完整唯一索引；PostgreSQL 唯一索引允许多个 NULL，不改变无操作号事件行为。
- `DB-LOCAL-003`：旧库迁移的创建警情、改写历史行和清理旧状态原先不在同一事务中。现复用 SQLite `BEGIN IMMEDIATE` 事务 helper，并以触发器故障注入验证失败会回滚全部迁移步骤。

### 验证记录

- 针对性数据库回归和原子 RPC 迁移静态回归通过；随后 `cd backend && npm test` 为 158/158，0 失败、0 skipped、0 todo。
- 新增测试未减少原有用例；`AGENTS.md`、质量/发布 workflow 和审核台账的后端门禁已同步为 158。
- 后端源代码改动按项目约定再次完成 CloudBase 正式部署；Deployment successful，健康检查 `ok=true`、`ready=true`、`databaseReady=true`、`asrConfigured=true`、`llmConfigured=true`。

### 保留的外部边界

- `DB-EXT-001`～`DB-EXT-003`：生产 PostgreSQL 的 RLS/约束、迁移并发与 RPC 故障注入、备份恢复和重启扩容连续性仍需真实凭据、备份和隔离环境；本轮没有执行生产迁移或数据写操作。

## 2026-08-29 自动续审：FLT-026 方案追踪补录

- App 功能组只读交叉复核确认 `FLT-026` 的代码证据、主问题台账和实施记录相互一致：前台服务已运行时不会自动刷新警情上下文，退出/归档后也没有明确停止服务。
- 因该项会直接改变后台通知和耗电行为，继续保留为唯一待用户确认的产品/使用逻辑；未修改 App 源码、未改变后台值守开关默认行为。
- 将证据、拟定使用逻辑、最小实施方案和 Android 真机验收项补入 `opendesign/audit/improvement-roadmap.md`，使路线图与主台账、分类表保持可追溯一致。
- 文档变更通过 `git diff --check`；无 README 或 App「关于我们」同步要求，因为未改变产品功能、品牌、架构或入口。
- 另新增 `opendesign/audit/external-acceptance-runbook.md`，固化隔离 PostgreSQL 迁移/RLS/RPC、双实例并发/恢复和 Android 真机验收步骤；手册只使用占位凭据和脱敏记录，不执行任何生产数据操作。
- 新增 `DB-LOCAL-004`：发现原子 RPC 开关可脱离操作账本单独启用；`backend/src/server.js` 已增加启动 fail-fast 校验，新增子进程回归后执行后端全量测试 159/159、Flutter analyze 0 issues、Flutter 测试 214/214，并按约定完成 CloudBase 正式部署；线上健康检查和模型清单校验通过。

## 2026-08-29 目标恢复后的最终本机复验

- 当前工作区重新执行 `cd backend && npm test`：159/159 通过，0 failed、0 skipped、0 todo。
- 重新执行 `cd app && flutter analyze`：0 issues；`cd app && flutter test`：214/214 通过。
- 重新通过后端/部署脚本 Node 语法检查、`bash -n deploy/deploy.sh`、`git diff --check`；敏感文件扫描未发现 `.env`、keystore、key.properties、调试脚本或临时日志进入版本控制。
- 复核结论：没有新增可由当前代码、测试或运行结果支持的阻断/严重缺陷；真实 PostgreSQL/RLS/RPC、多实例并发、备份恢复、Android 真机和 `FLT-026` 使用逻辑仍保持未闭合，不将本机证据冒充最终生产验收。
- 外部条件复核：当前环境仍无 `psql`/`pg_isready`、Docker/Podman、Android 设备或可用模拟器；GitHub 授权有效，既有 `v1.2.1+49` 的 Quality Checks、APK 构建和 Release 均成功，线上 `/api/health` 返回 `ok=true`、`ready=true`、`databaseReady=true`。
- 当前工作区重新完成 Android arm64 release 构建：`flutter build apk --release --target-platform android-arm64 --split-per-abi` 成功；APK 47,380,932 bytes，仅含 `lib/arm64-v8a/`，`apksigner` v2 验证通过、1 个签名者，证书 SHA-256 为 `0676114be5b9eb9d4448cb849d9b938b278214bb81de04a5debcde5eaf270668`，包 SHA-256 为 `139d0ca2fa0a916712496e2c674b3a4d1dc5dda7a31301cbc42f12bb698c390e`。
- 新增 `CI-OTA-001`：只读检查发现 GitHub 仓库尚未配置国内 OTA 所需四个 Secrets，且原发布 workflow 先创建 GitHub Release 后检查 OTA，可能形成半完成发布。已将 workflow 顺序调整为 OTA 上传/远端校验成功后再创建 GitHub Release；缺少 Secrets 和新 tag 实跑仍保留为外部验收项，详见 `round7-release-review.md`。
- 为 `CI-OTA-001` 补充 `deploy/cloudbase/README.md` 的四个 OTA Secrets、最小权限和发布顺序说明；本轮重新通过 `git diff --check` 与 release workflow YAML/步骤顺序静态校验。

## 2026-08-29 部署复验记录

- 因本轮修改涉及 `deploy/` 文档，按项目约定重新执行 `CLOUDBASE_ENV_ID=watchdog-prod-d6gch930m378d9a16 ./deploy/deploy.sh`。
- 第一次上传部署包时 CloudBase CLI 等待约 9 分钟后因对象存储请求 `read ETIMEDOUT` 退出；期间未执行数据库迁移、功能开关变更或生产数据写操作；现网健康检查仍为 `ok=true`、`ready=true`、`databaseReady=true`。
- 在确认现网健康后安全重试，第二次部署完成并通过脚本自动校验：Deployment successful，健康检查 `ok=true`、`ready=true`、`databaseReady=true`、`asrConfigured=true`、`llmConfigured=true`，线上模型清单 6 个文件校验通过。

## 2026-08-29 第八轮：OTA 公开对象地址修复与线上兼容入口复验

### 新增问题与处理

- `CI-OTA-002`：只读请求证实原 App/Release workflow 使用的云托管网关 `/ota/latest.json` 返回 HTTP 401；正确的 CloudBase PG Storage 公开对象入口返回 `STORAGE_BUCKET_NOT_FOUND`，且当前环境尚无 OTA bucket。根因是云托管网关与 PG Storage 对象接口地址混用。
- App 默认更新地址和 Release workflow 构建注入地址已统一为 `https://<env-id>.api.tcloudbasegateway.com/v1/storages/object/public/<bucket>/<object>`。
- 新增 `009_ota_public_bucket.sql`，幂等创建 `watchdog-ota` 公开 bucket、160 MiB 限制、APK/JSON MIME 白名单和公开读 RLS；已有非公开同名 bucket 时直接失败并要求人工复核。
- 后端增加严格白名单的旧 `/ota/*` 兼容重定向，仅允许 `latest.json` 和限定格式的 arm64 APK 路径，禁止任意对象路径和开放重定向。
- Release workflow 新增 OTA Secrets 格式门禁，构建时动态注入公开清单地址，并在创建 GitHub Release 前完成 OTA 上传、远端 APK/清单回读和完整性校验。

### 本阶段验证

- `cd backend && npm test -- --test-reporter=spec`：160/160 通过，0 failed、0 skipped、0 todo。
- `cd app && flutter analyze`：0 issues。
- `cd app && flutter test`：214/214 通过。
- `git diff --check`、`node --check backend/src/server.js`、`bash -n deploy/deploy.sh`、workflow YAML/步骤顺序检查和 OTA 迁移契约检查通过。

### 线上复验结果

- 按 `AGENTS.md` 对 backend/deploy 改动的要求重新执行 `CLOUDBASE_ENV_ID=watchdog-prod-d6gch930m378d9a16 ./deploy/deploy.sh`，CloudBase 返回 `Deployment successful`。
- 线上 `/api/health` 返回 `ok=true`、`ready=true`、`databaseReady=true`、`asrConfigured=true`、`llmConfigured=true`；模型清单和 6 个模型资源校验通过。
- 线上旧 `/ota/latest.json` 返回 HTTP 302，`Location` 固定为 `https://watchdog-prod-d6gch930m378d9a16.api.tcloudbasegateway.com/v1/storages/object/public/watchdog-ota/latest.json`；直接请求该 PG Storage 地址返回 `STORAGE_BUCKET_NOT_FOUND`，证明兼容路由已生效，剩余缺口是外部 bucket/迁移配置。

### 当前边界

- 未执行 `009_ota_public_bucket.sql`，未读取或写入生产数据库；原因是当前无迁移凭据、备份和预生产环境，不能安全代替运维执行外部数据结构变更。
- GitHub 当前仍缺少 `CLOUDBASE_OTA_ENV_ID`、`CLOUDBASE_OTA_BUCKET_ID`、`CLOUDBASE_OTA_API_KEY_ID`、`CLOUDBASE_OTA_API_KEY`；未创建新 tag、未触发新 Release。
- `opendesign/audit/external-acceptance-runbook.md` 已补充 OTA bucket、公开对象回读、最小权限 API Key 和 OTA 先于 GitHub Release 的验收步骤；本机最终卫生检查、`git diff --check`、workflow YAML、Node/Bash 语法检查通过。

## 2026-08-29 第九轮：生产 PostgreSQL 只读状态核查

- 用户要求暂缓 OTA 迁移；未执行 `009_ota_public_bucket.sql`、未上传 APK、未创建 OTA API Key。
- 通过已登录 CloudBase 新版 PostgreSQL 管理界面完成只读查询：`public.schema_migrations` 不存在；`storage.buckets` 与 `storage.objects` 基础表存在但 `watchdog-ota` 无记录；`watchdog_*` 原子 RPC 查询无结果；`pg_policies` 在 `public` 和 `storage` schema 均无结果；`auth_sessions`、`unit_members`、`operation_ledger` 等项目升级表不存在。
- 仅读取数量摘要：`units=1`、`incidents=15`、`incident_events=126`，没有读取或保存姓名、验证码、Token 和现场正文。
- CloudBase PostgreSQL“备份”页面显示当前共享集群暂不提供备份能力；因此不在生产执行项目迁移，不启用会话/RBAC、操作账本或原子操作开关。
- 该轮没有代码修改；新增只读证据记录 `opendesign/audit/round9-production-pg-readonly-review.md`，并将 DB-EXT-001～DB-EXT-003 的状态更新为“已确认外部缺口，待恢复点/隔离环境”。
- 同轮只读服务详情复核确认 CloudBase 控制台会明文显示部分运行时敏感环境变量；未复制具体值、未写入仓库，沿用 `SEC-018` 外部运维待办，后续只允许字段过滤查询并由运维完成顺序轮换。
- 同轮只读网关复核：CloudBase 服务列表显示 `watchdog-api-prod`“已暂停”；等待详情加载后部署 027 显示“正常”、100% 流量、1 个实例，但确认测试域名提示后访问默认网关 `/api/health` 返回 HTTP 503。此前部署脚本成功记录与当前状态不一致，登记 `DEPLOY-002`，未执行启用、重启或重新部署。
- 用户确认 `FLT-026`：切换警情时立即刷新后台服务上下文；退出或归档警情时立即停止服务；无当前警情时不启动服务；保留“后台值守”开关偏好，重新选择警情后自动恢复。该项进入 App 施工和 Android 生命周期验收队列。
- 用户确认 `PE-001`：首页语音和辅助问答统一 60 秒上限，提前 10 秒提示，到点自动结束并处理已录音内容；15MB 大小限制继续保留。该项进入 App 施工和回归验收队列。
- 用户确认 `PE-MODEL-001`：低存储时不自动删除当前模型或用户数据；空间不足先提示，提供打开系统存储设置和继续联网识别；下载中空间不足时保留旧模型。该项进入 App 施工和 Android 真机验收队列。
- 转入下一项自动整改 `BACK-012`：CloudBase HTTP 网关 `/` 路由的限频设置只读显示为“未设置”；后端现有 IP+单位进程级限流不能覆盖最多 5 个实例。整改计划为按 ASR/解析/聊天资源成本配置共享限频，保留后端兜底并做 429、突发流量和多实例压测；本轮未修改生产网关。

## 2026-08-29 续审：辅助问答限流容量边界修复

- 台账编号：`BACK-013`、`PERF-RATE-001`；级别：严重/一般。
- 复核发现 `/api/chat` 仍使用仅在超过 10000 条时粗略清理的旧 `Map`，与 ASR/解析已经使用的固定容量限流器不一致；高基数来源可造成不必要的内存压力。
- `backend/src/server.js` 已统一改用 `MinuteRateLimiter({ maxEntries: 10000 })`，保持每分钟 10 次提问限制，并对来源 key 设置硬容量上限；移除无用的分钟变量。未改变业务规则或接口协议。
- 验证：初次统一限流修复后 `cd backend && npm test` 为 160/160，`node --check src/server.js` 通过，`git diff --check` 通过；随后日志脱敏收口新增回归，最终后端全量为 161/161。两次均按 `AGENTS.md` 执行部署并由 CloudBase 返回 `Deployment successful`，线上健康检查和 6 个模型资源校验通过。
- 状态：代码问题已闭合；网关共享限流、多实例和全量容量压测仍归入 `BACK-012` 外部验收，不在本轮虚构为已完成。

## 2026-08-29 续审：错误日志无分隔符时的原文泄露收口

- 台账编号：`BACK-014`、`SEC-007`；级别：严重/一般。
- 复核发现 `sanitizeErrorLogText()` 只在错误文本含冒号时隐藏详情；不含冒号的异常文本会保留前 160 个字符，诊断日志上报因此存在原文进入普通操作日志的路径。
- `backend/src/server.js` 已将无冒号错误统一转换为 `[error details redacted]`；带冒号错误继续只保留错误类型前缀。接口响应不变，不影响用户业务流程。
- `backend/test/logs.test.js` 新增无冒号异常原文回归，断言服务端日志只返回固定占位符；后端全量测试为 161/161，0 failed、0 skipped、0 todo。
- `node --check src/server.js` 与 `git diff --check` 通过；按约定再次部署，CloudBase 返回 `Deployment successful`，线上健康检查和 6 个模型资源校验通过。
- 状态：代码侧问题已闭合；历史日志清理、技术日志与普通业务日志的最终角色分层仍需外部运维策略和验收。

## 2026-08-29 续审：数据库完整性约束迁移审查

- 台账编号：`BACK-015`；级别：一般。
- 证据：静态复核 `backend/migrations/006_integrity_constraints.sql`，确认关键数值范围、父子引用约束和索引均采用可重复的 `IF NOT EXISTS`/约束名检查，并以 `NOT VALID` 方式兼容历史异常；复核 `backend/scripts/migrate-cloudbase.js`，确认按文件版本和 SHA-256 校验和执行，已应用文件校验和变化会拒绝跳过。
- 线上只读证据：CloudBase PostgreSQL 中当前未发现 `public.schema_migrations`，业务结构也未发现该轮新增的约束对象，说明生产迁移尚未应用；本轮没有执行任何 DDL/DML。
- 修改方案：先在可恢复的预生产/隔离环境做重复操作号、孤儿引用、NULL 单位和数值范围预检；按版本顺序执行迁移；单独验证约束；再做普通角色跨单位读写、原子 RPC 和旧客户端兼容验收。无恢复点或隔离环境前保持生产迁移和相关开关关闭。
- 状态：静态方案通过，真实生产执行受外部恢复/预生产条件阻塞；没有把本地 SQLite 或模拟 PostgREST 结果冒充生产验收。

## 2026-08-29 续审：PE-001 录音时长上限与自动收口

- 唯一编号：`PE-001`；严重程度：一般。
- 影响范围：首页语音录入、辅助问答语音录入。原实现只在停止后检查 15MB 文件大小，长时间按住录音会在结束时才失败，可能丢失用户等待和现场口述内容。
- 复现证据：静态复核确认 `home_page.dart` 与 `chat_page.dart` 的录音生命周期没有计时器；`audio_service.dart` 的 15MB 保护位于 `stop()` 后。按 16kHz、单声道、16-bit WAV 估算，文件上限约对应 8 分钟录音。
- 根本原因：页面只依赖长按松手事件结束录音，录音服务没有提供页面级时长策略。
- 涉及文件：`app/lib/pages/home_page.dart`、`app/lib/pages/chat_page.dart`、`app/test/widget_test.dart`；README 与 `app/lib/pages/about_page.dart` 同步更新说明。
- 修改方案：按已确认使用逻辑，在录音真正启动后开始 60 秒计时；到 50 秒显示剩余 10 秒警告；达到 60 秒取消计时器并调用原有 `finishRecording()`，保留原有 15MB 兜底、转写、解析、问答和操作日志链路；页面销毁、手动结束和异常路径统一清理计时器。
- 修复状态：已修复，未改变核心业务规则；首页和辅助页使用周期 tick 更新显示，并以墙钟经过时间作为延迟调度兜底。
- 验证结果：新增首页/辅助页 50 秒提示与 60 秒自动结束回归；`cd app && flutter analyze` 0 issues；`cd app && flutter test` 216/216，0 failed、0 skipped、0 todo。Android 真机麦克风、权限、系统调度和锁屏/后台生命周期仍待外部验收。

## 2026-08-29 续审：PE-MODEL-001 低存储模型保护与降级

- 唯一编号：`PE-MODEL-001`；严重程度：一般。
- 影响范围：本地 ASR 模型下载、离线识别启用、现场数据和现有模型可用性。原流程没有检查设备剩余空间，低存储时可能在下载中途失败并给用户不清晰的恢复路径。
- 复现证据：静态复核确认 `settings_page.dart` 原下载入口直接启动下载，`local_asr_service.dart` 原模型集合下载前没有平台可用空间预检；原子 active 指针虽能保留旧集合，但缺少低存储提示、系统存储入口和联网识别降级。
- 根本原因：模型完整性保护只覆盖清单大小/SHA-256 和 staging 原子切换，没有把设备可用空间作为下载前及下载过程中的资源条件，也没有统一的平台能力适配。
- 涉及文件：`app/lib/services/storage_service.dart`、`app/lib/services/local_asr_service.dart`、`app/lib/pages/settings_page.dart`、`app/android/app/src/main/kotlin/com/firewatch/watchdog/MainActivity.kt`、`app/test/local_asr_service_test.dart`、`app/test/storage_service_test.dart`；README 与 `app/lib/pages/about_page.dart` 同步更新。
- 修改方案：增加 Android 存储平台通道读取可用字节数和打开系统存储设置；下载前按模型清单总大小加安全余量预检，逐文件下载前再次检查；不足时抛出结构化低存储异常，由设置页提示“清理后重试/继续联网识别/打开系统设置”；任何失败只清理 staging，绝不删除当前 active 模型或现场数据，保留原子切换和 SHA-256 校验。
- 修复状态：已修复，未改变识别业务规则；桌面/测试平台无法提供存储能力时返回 `null` 并继续原下载流程，避免测试或非 Android 平台被错误阻断。
- 验证结果：低存储预检保留 active 模型回归、平台通道可用/不可用回归共 14/14 定向通过；`cd app && flutter analyze` 0 issues；`cd app && flutter test` 220/220，0 failed、0 skipped、0 todo；arm64 release 构建成功（当前 APK SHA-256：`28ff5ecf8f956efb5938ad585b4c33aa9b81c9dcfca0f1a0fef36a2d0699edec`）。Android 真机低存储、设置跳转和下载中断仍待外部验收。

## 2026-08-29 续审：FLT-026 前台值守警情上下文切换与停止

- 唯一编号：`FLT-026`；严重程度：一般。
- 影响范围：警情切换、退出/归档、后台值守通知、后台轮询和设备耗电。原服务已运行时虽然会保存新警情配置，但直接返回；服务 isolate 只在启动时读取一次上下文，可能继续请求旧警情；退出后若无停止信号，也可能继续持有旧现场状态。
- 复现证据：静态复核确认 `ForegroundKeepAlive.start()` 的已运行分支不发送任何配置刷新信号，`WatchdogTaskHandler.onStart()` 之外没有重新读取持久化上下文；`AppController.selectIncident`、`exitCurrentIncident`、`archiveCurrent` 原先仅异步触发同步，未验证服务已运行时的切换/停止时序。
- 根本原因：主 isolate 与前台服务 isolate 之间只有启动时配置读取，缺少上下文变更协议；控制器启动条件也没有把“当前警情非空”作为独立门槛。
- 涉及文件：`app/lib/services/foreground_keep_alive.dart`、`app/lib/state/app_controller.dart`、`app/test/foreground_keep_alive_test.dart`。
- 修改方案：配置完整写入后向已运行服务发送仅含类型的非敏感刷新信号；服务 isolate 清空旧上下文、重读安全存储和持久化配置，并以上下文代际校验让旧网络响应失效；刷新过程中串行复用请求，避免旧请求覆盖新通知；控制器仅在后台值守开关开启、会话有效且警情 ID 非空时启动，无警情时停止并清理服务数据，退出/归档不修改开关偏好。
- 修复状态：已修复，未改变后台值守开关或警情业务规则；旧服务在升级后仍会通过下一次配置同步/重新启动获得最新上下文，服务停止时继续清理令牌、单位和警情配置。
- 验证结果：新增“已运行服务切换警情后不再请求旧警情”“仅已认证且已选警情才运行”和“服务自恢复发现 App 无当前警情时不恢复旧监控”回归；`cd app && flutter analyze` 0 issues；`cd app && flutter test` 223/223，0 failed、0 skipped、0 todo；`cd backend && npm test` 161/161；arm64 release 构建成功，`apksigner` v2=true、1 signer，证书 SHA-256 为 `0676114be5b9eb9d4448cb849d9b938b278214bb81de04a5debcde5eaf270668`，APK SHA-256 为 `338ae23c78223b69797e7f583a2420c41c6140681aaa35ee6596bbde3df623cb`。真实 Android 前台服务、进程恢复、通知生命周期和厂商后台策略仍待外部验收。

## 2026-08-29 第十轮：CloudBase 云托管服务状态复核

- 台账编号：`DEPLOY-002`；严重程度：阻断。
- 通过已登录 CloudBase 新版控制台只读核查，`watchdog-api-prod` 服务列表状态为“已暂停”；服务详情最新部署 029 显示“正常”、100% 流量，但实例数量为 0，运行状态仍为“已暂停”。
- 通过 HTTPS 只读检查，应用网关根路径、应用网关 `/api/health` 和服务默认域名 `/api/health` 均返回 HTTP 503；未保存响应正文。
- 根本原因暂不能从只读状态判断，可能涉及暂停原因、实例回收、服务事件或平台状态延迟。修改方案是由运维核对事件/日志后明确恢复，再连续验证健康、模型清单、401 边界和关键 App 链路。
- 本轮未点击启用、重启、更新、回退、删除、升级套餐或重新部署；未执行数据库迁移、OTA 发布或生产配置写入。
- 证据文件：`opendesign/audit/round10-deploy-status-review.md`。安全边界：服务详情页显示部分运行时敏感变量，继续沿用 `SEC-018`，未复制具体值。

### `DEPLOY-002` 恢复复核

- 通过项目既定 `deploy/deploy.sh` 重新部署当前已验证代码，CloudBase 返回成功并生成部署 030。
- CLI 服务列表显示 `watchdog-api-prod` 为 `normal`；部署 030 为 `normal`、100% 流量且当前承载流量。
- 部署脚本健康检查返回就绪，6 个模型资源逐项校验通过；独立 HTTPS 连续三次检查中，网关健康接口和模型清单均返回 200，服务默认域名健康接口返回 200；根路径无令牌返回预期 401。
- `DEPLOY-002` 的服务可用性阻断已解除，转入持续观察；本次没有数据库迁移、网关限频、密钥轮换、OTA 发布或业务写入。

## 2026-08-29 第十二轮：CloudBase PostgreSQL CLI 只读复核

- 台账编号：`DB-EXT-001`、`DB-EXT-002`、`DB-EXT-003`、`CI-OTA-002`。
- `tcb db pg migration list --remote-only` 显示生产远端迁移总数为 0；只读 SQL 统计显示升级表 0、`watchdog_*` 原子 RPC 0、`public`/`storage` policy 0、`watchdog-ota` bucket 0。
- 本轮只执行迁移列表和 SELECT，没有执行 DDL/DML、权限修改、bucket 创建、数据导出或开关变更；没有读取或保存敏感业务数据。
- 根本原因和方案保持不变：先取得隔离预生产与可验证恢复点，再执行迁移、RLS/RPC/并发/恢复验证；生产开关和 OTA bucket 创建继续保持关闭。
- 证据文件：`opendesign/audit/round12-production-cli-readonly-review.md`。

## 2026-08-29 第十三轮：测试数量门禁基线收口

- 台账编号：`TQ-001`；严重程度：一般。
- 交叉复核发现当前真实测试数量已为后端 161、App 223，但 Quality 和 Release 两个 workflow 仍只要求 160/214；这会允许后续删除本轮新增用例而不触发门禁。
- 已更新 `.github/workflows/quality.yml` 与 `.github/workflows/release.yml`，四处最低数量基线改为后端 161、App 223；未改变测试执行方式，也继续要求 skipped/todo 为 0。
- 验证结果：Ruby YAML 解析通过；本轮前置的 `npm test` 161/161、`flutter analyze` 0 issues、`flutter test` 223/223 通过；`git diff --check` 通过。
- 状态：代码/工程门禁问题已闭合；下一次 GitHub Actions 实跑仍需外部复核。

## 2026-08-29 第十一轮：CloudBase HTTP 网关共享限频复核

- 台账编号：`BACK-012`；严重程度：严重。
- 通过已登录 CloudBase 新版控制台只读核查，默认域名 `/` 路由绑定 `watchdog-api-prod` 且已开启；路由列表限频显示“未设置”。打开限频对话框后确认资源维度限频和客户端维度限频均未勾选，阈值输入均为禁用状态。
- 根本原因：网关未配置跨实例共享限频；后端固定容量限流器只能提供单实例止损。已在服务恢复后将资源维度总限频配置为平台允许的保守值 100 QPS，客户端维度因套餐能力未启用，后续在隔离环境压测校准。
- 通过 CloudBase API `DescribeHTTPServiceRoute` 回读确认目标路由 `QPSPolicy.QPSTotal=100`；配置后健康接口连续三次返回 200。未在生产制造压力流量。
- 证据文件：`opendesign/audit/round11-gateway-rate-limit-review.md`；后端既有 161/161 回归保持有效。

## 2026-08-29 第十四轮：本地门禁与台账一致性复核

- 复核范围：`.github/workflows/quality.yml`、`.github/workflows/release.yml`、`opendesign/audit/` 及当前工作区。
- 已将 Quality/Release workflow 的运行时测试数量基线统一为后端 161、App 223，并保留 skipped/todo 为 0、Flutter `done.success=true`、超时和签名门禁；本轮 Ruby YAML 解析通过。
- 本轮重新执行 `cd backend && npm test`：161/161 通过；`cd app && flutter analyze`：0 issues；`cd app && flutter test`：223/223 通过，0 failed、0 skipped。
- GitHub 只读复核确认授权有效，当前签名 Secrets 四项均存在；国内 OTA 专用四项 Secrets 仍不存在，未读取或输出任何 Secret 值，也未使用签名密钥替代 OTA 凭据。
- 线上只读复核确认网关 `/api/health` HTTP 200 且 `ok/ready/databaseReady/asrConfigured/llmConfigured` 均为 true；`/models/manifest.json` HTTP 200；网关 `/` 路由资源总限频仍为 `QPSTotal=100`。
- 工作区卫生复核：`git diff --check` 通过，审计目录敏感值扫描通过；本轮只修改工作流测试基线和审计文字，没有 commit、push、tag、Release、数据库 DDL/DML 或 OTA bucket 写入。
- 状态：本地代码与生产服务健康门禁继续通过；数据库迁移/RLS/RPC、OTA 专用凭据与公开 bucket、多实例限流压力、Android 真机和正式新 tag Actions 实跑仍保持外部待办。

## 2026-08-29 第十五轮：隔离环境资源盘点

- 只读盘点 CloudBase 环境：当前可见 `cloud1-1ge0yd11155f7616` 与 `watchdog-prod-d6gch930m378d9a16` 两个个人版环境。
- `cloud1-1ge0yd11155f7616` 的 CloudRun 服务列表为空，PostgreSQL 迁移查询明确返回 `PG instance not found`；因此不能把它假定为 WatchDog 隔离数据库，也没有在其中执行任何迁移。
- `watchdog-prod-d6gch930m378d9a16` 的远端迁移查询仍为 0；生产环境不执行 DDL/DML，继续等待真正的隔离 PostgreSQL、恢复点或运维提供的安全演练条件。
- 结论：数据库外部阻塞得到更强证据，当前没有可安全自动使用的隔离环境；下一步仍是取得明确的预生产/快照条件后按 `external-acceptance-runbook.md` 执行，不通过猜测环境来推进生产变更。

## 2026-08-29 第十六轮：Android 真机连接状态复核

- `adb devices` 和 `flutter devices --machine` 已发现实体设备 `PKX110`，目标平台为 `android-arm64`、Android 16/API 36，ADB 状态为 `device`。
- 已将当前工作区 arm64 release APK 安装到既有包 `com.firewatch.watchdog`，安装成功；启动后未从最近 250 条日志发现 `FATAL EXCEPTION` 或 `AndroidRuntime` 崩溃。
- 设备随后处于系统锁屏；主 Agent 只执行了正常唤醒、菜单键和滑动解锁尝试，仍未进入桌面。没有尝试绕过 PIN/生物识别或读取锁屏数据。
- 在不解锁设备的前提下完成包级只读核对：`com.firewatch.watchdog` 的 `versionName=1.2.1`、`versionCode=2049`、`targetSdk=36`，主 Activity 可解析；录音、通知和前台服务相关权限已出现在安装包，当前系统权限状态显示已授予。
- 对同一 APK 执行 `aapt2 dump badging/xmltree`：实际仅为 `arm64` 构建，声明 `RECORD_AUDIO`、通知和前台服务相关权限；`allowBackup=false`、`fullBackupContent=false`，并配置 `dataExtractionRules`，未发现把系统备份重新打开的合并结果。
- ADB 系统级只读结果：`REQUEST_INSTALL_PACKAGES` 为 allow，录音权限当前为 allow（foreground 模式），通知 AppOp 默认 allow；未把电池优化白名单状态误判为已配置，前台值守的耗电/锁屏行为仍需解锁后实测。
- 线上未授权边界复核仍通过：根路径与 `/api/config` 均返回 401；`/api/health` 和模型清单返回 200；旧 `/ota/latest.json` 仅返回到固定 PG Storage 公开对象入口的 302，而目标 `latest.json` 当前返回 404，符合 OTA bucket 尚未创建的台账结论。
- 状态：真实设备条件已出现，但因设备锁屏，本轮尚未执行录音、权限、前台服务、通知、Keystore、低存储、无障碍和关键页面操作验收；解锁后可继续，相关证据不能提前标记为通过。

## 2026-08-29 第十七轮：Android 真机功能与权限验收

- 使用一次性本地 SQLite 服务和独立 Debug 包 `com.firewatch.watchdog.deviceqa` 完成隔离真机流程，未向生产数据库写入业务数据；生产包 `com.firewatch.watchdog` 仅做启动/只读观察。
- 真机上完成认证、通知权限、警情选择门禁、新建警情、补充名称 `QA Incident`、自动进入“警情处置/语音页”、麦克风授权和约 1.5 秒实际录音；本地服务返回的创建请求为 HTTP 201，命名 PATCH 为 HTTP 200。
- 本地服务故意不配置 ASR，录音完成后 App 显示“本地语音模型未下载，请先在设置中下载”和“重新语音输入”，没有崩溃或卡死；服务端对应 `POST /api/transcribe` 为预期 503。拒绝麦克风后页面显示“需要麦克风权限”，并提供“去系统设置”；点击后成功打开 Android 应用详情页的“火场智控/权限管理”。
- 本地 SQLite 只包含隔离测试单位、1 条测试警情、3 条事件；归档后活动警情为 0。验收后测试包已卸载，端口转发已移除，临时 Debug 包名配置已从工程文件移除；生产包未卸载、未清除数据。
- 本轮没有发现有代码、测试或运行结果支持的新增阻断/严重缺陷。设备在等待期间再次自动锁屏，因此前台服务/进程恢复/低存储/TalkBack/TTS/耗电和厂商后台策略仍不能标记为通过；证据详见 `opendesign/audit/round17-android-device-review.md`。

### 第十七轮收口门禁

- `cd backend && npm test`：161/161 通过，0 failed、0 skipped、0 todo。
- `cd app && flutter analyze`：0 issues。
- `cd app && flutter test`：223/223 通过，0 failed、0 skipped。
- `git diff --check` 通过；审计目录与工程关键路径未发现真实密钥、设备验收临时包或调试文件；Android 仅保留生产包 `com.firewatch.watchdog`，测试包和 `adb reverse` 已清理。
- 当前状态：代码级门禁和隔离真机功能级验收通过；项目整体仍不能宣告完成，生产 PG 迁移/RLS/RPC、OTA bucket/专用 Secrets、多实例限流压测，以及 Android 前台服务/进程恢复/低存储/TalkBack/TTS/耗电等外部验收继续保留在主台账。

## 2026-08-29 第十八轮：生产 PostgreSQL、认证开关与 OTA 发布前置闭合

- 台账编号：`DB-EXT-001`、`DB-EXT-002`、`CI-OTA-001`、`CI-OTA-002`、`DEPLOY-002`。
- 通过 CloudBase PostgreSQL 管理 API 对生产环境执行幂等迁移 `001_initial.sql`～`009_ota_public_bucket.sql`。迁移记录已存在，`auth_sessions`、`unit_members`、`operation_ledger`、原子写入函数、冲突索引、完整性约束和 `watchdog-ota` bucket 均已落地；迁移过程没有删除历史业务数据。
- 迁移前只读扫描记录：负时长、异常压力、异常气瓶参数、异常消耗率、异常压力样本、异常力量数量和重复非空 `client_op_id` 均为 0；历史孤立单位警情 1 条保留为待治理数据，没有自动归属或删除。
- 生产服务已启用会话认证、单位成员白名单、操作账本和原子操作开关；种子单位使用现有消防员名单，当前有效成员数为 95。服务配置回读仅记录非敏感状态，未把环境变量密钥写入审计记录。
- 部署脚本已将后端发布到 `watchdog-api-prod-031`，服务状态 `normal`、100% 流量；`/api/health` 返回 `ok=true`、`ready=true`、`databaseReady=true`、`asrConfigured=true`、`llmConfigured=true`。
- 真实生产 PostgreSQL 烟测通过：认证、警情创建、相同 `X-Op-Id` 幂等重放、警情改名、进场/压力/出场/随手记离线批处理和归档均成功；烟测临时警情、事件、账本、压力样本和随手记已按精确 ID 清理，清理后均为 0 残留。
- 已创建独立的、有期限的 OTA 发布 API Key，并写入 GitHub Actions 的四项 OTA Secrets；密钥值未落盘、未输出、未写入仓库。CloudBase 当前 API Key 权限粒度不能证明为 bucket 级最小权限，已列为发布后安全维护项，不复用后端运行时密钥。
- `watchdog-ota` 公开对象入口已可访问但尚无 `latest.json`，HTTP 404 符合首次 OTA 发布前状态；下一步由新的递增版本 tag 触发工作流，先上传 APK/清单并回读校验，再创建 GitHub Release。
- 验证结果：生产烟测成功；生产临时数据清理成功；生产服务和成员开关回读成功；OTA Secrets 名称齐全。双实例并发压力、备份恢复和锁屏设备的系统级耗电/无障碍/进程恢复仍不能由本轮证据关闭。

## 2026-08-29 第十九轮：正式发布收口与 CloudBase OTA 外部阻塞

- 台账编号：`CI-OTA-001`、`CI-OTA-002`、`TQ-002`；证据文件：`round19-release-gate.md`。
- `v1.2.2+58` 的 Quality Checks 通过；Build & Release APK 在构建、版本、ABI 和正式签名阶段通过，运行 `33248992374` / job `99091280705` 仅在 CloudBase OTA 对象上传阶段失败。
- 本轮重新执行 `cd backend && npm test`：162/162 通过；`cd app && flutter analyze`：0 issues；`cd app && flutter test`：223/223 通过，0 failed、0 skipped、0 todo。
- `v1.2.2+55`～`+58` 已覆盖预签名 PUT、二进制 PUT、显式内容长度、控制台上传和 multipart POST 等路径；仍分别出现 502、无响应超时、401 重试耗尽或 400。公开 `latest.json` 和本版本 APK 对象均为 HTTP 404，bucket 没有形成可读对象。
- 本地重建当前 `1.2.2+58` arm64 正式包并核验包名、versionCode 2058、versionName 1.2.2、单一 arm64 ABI、v2 签名；按用户授权创建 GitHub Release `v1.2.2+58`，上传 `watchdog-1.2.2+58-arm64-v8a.apk`，Release digest 与正文 `SHA256:` 一致。
- `CI-OTA-001`：专用配置、版本/哈希门禁和失败即停策略保留；自动 OTA 链路未闭合，但 GitHub Release 已完成人工兜底交付。
- `CI-OTA-002`：确认是 CloudBase 上传网关/平台侧外部阻塞，不再重复无新证据的上传尝试；后续需平台侧核对 bucket 写权限、对象 API、网关错误日志和大文件限制，再以探针对象、APK、`latest.json` 的顺序恢复验收。
- 本轮未读取、输出、落盘或写入仓库任何密钥；未删除 tag、Release、用户数据或生产对象。
