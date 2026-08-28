# WatchDog 最新 Flutter / CI / 测试改动交叉复核

审查日期：2026-08-27（Asia/Shanghai）
审查范围：当前工作区最新 Flutter、认证、录音、设置、日志脱敏、测试及 GitHub Actions 改动。
审查方式：只读静态审查 + 现有测试执行；未修改源码或测试，仅新建本记录。
工作树说明：审查开始前工作区已有大量未提交改动；本记录不覆盖、不回滚既有改动。

## 1. 结论摘要

当前后端测试和 Flutter 静态分析通过，但 Flutter 全量测试未通过，不能作为本轮验收通过依据。已确认 8 项需要主 Agent 处理的问题，其中 5 项涉及核心/发布/安全链路，均未在本轮修改。

最新改动的交叉结论如下：

- 认证浮层已经新增访问令牌字段并移除 APK 内置默认令牌，但令牌没有在认证回调中作为显式参数进入认证闭环；错误令牌可让 UI 离开认证浮层后卡在警情选择页，且失败认证会提前持久化错误令牌。
- 录音“松手早于权限/插件返回”的单次竞态已增加取消标记，但录音请求仍可重入，且 `AudioService.start()` 失败会留下伪录音路径。
- 阈值 setter 已增加范围和顺序校验，但设置页自动保存仍可能部分写入，其他计算参数仍可保存为 0/负数；关键边界没有回归测试。
- App 操作日志对直接 `text/content/raw` 字段做了长度/摘要处理，但通用日志消息、服务端日志入口和 `Authorization: Bearer ...` 形式仍有脱敏缺口。
- 当前 App 共有 146 个测试声明；后端共有 102 个。`flutter test` 实际为 145 通过、1 失败，失败是新增脱敏字段导致测试未滚动到可视区域。
- 新增质量 workflow 覆盖 PR/分支 push，但 tag 发布 workflow 不依赖质量检查，也不自行运行三项门禁；当前已知 Flutter 测试失败不会阻止 tag 发布。

## 2. 实际验证记录

### 2.1 后端

命令：

```sh
cd /Users/vavavoom/Documents/WatchDog/backend
npm test
```

结果：退出码 0。

```text
tests 102
pass 102
fail 0
cancelled 0
skipped 0
todo 0
```

运行期间只有 Node SQLite ExperimentalWarning，没有失败或取消用例。当前声明数按文件统计为：`api.test.js` 15、`calc.test.js` 10、`chat.test.js` 10、`cloudbase-driver.test.js` 3、`database-readiness.test.js` 2、`db.test.js` 14、`incidents.test.js` 8、`logs.test.js` 6、`notes.test.js` 4、`parse.test.js` 22、`postgres-repository.test.js` 1、`token.e2e.test.js` 1、`user-settings.test.js` 6，合计 102。

### 2.2 Flutter App

命令：

```sh
cd /Users/vavavoom/Documents/WatchDog/app
flutter analyze
flutter test
```

`flutter analyze`：退出码 0，`No issues found!`。运行时提示 1 个 discontinued package 和 53 个受约束的新版本可用，不属于本轮失败。

`flutter test`：退出码 1；静态声明数为 146，实际为 145 通过、1 失败。失败用例：

```text
OpLogPage 操作日志 按操作分组展示步骤，可展开查看与切换同步开关
Expected: exactly one matching candidate
Actual: Found 0 widgets with text "text_length: 7" (hit-testable)
位置：/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart:992
```

当前声明数按文件统计为：`api_client_test.dart` 1、`app_controller_test.dart` 8、`diagnostic_log_service_test.dart` 1、`local_parser_test.dart` 20、`name_parser_test.dart` 7、`note_category_test.dart` 6、`sse_parser_test.dart` 7、`update_service_test.dart` 14、`widget_test.dart` 82，合计 146。

### 2.3 CI 配置静态检查

- `/Users/vavavoom/Documents/WatchDog/.github/workflows/quality.yml` 和 `release.yml` 均可被 Ruby YAML parser 解析。
- 本机未安装 `actionlint`，未完成 GitHub Actions schema 级校验。
- `flutter test` 期间只生成了被 `.gitignore` 忽略的构建/工具目录，未发现仓库内新写入的密钥、真实数据或调试文件。

## 3. 问题台账

严重程度含义：`阻断` 阻止基本验收或发布；`严重` 影响核心/安全/发布链路；`一般` 造成明显质量盲区或工程风险；`优化` 为长期改进建议。

