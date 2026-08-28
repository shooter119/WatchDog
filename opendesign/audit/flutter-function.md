# WatchDog Flutter App 功能组只读审计

审计日期：2026-08-27
审计范围：`app/lib`、`app/test`、Android 配置、`app/pubspec.yaml` 及其对后端接口的必要契约核对。
审计方式：静态调用链/状态机核查、现有测试执行、Flutter analyze、Android debug 构建。
修改边界：本轮只新建本审计文件，未修改源码、测试、依赖或部署文件。

## 总体结论

发现 21 项有代码或运行证据支持的问题：严重 10 项、一般 8 项、优化 3 项；未将未能由代码/测试/运行结果确认的猜测列入。当前测试和构建本身通过，但现有测试没有覆盖离线状态恢复、失效认证、异步录音启动竞态、通知调度失败重试、设置并发保存等关键边界。

## 问题台账

### FLT-001｜严重｜长按结束早于异步录音启动时，松手后仍可能开始录音

- 影响范围：从日志、看板、设置页切换到语音页的长按录音；Android 首次麦克风授权或录音启动较慢时尤其明显，存在非预期录音和语音流程卡住风险。
- 复现步骤/证据：
  1. 在非语音页长按底部语音按钮；`/Users/vavavoom/Documents/WatchDog/app/lib/main.dart:147-163` 先切页并异步调用 `HomePage.beginRecording()`。
  2. 在权限请求或 `AudioService.start()` 完成前松手；`/Users/vavavoom/Documents/WatchDog/app/lib/main.dart:166-172` 立即调用 `finishRecording()`。
  3. 此时 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/home_page.dart:193-194` 因 `_recording` 尚未置为 true 直接返回；原来的 `beginRecording()` 随后在 `:155-176` 完成并把 `_recording` 置为 true，没有任何待停止标记。
- 根本原因：录音状态只在两个异步 await 完成后建立，手势结束没有记录为取消请求；页面切换还额外引入了 `autoRecord` 的异步启动窗口。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/main.dart:147-172`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/home_page.dart:141-176`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/chat_page.dart:211-241`。
- 修改方案：引入录音启动代际/取消状态；手势结束时若仍在启动则标记取消，启动完成后立即停止并清理文件；页面切换和权限弹窗场景统一走同一状态机。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：静态状态转移可确认；现有 146 个 Flutter 测试未覆盖“延迟启动后松手”的场景。

### FLT-002｜严重｜压力复核和出场成功/入队后不更新本地 entries，可能继续报警或显示仍在场

