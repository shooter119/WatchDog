# WatchDog 安全与隐私只读审查

## 1. 审查信息

- 审查角色：安全与隐私组
- 审查日期：2026-08-27
- 审查范围：项目内全部源码、配置、脚本、测试、GitHub Actions 工作流、部署文档和 Git 跟踪文件；同时检查当前工作区中被忽略的密钥/临时文件是否存在。
- 操作边界：只读审查。除本报告外未修改源码、配置、测试、部署文件，也未调用生产写接口、删除数据、commit、push 或发版。
- 证据分级：
  - 真实漏洞：代码路径已经形成可利用或可破坏完整性/可用性的行为。
  - 风险假设：需要攻击者具备特定条件，或依赖部署配置/威胁模型。
  - 未验证项：当前环境无法访问生产状态、真实运行时密钥或外部服务，不能据此宣称已发生。

## 2. 总体结论

当前版本不能通过安全与隐私验收。代码、测试和静态配置已证实存在共享凭证冒用、认证 fail-open、审计日志可清空、历史未归属警情跨单位可见等高优先级问题；另有生产配置、CI 供应链、模型完整性和外部服务密钥投递等需在修复后验证的高风险项。

本轮没有修复任何问题，所有条目的状态均明确标为未修复或待生产验证，符合只读要求。

| 编号 | 结论性质 | 严重程度 | 状态 |
|---|---|---|---|
| SEC-001 | 真实漏洞 | 严重 | 未修复 |
| SEC-002 | 真实 fail-open 逻辑；生产是否触发未验证 | 严重 | 未修复 |
| SEC-003 | 真实漏洞 | 严重 | 未修复 |
| SEC-004 | 真实租户边界漏洞；影响取决于历史数据 | 严重 | 未修复 |
| SEC-005 | 真实审计完整性漏洞 | 严重 | 未修复 |
| SEC-006 | 风险假设；生产种子配置未验证 | 严重 | 未修复 |
| SEC-007 | 真实隐私/日志暴露 | 一般 | 未修复 |
| SEC-008 | 真实资源控制缺口；DoS 规模未验证 | 一般 | 未修复 |
| SEC-009 | 风险假设；运行时 URL 配置未验证 | 严重 | 未修复 |
| SEC-010 | 风险假设；Android 明文拦截行为未验证 | 一般 | 未修复 |
| SEC-011 | 真实本地明文存储风险 | 一般 | 未修复 |
| SEC-012 | 真实隐私设计风险；不是认证机制 | 一般 | 未修复 |
| SEC-013 | 风险假设；模型供应链完整性未验证 | 一般 | 未修复 |
| SEC-014 | 风险假设；CI 上游供应链未验证 | 严重 | 未修复 |
| SEC-015 | 风险假设；生产数据库驱动未验证 | 严重 | 未修复 |
| SEC-016 | 防御纵深缺口 | 优化 | 未修复 |
| SEC-017 | 本机密钥/临时文件权限与仓库规则风险 | 一般 | 未修复 |

## 3. 问题台账

### SEC-001：App 内置可预测共享 API 令牌

- 结论性质：真实漏洞；本机环境还观察到同值配置，但报告不记录令牌值。
- 严重程度：严重。
- 影响范围：所有依赖 X-Api-Token 的后端业务接口。攻击者得到 APK、源码或一台新安装设备后，可取得客户端默认令牌；若某环境沿用该默认值，整个共享 API 认证边界失效。
- 复现/证据：
  1. 清空 App 设置后读取 apiToken，app/lib/services/settings.dart:150-153 返回源码内置的开发令牌默认值。
  2. app/lib/api/api_client.dart:54-65 会把该值放入 X-Api-Token。
  3. backend/src/server.js:74-80 只做共享字符串比较。
  4. 对当前 backend/.env 仅输出键名和设置状态的扫描显示 API_TOKEN 已设置；安全比较显示其与 App fallback 相同，但未输出值。backend/.env 未被 Git 跟踪。