### QCR-001｜严重｜认证浮层令牌不能在认证阶段被验证，错误令牌会把用户带入不可恢复的警情选择状态

- 影响范围：首次安装、单位认证、后续 `/api/incidents` 等业务请求；错误或过期 API token 时用户无法正常进入警情，也无法通过被遮挡的设置页修改令牌。
- 复现步骤/证据：
  1. `/Users/vavavoom/Documents/WatchDog/app/lib/pages/incident_selection_overlay.dart:84-119` 读取访问令牌，并在调用认证回调前先执行 `Settings.setApiToken(token)`；回调只传单位名称、姓名和单位验证码，令牌没有作为认证参数传出。
  2. `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:178-195` 使用初始化阶段已经创建的 `api!.verifyUnit(...)`，认证成功后才在 `:195` 调用 `refreshConfig()` 重建带令牌的 ApiClient。
  3. 服务端 `/Users/vavavoom/Documents/WatchDog/backend/src/server.js:94-101` 明确跳过 `/api/auth/verify` 的 `API_TOKEN` 校验。因此输入错误 token 时单位认证仍返回 200；之后业务请求才在 token 中间件处返回 401 `API_TOKEN_INVALID`。
  4. `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:392-405` 只对 `UNIT_INVALID`/`UNIT_AUTH_REQUIRED` 进入失效认证流程，对 `API_TOKEN_INVALID` 只设置 `syncError`。`_authenticated` 已在 `:194` 设为 true，主界面因而离开认证浮层并停留在需要选择警情的浮层。
  5. 失败认证也会在 `:118` 之前把错误 token 写入 SharedPreferences；异常路径没有回滚。
- 根本原因：访问令牌作为浮层内部副作用写入，而不是认证事务的一部分；单位认证入口又故意绕过 API token，客户端没有在成功切换门禁前验证第一条受保护业务请求。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/pages/incident_selection_overlay.dart:84-124`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:166-199,344-409`；`/Users/vavavoom/Documents/WatchDog/backend/src/server.js:94-101,330-357`；`/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart:1982-2058`。
- 修改方案：让认证回调显式携带 token，使用该 token 构造临时认证/验证客户端；只有单位认证和首个受保护业务请求均成功后才持久化 token、单位信息并切换 `_authenticated`。若产品决定 `/api/auth/verify` 永久免 API token，则至少在切换 UI 门禁前调用受保护探测并将 `API_TOKEN_INVALID` 路由回认证浮层；失败时清理本次尝试写入的 token。
- 修复状态：待处理；本轮只读未修改。
- 验证结果：代码路径可确认；现有 App 用例只验证回调收到单位名称、姓名和验证码，没有断言 token 被保存、请求头携带 token、错误 token 的 401 或门禁回退。后端 `token.e2e.test.js` 只验证服务端 token 中间件，不覆盖 App 状态迁移。

### QCR-002｜严重｜录音插件启动失败后留下伪录音路径，下一次录音可能泄漏临时文件并污染状态

- 影响范围：Android 麦克风权限刚授予、录音插件异常、系统资源不足或录音启动失败后的下一次语音操作。
- 复现步骤/证据：
  1. `/Users/vavavoom/Documents/WatchDog/app/lib/services/audio_service.dart:17-27` 在 `_recorder.start(...)` 完成前就把 `_path` 写入；若插件抛异常，`_path` 不会自动清空。
  2. `HomePage.beginRecording()` 的异常处理在 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/home_page.dart:192-200` 只记录错误、显示错误并结束 op，没有调用 `AudioService.stop()` 或清理失败路径；`ChatPage` 的对应路径在 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/chat_page.dart:243-269` 同样如此。
  3. 下次调用 `start()` 会覆盖 `_path`，之前已创建或部分创建的文件失去引用；同时 `isRecording` 在失败后曾返回 true，取消竞态判断可能误认为已有录音。
