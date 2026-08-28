# 测试与质量组第二轮定向复核

复核日期：2026-08-27（Asia/Shanghai）
复核范围：当前工作区的测试计数、质量/发布 workflow、Flutter `ApiClient`、后端 ASR/parse、App 离线队列，以及 Android 真机覆盖。
复核方式：先完成只读检查和不改源码的安全验证；随后按用户授权修复 R2-QA-001、R2-QA-002、R2-QA-003、R2-QA-004、R2-QA-005、R2-QA-006，并补充对应回归测试。工作区原有未提交改动未回滚。

## 1. 本轮结论

代码当前的本机回归是绿的。第二轮发现的 6 项残余问题均已完成低风险修复并补回归测试；真实 CloudBase、Android 插件和上游服务仍需外部环境验收：

| 编号 | 严重程度 | 结论 |
|---|---|---|
| R2-QA-001 | 一般 | 已修复；`ApiClient` 成功响应形状及时间线嵌套事件校验已补齐并有回归测试。 |
| R2-QA-002 | 严重 | 后端多人解析重试找回人员后 guardrail 使用第一次响应；已修复并补回归测试。 |
| R2-QA-003 | 严重 | 已修复；离线压力复核会立即投影记录级压力、容量/耗气率和倒计时。 |
| R2-QA-004 | 一般 | 已修复；损坏 payload 单行隔离到 quarantine，合法警情继续补传，隔离失败时原行保留。 |
| R2-QA-005 | 严重 | 已修复；ASR 使用 staging + 完成标记 + active 指针整套原子切换，失败保留旧集合。 |
| R2-QA-006 | 一般 | 已修复；quality/release workflow 均解析运行时数量并执行 109/166 最低基线。 |

上述问题与上一轮已有的“没有 ASR/parse HTTP 边界测试、没有 App 离线/插件真机覆盖、ApiClient 测试不足”等问题不同：本报告在第 4 节只作当前状态确认，不重复建立旧编号。后续主台账以当前工作区最终验证结果为准。

## 2. 当前测试计数与最小验证

### 2.1 运行结果

| 验证项 | 命令 | 结果 |
|---|---|---|
| 后端 | `cd /Users/vavavoom/Documents/WatchDog/backend && npm test` | 退出码 0；`tests 109`、`pass 109`、`fail 0`、`cancelled 0` |
| Flutter 静态分析 | `cd /Users/vavavoom/Documents/WatchDog/app && flutter analyze` | 退出码 0；`No issues found!` |
| Flutter | `cd /Users/vavavoom/Documents/WatchDog/app && flutter test` | 退出码 0；最终 `+166`、`All tests passed!` |
| 工作区差异格式 | `git diff --check` | 退出码 0，无空白错误 |
| workflow YAML | Ruby Psych 解析 `.github/workflows/quality.yml` 与 `release.yml` | 两个文件均 `YAML OK`；本机没有 `actionlint`，因此未作 GitHub 语义级 lint |

### 2.2 声明计数交叉核对

当前测试发现入口和声明数如下，和 `AGENTS.md` 的 109/166 基线一致：

- 后端 `test/*.test.js` 由 `backend/package.json` 的 `node --test "test/*.test.js"` 发现；本次执行发现并通过 109 条，其中 `parse.test.js` 定向通过 23 条。
- App `test/**/*_test.dart` 由 Flutter 默认发现；按 `test`/`testWidgets` 声明统计合计 166。
- 运行时分别得到后端 109 与 App 166；新增 parse、ApiClient、离线队列、ASR、UI 边界回归均被实际收集，未发现“静态数字增加但运行时未收集”的假增长。
- 本轮测试只产生了已被忽略的 `app/.dart_tool/`、`app/build/` 等构建/依赖产物；未产生新的跟踪文件或 coverage 文件。

## 3. 新增/残余问题台账

### R2-QA-001：ApiClient 成功响应的 JSON 形状仍有未校验分支（已修复）