- 根本原因：把认证凭证作为客户端 fallback 发布，且没有按安装实例/用户进行安全注入和轮换。
- 涉及文件：app/lib/services/settings.dart:150-157；app/lib/api/api_client.dart:54-65；backend/src/server.js:74-80；backend/.env。
- 修改方案：删除客户端硬编码凭证；服务端使用高熵、轮换的服务端凭证；客户端通过安全注册或受控配置取得短期凭证，并迁移到 Keystore-backed secure storage；立即轮换任何曾与默认值相同的运行时令牌。
- 修复状态：未修复（只读审查）。
- 验证结果：backend/test/token.e2e.test.js:9-59 只验证“配置了正确令牌时”的行为，未覆盖新安装 fallback 与运行时令牌相同的否定场景。

### SEC-002：缺少 API_TOKEN 时认证静默放行

- 结论性质：真实 fail-open 逻辑；生产是否触发属于未验证项。
- 严重程度：严重。
- 影响范围：后端全部非 health API；若生产运行时漏配 API_TOKEN，业务接口没有 API 令牌保护。WATCHDOG_UNIT_AUTH_REQUIRED 也可由配置显式设置为关闭。
- 复现/证据：backend/src/server.js:21 将缺失 API_TOKEN 变为空串；backend/src/server.js:74-80 在 API_TOKEN 为空时直接 next；backend/src/server.js:22-24 将非测试环境的单位认证默认打开，但接受 WATCHDOG_UNIT_AUTH_REQUIRED=0。Dockerfile 只设置 NODE_ENV 和 PORT，backend/Dockerfile:11-12，没有启动时必需配置断言。
- 根本原因：把“本地开发便利”作为生产默认行为，缺少按环境 fail-closed 的启动检查。
- 涉及文件：backend/src/server.js:21-24,74-80；backend/Dockerfile:11-12；backend/test/token.e2e.test.js:8-63。
- 修改方案：生产环境启动时强制要求高熵 API_TOKEN、单位认证和数据库驱动；缺失或显式关闭时拒绝启动；只在隔离的 test/local profile 允许关闭。
- 修复状态：未修复。
- 验证结果：现有 e2e 仅注入测试令牌占位值验证 401/200，没有 API_TOKEN 缺失时生产配置必须失败的测试；生产环境变量未访问验证。

### SEC-003：单位认证后没有身份绑定，操作者和设备标识可冒用

- 结论性质：真实漏洞。
- 严重程度：严重。
- 影响范围：实名、操作日志、现场随手记、事件和管理操作的归属可信度；拥有共享单位凭证的任意客户端可伪造另一名操作者。
- 复现/证据：
  1. backend/src/server.js:98-113 仅接受请求方提交的 X-Unit-Id 和 X-Unit-Code，成功后把单位写入 req.unit，没有签发用户会话或身份凭证。
  2. backend/src/server.js:146-151 优先信任 body.actor_name、X-Actor-Name 或 X-Actor-Name-B64，再退回设备档案。
  3. backend/src/server.js:245-262 的认证接口接受 body.real_name，并按请求方提供的 X-Device-Id 保存。
  4. app/lib/api/api_client.dart:54-65 会发送单位、设备和操作者头；这些头均可被客户端改写。
  5. backend/src/server.js:1149-1167 直接接受 body.author；backend/src/server.js:1235-1267 又允许客户端以 X-Device-Id 覆盖实名设置。
- 根本原因：共享 API/单位码充当唯一访问门槛，X-Device-Id、actor_name 和 real_name 被当成身份而非不可信输入。
- 涉及文件：backend/src/server.js:98-113,146-151,245-262,1149-1167,1235-1267；app/lib/api/api_client.dart:54-65；backend/migrations/001_initial.sql:131-135。
- 修改方案：单位验证码只用于一次注册；服务端签发绑定用户、单位、设备和角色的短期会话/访问令牌；所有 actor/author 从服务端会话取值，不接受 body/header 覆盖；将管理操作改为显式 RBAC，并让设备 ID 仅作关联字段而非认证因素。
- 修复状态：未修复。
- 验证结果：现有测试覆盖单位码正确/错误和中文操作者头，但没有“同一凭证伪造不同 actor/author”的拒绝用例。

### SEC-004：历史 unit_id=NULL 警情对所有已认证单位可见

