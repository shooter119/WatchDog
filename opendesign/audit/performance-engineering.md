# WatchDog 性能与工程质量组只读审查

审查日期：2026-08-27
审查范围：`app/`、`backend/`、`deploy/`、Android/CI 构建与依赖配置。
审查角色：性能与工程质量组。
审查约束：只读审查；除本文件外不修改源码、测试、依赖、部署配置，不执行 commit、push、部署或发版。

## 1. 方法与基线

- 已先阅读项目根目录 `AGENTS.md`、`README.md`，并检查 Flutter、Node、Android Gradle、GitHub Actions、部署脚本和 `opendesign/audit/` 目录。
- 静态证据使用仓库当前工作区内容和 `nl -ba` 行号；动态检查只执行低风险的测试、分析、构建、依赖检查和 diff 检查。
- 当前工作区在本审查开始前已有未提交改动；本轮不覆盖或清理这些改动。
- 审查发现按 `PE-xxx` 编号。状态为“已确认，待修复”表示本轮按只读要求没有实施源码修复；“已确认维护风险”表示有明确工程证据但不等同于线上功能缺陷；未验证项单独列出，不计入已确认缺陷。

### 1.1 已执行验证

| 检查 | 命令/位置 | 结果 |
|---|---|---|
| 后端单测 | `cd backend && npm test` | 退出码 0；`tests 102`、`pass 102`、`fail 0`；有 Node experimental SQLite warning |
| Flutter 静态分析 | `cd app && flutter analyze` | 退出码 0；`No issues found! (ran in 1.1s)` |
| Flutter 测试 | `cd app && flutter test` | 退出码 0；全部通过，最终 `+146` |
| Release 构建 | `cd app && flutter build apk --release --no-pub` | 退出码 0；生成 `app-release.apk`，Flutter 输出约 `133.2MB` |
| 依赖新旧检查 | `cd app && flutter pub outdated` | 退出码 0；`11 upgradable dependencies are locked`、`7 dependencies are constrained`、`1 package is discontinued` |
| diff 空白检查 | `git diff --check` | 退出码 0；无输出 |
| 产物签名 | Android SDK `apksigner verify --print-certs` | 当前本地 release APK 有 WatchDog release 证书；未读取或输出私钥内容 |
| 产物 ABI | 对生成 APK 执行 `unzip -l`/库文件统计 | APK `133836551 bytes / 382 files`，包含 `arm64-v8a`、`armeabi-v7a`、`x86_64` 三种 ABI |

说明：项目约定中记录的历史用例数为后端 71、App 70；当前工作区实际为后端 102、App 146，属于当前已有改动后的基线。本审查没有减少测试用例。

## 2. 已确认问题台账

### PE-001：录音没有客户端时长/大小上限，转写链路对整段音频做多次内存复制

- 严重程度：一般
- 影响范围：App 录音内存峰值、ASR 解码耗时与卡顿、后端并发转写时的 Node 进程内存；长时间按住录音或多设备并发时风险放大。
- 复现/证据：
  - `app/lib/services/audio_service.dart:15-25` 只设置 16kHz、单声道 WAV，没有最大时长或字节数限制。
  - `app/lib/services/audio_service.dart:36-47` 在停止后通过 `readAsBytes()` 一次性读取整个 WAV。
  - `app/lib/services/local_asr_service.dart:304-315` 将 `Uint8List` 解析为 `Float32List`；后续 ASR/降噪还会建立处理用的样本缓冲。
  - `backend/src/server.js:642-655` 先把请求 chunks 全部放入数组，再通过 `Buffer.concat(chunks)` 形成完整音频；仅有 15MB 服务端上限，客户端没有对应的提前终止机制。
  - 低风险静态命令：`nl -ba app/lib/services/audio_service.dart | sed -n '15,50p'`、`nl -ba backend/src/server.js | sed -n '637,656p'` 可直接得到上述行。
- 根本原因：音频设计是“文件录音 → 整文件读入 Dart → PCM 浮点转换/降噪 → 整请求在 Node 缓冲”，没有统一的时长、大小、并发和流式内存预算。
- 涉及文件：`app/lib/services/audio_service.dart`、`app/lib/services/local_asr_service.dart`、`backend/src/server.js`。
- 修改方案：在 App 录音层增加最大时长/字节预算并在超限时自动停止、明确提示；服务端在读取前后都做有界校验并限制并发；条件允许时改为分片/流式转写或避免重复复制；为长录音、超限、并发上传补充测试和峰值内存指标。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：现有测试、analyze 和 release 构建均通过，但没有证明长录音和并发上传的内存峰值安全。