- 根本原因：录音路径的资源所有权在插件启动成功前就发布，且失败回滚不在 `AudioService.start()` 内完成，页面层也没有统一的失败清理协议。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/services/audio_service.dart:9-28,38-67`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/home_page.dart:143-201`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/chat_page.dart:212-269`。
- 修改方案：`start()` 失败时在 `finally/catch` 中清空 `_path` 并删除已创建文件；把录音状态改为明确的 idle/starting/recording/stopping，页面只调用统一取消接口。补测插件启动抛异常、文件已创建/未创建、失败后立即再次录音和 dispose 清理。
- 修复状态：待处理；本轮只读未修改。
- 验证结果：现有 `_FakeAudio.start()` 永不失败（`/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart:333-347`），没有覆盖该分支；`flutter test` 的通过结果不能排除 Android 插件失败后的资源泄漏。

### QCR-003｜严重｜录音启动请求仍可重入，单一布尔取消标记无法区分两次长按

- 影响范围：快速重复长按、页面切换自动录音与人工长按重叠、权限请求慢或录音插件启动慢时的语音链路；可能出现两次 `start()`、op_id 串线或一次松手影响另一轮录音。
- 复现步骤/证据：
  1. `HomePage.beginRecording()` 在 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/home_page.dart:143-159` 只在 `_recording` 和 `_processing` 上做同步检查，然后设置共享 `_recordingRequested = true`、生成 `_opId`，随后等待 `hasPermission()`。
  2. 在第一次 `hasPermission()` 尚未返回时再次调用 `beginRecording()`，第二次调用仍看到 `_recording == false`、`_processing == false`，会覆盖 `_opId` 并继续等待；两次恢复后都可能通过 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/home_page.dart:160-188` 的 `_recordingRequested` 检查并调用 `start()`。
  3. `ChatPage` 使用相同模式，见 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/chat_page.dart:213-251`。`_recordingRequested` 是页面级单布尔值，不绑定请求代际。
- 根本原因：检查和“占用录音启动槽”不是一个同步原子状态；取消标记没有请求 ID/代际，不能区分 A、B 两次启动。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/pages/home_page.dart:46-58,143-201`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/chat_page.dart:40-53,212-269`；底层服务 `/Users/vavavoom/Documents/WatchDog/app/lib/services/audio_service.dart:17-28`。
- 修改方案：增加 `_recordingStartFuture` 或单调递增 generation；只有持有当前 generation 的启动请求可以提交状态，重复 begin 直接返回；finish/cancel 只取消当前 generation，并保证底层 start/stop 串行。补测延迟 permission 下双 begin、双 finish、切页后自动录音与人工录音重叠。
- 修复状态：待处理；本轮只读未修改。
- 验证结果：现有测试直接 `await state.beginRecording(); await state.finishRecording()`，且 `_FakeAudio.hasPermission()` 立即完成，没有覆盖重入时序。

### QCR-004｜严重｜设置自动保存不是原子事务，且计算参数仍允许非法值进入运行时

- 影响范围：气瓶倒计时、提醒/报警阈值、用户修改后的即时运行配置；可能出现 UI 显示“保存失败”但部分设置已生效，或保存 0/负数后计算异常。
- 复现步骤/证据：
  1. `/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:511-533` 按顺序写入服务器、令牌、容量、满压、消耗率，再调用 `Settings.setThresholds()`；当用户输入 `warn=4, alarm=5` 时，`:521` 抛出 `ArgumentError`，此前的服务器/令牌/计算参数已经落库，`modifiedAt` 和 `refreshConfig()` 却不会执行。
  2. 同一方法对容量/满压/消耗率使用 `double.tryParse(...) ?? 默认值`，但不验证 `>0` 和上限；例如输入消耗率 `0` 会被解析为 0 并写入。`/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:261-279` 的本地 setter 也没有范围检查。
  3. 后续 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:554-560` 的离线时长计算使用 `calcConfig.consumptionLpm` 做除数；非法设置可能产生无效时长或异常。阈值 setter 虽在 `/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:288-295` 校验了范围/顺序，但设置页没有围绕非法输入给出字段级反馈或事务回滚。
- 根本原因：自动保存把多个独立持久化写操作串成一次 UI 操作，却没有先整体校验、临时快照/回滚或统一合法值策略；本地 setter 与云端应用校验不一致。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:499-547`；`/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:84-138,261-295`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:529-593`；`/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart:853-902`。
- 修改方案：保存前一次性解析并校验所有字段，非法时不写任何字段并定位错误；或引入可回滚的设置事务。容量、满压、消耗率与阈值共用同一范围常量，云端应用与本地 setter 使用同一校验；保存成功后再刷新 Controller。补测反向阈值、负数、0、超上限、非法文本、保存期间二次编辑和部分写失败。
- 修复状态：待处理；本轮只读未修改。
- 验证结果：现有设置用例只验证消耗率正常值 `55` 失焦保存和屏幕常亮开关；没有非法输入、阈值关系、原子性或并发保存断言。

### QCR-005｜严重｜当前 Flutter 全量测试已失败，新增日志脱敏用例与 UI 可视区域假设不一致

- 影响范围：Flutter CI 质量门禁和本轮最终验收；当前工作区无法满足“Flutter 测试全部通过”。
- 复现步骤/证据：
  1. 在 `/Users/vavavoom/Documents/WatchDog/app` 运行 `flutter test`。
  2. 运行总数为 146，结果为 145 pass、1 fail。
  3. 失败在 `/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart:989-993`：展开 `op-test-1` 后直接要求 `find.text('text_length: 7').hitTestable()`。
  4. 新的 `/Users/vavavoom/Documents/WatchDog/app/lib/services/op_log_service.dart:121-127` 将原始 `text` 改成 `text_length` 和 `text_sha256` 两行；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/op_log_page.dart:324-341` 将数据块追加到步骤内容后。展开后数据块在当前 viewport 外，元素存在但不可命中，因此实际错误是可视性断言，不是缺少脱敏数据的证明。
