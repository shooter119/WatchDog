# WatchDog 测试与质量组审查记录

审查日期：2026-08-27（Asia/Shanghai）
审查范围：`backend/test`、`app/test`、测试配置、发布工作流、关键生产代码与测试替身
审查方式：只读审查；未修改源码或测试，仅新建本记录文件。
工作树基线：审查开始时已有未提交改动；本记录按当前工作树结果记账，不覆盖或回滚既有改动。

## 1. 结论摘要

当前测试运行结果良好：后端 `npm test` 两次均为 102/102 通过；Flutter `flutter analyze` 为 0 issues，`flutter test` 两次均为 146/146 通过。测试声明数与运行汇总一致。

但这不能直接等同于整体验收通过。当前测试大量集中在纯逻辑和 Widget 展示，现场安全相关的真实链路仍由替身绕开，且发布工作流没有自动运行后端测试、Flutter analyze 或 Flutter test。以下 `严重` 项为必须由主 Agent 推进的测试/质量缺口；本轮只读，状态均未修复。

## 2. 实际验证记录

### 2.1 后端

命令：

```sh
cd /Users/vavavoom/Documents/WatchDog/backend
npm test
```

配置依据：`backend/package.json:10` 使用 `NODE_ENV=test node --test "test/*.test.js"`，Node 要求见 `backend/package.json:13-15`。

结果（第一次与第二次）：

```text
tests 102
pass 102
fail 0
cancelled 0
skipped 0
todo 0
```

两次均以退出码 0 结束。运行期间有 Node SQLite ExperimentalWarning，但没有测试失败或取消。

当前工作树按文件统计的测试声明数：

| 文件 | 用例数 |
|---|---:|
| `api.test.js` | 15 |
| `calc.test.js` | 10 |
| `chat.test.js` | 10 |
| `cloudbase-driver.test.js` | 3 |
| `database-readiness.test.js` | 2 |
| `db.test.js` | 14 |
| `incidents.test.js` | 8 |
| `logs.test.js` | 6 |
| `notes.test.js` | 4 |
| `parse.test.js` | 22 |
| `postgres-repository.test.js` | 1 |
| `token.e2e.test.js` | 1 |
| `user-settings.test.js` | 6 |
| **合计** | **102** |

已有覆盖较好的区域：计算公式、部分解析 guardrail、SQLite 仓储、进退场与压力复核 API、警情归档/时间线、随手记、操作日志、聊天接口、用户设置、Token/单位认证、数据库就绪等待，以及 CloudBase 客户端的少量请求形态。

### 2.2 Flutter App

命令：

```sh
cd /Users/vavavoom/Documents/WatchDog/app
flutter analyze
flutter test
```

配置依据：`app/analysis_options.yaml` 继承 `flutter_lints`，只排除 `third_party/**`；`app/pubspec.yaml:30` 声明 `flutter_test`。没有发现 `flutter_test_config.dart`、coverage 脚本或专门的集成测试配置。

结果：

```text
flutter analyze: No issues found!
flutter test: All tests passed!，146 个用例，0 失败
```

`flutter test` 两次均通过；第一次和第二次都完成到 `+146`。运行时提示 1 个 discontinued package、53 个受约束的新版本可用，这不是本轮测试失败。

当前工作树按文件统计的测试声明数：

| 文件 | 用例数 |
|---|---:|
| `api_client_test.dart` | 1 |
| `app_controller_test.dart` | 8 |
| `diagnostic_log_service_test.dart` | 1 |
| `local_parser_test.dart` | 20 |
| `name_parser_test.dart` | 7 |
| `note_category_test.dart` | 6 |
| `sse_parser_test.dart` | 7 |
| `update_service_test.dart` | 14 |
| `widget_test.dart` | 82 |
| **合计** | **146** |

已有覆盖较好的区域：本地文本解析、姓名粘贴解析、日志分类、SSE 行解析、OTA 清单/缓存包解析、启动认证/警情选择 UI、看板与倒计时展示、压力录入 UI、进退场确认 UI、日志/统计/辅助问答 UI、导航与部分窄屏布局。

### 2.3 工作区副作用