- 影响范围：看板、详情页、每秒阈值检查、压力复核弹窗和手动出场；断网时必现，在线请求成功但随后同步失败时同样发生。
- 复现步骤/证据：
  1. 断网后更新压力。`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:574-585` 将操作入队并把返回值设为旧的 `current`，没有替换 `entries` 或 `notifyListeners()`。
  2. 断网后登记出场。`:591-605` 只入队 `exit`，同样不修改对应 `Entry` 的 `exitedAt`。
  3. `/Users/vavavoom/Documents/WatchDog/app/lib/pages/report_pressure_sheet.dart:254-264` 在没有异常时关闭弹窗；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/entry_detail_page.dart:41-57` 继续播报“已登记出火场”。但 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:443-467` 仍按旧 active entry 检查并启动报警循环。
  4. 即使在线 PATCH/exit 已成功，只要后续 `sync()` 在 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:387-400` 失败，服务端状态也不会回填本地列表。
- 根本原因：只有进场路径在 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:534-539` 做了即时本地插入，压力/出场路径依赖下一次完整同步，没有本地乐观更新或 pending 状态。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:357-405,410-467,557-606`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/report_pressure_sheet.dart:254-274`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/entry_detail_page.dart:25-58`。
- 修改方案：成功响应或离线入队后立即生成对应本地 Entry 副本并通知；同步失败保留本地 pending 标记；补传成功后再以服务器数据校正，并确保报警/通知重排。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：代码路径可直接确认；现有测试中的 `_FakeController.markExited()` 在 `/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart:77-81` 主动修改本地 entries，掩盖了真实控制器缺陷；未发现真实离线压力/出场回归测试。

### FLT-003｜严重｜单人气瓶容量只在首次在线创建时短暂生效，离线、复核和详情会丢失

- 影响范围：用户为不同人员填写 9L/6.8L 等不同气瓶时的倒计时、离线补传、同名合并/压力复核和详情信息；会产生错误剩余时间。
- 复现步骤/证据：
  1. 录入页确实允许每个人单独填写容量，`/Users/vavavoom/Documents/WatchDog/app/lib/pages/home_page.dart:857-874,925-941` 将 `volumeL` 传入控制器。
  2. 断网创建时，`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:484-521` 虽接收 `volumeL`，但离线时长计算 `:505-510` 固定使用 `calcConfig.cylinderVolL`，队列 payload `:517-521` 也没有容量字段。
  3. `Entry` 模型 `/Users/vavavoom/Documents/WatchDog/app/lib/models/models.dart:1-25` 没有 per-entry 容量字段；合并仅在 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/home_page.dart:904-910` 发送压力，无法保留原容量。
  4. 跨组接口证据：后端离线重放 `/Users/vavavoom/Documents/WatchDog/backend/src/server.js:444-455` 使用全局 `CFG.calc`；压力重算 `:464-473` 也使用全局容量。在线创建虽接受容量 `:920-957`，数据库 entries 表 `/Users/vavavoom/Documents/WatchDog/backend/src/db-sqlite.js:29-40` 没有容量列。详情页 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/entry_detail_page.dart:261-294` 只能显示全局 `cfg.cylinderVolL`。
- 根本原因：per-entry 容量未进入 Entry 模型、离线事件 payload、数据库持久化和压力复核接口；在线首次创建的计算结果无法作为后续计算的输入保存。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/models/models.dart:1-56`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:479-539,557-588`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/home_page.dart:857-910,925-941`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/entry_detail_page.dart:261-294`；需与后端事件/数据库契约协同。
- 修改方案：明确容量的持久化归属；在 Entry、创建响应、离线事件、压力复核和数据库中完整携带并使用，详情显示记录值；若产品决定容量只影响首次计算，也必须在 UI 和接口中明确并禁止后续误显示全局值。
- 修复状态：未修复（需与后端组协调，当前只读）。
- 验证结果：现有测试只验证录入表单显示 9.0L（`/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart:1336-1355`），未覆盖离线/复核后的时长一致性。

### FLT-004｜严重｜单位认证失效后不会重新进入认证门禁

- 影响范围：单位验证码被撤销、服务端单位迁移、认证 token 失效或权限变更后的启动恢复与现场操作；用户可能继续看到旧警情/旧缓存而不知道已失去访问权。
- 复现步骤/证据：
  1. 已认证启动时，`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:139-147` 仅依据本地四项 SharedPreferences 判断 `_authenticated`。
  2. 认证后的轮询在 `:357-400` 对所有异常统一设置 `syncError`，没有针对 401/403 清除认证或当前警情。
  3. 主界面只有 `controller.needsAuthentication` 或 `needsIncidentSelection` 为真时才展示门禁，见 `/Users/vavavoom/Documents/WatchDog/app/lib/main.dart:251-300`；异常路径不会改变这两个状态。
  4. 后端认证中间件明确会对缺失/错误单位凭证返回 401/403，见 `/Users/vavavoom/Documents/WatchDog/backend/src/server.js:98-107`，因此不是抽象的错误类型猜测。
- 根本原因：认证状态是启动时一次性布尔值，API 响应没有“会话失效”事件处理；错误状态只影响连接提示，不影响数据门禁和操作资格。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:81-90,134-147,357-400`；`/Users/vavavoom/Documents/WatchDog/app/lib/main.dart:251-300`；后端状态码契约见 `/Users/vavavoom/Documents/WatchDog/backend/src/server.js:98-107`。
- 修改方案：ApiException 保留 HTTP 状态码；统一拦截 401/403，停止轮询/保活、清空或冻结现场数据、清除失效认证并重新显示认证浮层；保留明确的重新认证提示。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：现有测试覆盖初次认证成功/失败（`/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart:1981-2044`），未覆盖认证失效后的状态迁移。

### FLT-005｜严重｜新安装 App 固化已知 API token，生产 token 不匹配会阻断首次认证