- 根本原因：测试修改同步更新了期望文本，却没有在展开后 `ensureVisible`/滚动到数据块；测试依赖固定卡片高度。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart:947-1000`；相关生产显示 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/op_log_page.dart:264-359`；脱敏逻辑 `/Users/vavavoom/Documents/WatchDog/app/lib/services/op_log_service.dart:113-139`。
- 修改方案：测试先通过稳定 Key 或 `ensureVisible` 定位数据块，再断言 `text_length`、`text_sha256` 和原文不存在；若需要产品上保证可见性，再由 UI 组评估布局，而不是用 hit-testable 代替存在性断言。
- 修复状态：待处理；本轮明确未修改测试。
- 验证结果：失败可稳定由 `flutter test` 复现；后端测试和 Flutter analyze 不受影响。修复后必须重新运行完整 `flutter test`，并确认用例总数不少于 146。

### QCR-006｜严重｜日志脱敏对 Bearer 令牌和服务端日志入口不完整

- 影响范围：诊断异常、操作日志上传、服务端日志查询；在错误文本包含 HTTP 认证头或旧/非当前客户端提交敏感字段时，令牌可能进入本地日志或云端日志。
- 复现步骤/证据：
  1. `/Users/vavavoom/Documents/WatchDog/app/lib/services/diagnostic_log_service.dart:336-345` 的正则把 `Authorization: Bearer real-secret` 匹配为键值 `Authorization: Bearer`，替换后会留下 `real-secret`；它只按空白分隔符前的一个 token 脱敏，不能识别 Bearer 两段结构。
  2. `/Users/vavavoom/Documents/WatchDog/app/lib/services/op_log_service.dart:103-139` 只对键名匹配 `text/content/message/raw` 的字符串做长度/摘要处理；`msg` 始终原样保存，`data` 中的 `token`、`apiToken`、`authorization`、`password` 等字段不会被清理。
  3. `/Users/vavavoom/Documents/WatchDog/backend/src/server.js:256-270` 的 `logOp()` 直接写入 data；`/Users/vavavoom/Documents/WatchDog/backend/src/server.js:1453-1469` 的 `/api/logs` 接口也直接接受客户端 `msg` 和 `data`，没有服务端最终脱敏/白名单边界。
  4. 现有唯一诊断测试 `/Users/vavavoom/Documents/WatchDog/app/test/diagnostic_log_service_test.dart:6-31` 只覆盖 `api_token=secret-value`，没有 Bearer、嵌套 Map/List、消息字段、服务端入口或旧日志迁移场景。