- 唯一编号：R2-QA-001
- 严重程度：一般
- 影响范围：警情选择、认证后活动警情列表、部分 `ApiClient` 模型映射；网关或服务端错误地返回 HTTP 200 非数组/非对象时，页面拿到 `TypeError`/`_CastError`，而不是统一的 `ApiException`，不利于用户重试和诊断。
- 复现步骤或证据：
  1. `app/lib/api/api_client.dart:721-735` 的 `fetchIncidents` 在 `_decodeJson` 后直接执行 `final list = body as List`，没有 `body is! List` 保护。
  2. 同文件 `:738-765` 的 `createIncident` 最终直接把 `body` 转成 `Map<String, dynamic>`；`fetchIncident` 也直接把成功 body 转成 Map。
  3. 当前唯一直接使用生产 `ApiClient` 的 `app/test/api_client_test.dart:9-34` 只覆盖单个 `sendChatMessage` HTTP 200 happy path；没有上述响应形状测试。
  4. 当前 `_decodeJson` 已能处理 HTML/非法 JSON，但“合法 JSON、错误顶层类型”不走该错误保护，属于本轮复核出的残余边界。
- 根本原因：统一 JSON 解码和统一业务对象形状校验是两层职责，目前只完整覆盖了第一层，部分方法仍依赖强制 cast。
- 涉及文件：`app/lib/api/api_client.dart`、`app/test/api_client_test.dart`。
- 修改方案：为每个返回 List/Map 的方法增加显式形状校验，统一抛出带 `statusCode/code` 的 `ApiException`；给 `ApiClient` 注入可替换 HTTP client 或本地 HTTP server，覆盖非 JSON、错误顶层类型、错误状态码和关键 header。
- 修复实施：`api_client.dart` 的 List/Map 响应入口统一做显式形状检查，`fetchTimeline` 额外校验 `events` 为数组且每项为对象；错误统一为 `INVALID_RESPONSE_SHAPE` 的 `ApiException`。`api_client_test.dart` 补充警情列表/对象、错误码和时间线嵌套结构回归。
- 修复状态：已修复。
- 验证结果：定向 ApiClient 用例与全量 `flutter test` 均通过；Flutter 全量最终为 166/166，`flutter analyze` 无问题。

### R2-QA-002：多人解析重试后仍以第一次响应做意图 guardrail（已修复）

- 唯一编号：R2-QA-002
- 严重程度：严重
- 影响范围：多人一次性进场登记；可能出现模型第一次响应漏掉人员、重试已经找回全部人员，但 App 仍按 `note` 自动写日志而不进入进场确认，造成安全登记缺失。
- 复现步骤或证据：
  1. 修复前的 `backend/src/parse.js:201-215` 在多人压力文本下重试模型，并把成功的人员列表写入局部变量 `people`。
  2. 修复前的 `backend/src/parse.js:217-226` 随后调用 `guardrailIntent(text, parsed, firefighters)` 和 `guardrailAction(text, parsed)`，这里仍传第一次模型响应 `parsed`，而不是包含重试结果的人员集合。
  3. `guardrailIntent` 在 `backend/src/parse.js:168-171` 对 `intent=entry` 且 `parsed.people` 为空、文本没有显式“进入/进场”词时降级为 `note`。标准报数文本“张伟20兆帕，李娜22兆帕”有两个压力值但没有该动作词。
  4. 修复前隔离运行验证使用第一次 mock 响应 `{intent: entry, action: enter, people: []}`、第二次响应包含张伟/李娜两人，输入为上述标准文本；输出为 `calls:2, people:2, intent:"note"`。
- 根本原因：重试只更新了输出人员，没有更新 guardrail 使用的解析快照；人员恢复和意图安全校验使用了不同状态。
- 涉及文件：`backend/src/parse.js`、`backend/test/parse.test.js`。
- 修改方案：在重试决策完成后构造包含规范化最终 `people` 的 `finalParsed`，让 `guardrailIntent` 与 `guardrailAction` 共同消费该最终结果；同时将返回的 `note` 与最终解析结果保持一致。
- 涉及修改：`backend/src/parse.js` 在多人重试后同步更新 `finalParsed`，并将两个 guardrail 的输入从首次 `parsed` 切换为 `finalParsed`；`backend/test/parse.test.js` 新增首次漏人、第二次找回张伟/李娜及 20/22MPa 的回归用例，首次响应还故意返回 `action=exit` 以验证动作 guardrail 不读取旧快照。
- 修复状态：已修复；本次仅修改上述两个源码/测试文件，未回滚工作区既有改动。
- 验证结果：定向 `NODE_ENV=test node --test test/parse.test.js` 通过 `23/23`；后端全量 `npm test` 通过 `109/109`，`fail 0`。回归结果为 `calls=2`、`intent=entry`、`action=enter`、`people=[张伟(20), 李娜(22)]`，顺序与压力值均正确。
- 部署验证：按项目约定尝试运行 `./deploy/deploy.sh`，因本机未设置 `CLOUDBASE_ENV_ID`/`CLOUDBASE_ENV` 以退出码 1 停止；未调用 CloudBase CLI、未改变线上状态，因此 CloudBase 生产实例上的实际解析链路不能在本机完成验证。