- 结论性质：真实租户边界漏洞；实际数据影响取决于生产是否已有 unit_id 为空的历史记录。
- 严重程度：严重。
- 影响范围：警情列表及按警情 ID 读取的 entries、notes、timeline、forces、logs 等现场数据，可能跨单位暴露。
- 复现/证据：backend/src/server.js:123-129 只有在 incident.unit_id 存在且不等于当前单位时拒绝；unit_id=NULL 会通过。backend/src/db-sqlite.js:652-668 使用 unit_id = ? OR unit_id IS NULL；backend/src/db-postgres.js:320-329 对 unit_id 为空的行同样保留。backend/migrations/002_units.sql:1-13 明确选择让历史警情保持 NULL。攻击路径是用单位 A/B 各自通过认证后，用同一旧警情 ID 请求资源，两者均不应得到该数据但当前逻辑会通过。
- 根本原因：为了兼容旧数据，把“未归属”错误地当成“所有租户可见”，而不是隔离/待归属状态。
- 涉及文件：backend/src/server.js:123-129；backend/src/db-sqlite.js:627,652-668；backend/src/db-postgres.js:320-329；backend/migrations/002_units.sql:1-13。
- 修改方案：先做只读盘点和人工归属/隔离；租户接口禁止 NULL 记录跨单位读取；必要时将旧数据迁入明确的隔离租户或仅管理员可见；完成回填后将 unit_id 设为 NOT NULL，并添加跨单位回归测试。
- 修复状态：未修复。
- 验证结果：backend/test/api.test.js:118-132 只验证不同警情场景隔离，没有单位 A/B 访问 legacy NULL 警情的测试；未查询生产数据。

### SEC-005：操作日志可被普通单位成员清空/伪造，审计链不可信

- 结论性质：真实审计完整性漏洞。
- 严重程度：严重。
- 影响范围：事故复盘、责任追踪和取证；任何满足当前警情要求的调用方都可删除本警情全部日志，也可提交任意 stage、msg、data、device 和 op_id。
- 复现/证据：
  - backend/src/server.js:1274-1304 的 POST /api/logs 只调用 requireIncident，没有 management 角色检查，并接受客户端日志内容和设备值。
  - backend/src/server.js:1310-1332 的 GET/DELETE /api/logs 同样只调用 requireIncident；DELETE 会调用 db.clearLogs。
  - backend/src/server.js:153-169 已存在 management 参数，但日志路由没有使用它。
  - backend/test/logs.test.js:104-109 明确验证普通测试头可以 DELETE 并清空当前警情日志。
  - backend/src/server.js:1081-1120 的全局消防员/热词删除接口也没有管理角色边界。
- 根本原因：调试接口已经部署到业务服务，缺少 RBAC、不可变审计存储和删除审批。
- 涉及文件：backend/src/server.js:153-169,1274-1332；backend/test/logs.test.js:104-109。
- 修改方案：将日志查询按角色和最小范围授权；禁止客户端指定审计操作者和设备；核心审计事件由服务端生成并追加写入不可变存储；删除改为管理员审批/保留期清理并记录删除事件；将调试接口移出生产路由。
- 修复状态：未修复。
- 验证结果：现有测试反向证明 DELETE 当前被允许；没有非管理用户 403、日志防篡改和删除留痕测试。

### SEC-006：单位验证码无限尝试，且代码库存在公开测试种子

- 结论性质：风险假设；若生产沿用测试种子则可直接降低认证强度，生产配置未验证。
- 严重程度：严重。
- 影响范围：单位认证接口和后续所有单位级数据；攻击者可以自动化猜测低熵验证码。
- 复现/证据：backend/src/server.js:245-262 的 /api/auth/verify 没有按 IP、设备、单位或时间窗限制失败次数。backend/src/db-postgres.js:20-25、backend/migrations/002_units.sql:23-26 和 backend/.env.example:46-49 提供了默认测试单位/四位验证码。backend/test/api.test.js:56-84 只有一次错误尝试和一次成功尝试，没有限流或锁定断言。
- 根本原因：测试阶段种子和生产初始化路径共用，验证码明文存储且没有抗暴力破解控制。
- 涉及文件：backend/src/server.js:245-262；backend/src/db-postgres.js:20-25；backend/src/db-sqlite.js:20-25；backend/migrations/002_units.sql:23-26；backend/.env.example:46-49。
- 修改方案：生产禁止默认种子和默认值；使用每单位高熵一次性/可轮换秘密，数据库只保存哈希；对认证失败做 IP+设备+单位组合限流、退避、锁定和告警；增加生产配置检查。
- 修复状态：未修复。
- 验证结果：未对生产认证接口做尝试；报告不写入验证码值。