### PE-002：录音停止异常时临时 WAV 不一定清理

- 严重程度：一般
- 影响范围：设备临时目录长期积累录音文件；插件停止失败、文件不存在或读取失败时尤其明显。
- 复现/证据：`app/lib/services/audio_service.dart:36-47` 只有在 `_recorder.stop()`、`exists()` 和 `readAsBytes()` 全部成功后才进入 `file.delete()`；其中任一步抛错都会跳过删除。`dispose()` 位于 `:50`，只释放 recorder，没有按当前 `_path` 停止并删除活动录音。
- 根本原因：清理逻辑不是 `finally`，且录音路径状态与 recorder 生命周期没有统一的失败收口。
- 涉及文件：`app/lib/services/audio_service.dart`。
- 修改方案：用 `try/finally` 包围停止、读取和删除；失败时仍尝试停止 recorder、删除 `.wav`；`dispose()` 对活动录音执行可取消的清理，并使清理操作幂等。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：静态控制流可稳定确认；尚未做真实文件 I/O/plugin stop 失败注入测试。

### PE-003：页面在异步启动录音后被卸载时可能遗留活动录音

- 严重程度：一般
- 影响范围：页面切换、系统返回、权限弹窗或后台切换期间的麦克风占用、录音文件和后续录音状态。
- 复现/证据：
  - `app/lib/pages/home_page.dart:172-179` 在 `await _audio.start()` 返回后，如果 `!mounted`，直接 `return`，没有 stop/cancel。
  - `app/lib/pages/chat_page.dart:237-241` 有同样分支。
  - 这两个分支均位于资源启动的异步边界之后，属于从代码逻辑可确定的生命周期缺口。
- 根本原因：组件 mounted 状态只用于防止 `setState`，没有把已启动的资源纳入卸载清理协议。
- 涉及文件：`app/lib/pages/home_page.dart`、`app/lib/pages/chat_page.dart`、`app/lib/services/audio_service.dart`。
- 修改方案：组件 dispose/unmounted 分支统一取消振幅订阅并停止/删除活动录音；AudioService 增加可查询的 active 状态和幂等 abort；为 start 延迟后 dispose 的 widget 测试补回归用例。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：现有 Flutter 测试通过，但没有覆盖该异步卸载时序。

### PE-004：主 isolate 与前台服务同时以 5 秒频率轮询，并强制持有唤醒锁/Wi-Fi 锁

- 严重程度：一般
- 影响范围：Android 电量、移动网络流量、后端请求量和设备长期运行稳定性；也存在重复解析和重复状态维护。
- 复现/证据：
  - `app/lib/state/app_controller.dart:344-355` 启动 5 秒 `_pollTimer`，并立即调用 `sync()`。
  - `app/lib/state/app_controller.dart:357-391` 每轮依次执行离线队列、警情、当前警情、entries、notes、forces 等同步工作。
  - `app/lib/services/foreground_keep_alive.dart:44-50` 配置 `repeat(5000)`、`allowWakeLock: true`、`allowWifiLock: true`。
  - `app/lib/services/foreground_keep_alive.dart:121-167` 在独立 isolate 中再次每 5 秒刷新看板。
  - 两套循环的责任重叠：主 isolate 更新 App 状态，服务 isolate 又独立请求 `/api/entries?active=1` 更新通知栏。
- 根本原因：前台展示同步和后台常驻通知采用两个独立 scheduler，没有共享结果、生命周期策略或退避策略。
- 涉及文件：`app/lib/state/app_controller.dart`、`app/lib/services/foreground_keep_alive.dart`。
- 修改方案：设计单一轮询源；前台活跃时服务只消费主 isolate/共享缓存，后台时才启用服务轮询；根据 App 生命周期、网络状态和告警状态调整频率；仅在确需保活时持有锁；记录请求量、电量和失败率后再确定默认周期。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：静态调用关系确认重复轮询；无真机电量或后台进程 profile，因此实际耗电量未量化。

### PE-005：前台服务 5 秒回调没有 in-flight 闸门，慢请求会重叠