- 影响范围：正式 APK 首次安装、单位认证和 API 安全；若生产服务遵守随机 API_TOKEN 约定，用户没有在认证浮层输入 token 的入口，认证请求会直接失败。
- 复现步骤/证据：
  1. 新安装且 SharedPreferences 没有 `api_token` 时，`/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:150-153` 返回固定字符串 `watchdog-dev-token-2026`。
  2. `/Users/vavavoom/Documents/WatchDog/app/lib/api/api_client.dart:54-64,697-703` 会把它作为认证请求头发送。
  3. 发布 workflow 的构建命令 `/Users/vavavoom/Documents/WatchDog/.github/workflows/release.yml:51-55` 没有通过 `--dart-define` 或其它安全注入方式配置 token；服务端示例 `/Users/vavavoom/Documents/WatchDog/backend/.env.example:42-44` 要求运行时使用随机 API_TOKEN。
- 根本原因：客户端使用可逆的公开构建产物承载一个开发默认令牌，且认证流程没有安全的设备注册/运行时配置闭环。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:150-158`；`/Users/vavavoom/Documents/WatchDog/app/lib/api/api_client.dart:54-71,697-717`；`/Users/vavavoom/Documents/WatchDog/.github/workflows/release.yml:51-55`；`/Users/vavavoom/Documents/WatchDog/backend/.env.example:42-44`。
- 修改方案：移除硬编码 token；由后端设计不依赖共享静态 token 的单位/设备注册或短期凭证流程，或在受控安装流程中安全配置且不把生产密钥打进 APK。此项需要后端与发布流程共同决策。
- 修复状态：未修复（高风险跨组问题，当前只读）。
- 验证结果：静态调用链确认；未读取任何真实环境变量或密钥，也未进行生产认证尝试。

### FLT-006｜严重｜离线队列没有单位边界，退出单位后旧操作仍会按新身份反复补传

- 影响范围：退出单位/切换单位、离线现场操作、长期轮询和历史数据隔离；会造成旧队列永久重试，遗留警情可能在新身份下继续产生请求。
- 复现步骤/证据：
  1. 队列表只存 `incident_id/type/time/payload/op_id`，没有单位标识，见 `/Users/vavavoom/Documents/WatchDog/app/lib/services/offline_queue.dart:20-29`。
  2. `leaveUnit()` 清理认证和当前数据，但没有清空、隔离或转移队列，见 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:201-227`。
  3. 新单位认证后，`sync()` 在 `:357-362` 调用 `OfflineQueue.drain((id) => api!.forIncident(id))`；`drain` 在 `/Users/vavavoom/Documents/WatchDog/app/lib/services/offline_queue.dart:57-76` 使用当前 ApiClient 的单位凭证补传所有历史 incident。
  4. 归属新单位的旧警情会被服务端拒绝，但 `drain` 的 `:93-97` 对失败只保留队列；后端对历史 `unit_id` 为空的兼容警情允许可见，见 `/Users/vavavoom/Documents/WatchDog/backend/src/server.js:123-129`，存在错误归属风险。
- 根本原因：离线事件的隔离键只有警情，没有单位；退出单位没有定义队列的生命周期和失败处置策略。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/services/offline_queue.dart:14-99`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:201-227,344-362`；后端单位边界见 `/Users/vavavoom/Documents/WatchDog/backend/src/server.js:98-129`。
- 修改方案：队列 schema 增加 `unit_id` 并迁移；按单位/警情隔离 drain；退出单位时停止并隔离待传数据，向用户显示待处理数量或提供明确清理/导出策略；禁止用新单位凭证重放旧单位操作。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：现有测试没有覆盖离线入队后退出单位再认证的场景。

### FLT-007｜严重｜提醒/报警阈值允许负数或反向关系，可能使报警分级失真