### SEC-007：语音文本、名单和异常上下文写入日志并向宽权限接口返回

- 结论性质：真实隐私/日志暴露。
- 严重程度：一般。
- 影响范围：语音转写、消防员/热词名单、现场笔记、压力/事件上下文、异常堆栈和上游错误响应；这些信息可能落入服务 stdout、数据库操作日志、App 本地日志和诊断上报。
- 复现/证据：
  - backend/src/server.js:663-677 将 ASR 文本写入 asr_done/transcribe_resp。
  - backend/src/server.js:686-706 将完整 parse text、名单和热词写入日志。
  - backend/src/server.js:1160-1170 在事件 payload 保存完整笔记文本，并在日志中保存文本前缀。
  - backend/src/server.js:1314-1320 将 data 原样从日志查询返回。
  - backend/src/server.js:1334-1340 记录 err.stack/err.message；backend/src/parse.js:42-65,231-250,257-278,319-347 会把上游响应体片段放进错误信息。
  - app/lib/services/diagnostic_log_service.dart:143-178,181-228 保存 error、stack、context、breadcrumbs 并可上传；app/lib/services/diagnostic_log_service.dart:308-317 只对少量 key=value 形式做正则脱敏。
- 根本原因：业务内容、审计事件和诊断日志共用数据通道，默认采集过多，且查询没有管理范围限制。
- 涉及文件：backend/src/server.js；backend/src/parse.js；backend/src/logger.js:3-17；app/lib/services/diagnostic_log_service.dart。
- 修改方案：默认不记录原始语音文本、完整笔记和名单；将审计字段与技术日志分离；服务端统一结构化脱敏并限制上游错误体；日志接口按角色授权、短保留期和加密存储；诊断上报采用 allowlist 字段而非通用上下文。
- 修复状态：未修复。
- 验证结果：静态证据确认存在原文写入；未读取或导出任何生产日志。

### SEC-008：转写/解析资源限制和问答限流不足

- 结论性质：真实资源控制缺口；实际 DoS/费用规模未验证。
- 严重程度：一般。
- 影响范围：ASR/LLM 费用、CPU、内存和服务可用性；可影响单实例后端。
- 复现/证据：backend/src/server.js:637-684 对每个转写请求在内存累计最多 15MB 音频，没有 IP、令牌、设备并发上限；backend/src/asr.js:181-197 先把所有压缩音频 frames 累积后发送。/api/parse 在 backend/src/server.js:686-709 没有独立频率限制。/api/chat 的计数器位于 backend/src/server.js:768-801，使用可伪造的 X-Device-Id 作为 key，chatRateBuckets 对新 key 没有淘汰机制。
- 根本原因：限流仅按客户端自报设备 ID，且只覆盖 chat；音频处理采用全量缓冲。
- 涉及文件：backend/src/server.js:637-709,768-801；backend/src/asr.js:181-197。
- 修改方案：在网关和服务内增加按 IP/令牌/单位/设备的分层限流、并发 semaphore、超时和供应商预算；对原始请求校验 Content-Length 并采用流式/有界缓冲；为 rate bucket 做过期淘汰；补充压力和成本回归测试。
- 修复状态：未修复。
- 验证结果：现有测试只验证 chat 在固定测试设备下触发 429；未进行 transcribe/parse 负载测试，也未验证高基数设备头造成的内存增长。

### SEC-009：外部服务基础 URL 可投递机密，没有 HTTPS/主机白名单