### R2-QA-003：离线压力复核入队但本地状态仍是旧值

- 唯一编号：R2-QA-003
- 严重程度：严重
- 影响范围：断网现场的压力复核、看板状态、倒计时和前台告警；用户提交新压力后，在网络恢复前无法看到新的本地压力/倒计时，可能继续依据过期状态判断。
- 复现步骤或证据：
  1. `app/lib/state/app_controller.dart:650-693` 的 `updatePressure` 在网络异常时把新压力写入 `OfflineQueue`，但在 `:688` 设置 `e = current`。
  2. 后续 `:690` 只把该条目替换为同一个 `current`，虽然 `:691` 通知监听者，但 `Entry.pressureMpa`、`exitAt`、`durationMin` 没有变化。
  3. `app/lib/models/models.dart:34-47` 的 `Entry.copyWith` 目前只支持 `exitedAt`，没有压力、时长或结束时间参数，因此现有实现没有本地投影新读数的路径。
  4. `app/test` 没有失败型 `ApiClient.updateEntry` 驱动的 `AppController.updatePressure` 用例；全量 Widget 测试使用 `_FakeController` 或成功型 `_FakeApi`，不能触达此分支。
- 根本原因：离线队列写入和本地领域对象更新被当成两个步骤，但失败分支只完成了前者；状态模型也没有提供安全的复制/重算接口。
- 涉及文件：`app/lib/state/app_controller.dart`、`app/lib/models/models.dart`、`app/lib/services/offline_queue.dart`、`app/test`。
- 修改方案：定义离线压力复核的本地状态投影，保留记录级容量/耗气率并按同一计算函数更新压力、耗气率采样前的显示状态和 `exitAt`；为网络失败、立即通知、下一次补传和补传失败保留队列分别增加控制器测试。具体计算规则应复用现有后端契约，不在测试组擅自改产品规则。
- 修复实施：`AppController.updatePressure` 在网络失败后通过同一计算配置立即生成记录级本地投影，更新压力、容量/耗气率、时长和 `exitAt`，再保留原离线补传路径；新增可控 API/队列 seam 与离线压力回归。
- 修复状态：已修复。
- 验证结果：离线压力专项用例和全量 `flutter test` 166/166 通过。

### R2-QA-004：损坏离线 payload 可阻塞整批补传

- 唯一编号：R2-QA-004
- 严重程度：一般
- 影响范围：离线操作恢复；一条损坏/手工残留/升级不兼容的 SQLite payload 可能让本轮 `drain` 在读取阶段直接失败，后续警情和合法操作不再尝试补传。
- 复现步骤或证据：
  1. `app/lib/services/offline_queue.dart:56-69` 在建立每个警情分组时直接执行 `jsonDecode(row['payload'] as String) as Map<String, dynamic>`。
  2. 该解析发生在 `for (final entry in grouped.entries)` 的 `try` 之前（`:74-94` 的异常处理只包住上传和结果删除），因此坏 JSON 不会被该组的 catch 隔离。
  3. `AppController.sync` 在 `app/lib/state/app_controller.dart:390-450` 会把异常作为整个同步失败处理；没有隔离坏行、记录诊断或继续处理其他组的分支测试。
- 根本原因：持久化数据解码没有按行容错/隔离，队列上传错误处理的粒度晚于 payload 解析。
- 涉及文件：`app/lib/services/offline_queue.dart`、`app/lib/state/app_controller.dart`、缺失的 `app/test` 队列测试。
- 修改方案：按行解析并将损坏行移入可诊断的 quarantine/失败状态，或在不丢数据的前提下只跳过该行继续合法分组；增加损坏 JSON、合法行与部分服务端结果混合时的回归测试。不得静默删除原始数据。
- 修复实施：队列改为逐行解码；坏行写入 `offline_operations_quarantine` 后删除原行，隔离失败则保留原行；合法分组继续按序补传，客户端按警情释放。
- 修复状态：已修复。
- 验证结果：新增损坏 payload、隔离失败保留原行和合法行继续补传用例；全量 `flutter test` 166/166 通过。