- 影响范围：全局看板颜色、TTS、声音报警和本地通知调度；错误设置会让“提醒”分支永远不可达或直接关闭阈值。
- 复现步骤/证据：
  1. 设置页 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:507-516` 只做 parse/default，不做范围或 `alarm <= warn` 校验，保存后仍显示“已保存”。
  2. 本地 setter `/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:247-257` 直接写入；云端应用 `:102-105` 只检查两个值非负，也不检查关系和上限。
  3. 写入 `warn=1, alarm=5` 后，`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:448-461` 对剩余 5 分钟以内先进入 alarm，warn 分支永远不会命中；写入负值则相应阈值不会触发。
- 根本原因：设置入口、云端合并和运行时使用之间没有统一的安全范围校验。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:498-539`；`/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:82-117,247-257`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:443-467`。
- 修改方案：在 Settings 单一入口定义并复用合法范围（至少 `0 <= alarm <= warn`，并设置合理上限）；非法输入阻止保存并定位到字段；云端数据也必须同样校验，应用失败配置时回退安全默认值。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：现有设置测试只覆盖正常输入/自动保存，未覆盖负数和反向阈值。

### FLT-008｜一般｜设置自动保存会丢弃保存期间产生的第二次编辑

- 影响范围：设置页文本输入，尤其服务器地址、容量、消耗率和阈值快速连续修改时；UI 的最终值可能与 SharedPreferences/运行时配置不同。
- 复现步骤/证据：
  1. 最后一个输入框失焦时，监听器在 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:75-88` 调用 `_autoSave()`。
  2. 保存开始后 `:500-505` 设置 `_saving=true`；任何期间触发的下一次保存在 `:503` 直接 return。
  3. 用户在第一轮保存尚未完成时修改另一个字段并失焦，第二次请求被丢弃；`:529-537` 没有 dirty/revision 标记或完成后的重试。
- 根本原因：用布尔锁去重并发回调，但没有记录锁期间发生的变更。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:75-88,498-539`。
- 修改方案：使用变更代际或 dirty 标记；保存期间合并最新快照，完成后若代际变化自动再保存；最好将本地写入、刷新客户端、云同步拆成可串行阶段。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：代码逻辑确认；现有测试只验证单次失焦保存，未覆盖保存期间二次编辑。

### FLT-009｜一般｜后台同步/名单失败和设置保存会取消或销毁共享 API 客户端

- 影响范围：启动认证后的首次同步、轮询、现场进出场请求、设置保存和名单加载；会出现与当前错误无关的请求被取消。
- 复现步骤/证据：
  1. `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:152-160` 同时启动 `startSync()`、`loadRoster()`、`syncSettings()` 和日志补传，它们共享 `api`。
  2. `syncSettings()` 捕获任意异常后在 `:294-297` 调用动态 `api?.cancelRequests()`；`loadRoster()` 失败也在 `:928-930` 调用同一操作。
  3. 设置自动保存在 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:529-532` 调用 `refreshConfig()` 并 fire-and-forget `syncSettings()`；`refreshConfig()` 在 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:300-316` 直接替换并 dispose 旧客户端，未等待正在使用旧客户端的核心请求。
- 根本原因：后台任务没有绑定客户端实例的生命周期；错误恢复使用当前全局 `api`，而不是产生错误的实例，配置切换也没有串行化。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:152-164,277-316,913-930`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:498-532`。
- 修改方案：为每个请求保留所属 ApiClient；取消只能作用于对应任务；刷新配置前等待/迁移在途核心请求，或用读写锁/客户端代际保护；后台错误不要关闭无关业务连接。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：静态并发调用链确认；现有测试没有并发刷新配置与同步的测试。

### FLT-010｜一般｜多个核心 API 在检查 HTTP 状态前直接解析响应，网关 HTML 错误会绕过离线恢复

- 影响范围：进场、压力更新、日志写入、警情创建/读取和离线补传在 CloudBase 代理返回 HTML 502/503 时的错误处理。
- 复现步骤/证据：
  1. 客户端已经实现了处理非 JSON 响应的 `_decodeJson()`，并明确说明网关可能返回 HTML，见 `/Users/vavavoom/Documents/WatchDog/app/lib/api/api_client.dart:109-116`。
  2. 但进场 `:258-270`、更新压力 `:292-298`、创建警情 `:672-687`、读取警情 `:724-730`、离线补传 `:898-904` 等路径先执行 `jsonDecode`，再检查状态码。
  3. 代理返回 `<html>...503...</html>` 时会先抛 `FormatException`；`AppController.createEntryFromVoice()` 的网络错误识别 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:812-816` 不包含该异常，因此不会进入离线入队。
- 根本原因：错误响应解析策略没有在所有 API 方法统一使用，且离线兜底依赖脆弱的异常字符串匹配。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/api/api_client.dart:227-270,281-298,645-687,720-730,888-904`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:479-539,812-816`。
- 修改方案：所有响应先统一解码为安全的 ApiException（保留 statusCode 和 retryable 信息），再按状态处理；对网关 5xx/连接类错误统一决定重试或离线入队。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：静态逻辑确认；现有 API 测试覆盖成功 JSON，不覆盖 HTML/非 JSON 错误响应。