Flutter 测试期间生成了未跟踪的空目录 `app/android/.kotlin/sessions/`；已确认无文件，并仅清理该验证产生的空目录。审查结束时未发现 coverage、日志或密钥文件被写入仓库。

## 3. 测试配置与覆盖审查

### 3.1 后端测试入口

- 只有 `npm test`，匹配 `test/*.test.js`；没有 coverage 命令、覆盖率阈值、随机化/并发策略说明或测试超时配置。
- Node test runner 会并行加载多个测试文件；各文件大多在 `require('../src/db')` 前设置临时目录，隔离策略基本有效。
- `token.e2e.test.js` 启动真实子进程；其余 API 测试主要是进程内监听随机端口的 Express 服务。

### 3.2 Flutter 测试入口

- 依赖 `flutter test` 默认发现 `app/test/**/*_test.dart`；没有自定义 test config、coverage 阈值、golden 基线、integration_test 或 Android 真机自动化配置。
- `widget_test.dart` 一份文件包含 82 个 Widget 用例、约 2659 行，是 App 测试总量的约 56%；它通过 `_FakeController`、`_FakeApi`、`_FakeAudio` 大量隔离网络/插件，适合 UI 回归，但不能证明生产控制器、API 客户端或 Android 插件链路正常。
- 测试显式 mock `watchdog/screen` 与 `SystemChannels.platform`，并将本地 ASR/云端解析开关设为云端路径；Android 权限、录音文件和本地模型实际行为没有被覆盖。

## 4. 问题台账

严重程度含义：`阻断` 会阻止基本验证；`严重` 会使核心/安全/现场链路缺少可靠回归保护；`一般` 会造成明显质量盲区或工程风险；`优化` 为提升长期可维护性与可观测性的建议。

### TQ-001：AGENTS.md 中的测试基线数量已过期

- 严重程度：一般
- 影响范围：验收门槛、主 Agent 的回归判断、未来“用例不得减少”的检查。
- 复现步骤/命令/结果：
  1. 读取 `AGENTS.md:21-25`，记录为后端 71、App 70。
  2. 在 `backend/` 运行 `npm test`，结果为 102 pass。
  3. 在 `app/` 运行 `flutter test`，结果为 146 pass。
  4. 用 `rg -c '^\s*test\s*\(' backend/test` 与 `rg -c '^\s*test(?:Widgets)?\s*\(' app/test` 汇总，也分别得到 102、146。
- 根本原因：用例基线硬编码在 AGENTS.md，没有由测试入口或 CI 自动生成/校验；当前工作树还包含已修改的测试和新增 `database-readiness.test.js`。
- 涉及文件：`AGENTS.md`、`backend/package.json`、`backend/test/*`、`app/test/*`。
- 修改方案：由主 Agent 在确认当前工作树应作为新基线后同步更新数字；同时增加脚本/CI 输出并比较测试数量，避免手工数字再次失真。不要把新增用例简单删除以回到旧数字。
- 修复状态：待处理；本轮只读未修改。
- 验证结果：已用两轮全量运行和静态声明统计确认 102/146，证据一致。

### TQ-002：没有 PR/主分支测试门禁，发布工作流也不运行测试

- 严重程度：严重
- 影响范围：代码合并与 APK 发布可能绕过后端测试、Flutter 静态分析和 Flutter 测试；失败只能依赖人工发现。
- 复现步骤/命令/结果：
  1. `find .github/workflows -maxdepth 1 -type f` 只发现 `release.yml`。
  2. 读取 `.github/workflows/release.yml:5-7`，触发条件仅为 push tag `v*`。
  3. 读取 `.github/workflows/release.yml:51-56`，发布 job 执行 `flutter pub get` 和 `flutter build apk --release`，没有 `npm test`、`flutter analyze` 或 `flutter test`。
- 根本原因：当前 CI 只承担发布构建/签名/Release 资产生成，没有独立质量工作流，也没有让发布依赖质量检查。
- 涉及文件：`.github/workflows/release.yml`；缺失的 PR/push 测试 workflow。
- 修改方案：增加 PR 和主分支 push 的质量 workflow，运行 `backend/npm test`、`app/flutter analyze`、`app/flutter test`；发布 job 在构建前复用或重复执行这些检查，并保存失败日志/测试摘要。
- 修复状态：待处理；本轮只读未修改。
- 验证结果：本机两轮测试通过，但没有远程 CI 门禁可证明合并/发布会执行这些命令。