- 严重程度：一般
- 影响范围：弱网下服务 isolate 中同时存在多个 HTTP 请求，增加网络、CPU、JSON 解析和通知更新压力；可能造成结果乱序。
- 复现/证据：
  - `app/lib/services/foreground_keep_alive.dart:164-168` 的 `onRepeatEvent` 每次直接 `unawaited(_refresh())`。
  - `app/lib/services/foreground_keep_alive.dart:176-186` 单次请求 timeout 为 8 秒，而回调周期为 5 秒；代码没有 `_refreshing` 或串行队列判断。
  - 因此只要请求持续 5 秒以上，下一次回调就会启动第二个请求。
- 根本原因：fire-and-forget 调度没有和请求生命周期绑定。
- 涉及文件：`app/lib/services/foreground_keep_alive.dart`。
- 修改方案：增加 `_refreshing` 状态并在 `try/finally` 释放，或使用串行任务队列；超时后设置退避而不是固定重试；增加延迟 HTTP 的测试验证同一时刻最多一个刷新。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：由周期 5 秒与 timeout 8 秒的静态逻辑直接确认；没有修改插件代码或运行真实后台服务。

### PE-006：每秒阈值 tick 会触发包含全部页面的 AnimatedBuilder/IndexedStack 重建

- 严重程度：优化
- 影响范围：主线程每秒重建 Notes、Board、Home、Chat、Settings 五个页面子树；在低端 Android、录音振幅动画或列表较大时可能增加帧耗时和 GC。
- 复现/证据：
  - `app/lib/state/app_controller.dart:349-353` 每秒执行 `_checkThresholds()` 后无条件 `notifyListeners()`。
  - `app/lib/main.dart:223-255` 根 `AnimatedBuilder` 监听整个 controller，每次通知都会重新创建五个页面并构造 `IndexedStack` children。
- 根本原因：阈值计时、网络同步、页面数据共用一个粗粒度 ChangeNotifier 广播；没有 selector 或按字段拆分订阅。
- 涉及文件：`app/lib/state/app_controller.dart`、`app/lib/main.dart` 及相关页面。
- 修改方案：将倒计时/告警 tick 与页面数据状态拆分；仅在可见且发生实际 UI 变化时通知；采用 selector/局部 `ValueListenableBuilder`；保留告警计算但避免每秒让全部页面重建；用 Flutter DevTools frame timeline 和 profile APK 验证。
- 修复状态：已确认的静态效率问题，待修复（本轮只读）。
- 验证结果：analyze/test 通过；没有设备帧时间数据，实际卡顿程度未量化。

### PE-007：5 秒同步会触发警情列表的归档写操作和逐警情 forces 查询

- 严重程度：一般
- 影响范围：后端 SQLite/PostgREST 查询写入次数、移动网络延迟和轮询耗时；警情数量增加后线性放大。
- 复现/证据：
  - `app/lib/state/app_controller.dart:348` 每 5 秒触发轮询，`:362` 每轮调用 `fetchIncidents`。
  - `backend/src/server.js:290-294` `/api/incidents` 每次请求先执行 `db.archiveStaleIncidents()`，再对 `listIncidents()` 的每条记录调用 `incidentView`。
  - `backend/src/server.js:268-277` `incidentView` 对每条警情执行 `db.listIncidentForces(incident.id)`，形成逐警情查询；缺标题的归档记录还会额外调用建议标题逻辑。
- 根本原因：维护任务放在高频读接口中，且列表响应采用 per-incident 查询而不是聚合/批量查询。
- 涉及文件：`app/lib/state/app_controller.dart`、`backend/src/server.js`、对应数据库 repository 文件。
- 修改方案：将过期归档迁移到定时任务或带时间闸门的后台任务；列表接口使用批量 forces 汇总/联表；只在数据或生命周期允许时轮询；增加警情数量与响应时延的基准测试。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：静态调用链确认额外工作；现有单测通过，但没有生产警情规模和 PostgREST latency 数据。

### PE-008：操作日志上传成功时会清空上传期间新追加的日志

- 严重程度：一般
- 影响范围：操作追踪和问题诊断事件丢失；在同步请求较慢时更容易发生。
- 复现/证据：
  - `app/lib/services/op_log_service.dart:102-110` `record()` 可在任何时刻向 `_pending` 追加。
  - `app/lib/services/op_log_service.dart:121-127` 上传时把当前 `_pending` 转成请求，等待 `sendLogs()` 返回后直接 `_pending.clear()`。
  - 可稳定构造：令 `_pending=[A]`，让 `sendLogs([A])` 延迟；期间调用 `record(B)`；请求成功后 `clear()` 同时删除未上传的 B。