### R2-QA-005：本地 ASR 模型更新不是整套原子发布

- 唯一编号：R2-QA-005
- 严重程度：严重
- 影响范围：首次/更新本地 ASR、断点失败后的离线识别可靠性；更新中断后可能把旧 encoder 与新 decoder/joiner/tokens 混用，导致模型加载失败或识别结果异常。
- 复现步骤或证据：
  1. `app/lib/services/local_asr_service.dart:82-88` 顺序下载五个文件。
  2. `_downloadFile` 在 `:143-159` 为每个文件单独写 `.part` 并 rename 到最终文件；前一个文件 rename 成功后，后一个文件失败不会回滚前一个文件。
  3. `isModelInstalled` 在 `:73-87` 只检查五个最终文件是否存在，没有版本 marker、完整性 manifest 或同一临时目录的完成标记。
  4. `app/test` 没有导入 `local_asr_service.dart`，因此没有下载中断、残留 `.part`、混合版本或恢复启动测试。
- 根本原因：单文件安全 rename 被误当成模型集合的原子发布；集合级提交边界缺失。
- 涉及文件：`app/lib/services/local_asr_service.dart`、缺失的 `app/test` ASR 下载测试。
- 修改方案：在版本化 staging 目录完整下载并校验所有文件，写入完成 marker 后整体 rename/切换；失败保留旧的完整版本，启动只接受带 marker 的同一版本。测试需注入 HTTP/文件目录，覆盖中途中断、重试和旧版本保留。
- 修复实施：模型下载改为版本化 staging 目录，所有必需文件非空且完成标记写入后才切换 `.active` 指针；失败清理 staging 并保留旧 active，安装检查只接受完整集合。
- 修复状态：已修复。
- 验证结果：新增旧目录/混合集合、完整切换、失败保留旧集合、并发下载用例；定向及全量 `flutter test` 166/166 通过。真实模型上游下载仍需设备/网络验收。

### R2-QA-006：CI 尚未执行测试数量不减少门禁

- 唯一编号：R2-QA-006
- 严重程度：一般
- 影响范围：分支合并和 tag 发布质量；删除或跳过测试后，只要剩余测试退出码为 0，workflow 仍会通过，不能执行 `AGENTS.md` 的“测试用例数量不得减少”要求。
- 复现步骤或证据：
  1. 初始审查快照中的 `AGENTS.md:23-25` 要求后端 107、App 150 且改动后不得减少；本轮新增回归后已同步为后端 109、App 166。
  2. 原始 `.github/workflows/quality.yml` 仅运行 `npm ci && npm test` 与 `flutter pub get && flutter analyze && flutter test`。
  3. 原始 `.github/workflows/release.yml` 的发布前质量步骤也是同样命令；没有读取 Node test 汇总、Flutter 最终计数或与基线比较的步骤。
  4. 因此初始本机 107/150 只是事实验证，不是 CI 对未来提交的保护。
- 根本原因：质量 workflow 只把进程退出码作为门禁，没有可维护的测试计数基线/报告解析脚本。
- 涉及文件：`.github/workflows/quality.yml`、`.github/workflows/release.yml`、`AGENTS.md`。
- 修改方案：增加统一、可复用的计数检查脚本或测试 reporter 解析；门禁至少断言后端不少于当前基线，并在新增基线时显式更新文档/配置。不要只依赖 `rg` 统计源码声明。
- 修复实施：quality/release 两个 workflow 在质量命令后解析 Node `ℹ tests N` 和 Flutter JSON `testDone`，并以 `MIN_BACKEND_TESTS=109`、`MIN_APP_TESTS=166` 做不减少门禁；release 先通过同一门禁再构建。
- 修复状态：已修复。
- 验证结果：两个 YAML 文件经 Ruby YAML parser 解析通过；本机 109/109、166/166 通过。未安装 `actionlint`，也没有远程 GitHub Actions 运行证据。

## 4. 范围覆盖现状确认（沿用既有编号，不重复立项）

下表是本轮对用户点名范围的当前确认。除 R2-QA-001～006 外，不重新复制第一轮问题的完整字段；对应旧编号仍保持开放/待外部验收。