### TQ-003：后端核心语音 HTTP 链路没有边界回归测试

- 严重程度：严重
- 影响范围：现场“按住说话→转写→语义解析”的服务端入口；可能遗漏音频格式、请求体、超时、ASR 响应帧、模型错误和 HTTP 错误映射回归。
- 复现步骤/命令/结果：
  1. `backend/src/asr.js` 有 242 行帧构造、帧解析、分片发送和超时处理代码。
  2. `backend/src/server.js:637-710` 定义 `/api/transcribe` 和 `/api/parse`。
  3. `rg -n "/api/(transcribe|parse)" backend/test` 无结果；`backend/test` 也没有直接导入 `../src/asr`。
  4. `parse.test.js` 的 22 个用例直接测 `parse.js` 函数和 guardrail，并不能覆盖 Express 请求校验/鉴权/ASR WebSocket/响应解析边界。
- 根本原因：单测集中在纯解析逻辑，未提供可注入的 ASR/WebSocket 与模型客户端边界，缺少 API contract test。
- 涉及文件：`backend/src/asr.js`、`backend/src/server.js:637-710`、`backend/src/parse.js`、`backend/test/parse.test.js`。
- 修改方案：为 ASR 帧构造/解析和发送状态机提供可注入 WebSocket 的单测；为 `/api/transcribe`、`/api/parse` 增加真实 Express 边界测试，覆盖无警情、空/超大 body、支持的音频 Content-Type、模型超时/非 200/坏 JSON、成功响应和错误日志脱敏。
- 修复状态：待处理；本轮不补测试。
- 验证结果：现有后端全量测试通过，但没有覆盖上述入口；不能据此判定语音服务端链路通过。

### TQ-004：App 的真实同步与离线补传链路被测试替身绕开

- 严重程度：严重
- 影响范围：断网时进退场、压力复核、随手记的持久化、恢复网络后的顺序补传、幂等和部分失败恢复；可能导致现场数据不显示、重复或无法补传。
- 复现步骤/命令/结果：
  1. `app/test/widget_test.dart:64-68` 的 `_FakeController` 覆盖 `startSync()` 和 `sync()` 为空实现，并注明不发网络请求。
  2. `app/lib/state/app_controller.dart:344-405` 的生产实现包含 5 秒/1 秒定时器、`OfflineQueue.instance.drain`、活跃警情/条目/日志/力量拉取和错误恢复。
  3. `app/lib/services/offline_queue.dart:9-99` 没有被任何 `app/test` 直接导入；其 SQLite 队列、唯一 `client_op_id`、按 id 顺序分组补传和部分结果删除均无 App 单测。
  4. App Widget 测试的 `_FakeApi` 成功返回 create/exit/pressure 结果，因此没有触发 `AppController` 中的网络异常分支。
- 根本原因：UI 测试为避免轮询定时器影响 `pumpAndSettle`，把核心控制器生命周期和网络同步整体替换掉；离线队列没有依赖注入测试接口。
- 涉及文件：`app/test/widget_test.dart:36-91`、`app/lib/state/app_controller.dart:344-405,479-606,738-773`、`app/lib/services/offline_queue.dart`；后端对应 `backend/src/server.js:412-493` 及已有的少量 `incidents.test.js` 补传测试。
- 修改方案：增加可控时间/可注入存储的 `OfflineQueue` 单测，覆盖 enqueue 去重、跨警情分组、顺序、服务端只返回部分结果、网络失败保留、过期 accepted；为 `AppController` 使用失败型 ApiClient 测试 entry/pressure/exit/note 入队和下一轮 drain；增加控制器真实 sync 的一次成功/失败/归档警情场景测试。
- 修复状态：待处理；本轮不补测试。
- 验证结果：后端离线接口已有“note 接受+重复”测试，但 App 队列和控制器实际链路未验证；全量测试通过不能排除该缺口。