- 根本原因：上传没有固定批次快照和按事件 ID/对象身份确认删除，成功操作作用于整个可变队列。
- 涉及文件：`app/lib/services/op_log_service.dart`。
- 修改方案：上传前取批次快照并从队列中仅移除已确认的那一批；为事件增加稳定 ID 或按对象身份移除；补充 deferred API 回归测试。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：代码逻辑可稳定复现；现有 Flutter 测试没有覆盖上传期间追加日志的竞态。

### PE-009：诊断日志上传成功时会删除上传期间新写入的整个 pending 文件

- 严重程度：一般
- 影响范围：诊断异常在上传窗口内发生时被静默删除，降低线上故障定位能力。
- 复现/证据：
  - `app/lib/services/diagnostic_log_service.dart:182-197` 初始化并等待当前写队列后读取文件，等待 `api.sendLogs(events.take(...))`。
  - `app/lib/services/diagnostic_log_service.dart:218-227` 新事件可以在 `_writeQueue` 中追加到同一个 pending 文件。
  - `app/lib/services/diagnostic_log_service.dart:197-198` 上传成功后无条件 `file.delete()`，会删除发送开始后追加的事件。
  - 可稳定构造：延迟 `sendLogs`，期间调用记录诊断事件，返回成功后观察 pending 文件整体删除。
- 根本原因：文件上传没有原子 claim/rename，也没有把删除范围限制到已经读取的批次。
- 涉及文件：`app/lib/services/diagnostic_log_service.dart`。
- 修改方案：flush 前原子 rename/claim 一个批次文件；新事件写入新文件；仅在批次成功后删除已 claim 文件，失败则合并或保留；增加并发写入回归测试。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：静态控制流确认；现有测试未覆盖 flush 与 append 并发。

### PE-010：操作日志每条事件都触发完整 SharedPreferences JSON 持久化

- 严重程度：优化
- 影响范围：高频录音、网络同步和页面操作期间的磁盘写入、JSON 序列化与后台 Future 数量；日志上限虽有界，但每次写都序列化整个本地日志列表。
- 复现/证据：`app/lib/services/op_log_service.dart:102-110` 每次 `record()` 都调用 `_persist()`；`:144-148` 每次重新获取 SharedPreferences 并 `jsonEncode(_logs.map(...))` 后写入完整日志集合。
- 根本原因：持久化策略按事件触发，没有 debounce、串行写队列或增量文件格式。
- 涉及文件：`app/lib/services/op_log_service.dart`。
- 修改方案：用串行 debounce（例如短窗口合并多次写入），应用生命周期暂停/后台时强制 flush；必要时改用有界 JSONL/SQLite；保留掉电恢复测试并测量写入频率。
- 修复状态：已确认的工程效率问题，待修复（本轮只读）。
- 验证结果：静态证据明确；未在真实设备测量 I/O 和电量影响。

### PE-011：聊天限流 Map 对唯一 client key 无过期淘汰

- 严重程度：一般
- 影响范围：长时间运行的 Node 进程内存持续增长；攻击者或大量临时设备 ID/IP 可制造 key 数量，最终造成 GC 压力。
- 复现/证据：
  - `backend/src/server.js:768-780` `chatRateBuckets` 是进程级 `Map`，新 minute 只替换同一个 key 的 bucket，没有定时清理、容量上限或 LRU。
  - `backend/src/server.js:119-121` `deviceKey` 接收最多 128 字符的客户端 header；`:793-801` 以 device ID、IP 或 anonymous 作为 key。
  - 对每个新 key 调用一次 `chatRateLimited()` 即会永久留下一个 Map entry，静态逻辑可确认无界增长。
- 根本原因：单实例内存限流只实现了计数，没有实现 bucket 生命周期管理。
- 涉及文件：`backend/src/server.js`。
- 修改方案：按时间周期清理旧 bucket，并设置最大 key 数量/LRU；多实例部署使用受控的共享限流存储；记录 key 数量、拒绝率和清理结果。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：Node 单测通过，但没有长时间或恶意唯一 key 压测。

### PE-012：SSE 客户端断连没有取消上游 DeepSeek 流