- 结论性质：风险假设；需要运行时环境被误配或被有权修改，当前生产值未验证。
- 严重程度：严重。
- 影响范围：CloudBase service_role API key、DeepSeek API key 以及携带的现场数据可能被发送到错误或恶意端点。
- 复现/证据：backend/src/cloudbase-postgrest.js:44-80 使用 CLOUDBASE_REST_BASE_URL 或拼接值，并直接发送 Authorization: Bearer service_role key；未检查 URL scheme 或主机。backend/src/parse.js:42-60,231-245,257-275,319-344 对 DEEPSEEK_BASE_URL 采用同样模式。backend/.env.example:11,26 和 deploy/cloudbase/README.md:46-65 允许运行时配置这些地址。
- 根本原因：把可配置地址视为可信，而密钥投递逻辑没有强制 TLS 和目标约束。
- 涉及文件：backend/src/cloudbase-postgrest.js:44-80；backend/src/parse.js:42-60,231-245,257-275,319-344；backend/.env.example；deploy/cloudbase/README.md。
- 修改方案：启动时强制 https；对 CloudBase、DeepSeek 分别做精确主机白名单或显式受控代理；禁止生产任意自定义地址；密钥放入 Secret Manager，增加启动配置和出站目标审计。
- 修复状态：未修复。
- 验证结果：默认配置扫描到 HTTPS 地址；没有发现固定生产明文地址，但没有验证 CloudBase 运行时最终环境变量。

### SEC-010：App 服务器地址可任意修改，未限制 HTTPS/目标范围

- 结论性质：风险假设；仓库没有固定生产 HTTP 地址，Android 对明文流量的最终拦截行为未实机验证。
- 严重程度：一般。
- 影响范围：API token、单位码、设备标识、操作者信息和现场数据可能被发往用户输入的任意服务器；若平台允许 HTTP，还会产生明文传输。
- 复现/证据：app/lib/pages/settings_page.dart:1217-1243 显示服务器地址为可编辑输入且无 scheme/host validator；app/lib/services/settings.dart:119-134 原样保存；app/lib/api/api_client.dart:73 使用 Uri.parse 拼接，app/lib/api/api_client.dart:54-65 将认证/身份头附带到请求。
- 根本原因：默认地址是 HTTPS，但可编辑地址没有安全策略，且凭证未与目标绑定。
- 涉及文件：app/lib/pages/settings_page.dart:1217-1243；app/lib/services/settings.dart:119-134；app/lib/api/api_client.dart:54-73；app/android/app/src/main/AndroidManifest.xml:1-64。
- 修改方案：生产构建只允许固定 HTTPS 主机或受控 allowlist；自托管场景要求显式确认并校验 HTTPS、端口和证书策略；切换目标时清理/重新注册凭证；增加 HTTP 地址拒绝测试和真机验证。
- 修复状态：未修复。
- 验证结果：rg 扫描未发现生产默认 HTTP/WS 地址；测试中的 localhost/http 地址均为测试夹具，不能证明生产输入安全。

### SEC-011：API 令牌、单位码和现场内容在 App 本地明文保存

- 结论性质：真实本地明文存储风险；依赖设备被 root、备份、调试或本地取证。
- 严重程度：一般。
- 影响范围：API token、单位验证码、实名、辅助问答历史、操作日志、离线事件 payload 和诊断日志。
- 复现/证据：
  - app/lib/services/settings.dart:150-205 使用 SharedPreferences 保存 apiToken、realName、unitId、unitCode。
  - app/lib/services/foreground_keep_alive.dart:60-77 将 serverUrl、token、unitId、unitCode 写入前台服务数据，app/lib/services/foreground_keep_alive.dart:140-160 再读出。
  - app/lib/services/chat_history.dart:7-36 将问答原文保存到 SharedPreferences。
  - app/lib/services/op_log_service.dart:102-110,144-148 保存操作日志；app/lib/services/offline_queue.dart:16-50 在 SQLite payload 中保存离线操作；app/lib/services/diagnostic_log_service.dart:206-228 保存 JSONL 文件。
  - app/pubspec.yaml:9-27 未发现 secure storage 依赖；app/android/app/src/main/AndroidManifest.xml:17-64 未显式声明备份策略，具体系统行为需实机验证。