### TQ-005：录音、权限、本地 ASR 和模型下载没有真实行为覆盖

- 严重程度：严重
- 影响范围：Android 设备上的按键录音、WAV 参数/文件生命周期、本地离线识别、模型下载失败重试与残留文件清理、权限拒绝恢复。
- 复现步骤/命令/结果：
  1. `app/lib/services/audio_service.dart:9-50` 直接依赖 `record` 和临时文件，并固定 WAV/16kHz/单声道配置。
  2. `app/lib/services/local_asr_service.dart:16-164` 负责模型文件检查、HTTP 下载、`.part` 文件、进度回调、降噪模型和旧模型清理。
  3. `app/test` 无 `audio_service.dart` 或 `local_asr_service.dart` 的测试导入；`widget_test.dart:333-345` 的 `_FakeAudio` 固定权限为 true，`stop()` 永远返回空字节，未触达生产插件/文件逻辑。
  4. `flutter test` 运行在桌面测试 binding，未执行 Android record/sherpa-onnx 真机行为。
- 根本原因：录音与端侧模型均是平台/文件系统依赖，没有可注入的 recorder、HTTP client、文件目录和模型识别器测试 seam。
- 涉及文件：`app/lib/services/audio_service.dart`、`app/lib/services/local_asr_service.dart`、`app/test/widget_test.dart:333-345`、`app/lib/state/app_controller.dart`。
- 修改方案：先把 WAV 头/样本解析和下载文件替换、重试、清理抽成可测纯逻辑；使用 mock platform channel/HTTP client 覆盖权限拒绝、start/stop 异常、空/损坏文件、HTTP 404/超时/中断和重试后残留；在 Android 真机或 emulator 增加最小录音/模型 smoke test。
- 修复状态：待处理；本轮不补测试。
- 验证结果：Flutter analyze 与 146 个测试通过，但本地 ASR/录音生产代码仍未被测试触达。

### TQ-006：生命安全阈值、声音告警和后台保活没有回归保护

- 严重程度：严重
- 影响范围：10 分钟提醒、5 分钟报警、超时报警、TTS、报警音循环、本地通知、精确闹钟和后台前台服务；属于现场安全核心能力。
- 复现步骤/命令/结果：
  1. `app/lib/state/app_controller.dart:344-477` 的生产 `startSync`、每秒 `_checkThresholds`、去重播报、报警循环和通知调度均在 `_FakeController` 的空 `startSync/sync` 下不执行。
  2. `app/lib/services/alarm_service.dart:68-264`、`tts_service.dart`、`foreground_keep_alive.dart`、`screen_on.dart` 均没有对应的 `app/test` 直接导入。
  3. 现有 Widget 用例验证的是已有条目的颜色/文字和按钮布局，并没有断言 TTS 调用、报警开始/停止、通知三档时间点或后台服务配置。
- 根本原因：AlarmService/TtsService/ForegroundKeepAlive 是内部具体实例，不易替换；测试为稳定收敛而禁用了真实控制器定时器，未建设时间与通知依赖注入层。
- 涉及文件：`app/lib/state/app_controller.dart:344-477`、`app/lib/services/alarm_service.dart`、`app/lib/services/tts_service.dart`、`app/lib/services/foreground_keep_alive.dart`、`app/lib/services/screen_on.dart`、`app/test/widget_test.dart:64-68`。
- 修改方案：抽象 clock、报警、TTS、通知与保活接口；用 fake clock 验证 warn/alarm/timeout 边界、只播报一次、危险状态持续/解除、已出场取消通知；增加 Android channel/plugin smoke test，验证无权限或 MissingPlugin 时不阻塞主流程。
- 修复状态：待处理；本轮不补测试。
- 验证结果：现有测试全通过，但没有证据证明后台/锁屏/权限环境中的报警行为正确。

### TQ-007：ApiClient 传输层覆盖严重不足