### FLT-011｜一般｜自动记日志失败后仍跳转日志页，用户失去当前重试上下文

- 影响范围：语音意图识别为 note 后的自动记日志流程；鉴权失败、服务端校验失败等非网络错误时尤为明显。
- 复现步骤/证据：`/Users/vavavoom/Documents/WatchDog/app/lib/main.dart:175-197` 在 `controller.addNote()` 抛错后显示失败 SnackBar，但 `:198` 无条件执行 `_selectTab(0)`。因此“识别成功、保存失败”的文本和重试入口不会保留在当前语音页。
- 根本原因：成功和失败分支共用无条件导航，错误处理只负责提示没有控制流程结果。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/main.dart:175-199`。
- 修改方案：只在 `addNote` 成功（包括离线入队成功）后跳转；失败时保留文本并提供重试/复制或手动保存入口。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：代码路径确认；现有 note 路由测试为成功回调路径，未覆盖 addNote 抛错后的导航断言。

### FLT-012｜一般｜详情页手动出场的主请求没有异常边界

- 影响范围：详情页的手动出场；归档竞态、记录不存在、鉴权错误和非网络 API 错误会导致无用户反馈。
- 复现步骤/证据：`/Users/vavavoom/Documents/WatchDog/app/lib/pages/entry_detail_page.dart:25-41` 直接 await `markExited()`；其后的 `try/catch` 从 `:42` 才开始，只包裹火场日志 `addActionLog()`。当 `markExited()` 抛出时，确认按钮的异步回调直接结束，页面不提示失败，也不会执行后续清理/返回。
- 根本原因：把“主状态变更”和“后置日志写入”分成了 try 范围，但主状态变更没有自己的失败恢复；离线成功时又受 FLT-002 影响。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/pages/entry_detail_page.dart:25-58`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:591-606`。
- 修改方案：整个确认流程包在可见错误边界中；主请求失败保留页面并提示重试，成功后再写日志；将离线 pending 状态明确展示。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：静态确认；现有详情页测试覆盖取消确认和成功路径，未覆盖主请求抛错。

### FLT-013｜严重｜AlarmService 首次初始化失败后永久不可重试

- 影响范围：本地通知、锁屏/后台提醒和警情报警；一次插件初始化失败可能让整个 App 进程后续都无法恢复通知能力。
- 复现步骤/证据：
  1. `/Users/vavavoom/Documents/WatchDog/app/lib/services/alarm_service.dart:85-102` 在任何 await 前先把 `_inited` 设为 true。
  2. 初始化、权限或音频插件任一步骤失败时，`AppController._initOptionalServices()` 只在 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:230-247` 记录日志并继续，不把 AlarmService 重置。
  3. 后续再次调用 `alarm.init()` 会在 `AlarmService:86` 直接 return；控制器 `_alarmReady` 仍为 false，当前进程内没有恢复入口。
- 根本原因：初始化状态在成功之前被标记完成，异常路径没有回滚/重试机制。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/services/alarm_service.dart:85-137`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:230-247`。
- 修改方案：仅在所有必需初始化成功后设置 `_inited`；失败时恢复 false 并保存可重试错误；设置页或下一次认证/前台恢复时显式重试。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：静态异常路径确认；没有通知插件初始化失败后再次恢复的测试。

### FLT-014｜严重｜通知调度在成功前写入 _scheduled，失败后同一条目永不重试