- 根本原因：敏感凭证与业务数据使用普通偏好存储/应用文件，没有统一加密、最小留存和清理策略。
- 涉及文件：上述 App settings、foreground、chat、op log、offline queue、diagnostic log 文件及 app/pubspec.yaml。
- 修改方案：令牌改用 Android Keystore-backed secure storage；对离线数据库和诊断文件加密或最小化；明确问答/日志保留期和退出单位时清理；评估 Android backup/data extraction 策略。
- 修复状态：未修复。
- 验证结果：静态确认数据写入路径；没有读取真实本地数据，也未做 root/备份取证测试。

### SEC-012：稳定设备指纹支持跨重装关联，且被错误地用于身份关联

- 结论性质：真实隐私设计风险；不是认证因素。
- 严重程度：一般。
- 影响范围：跨重装/长期设备可关联性、设备档案和操作日志中的追踪风险。
- 复现/证据：app/lib/services/op_log_service.dart:80-99 优先使用 Android ID；app/lib/services/op_log_service.dart:151-165 使用固定盐做 SHA-256；app/android/app/src/main/kotlin/com/firewatch/watchdog/MainActivity.kt:36-39 读取 Settings.Secure.ANDROID_ID；app/lib/api/api_client.dart:54-65 在请求中发送 X-Device-Id；backend/src/server.js:119-121,1235-1267 以该值访问档案/设置。
- 根本原因：稳定哈希被当作跨重装用户识别码，且未设置轮换、撤回和用途边界；哈希并不等于认证。
- 涉及文件：app/lib/services/op_log_service.dart；app/android/app/src/main/kotlin/com/firewatch/watchdog/MainActivity.kt；app/lib/api/api_client.dart；backend/src/server.js:119-121,1235-1267。
- 修改方案：默认使用每次安装随机、可撤回的 opaque ID；如需设备连续性则使用服务端注册凭证而非公开可计算哈希；告知用途并设置保留期、注销和轮换。
- 修复状态：未修复。
- 验证结果：静态确认固定盐和 Android ID 路径；未做跨设备/跨重装实机测试。

### SEC-013：端侧 ONNX ASR 模型下载没有校验和/签名

- 结论性质：风险假设；模型篡改到 native parser/资源耗尽的实际可利用性未验证。
- 严重程度：一般。
- 影响范围：语音识别完整性、启动稳定性和模型供应链；恶意模型可能导致错误识别、崩溃或资源消耗。
- 复现/证据：backend/src/server.js:58-62 将 /models 作为不需要业务令牌的公开静态目录；app/lib/services/local_asr_service.dart:78-103 下载模型；app/lib/services/local_asr_service.dart:117-163 只检查 HTTP 200，写入 .part 后直接 rename，没有大小、SHA-256、签名或版本清单校验；app/lib/services/local_asr_service.dart:228-275 随后把文件交给 sherpa-onnx。
- 根本原因：模型分发只依赖 TLS/路径，没有端到端完整性信任根。
- 涉及文件：backend/src/server.js:58-62；app/lib/services/local_asr_service.dart:78-163,228-275；deploy/models/。
- 修改方案：发布带签名的 manifest 和每文件 SHA-256/大小；App 内置公钥验签并拒绝缺失/不匹配项；限制最大尺寸、版本回滚和下载重试；模型完整性验证与 OTA APK 验证使用独立清单。
- 修复状态：未修复。
- 验证结果：未模拟篡改模型；对 OTA APK 发现已有 SHA-256、包名、版本号校验，但该保护没有覆盖 ASR 模型。

### SEC-014：CI 使用可变 Action tag，且 Gradle 正式包缺少密钥时回退 debug 签名

- 结论性质：风险假设；依赖上游 Action tag 被替换、标签权限或 CI 供应链受攻击。
- 严重程度：严重。
- 影响范围：正式 APK 供应链、签名私钥和 GitHub Release 发布权限。workflow 具有 contents: write 权限。
- 复现/证据：
  - .github/workflows/release.yml:9-17,21-30,105-113 使用 actions/checkout@v4、actions/setup-java@v4、subosito/flutter-action@v2、softprops/action-gh-release@v2 等可变 tag。
  - .github/workflows/release.yml:33-49 把签名 secret 写入工作区文件后构建。
  - app/android/app/build.gradle.kts:38-49 在 key.properties 不存在时静默使用 signingConfigs.debug。
  - .github/workflows/release.yml:58-76 事后比对 APK 与 keystore 指纹，能阻止错误包发布，但不能阻止恶意构建步骤读取 secret，也不能保护本地/其他流水线的 debug fallback。