- 根本原因：脱敏分散在 App 的两个不同日志管道，且服务端信任客户端已脱敏；正则只覆盖简单 `key=value`，没有在最终存储边界再次清理。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/services/diagnostic_log_service.dart:141-179,333-346`；`/Users/vavavoom/Documents/WatchDog/app/lib/services/op_log_service.dart:102-139`；`/Users/vavavoom/Documents/WatchDog/backend/src/server.js:256-270,1441-1475`；`/Users/vavavoom/Documents/WatchDog/app/test/diagnostic_log_service_test.dart`；`/Users/vavavoom/Documents/WatchDog/backend/test/logs.test.js`。
- 修改方案：建立一个递归、字段白名单优先的日志 sanitizer；至少覆盖 `Authorization: Bearer`、`X-Api-Token`、`api_token/apiToken/access_token/password/secret`、嵌套 Map/List、消息和异常文本；服务端 `/api/logs` 入库前再次应用同等策略。对历史本地日志做迁移或清理策略。测试应断言原文 secret 不出现在 `msg/data/error/stack`。
- 修复状态：待处理；本轮只读未修改。
- 验证结果：正则逻辑可直接确认 Bearer 形式会残留第二段 secret；当前测试仅证明简单下划线键值可替换，不能证明日志链路已安全。

### QCR-007｜严重｜发布 tag 不依赖质量门禁，当前已知 Flutter 失败仍可能触发 APK 发布

- 影响范围：GitHub Release、正式签名 APK、OTA 分发；未经后端测试/Flutter analyze/Flutter test 的提交可被打包并发布。
- 复现步骤/证据：
  1. `/Users/vavavoom/Documents/WatchDog/.github/workflows/quality.yml:4-7` 只配置分支 push 和 pull request；tag push 不属于 `branches` 过滤范围。
  2. `/Users/vavavoom/Documents/WatchDog/.github/workflows/release.yml:5-7` 独立监听 `v*` tag，但整个 job 没有 `needs: quality`，也没有 `npm test`、`flutter analyze` 或 `flutter test` 步骤。
  3. 当前工作区已实际复现 `flutter test` 145/146；只要该提交被打 tag，release workflow 仍会进入 `/Users/vavavoom/Documents/WatchDog/.github/workflows/release.yml:55-129` 的构建、签名、ABI 检查和 Release 创建阶段。
- 根本原因：质量 workflow 与发布 workflow 是两个互不依赖的触发/作业图，发布流程只验证构建产物，不验证测试质量门禁。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/.github/workflows/quality.yml`；`/Users/vavavoom/Documents/WatchDog/.github/workflows/release.yml:5-129`。
- 修改方案：抽取可复用 quality job 或在 release job 前运行完全相同的 `backend/npm test`、`app/flutter analyze`、`app/flutter test`；让 release 明确依赖 quality 成功。为 tag、分支和 PR 使用一致的 Flutter/Node 版本，并上传测试摘要。
- 修复状态：待处理；本轮未修改 workflow。
- 验证结果：本机 YAML 语法可解析；未安装 `actionlint`，也未触发远程 Actions。静态 job 图已足以确认当前没有发布前质量依赖。

### QCR-008｜一般｜发布 workflow 未校验 tag、pubspec 和 App 内 fallback 版本一致