- 影响范围：剩余时间提醒、报警和超时通知，尤其是首次权限未授予、系统通知插件瞬时失败或后台调度失败时。
- 复现步骤/证据：`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:419-427` 先写 `_scheduled[e.id] = e.exitAt`，再 await `cancelForEntry` 和 `scheduleForEntry`。任一步抛错会跳到 `sync()` 的 `:392-400`，但 `_scheduled` 已保留；下一次 `_rescheduleNotifications()` 因 `:420` 发现 exitAt 相同而跳过调度。
- 根本原因：调度缓存被当作“已尝试”而非“已成功”，失败没有回滚。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:410-437`；实际调度异常来源及调用见 `/Users/vavavoom/Documents/WatchDog/app/lib/services/alarm_service.dart:143-223`。
- 修改方案：完成全部 schedule 后再写缓存；失败时删除该条目并保留待重试状态；调度失败不应把已经成功的数据同步标成不可恢复的整轮失败。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：静态控制流确认；现有测试未注入通知调度异常。

### FLT-015｜一般｜本地 ASR 模型下载没有连接/流读取超时，设置页可能永久停留下载中

- 影响范围：首次启用离线语音、弱网/半连接/服务端不再发送数据的 Android 设备；用户无法取消或重试回到可用状态。
- 复现步骤/证据：
  1. `/Users/vavavoom/Documents/WatchDog/app/lib/services/local_asr_service.dart:117-151` 使用 `client.send(request)` 和 `await for (final chunk in res.stream)`，没有 timeout、取消令牌或总时限。
  2. 页面在 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:469-495` 把 `_downloading` 设为 true，只有 `downloadModel()` 返回/抛出后才在 finally 清零；下载中的 UI 没有取消按钮。
  3. `:124` 的重试数组是 `[url, url]`，两个尝试指向同一 URL，不能处理持续挂起的网络状态。
- 根本原因：文件下载只有异常重试，没有连接、首字节、读取空闲和总时长控制，也没有用户取消路径。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/services/local_asr_service.dart:78-164`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:426-495,1329-1445`。
- 修改方案：为连接、首字节和流空闲设置超时；使用可取消请求和临时文件清理；限制重试次数并展示可重试错误。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：静态确认；没有挂起流/弱网下载测试。

### FLT-016｜严重｜关闭联网语音时未等待本地模型检查，用户可把语音功能切到不可用

- 影响范围：设置页关闭联网 ASR 后的下一次语音录入；用户选择“稍后下载”或本地模型不存在时，录音后的识别流程直接失败。
- 复现步骤/证据：
  1. 关闭开关时 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:1033-1037` 先 fire-and-forget `_checkModelBeforeOffline()`，马上把 `_asrCloud` 设为 false 并自动保存。
  2. 用户在 `:438-459` 的对话框选择“稍后”后，没有恢复开关或阻止保存。
  3. 下一次识别进入 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:1054-1068` 的本地路径；本地模型初始化 `/Users/vavavoom/Documents/WatchDog/app/lib/services/local_asr_service.dart:228-239` 找不到文件时抛出 `LocalAsrNotInstalledException`。
- 根本原因：能力前置条件检查和设置变更没有串行化，开关状态先于模型可用性落盘。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:426-460,1017-1037`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:1035-1068`；`/Users/vavavoom/Documents/WatchDog/app/lib/services/local_asr_service.dart:228-239`。
- 修改方案：关闭开关前 await 模型检查/下载结果；取消下载或下载失败时保持联网开关开启并明确提示；启动识别前再次检查模型并提供直接下载入口。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：静态路径确认；现有测试未覆盖“稍后下载后立即录音”。

### FLT-017｜一般｜用户修改服务器地址后，本地 ASR 仍固定下载编译期默认地址

- 影响范围：自部署/测试服务器和离线模型下载；API 已切换到自定义地址但模型请求仍打到默认 CloudBase 网关。
- 复现步骤/证据：
  1. 模型地址由编译期常量决定，`/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:11-15` 的 `defaultModelBaseUrl` 不读取 SharedPreferences。
  2. `LocalAsrService` 在 `/Users/vavavoom/Documents/WatchDog/app/lib/services/local_asr_service.dart:25,31-32` 将该常量固化到下载 URL。
  3. 设置页允许修改服务器地址 `/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:1217-1245`，控制器在 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:300-315` 只用它重建 API 客户端，没有同步模型地址。
- 根本原因：API base URL 和模型 base URL 生命周期不一致；模型 URL 只能通过编译期 dart-define 覆盖，用户配置入口没有对应关系。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:4-15,119-134`；`/Users/vavavoom/Documents/WatchDog/app/lib/services/local_asr_service.dart:16-32`；`/Users/vavavoom/Documents/WatchDog/app/lib/pages/settings_page.dart:1217-1245`。
- 修改方案：明确并实现模型 URL 的运行时派生/单独配置；切换服务器时校验 `/models/` 能力，或将模型地址作为同一服务器的显式配置。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：静态调用链确认；现有测试未覆盖自定义 server URL 下的模型下载。

#### 后续闭合记录（2026-08-28）