- 严重程度：一般
- 影响范围：移动端取消/断网后，后端可能继续占用上游连接、读取 token 和 CPU，直到上游结束或 60 秒超时；并发流式请求时资源浪费。
- 复现/证据：
  - `backend/src/server.js:823-854` 流式接口在 `for await` 中持续向 `res.write()`，没有 `req/res` close/aborted 处理或 AbortController 传递。
  - `backend/src/parse.js:259-275` 上游 fetch 只使用固定 `AbortSignal.timeout(60000)`，没有来自下游连接的取消信号。
  - `backend/src/parse.js:281-303` 会持续读取上游 reader，直到上游结束、超时或异常。
- 根本原因：下游 HTTP 生命周期与上游 fetch/reader 生命周期解耦。
- 涉及文件：`backend/src/server.js`、`backend/src/parse.js`。
- 修改方案：为每个 SSE 请求创建 AbortController，在 `req`/`res` close 或 aborted 时 abort 上游；停止写入并释放 reader；增加客户端断连的集成测试和活动上游请求指标。
- 修复状态：已确认资源取消缺口，待修复（本轮只读）。
- 验证结果：静态证据确认缺少取消绑定；未执行真实上游请求或断连压测。

### PE-013：后端操作日志批量上报被逐条串行写入数据库

- 严重程度：优化
- 影响范围：一次最多 100 条日志会产生最多 100 次顺序数据库请求；PostgREST/云网络延迟直接累积，挤占同步与主业务请求。
- 复现/证据：
  - `backend/src/server.js:1275-1304` 接受最多 100 条日志后，在 `for (const item of logs)` 中逐条 `await db.addLog(...)`。
  - `backend/src/db-postgres.js:191-196` `addLog()` 每次调用 `insertOne('logs', ...)`，即单独一次写请求。
- 根本原因：客户端虽有批量协议，repository 层仍采用单行串行写入，没有 bulk insert/事务/RPC。
- 涉及文件：`backend/src/server.js`、`backend/src/db-postgres.js`、SQLite repository 对应实现。
- 修改方案：在数据库适配层增加批量插入接口；PostgREST 使用 bulk payload 或服务端 RPC，SQLite 使用事务；明确部分失败和幂等语义，并以 100 条日志基准测试验证。
- 修复状态：已确认的网络/数据库效率问题，待修复（本轮只读）。
- 验证结果：后端 102 个测试全部通过；没有对云端 PostgREST 做延迟基准或故障注入。

### PE-014：本地 ASR 模型下载请求没有连接/整体超时

- 严重程度：一般
- 影响范围：首次安装或重新下载模型时，网络半连接或服务端不再发送数据会让设置页长期处于下载状态，阻塞用户获得离线语音能力。
- 复现/证据：
  - `app/lib/services/local_asr_service.dart:117-163` 为每个模型文件建立 `http.Client` 并 `await client.send(request)`，随后直接 `await for (final chunk in res.stream)`。
  - 该段没有 `Future.timeout`、空闲读取超时、取消 token 或整体 deadline；重试数组 `:123-126` 只是同一 URL 重试两次，不能处理永久挂起的请求。
- 根本原因：下载重试实现只关注异常，不区分连接、首字节、空闲和整体超时，也没有把下载任务与页面生命周期取消绑定。
- 涉及文件：`app/lib/services/local_asr_service.dart`。
- 修改方案：增加连接/首字节/空闲/整体超时和取消；保留 `.part` 的安全清理与必要的断点续传；对每个文件显示可恢复状态，模型下载失败应可重试而不永久占用任务。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：静态代码确认没有超时；没有搭建可控慢响应服务器做运行验证。

### PE-015：告警循环启动 Future 未处理异常，失败后可能永久卡在 looping 状态

- 严重程度：一般
- 影响范围：告警音启动失败时，后续阈值 tick 可能不再重试，且异常缺少用户反馈/结构化诊断；属于资源生命周期和关键异常监控风险。
- 复现/证据：
  - `app/lib/state/app_controller.dart:463-468` 直接调用 `alarm.startAlarmLoop()`/`alarm.stopAlarm()`，未 await、未使用带错误处理的 `unawaited`。
  - `app/lib/services/alarm_service.dart:235-246` 先将 `_looping = true`，再依次 await 音量、player mode、source、release mode 和 resume；方法内部没有 try/catch/finally 将 `_looping` 恢复为 false。
  - 任一步 native audio 操作抛错时，`_looping` 可保持 true，下一次调用在 `:238-239` 直接返回。