- 严重程度：一般
- 影响范围：所有 App→后端请求的 URL、Token/设备/单位/实名/op_id 头、中文实名 Base64、错误解析、超时、重试、取消和 JSON 映射。
- 复现步骤/命令/结果：
  1. `app/test/api_client_test.dart` 只有 1 个测试，只验证完整警情简报的 `/api/chat` 请求体。
  2. `app/lib/api/api_client.dart:54-107` 有统一 headers、客户端池、取消/重建连接；`191-459` 还有转写、解析、进退场、名单、日志、配置、聊天等大量请求方法。
  3. `widget_test.dart` 使用 `_FakeApi` 覆盖这些 API 方法，不能验证生产 `ApiClient` 的请求头和响应错误分支；`sse_parser_test.dart` 只测 parser，不测 `sendChatMessageStream` 网络状态机。
- 根本原因：没有统一的可注入 HTTP client；唯一 API 测试使用本地 `HttpServer` 只覆盖一个聊天成功场景。
- 涉及文件：`app/lib/api/api_client.dart`、`app/test/api_client_test.dart`、`app/test/sse_parser_test.dart`、`app/test/widget_test.dart`。
- 修改方案：为 ApiClient 注入 `http.Client`，建立请求矩阵：headers/forIncident/forAssistant、200/201/400/401/403/409/5xx/HTML、超时和重试、取消/释放、每个 CRUD 的 JSON 映射；单独验证中文实名 Base64 不进入非法 HTTP header。
- 修复状态：待处理；本轮不补测试。
- 验证结果：现有唯一 API 测试通过；其余方法没有独立传输层证据。

### TQ-008：生产 PostgreSQL/CloudBase 适配器与迁移缺少真实契约验证

- 严重程度：一般
- 影响范围：线上 PostgREST 查询语法、重试/超时、迁移后的列/唯一约束、`service_role` 访问、归档/事件/单位等生产数据读写。
- 复现步骤/命令/结果：
  1. `backend/test/cloudbase-driver.test.js` 只有 3 个测试，主要验证一次 select、一次 insert/重复键和环境变量别名。
  2. `backend/test/postgres-repository.test.js` 用测试内 `Map`、`matches` 和简化响应模拟 PostgREST，没有真实 CloudBase/PostgreSQL 连接。
  3. `backend/src/cloudbase-postgrest.js` 还包含 GET 重试、408/429/5xx、Retry-After、超时、update/remove/upsert/rpc/count/filter 编码逻辑；这些分支没有成套测试。
  4. `backend/migrations/002_units.sql` 是当前未跟踪迁移文件，测试只在 fake table 中添加 `units`，没有执行 SQL 迁移或 schema smoke test。
- 根本原因：测试为了离线运行自建了轻量 fake，但没有与真实 PostgREST schema/迁移相结合的 contract test。
- 涉及文件：`backend/src/cloudbase-postgrest.js`、`backend/src/db-postgres.js`、`backend/test/cloudbase-driver.test.js`、`backend/test/postgres-repository.test.js`、`backend/migrations/002_units.sql`、`deploy/`。
- 修改方案：增加不含生产密钥的临时/隔离 CloudBase PG contract job，执行迁移后验证关键表/唯一约束和 CRUD；在本地补齐 adapter 的 retry、timeout、错误 body、filter、update/delete/rpc 测试；部署前做 dry-run + health/schema smoke test。
- 修复状态：待处理；本轮未连接线上数据库，也未运行部署命令，避免只读审查产生外部状态变化。
- 验证结果：本地 fake 适配器测试通过；没有真实 schema/迁移/部署验证结果。

### TQ-009：若干管理端点与归档页面没有边界回归测试

- 严重程度：一般
- 影响范围：设备 profile、消防站维护、参战力量删除、归档档案页面，以及它们的错误/权限/空态行为。
- 复现步骤/命令/结果：
  1. `backend/src/server.js` 定义 `/api/profile`、`PUT /api/profile`、`POST /api/stations` 和 `DELETE /api/incidents/:incidentId/forces/:forceId`；`backend/test` 未出现这些请求场景。
  2. `app/lib/pages/archived_incidents_page.dart` 没有被 `app/test` 直接导入；现有测试覆盖的是警情选择浮层和少量归档入口，不是归档档案列表/时间线页面。
  3. 参战力量测试覆盖新增、更新、版本冲突和查询，但没有删除成功/错误/越权场景。