主 Agent 复核确认该问题可以在不改变产品规则的前提下修复：`LocalAsrService` 现在在下载时解析运行时 `Settings.serverUrl` 并追加 `/models`；显式构造参数和 `WATCHDOG_MODEL_BASE_URL` 仍可覆盖。`controller_service_lifecycle_test.dart` 新增自部署地址请求断言，定向测试通过；全量门禁结果以 `round5-cross-review.md` 为准。

### FLT-018｜一般｜问答历史加载、发送和清空之间存在并发覆盖

- 影响范围：辅助页快速输入、首次打开页面、清空对话和流式回答；用户输入或刚清空的记录可能被旧历史/晚到回复覆盖或重新写回。
- 复现步骤/证据：
  1. `/Users/vavavoom/Documents/WatchDog/app/lib/pages/chat_page.dart:45-57` 启动 `_loadHistory()`，但 `_loading` 初值为 false；`submitQuestion()` 在 `:95-131` 不检查历史是否已加载。
  2. 若发送先于历史读取完成，`_loadHistory()` 在 `:68-84` 直接把 `_messages` 替换成旧历史，覆盖刚添加的本地用户消息和占位回复。
  3. 清空按钮只按 `_messages.isEmpty` 判断，在 `:422-425` 未因 `_sending` 禁用；清空操作在 `:352-374` 执行，而流式请求完成后控制器在 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:879-885` fire-and-forget 写回历史。
  4. `ChatHistory.appendExchange()` 的 load→append→save 也没有串行锁，见 `/Users/vavavoom/Documents/WatchDog/app/lib/services/chat_history.dart:39-67`，因此清空和晚到保存可互相覆盖。
- 根本原因：历史读取、写入和清空没有代际标记或串行队列；页面状态和持久化状态各自独立推进。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/pages/chat_page.dart:40-131,352-385,422-425`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:859-898`；`/Users/vavavoom/Documents/WatchDog/app/lib/services/chat_history.dart:14-67`。
- 修改方案：历史未加载完成前禁用提交或合并本地新消息；为 clear/send 使用 generation；ChatHistory 的 load/save/clear 进入单写入队列，并在 clear 后拒绝旧请求回写。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：静态时序确认；现有问答测试在 `pumpAndSettle()` 后发送，未覆盖加载延迟和清空竞态。

### FLT-019｜优化｜问答语音空结果没有结束操作日志

- 影响范围：操作日志的完整性、语音故障排查，不直接改变业务数据。
- 复现步骤/证据：`ChatPage.finishRecording()` 在收到空白转写时记录 `transcribe_empty` 后直接 `return`；下一次录音会覆盖 `_opId`，该操作因此没有 `op_end`。此外，录音中页面销毁时 `dispose()` 原先也没有结束当前操作。转写异常分支本已有 `transcribe_error` 终态。
- 根本原因：空结果分支和 `dispose()` 均遗漏统一 `_endOp()` 收尾；页面销毁后的成功转写分支也直接返回。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/pages/chat_page.dart`、`/Users/vavavoom/Documents/WatchDog/app/test/widget_test.dart`。
- 修改方案：空转写、录音中 `dispose()` 和页面销毁后的成功转写均写入终态，区分 `no_speech`、`page_disposed` outcome；增加两个 Widget 回归验证同一 `op_id` 的终态。
- 修复状态：已修复。
- 验证结果：两个定向 Widget 回归通过；全量 Flutter 196/196、`flutter analyze` 0 issues。

### FLT-020｜优化｜实名字段列入同步白名单但既不上传也不从云端应用

- 影响范围：跨设备设置同步和实名显示的一致性；当前日志请求仍直接带本地作者，因此不是即时日志丢失问题。
- 复现步骤/证据：
  1. `Settings.syncKeys` 在 `/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:40-53` 包含 `real_name`。
  2. 但 `toSyncMap()` 的返回值 `:65-79` 没有 `real_name`，`applyFromServer()` `:82-117` 也没有写回 `_kRealName`。
  3. `AppController.syncSettings()` 在 `/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:277-297` 仍按该同步协议推拉设置。