- 根本原因：异步告警状态在资源初始化成功前就提交，且调用方丢弃 Future 错误。
- 涉及文件：`app/lib/state/app_controller.dart`、`app/lib/services/alarm_service.dart`。
- 修改方案：只有资源准备成功后再提交 looping 状态；失败时在 finally 回滚并记录可观测事件；调用方使用 `unawaited(...catchError(...))` 或统一报警任务队列；为 native player 抛错补测试。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：analyze 未报告该 Future 生命周期问题；没有真实音频设备故障注入。

### PE-016：构建配置声称仅 arm64，但实际 release APK 包含三种 ABI，且 CI 文件名会误导产物使用者

- 严重程度：一般
- 影响范围：APK 下载体积、安装存储、发布渠道识别和交付文档；当前 APK 含有 `armeabi-v7a`、`arm64-v8a`、`x86_64` 的 native 库，增加约几十 MB 的无用内容。
- 复现/证据：
  - `app/android/app/build.gradle.kts:50-55` 在 release 中设置 `abiFilters += listOf("arm64-v8a")`，注释明确目标是正式包仅保留真机架构。
  - 实际命令 `cd app && flutter build apk --release --no-pub` 成功生成约 133.2MB APK；对该 APK 统计得到 `arm64-v8a`、`armeabi-v7a`、`x86_64` 三个 ABI，且 `libonnxruntime.so` 分别约 21.7MB、15.0MB、25.0MB。
  - `.github/workflows/release.yml:78-86` 直接把同一个 `app-release.apk` 复制为 `watchdog-${VERSION}-arm64-v8a.apk`，没有校验 APK 内容是否真的只有 arm64。
- 根本原因：当前 Flutter/插件打包链路没有使该 release ABI filter 生效，CI 又把 universal APK 以 arm64 文件名发布，缺少产物结构门禁。
- 涉及文件：`app/android/app/build.gradle.kts`、`.github/workflows/release.yml`，以及影响 native 打包的 Flutter/plugin 配置。
- 修改方案：先确认 Flutter 与 `sherpa_onnx` 的 ABI 打包策略，再采用经验证的 split-per-ABI 或正确覆盖过滤器；CI 对 APK `lib/<abi>/` 做断言，名称和实际内容一致；用下载大小和真机安装回归验证。
- 修复状态：已确认，待修复（本轮只读）。
- 验证结果：release 构建通过，但产物检查与配置意图矛盾；当前本地签名证书有效，不把签名本身列为缺陷。

### PE-017：依赖存在已锁定升级、约束落后和 discontinued 包，增加维护与构建风险

- 严重程度：优化
- 影响范围：安全修复和性能改进不能及时进入；旧 API/构建工具兼容窗口缩小；`flutter_markdown` 已 discontinued，后续 Flutter/Dart 升级风险增加。
- 复现/证据：
  - `app/pubspec.yaml:12-27` 直接依赖包含 `record`、`audioplayers`、`flutter_foreground_task`、`flutter_local_notifications`、`sherpa_onnx`、`flutter_markdown` 等关键运行库；`:41-43` 还有 vendored `package_info_plus` override。
  - `cd app && flutter pub outdated` 退出码 0，报告 `11 upgradable dependencies are locked`、`7 dependencies are constrained to versions older than a resolvable version`，并报告 `flutter_markdown 0.7.7+1` discontinued、建议 `flutter_markdown_plus`。
- 根本原因：依赖约束与 lockfile 长期冻结，且有本地 override；升级需要结合 Android、音频、ASR 和通知插件一起验证，因此没有自动跟进。
- 涉及文件：`app/pubspec.yaml`、`app/pubspec.lock`、`app/third_party/package_info_plus/` 及相关插件使用代码。
- 修改方案：建立依赖升级矩阵，优先处理 discontinued、安全和 native 运行库；逐项升级并跑完整测试、analyze、release APK 和真机语音/通知回归；确认 vendor override 的上游修复后再移除。
- 修复状态：已确认维护债务，待排期（本轮只读）。
- 验证结果：依赖报告可复现；当前测试、分析和构建均通过，不能据此证明升级不会破坏行为。

### PE-018：后台/增强能力的异常大量静默吞掉，缺少性能与资源指标