- 根本原因：端点按功能增量加入，测试优先覆盖主路径，未用路由清单反向检查每个读写端点和页面入口。
- 涉及文件：`backend/src/server.js:514-636`、`backend/test/incidents.test.js`、`app/lib/pages/archived_incidents_page.dart`、`app/test/widget_test.dart`。
- 修改方案：按路由清单补齐 profile/station/force delete 的 2xx、400、401/403、404、409 和警情隔离测试；为归档页面添加空态、排序、时间线展开、长文本和加载失败 Widget 测试。
- 修复状态：待处理；本轮不补测试。
- 验证结果：现有全量通过，但上述端点/页面没有独立回归证据。

### TQ-010：测试依赖墙钟、随机端口和大量 `pumpAndSettle`，存在脆弱性

- 严重程度：一般
- 影响范围：CI 负载变化、慢设备、时间边界、端口占用或动画/定时器变化时的误报和偶发超时。
- 复现步骤/命令/结果：
  1. `backend/test/token.e2e.test.js:11` 使用 `3900 + Math.random() * 500` 选端口，并在 `:31` 以 250ms 轮询最多 10 秒等待服务；`incidents.test.js:38` 也用 `Date.now()+Math.random()` 生成操作 ID。
  2. 后端多个测试直接使用 `Date.now()`，如 `api.test.js:195` 以当前时间 ±5 秒判断倒计时；没有 fake clock。
  3. `app/test/widget_test.dart` 使用当前时间构造条目，且有大量 `pumpAndSettle()`；还断言 `btnH == 44.0`（约 `:597`）和固定设备宽度/像素布局。
  4. 本轮两次运行均通过，但 Flutter 第二次完成时间明显长于第一次，说明测试耗时对环境有敏感性；没有执行时间阈值或失败重试策略。
- 根本原因：生产代码直接读取系统时钟/定时器，测试采用真实 sleep/settle 和绝对像素断言，缺少 clock、随机源和固定动画控制。
- 涉及文件：`backend/test/token.e2e.test.js`、`backend/test/incidents.test.js`、`backend/test/api.test.js`、`app/test/widget_test.dart`、涉及定时器的 App 生产代码。
- 修改方案：后端监听端口统一使用 `server.listen(0)` 或可靠的端口分配；注入 clock/使用 fake time；App 使用 fake clock 和显式有限 pump，减少对 `pumpAndSettle` 的依赖；将设计契约断言与非必要像素常量断言分层。
- 修复状态：待处理；本轮不改测试。
- 验证结果：两轮全量运行通过，未观察到实际失败；本项是由代码结构和测试写法直接证明的脆弱性风险，不宣称已有 flaky 复现。

### TQ-011：没有覆盖率产物或最低覆盖率门槛

- 严重程度：优化
- 影响范围：无法量化纯逻辑、API 边界、平台服务和异常分支的真实覆盖率；用例数量增长可能掩盖关键路径仍未触达。
- 复现步骤/命令/结果：
  1. `backend/package.json` 只有 `test` 和迁移脚本，没有 coverage script。
  2. `app/pubspec.yaml`、`app/analysis_options.yaml` 和 `.github/workflows/release.yml` 没有 `flutter test --coverage`、coverage artifact 或阈值检查。
  3. 本轮只得到通过数，无法得到 backend/App 的行/分支覆盖率。
- 根本原因：测试质量以用例数量和退出码为主，没有覆盖率报告与关键目录最低线。
- 涉及文件：`backend/package.json`、`app/pubspec.yaml`、`.github/workflows/release.yml`；建议新增的质量 workflow。
- 修改方案：后端使用 Node test coverage 能力生成报告，App 生成 `flutter test --coverage`；先建立基线，再对 `server.js`、`db-*`、`api_client.dart`、`app_controller.dart`、现场服务目录设置合理的最低线，覆盖率下降阻断 PR，同时允许平台/第三方代码单独豁免并说明理由。
- 修复状态：待处理；本轮不改配置。
- 验证结果：已确认现有测试通过，但当前没有覆盖率数字可供验收。