- 根本原因：白名单/后端契约与 App 实际 payload、应用逻辑不一致，实名字段的同步意图没有闭环。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/lib/services/settings.dart:35-117`；`/Users/vavavoom/Documents/WatchDog/app/lib/state/app_controller.dart:277-297`；后端允许键见 `/Users/vavavoom/Documents/WatchDog/backend/src/server.js:186-199`。
- 修改方案：若实名属于云同步设置，补齐上传和安全应用；若出于认证安全必须本地独立保存，则移除白名单并同步更新注释、后端键和产品说明。
- 修复状态：未修复（需要产品/安全边界确认，当前只读）。
- 验证结果：静态契约差异确认；现有测试只验证本地实名随日志请求提交。

### FLT-021｜优化｜缺少本地签名文件时 release 构建静默回退 debug 签名

- 影响范围：Android 手工/本地正式包分发、OTA 更新和安装升级链路；CI workflow 有后置指纹检查，因此当前 CI 失败时能拦截，但本地 release 命令仍可生成错误签名包。
- 复现步骤/证据：`/Users/vavavoom/Documents/WatchDog/app/android/app/build.gradle.kts:38-49` 在 `key.properties` 不存在时将 release 的 `signingConfig` 设置为 debug。workflow 的注释 `/Users/vavavoom/Documents/WatchDog/.github/workflows/release.yml:33-34` 也承认该静默退化，后置检查在 `:58-79` 才失败。
- 根本原因：release 构建配置把缺少正式密钥当作可用 fallback，而不是构建前置条件。
- 涉及文件：`/Users/vavavoom/Documents/WatchDog/app/android/app/build.gradle.kts:38-59`；`/Users/vavavoom/Documents/WatchDog/.github/workflows/release.yml:33-79`。
- 修改方案：release 类型缺少 key.properties 时直接 fail fast；debug 签名只允许 debug 类型；将指纹检查保留为第二道防线。
- 修复状态：未修复（只读审查移交主 Agent）。
- 验证结果：当前 `flutter build apk --debug --no-pub` 成功；未运行无 key.properties 的 release 构建，以避免改变签名/发布状态，静态配置已足以确认风险。

## 检查范围与未发现项

- 已阅读并遵守项目根目录 `AGENTS.md`、`README.md`，核对 App 入口、底部导航、认证/警情选择、语音意图路由、离线队列、设置同步、报警/保活、OTA、Android Manifest/Gradle、`pubspec.yaml`、测试配置和现有测试辅助类。
- 已检查 `app/lib` 全部页面、状态、API、模型和服务文件，以及 `app/test` 现有测试文件；未把纯风格偏好、没有调用链证据的猜测或已被现有逻辑排除的批量导入问题列入。
- `app/pubspec.yaml` 依赖解析和本地 `package_info_plus` override 未发现本轮可由代码/运行结果确认的缺陷；Android 权限大多有对应功能调用和设置入口，未把“可能影响商店审核”的策略问题冒充运行缺陷。
- 仓库已有未提交改动，涉及 App、后端、部署和 README；本组没有覆盖、回滚或修改这些改动。当前报告是本组唯一新增文件。

## 验证记录

- `cd /Users/vavavoom/Documents/WatchDog/app && flutter analyze`：通过，`No issues found!`。
- `cd /Users/vavavoom/Documents/WatchDog/app && flutter test`：通过，`All tests passed!`，当前实际执行 146 个测试；未减少测试用例。AGENTS.md 中记录的 70 个 App 用例数已与当前工作树不一致，本报告以实际运行结果为准。
- `cd /Users/vavavoom/Documents/WatchDog/app && flutter build apk --debug --no-pub`：通过，生成 `build/app/outputs/flutter-apk/app-debug.apk`。
- 未运行 backend `npm test`，因为本次角色限定为 Flutter App 功能组只读审查，且没有修改后端；后端文件只在核对离线/认证契约时作为证据引用。
- 未执行真实设备手工验证、断网/弱网注入、通知权限拒绝、单位凭证撤销或生产认证测试；这些不是本轮静态结论的依据。

## 阻塞与移交

- 本组只读约束阻止直接修复和补充回归测试；所有问题状态均为“未修复”或“需跨组/产品决策”，应由主 Agent 统一排期，涉及后端契约的项需先协调文件修改顺序。
- 需要真实 Android 设备/模拟器与可控测试服务，才能完成长按延迟录音、权限拒绝后恢复、通知调度异常、弱网下载、认证失效和离线跨单位隔离的动态复核。
- FLT-003、FLT-005、FLT-006、FLT-009、FLT-020 需要后端/安全/发布流程共同确认；FLT-005 的最终修复不能通过把生产密钥继续硬编码进 APK 解决。