| 范围 | 当前证据 | 当前覆盖缺口 | 既有台账对照 |
|---|---|---|---|
| ApiClient | `api_client_test.dart` 已覆盖警情列表/对象、错误码和时间线嵌套形状；Widget 测试主要通过 `_FakeApi` 覆盖页面流程。 | 请求头、超时/取消、流式 HTTP 仍主要依赖集成环境；R2-QA-001 已修复。 | 延续 TQ-007 |
| 后端 ASR | `backend/src/asr.js` 没有被 `backend/test` 导入；帧构造/解析、WS 生命周期、空/坏/压缩/错误帧无单测。 | 没有可注入 WebSocket 的协议/状态机测试，也没有 `/api/transcribe` 的真实 Express 边界测试。 | 延续 TQ-003、TQ-005 |
| 后端 parse | 23 个 parse 测试通过 `globalThis.fetch` mock 覆盖 guardrail 和少数完整调用；新增用例覆盖多人重试最终结果。 | `/api/parse` 的鉴权/输入/限流/上游错误边界仍无测试；R2-QA-002 已修复。 | 延续 TQ-003 |
| App 离线 | 已有 `app_controller_offline_test.dart`、`offline_queue_test.dart` 覆盖本地压力投影、损坏行隔离和合法行继续补传。 | SQLite 真机迁移、单位切换、插件网络断开仍需设备/集成环境；R2-QA-003、004 已修复。 | 延续 TQ-004、FLT-006 |
| 录音/本地 ASR | 新增 `local_asr_service_test.dart` 覆盖集合完整性、staging、失败回滚和并发下载。 | WAV/插件权限、真实模型下载/识别和设备文件生命周期仍无真机证据；R2-QA-005 已修复集合边界。 | 延续 TQ-005、PE-014、SEC-013 |
| 告警/前台保活 | 当前测试没有 `AlarmService`、`ForegroundKeepAlive`、TTS 或 Android 通知插件的 first-party test。 | 真机权限、后台进程、通知调度、声音循环、电池优化和进程重启无证据。 | 延续 TQ-006 |
| Android 真机 | `find` 未发现项目自身 `integration_test/`、`androidTest/` 或 `test_driver/`；第三方 `package_info_plus` 示例不计入项目覆盖。 | 没有首次认证、错误 token 重试、长按录音、断网补传、告警和 OTA 安装的设备 smoke test。 | 延续 TQ-005、TQ-006、SEC-014 |

## 5. 质量 workflow 当前状态

已确认的正向状态：

- `.github/workflows/quality.yml` 已对分支 push 和 pull request 运行后端测试、Flutter analyze、Flutter test。
- `.github/workflows/release.yml` 已在构建和签名之前重复运行三项质量命令，并有版本一致性、arm64 ABI 和签名检查。
- 两个 workflow YAML 文件可以被 YAML parser 读取，本机三项命令均通过。

仍不足以作为完整验收证据的部分：

- 本轮没有触发 GitHub Actions，因此无法证明 runner 上的 Node/Flutter 版本、缓存、Android SDK、签名 secrets 与本机一致。
- workflow 已有数量不减少门禁（R2-QA-006）；仍没有覆盖率阈值、真机 smoke 或 ASR 上游契约 job。
- `actionlint` 本机不可用；Ruby 解析只证明 YAML 语法，不证明 GitHub expression、action 输入和 runner 行为全部正确。

## 6. 交付主 Agent 的行动建议

1. 在 CloudBase 预生产条件具备后，执行真实迁移、部署健康检查、PostgreSQL 并发和网关行为验证。
2. 在 Android 设备条件具备后，执行认证、录音、离线补传、通知/前台服务、本地 ASR、OTA 的设备 smoke；测试替身不能替代该证据。
3. 继续补充 ApiClient 请求取消、ASR 上游协议和覆盖率门槛；本轮已闭合六项定向残余缺陷。

## 7. 本轮验收判定

- 本机后端自动化回归：通过（109/109，含多人解析回归和分页边界）；App analyze 通过、166/166。
- 测试基线：`AGENTS.md` 与 quality/release workflow 已更新为后端 109、App 166，运行时数量门禁已实现。
- 本次定向修复验收：R2-QA-001～006 全部通过代码级回归；真实模型上游、Android 插件与 GitHub Actions 仍需外部环境证据。
- 本报告已记录本次源码/测试修改；工作区其他既有未提交改动未回滚。