## 5. 推荐补测优先级

### P0（主 Agent 修复后必须先复核）

1. 后端 `/api/transcribe`、`/api/parse` + ASR 帧状态机/异常响应。
2. App `OfflineQueue` 和 `AppController` 四类离线操作（entry/pressure/exit/note）入队、补传、幂等和失败保留。
3. 10/5/0 分钟阈值、TTS/报警循环/通知调度/已出场取消，以及后台保活失败不阻塞主链路。
4. 真实 `ApiClient` headers、错误映射、超时/取消/重试与所有核心 CRUD。

### P1

1. 录音权限、WAV 输出、模型完整性/下载重试/残留清理和 Android smoke test。
2. CloudBase adapter 的 retry/filter/update/delete/rpc 错误矩阵、迁移后 schema smoke test。
3. profile/station/force delete、归档页面和失败/空态场景。

### P2

1. 去除墙钟/随机端口/无限 settle 依赖，建立 fake clock 和稳定的 Widget 尺寸策略。
2. 接入 coverage 报告、趋势和目录级门槛；同步维护真实测试基线。

## 6. 最终验收清单（本组视角）

### 已满足

- [x] 后端 `npm test` 已执行两轮：102/102 pass，0 fail。
- [x] App `flutter analyze` 已执行：0 issues。
- [x] App `flutter test` 已执行两轮：146/146 pass，0 fail。
- [x] 实际用例数已按文件统计，后端 102、App 146。
- [x] 现有测试未发现 skipped、todo 或失败用例。
- [x] 审查未修改源码/测试；验证生成的空 `.kotlin` 目录已清理。

### 尚未满足

- [ ] AGENTS.md 测试基线与当前实际数量统一，并具备防回退检查。
- [ ] PR/主分支/发布链路具备自动质量门禁。
- [ ] 核心语音服务端边界和 App 录音/本地 ASR 有可重复回归测试。
- [ ] App 真实同步、离线队列、幂等补传和恢复失败场景有测试。
- [ ] 阈值告警、TTS、通知、锁屏/后台保活有可替换依赖和边界测试。
- [ ] ApiClient 全核心请求的 headers/错误/超时/取消/映射有测试。
- [ ] PostgreSQL/CloudBase 迁移与生产契约有隔离 smoke/contract test。
- [ ] 未覆盖管理端点和归档页面完成空态、错误、权限和隔离回归。
- [ ] 测试从墙钟/随机/无限 settle 中解耦，并确认重复运行无 flaky。
- [ ] 有覆盖率报告、趋势和关键目录最低门槛。
- [ ] 主 Agent 完成后续修复后重新运行全量验证，并确保最终工作区无密钥/调试文件。

因此，本组当前结论是：**测试命令结果通过，但测试质量最终验收暂不通过；阻塞原因是 TQ-002 至 TQ-006 等高风险覆盖缺口，不是现有用例运行失败。**

## 7. 建议交叉复核项目

- 后端与架构组：复核 TQ-003/TQ-008 的路由、数据库迁移、幂等和错误码矩阵；确认 fake PostgREST 没有掩盖线上 schema/query 差异。
- Flutter App 功能组：复核 TQ-004/TQ-005，设计真实控制器注入点，验证断网→本地显示→恢复网络→服务端一致性的完整链路。
- UI/UX 组：复核 TQ-006/TQ-009/TQ-010，重点看告警层级、离线/权限失败反馈、归档空态、窄屏/横屏以及测试中的固定尺寸断言是否为明确设计契约。
- 安全与隐私组：复核 TQ-003/TQ-007/TQ-008，确认 Token、单位认证、中文实名 Base64、日志/诊断 payload 与 LLM 错误路径不会在测试替身或真实响应中泄露。
- 性能与工程质量组：复核 TQ-002/TQ-010/TQ-011，建立 CI 总耗时、重复运行、coverage 趋势和超时/资源泄漏检查。
- 主 Agent/最终验收：所有高优先级补测完成后，至少连续运行后端和 Flutter 全量测试各两次；再运行 `flutter analyze`，核对实际数量、README/About 同步、`git status` 与密钥排除清单。