- 根本原因：上游依赖未 pin 到不可变 commit，构建脚本 fail-open，发布凭证与构建权限集中在同一 job。
- 涉及文件：.github/workflows/release.yml；app/android/app/build.gradle.kts；app/android/.gitignore。
- 修改方案：所有 Action pin 完整 commit SHA；保护 v* tag 和 release 分支；拆分构建/签名/发布权限；release profile 缺少签名材料时直接失败；secret 写入后显式清理并增加 secret 非空校验。
- 修复状态：未修复。
- 验证结果：当前工作流静态检查逻辑包含签名指纹防呆；未访问 GitHub Actions 历史运行状态，不能宣称流水线已安全。

### SEC-015：生产数据库驱动缺失时静默回退 SQLite

- 结论性质：风险假设；生产 CloudBase 运行时环境未验证。
- 严重程度：严重。
- 影响范围：数据持久性、认证/单位状态和事故记录；CloudBase 配置漏项时服务可能启动在容器本地 SQLite，导致重启/扩容后数据不可见或丢失。
- 复现/证据：backend/src/db.js:1-7 在 WATCHDOG_DB_DRIVER 缺失或未知时默认 require('./db-sqlite')；backend/src/db-sqlite.js:6-9 把数据库放在本地 data 目录；backend/Dockerfile:11-12 只设置 NODE_ENV/PORT；deploy/cloudbase/README.md:43-50 才以文档方式要求设置 CloudBase 驱动和 service role key。
- 根本原因：生产启动没有对数据库驱动和连接密钥做 fail-closed 断言。
- 涉及文件：backend/src/db.js:1-7；backend/src/db-sqlite.js:6-18；backend/Dockerfile:11-16；deploy/cloudbase/README.md:43-50。
- 修改方案：NODE_ENV=production 时仅允许 cloudbase/postgres 驱动；缺少驱动、环境 ID、API key 或迁移状态时拒绝启动；把持久化/备份/恢复演练纳入部署验收。
- 修复状态：未修复。
- 验证结果：本地测试默认使用 SQLite 且通过；当前本机 .env 的驱动键已设置，但无法验证 CloudBase 线上实际变量和重启持久性。

### SEC-016：数据库启用 RLS 但没有租户策略，服务角色拥有全表 DML

- 结论性质：防御纵深缺口，不是已证明的直接越权。
- 严重程度：优化。
- 影响范围：一旦服务端凭证泄露、后台查询绕过应用层或新接口遗漏 unit/incident 过滤，数据库本身不会提供第二层租户隔离。
- 复现/证据：backend/migrations/001_initial.sql:151-166 对多张表启用 RLS，但没有 CREATE POLICY，并向 service_role 授予全表 SELECT/INSERT/UPDATE/DELETE；backend/src/cloudbase-postgrest.js:77-80 使用该 service_role 令牌访问数据库。
- 根本原因：所有授权假设集中在 Express 应用层，数据库层没有最小权限和租户策略。
- 涉及文件：backend/migrations/001_initial.sql:151-166；backend/migrations/002_units.sql:20-21；backend/src/cloudbase-postgrest.js:77-80。
- 修改方案：评估 CloudBase PostgREST 支持的最小权限角色和 RLS policy；至少为服务端访问增加可审计的租户条件/存储过程；高风险表禁止任意全表写入。
- 修复状态：未修复。
- 验证结果：静态确认无 policy；未在生产数据库执行任何查询或权限变更。

### SEC-017：当前工作区有 0644 的被忽略密钥/环境文件，忽略规则覆盖不足