- 严重程度：优化
- 影响范围：网络失败、降噪器初始化失败、诊断上传失败等无法区分“预期降级”和“持续资源异常”；轮询、音频、模型和告警的性能退化难以定位。
- 复现/证据：
  - `app/lib/services/foreground_keep_alive.dart:222-224` 网络异常直接静默等待下周期。
  - `app/lib/services/local_asr_service.dart:296-298` 降噪器加载异常静默跳过。
  - `app/lib/services/diagnostic_log_service.dart:199-200` 诊断上传失败静默保留文件。
  - 这些路径没有统一的计数器、耗时、队列长度、当前请求数、音频时长/字节数或模型加载耗时指标。
- 根本原因：错误处理以“不影响核心流程”为目标，但没有区分可接受降级、可重试故障和资源泄漏/持续失败。
- 涉及文件：上述三个 service，以及统一日志/诊断基础设施。
- 修改方案：增加低开销结构化指标和采样日志（去除敏感内容），记录轮询耗时/失败连续次数、音频大小与 ASR 时延、模型下载状态、告警启动失败、pending 队列长度；为持续失败增加退避和一次性用户反馈。
- 修复状态：已确认的可观测性缺口，待修复（本轮只读）。
- 验证结果：静态路径确认；没有线上监控数据，无法量化故障发生率。

## 3. 未验证项（不计入已确认缺陷）

以下项目有审查价值，但本轮没有足够的运行证据，因此只列为未验证风险，不按缺陷宣布：

| 编号 | 未验证项 | 需要的证据/下一步 |
|---|---|---|
| UV-001 | 真机启动耗时、首屏帧、每秒 tick 的实际 frame time、内存峰值、后台电量和唤醒次数 | Android profile/release 真机 + Flutter DevTools timeline、Memory、Battery Historian 或等效数据 |
| UV-002 | `sherpa_onnx` native recognizer/denoiser 在识别、模型删除、热词重载并发时是否发生 native use-after-free 或崩溃 | 受控 Android 集成测试；禁止在没有隔离和备份的情况下直接删除用户模型 |
| UV-003 | App 的 HTTP 连接池复用、CloudBase 网关延迟、弱网重试及后端 5 秒轮询在真实设备群上的吞吐 | 预生产压测、请求耗时分位数、连接数、超时率和 CloudBase 运行指标 |
| UV-004 | `/api/offline-ops` 多操作批次在中途数据库失败时的部分提交、一致性和幂等性 | 数据库故障注入；需要后端/架构组确认事务边界和核心业务规则后再改 |
| UV-005 | release 构建在缺少 `app/android/key.properties` 时是否会被 CI 可靠阻断 | 当前本地 key/keystore 存在且 APK 已验证为 release 证书；CI 有 fingerprint 校验，但未模拟缺失 secret 的完整 Actions 运行 |
| UV-006 | `android/gradle.properties:1` 的 `-Xmx8G`、4G Metaspace 和 512M code cache 是否造成 CI/开发机资源争用 | 在目标 runner 和最低配置开发机采集 Gradle RSS、构建时长、OOM/交换情况 |
| UV-007 | HTTP client、音频 recorder、通知/播放器插件在真实系统杀进程、权限撤销、蓝牙/电话打断和页面销毁时的释放行为 | Android 设备矩阵的生命周期与权限集成测试 |
| UV-008 | 热词、警情、日志数量达到业务上限之外时，列表 payload 和本地 JSON/文件轮转的增长曲线 | 明确业务容量上限后做数据规模基准和压力测试；不能用当前小样本测试替代 |

## 4. 交叉复核与验收结论

- 后端测试、Flutter analyze、Flutter 测试和 release 构建在当前基线上均通过；这证明当前改动没有被基础验证立即阻断，不代表上述静态问题已修复。
- 发现之间的主要交叉关系已合并：PE-004/005/006/007 共同覆盖轮询放大链路；PE-001/002/003 共同覆盖录音资源生命周期；PE-008/009 共同覆盖上传批次竞态；PE-016/017 覆盖构建产物与依赖工程质量。
- 本轮未修改源码，因此不存在由本审查引入的高优先级代码回归；但 PE-001、PE-004、PE-005、PE-007、PE-011、PE-012、PE-015、PE-016 仍需要修复或验证，不能据此宣布性能与工程质量验收通过。
- 建议下一轮顺序：先修复录音生命周期/内存边界和双轮询并发，再修复日志批次竞态、聊天流取消与限流淘汰，随后处理列表 N+1、批量写入、模型下载超时和 ABI 产物门禁；每轮修改后重新执行 AGENTS.md 要求的后端/App 全量验证，并补充真机与预生产数据。