- 影响范围：发布资产命名、Release body、OTA 版本比较和下载包内 versionCode；tag 打错或漏改版本时会生成“外部版本名”和“APK 内版本”不一致的发布物。
- 复现步骤/证据：
  1. `/Users/vavavoom/Documents/WatchDog/.github/workflows/release.yml:98-113` 直接从 `GITHUB_REF` 派生 `VERSION`，并用它命名 APK、Release name 和 `versionCode` 文本，没有读取或比较 `app/pubspec.yaml`。
  2. 当前 `/Users/vavavoom/Documents/WatchDog/app/pubspec.yaml:4` 和 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:22-23` 都是 `1.2.0+48`，但 workflow 没有把这个一致性作为自动门禁。
  3. `/Users/vavavoom/Documents/WatchDog/app/lib/services/update_service.dart:30-35,100-107,135-141` 从 tag 的 `+N` 得到 versionCode，并把它传给原生包验证；若 tag 与实际构建包不一致，OTA 可能误判版本或拒绝复用/安装。
- 根本原因：发布元数据以 tag 为唯一来源，构建元数据以 pubspec 为来源，两者之间没有 CI 断言。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/.github/workflows/release.yml:94-119`；`/Users/vavavoom/Documents/WatchDog/app/pubspec.yaml:4`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:22-23`；`/Users/vavavoom/Documents/WatchDog/app/lib/services/update_service.dart:30-141`。
- 修改方案：构建前解析 `pubspec.yaml` 的 version，与去掉 `v` 的 tag 完全比较；同时检查设置页 fallback 常量，或移除该重复常量并只使用运行时 package info。增加错误 tag、缺少 `+N`、versionCode 不一致的 CI 用例。
- 修复状态：待处理；本轮未修改。
- 验证结果：当前版本字符串静态一致，但未发现 workflow 的一致性校验；属于流程能证明的缺口而非当前 tag 已错的断言。

## 4. 关键路径覆盖复核

### 已有证据

- 后端进退场、警情隔离、单位认证、Token 中间件、日志 CRUD、用户设置、解析 guardrail 和数据库就绪测试均通过 102/102。
- Flutter 本地 parser、姓名 parser、日志分类、SSE parser、OTA 清单解析、页面展示/导航/部分窄屏布局有较多 Widget/纯逻辑覆盖。
- 新增认证浮层有 2 个 UI 用例；新增日志脱敏有 1 个间接 Widget 断言；新增 OTA 解析有多组纯函数用例。

### 仍缺失或被替身绕开的关键路径

- 没有 App `AppController.authenticate()` + `ApiClient.verifyUnit()` 的真实请求头/持久化/成功后首个受保护请求集成测试。
- 没有延迟 permission、延迟 recorder start、双 begin/双 finish、start 抛异常、dispose 期间录音的测试。
- 没有设置反向阈值、负数/0/超上限、非法文本、保存期间第二次编辑及部分写失败测试。
- 没有覆盖 `DiagnosticLogService` 的 Bearer/nested/list 脱敏，也没有服务端 `/api/logs` 最终入库脱敏测试。
- `widget_test.dart` 的 `_FakeController.startSync/sync` 是空实现（`/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart:64-68`），`_FakeAudio` 权限始终 true、启动不失败（`:333-347`），因此不能证明真实同步、报警、录音插件链路。
- 现有 `update_service_test.dart` 主要验证解析器和缓存逻辑，未在真实 release workflow 语境验证 tag/pubspec/包内 versionCode/签名/ABI 一致性。

## 5. 最终验收清单

当前状态：未通过。以下项目必须在修复后重新核验：

- [ ] 认证成功只在正确令牌和首个受保护业务请求均成功后切换门禁；错误 token 可回到认证浮层并可重试。
- [ ] 录音启动/停止状态机对早松手、重复长按、权限拒绝、插件异常、页面销毁均无双启动、幽灵录音或临时文件泄漏。
- [ ] 设置输入先整体校验，阈值满足 `0 ≤ alarm ≤ warn ≤ 1440`，容量/满压/消耗率满足统一安全范围；非法输入不产生部分写入。
- [ ] 日志中不出现 bearer/API token/password/secret 原文；App 本地、上传 payload、服务端入库和异常栈均有测试证据。
- [ ] `/Users/vavavoom/Documents/WatchDog/backend` 的 `npm test` 全部通过，且用例数不少于当前 102。
- [ ] `/Users/vavavoom/Documents/WatchDog/app` 的 `flutter analyze` 为 0 问题。
- [ ] `/Users/vavavoom/Documents/WatchDog/app` 的 `flutter test` 全部通过，且用例数不少于当前 146；QCR-005 必须消除。
- [ ] release tag 必须先通过同一套后端/App 质量门禁；签名、arm64 ABI、SHA256 和 Release asset 检查继续通过。
- [ ] release tag、`app/pubspec.yaml`、运行时 package version 和 App fallback 常量一致。
- [ ] 重新检查 README 与 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/about_page.dart` 的实质变更同步关系。
- [ ] `git status`/`git diff` 只保留本轮相关改动；无密钥、真实数据、构建产物或临时调试文件进入版本控制。

## 6. 建议的交叉复核项目

1. 后端/安全组复核 QCR-001 与服务端 `/api/auth/verify` 的令牌语义：明确“单位验证码”和“API_TOKEN”是否应在同一事务完成，补一条错误 token 的 App-to-API 测试。
2. Flutter 功能组与测试组共同用可控 fake recorder/permission 编写 QCR-002、QCR-003 的时序测试，再由性能组检查重复 start/stop、文件句柄和页面销毁后的回调。
3. 设置页由功能组实现统一 validator，测试组以表格覆盖合法边界、非法边界、自动保存并发和云端设置合并；后端组同步复核服务端 user-settings 白名单与范围。
4. 安全组定义唯一 sanitizer 契约，App 与后端各自测试同一组 secret fixtures；日志页 UI 只验证脱敏字段展示，不依赖固定 viewport 高度。
5. 测试/工程组把质量 job 接入 release 依赖，增加 tag/pubspec/versionCode 一致性断言，并在可用环境运行 `actionlint`/GitHub Actions dry-run。
6. 最终验收时由主 Agent 重新运行后端、Flutter analyze、Flutter test，必要时执行 arm64 release build 和 Android 真机关键流程：首次认证、错误 token 重试、长按录音、松手、断网设置保存、报警阈值边界和 OTA 校验。