- 结论性质：本机暴露风险和工程防护缺口；没有证据表明这些文件已进入 Git 历史。
- 严重程度：一般。
- 影响范围：同一机器上的其他用户、备份、同步工具或误打包过程可能读取本地密钥和签名材料。
- 复现/证据：
  - 只读 Git 检查显示 backend/.env、app/android/key.properties、app/android/app/watchdog-release.keystore、backend/asr-debug.js 当前均未跟踪且被忽略；stat 显示这些文件权限为 -rw-r--r--。
  - 根 .gitignore:4-11 只忽略 backend/.env、backend/data、日志和一个调试脚本，没有通用的 .env、证书、备份/转储文件规则；app/android/.gitignore:11-15 单独忽略签名文件。
  - git rev-list --objects --all 未发现上述敏感路径；常见私钥/API key 形式的跟踪文件扫描无匹配。gitleaks/trufflehog 在当前环境未安装，因此不能把该结果等同于完整秘密扫描。
- 根本原因：本地 secret 文件权限宽松，且防误提交依赖少数路径规则，没有统一 secret scanning/pre-commit 约束。
- 涉及文件：.gitignore；app/android/.gitignore；backend/.env；app/android/key.properties；app/android/app/watchdog-release.keystore；backend/asr-debug.js。
- 修改方案：本地 secret/签名文件至少设为 0600；使用 CI/提交前 secret scanner；增加通用忽略并保留必要模板的显式跟踪；调试脚本改为只读环境变量注入并清理共享工作区副本；轮换已在不受控权限下使用过的凭证。
- 修复状态：未修复（本轮不能改权限或删除文件，避免越过只读范围）。
- 验证结果：未输出任何真实密钥值；没有发现 Git 跟踪泄露证据，但完整历史扫描工具和生产平台扫描仍待执行。

## 4. 已确认的正向控制

- 默认 App 服务地址、模型地址、DeepSeek 地址使用 HTTPS；ASR WebSocket 使用 WSS。仓库未发现固定生产 HTTP/WS 地址。
- Express JSON、音频、笔记、日志、离线操作和 chat 均存在长度/数量上限；数据库访问路径主要使用参数化查询或白名单过滤，未发现已证实的 SQL 注入路径。
- OTA APK 下载已有 SHA-256、包名、版本号和路径穿越检查：app/lib/services/update_service.dart、app/android/app/src/main/kotlin/com/firewatch/watchdog/MainActivity.kt:179-213。该控制不覆盖 ASR 模型。
- 常见私钥和 token 形式的 Git 跟踪文件扫描无匹配；当前敏感文件均为 ignored 状态。报告没有记录真实密钥、验证码或现场数据。

## 5. 验证记录和限制

- backend：在 backend/ 执行 npm test，102/102 通过。
- App：在 app/ 执行 flutter analyze，No issues found；执行 flutter test，146/146 通过。
- 部署脚本：bash -n deploy/deploy.sh 通过；git diff --check 通过。
- 依赖审计：npm audit --omit=dev --json 未完成，当前 npm registry mirror 对 audit endpoint 返回 404/NOT_IMPLEMENTED；该结果是验证阻塞，不是已确认依赖漏洞。
- 未执行：没有访问 CloudBase 生产数据库、运行时环境变量、GitHub Actions 历史日志或真实日志；没有调用生产写接口；没有模拟真实设备 root/备份/抓包、跨单位 legacy 数据读取、模型篡改或高并发压力。
- 工作区基线：审查开始前已有多处 README、App、backend、migration 和 deploy 相关未提交改动；本报告未覆盖、未重置、未合并这些改动。后续修复应先区分这些既有改动，避免将其误归因于本次审查。

## 6. 建议验收顺序

1. 先关闭 SEC-001、SEC-002、SEC-003、SEC-004、SEC-005、SEC-006，补充跨单位、冒用操作者、缺失生产配置和日志 RBAC 回归测试。
2. 再处理 SEC-009、SEC-014、SEC-015，并在隔离环境完成出站目标、签名流水线和容器重启持久性验证。
3. 处理 SEC-007、SEC-008、SEC-010、SEC-011、SEC-012、SEC-013、SEC-017 的隐私、资源和供应链风险。
4. 完成后重新运行 backend npm test、app flutter analyze、app flutter test，增加安全专项测试和必要的真机/部署演练；所有高优先级条目关闭前不得宣布安全验收通过。
