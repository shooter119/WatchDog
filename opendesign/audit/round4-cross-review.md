# WatchDog 第四轮多 Agent 交叉复核记录

审核日期：2026-08-28
审核负责人：WatchDog 主 Agent
参与小组：后端与架构、Flutter App 功能、UI/UX、安全与隐私、测试与质量、性能与工程质量。
本轮原则：先复核已有修改，再以不重叠文件范围修复确定存在且低风险的问题；未 commit、push 或发版，未读取或写入真实密钥。

## 问题记录

### BACK-R4-001｜严重｜SQLite 重复归档的状态保护不足

- 影响范围：同一警情重复归档、并发归档或重试时，可能重复写入事件，或覆盖已归档时间/操作者。
- 复现/证据：旧 SQLite UPDATE 只按 id 更新；重复调用归档路径可再次报告 changed。复核后新增 `backend/test/db.test.js` 回归，第二次归档要求 `changed=false` 且保留第一次归档元数据。
- 根本原因：UPDATE 缺少 `status='active'` 条件，返回值未依据实际 affected rows 判断。
- 涉及文件：`backend/src/db-sqlite.js`、`backend/test/db.test.js`。
- 修改方案：为归档 UPDATE 增加 active 条件，依据 `result.changes > 0` 返回 changed。
- 修复状态：已修复 SQLite 路径；PostgreSQL 跨表事务和多实例并发仍由 BACK-006/BACK-009/BACK-010 记录。
- 验证结果：定向 db 测试 16/16；后端全量 `npm test` 112/112；修复后已重新线上部署并健康检查通过。

### PE-R4-001｜一般｜认证启动重复加载名单

- 影响范围：启动阶段可能重复读取 firefighters/hotwords，增加延迟、网络请求和服务端负载；认证前读取还会得到无效请求。
- 复现/证据：`AppController` 初始化、认证完成和显式刷新存在多个触发点；新增生命周期测试并发调用 `loadRoster()`，要求每类请求只发生一次。
- 根本原因：初始化/认证流程没有统一服务启动点和 single-flight Future。
- 涉及文件：`app/lib/state/app_controller.dart`、`app/test/controller_service_lifecycle_test.dart`。
- 修改方案：认证后统一启动远端服务，名单加载合并为同一个 Future，并保留 CRUD 后显式刷新。
- 修复状态：已修复代码级竞态；多实例服务端缓存仍需单独架构设计。
- 验证结果：生命周期定向测试通过；Flutter 全量 179/179。

### WD-APP-LIFECYCLE-20260828-01｜一般｜App 异步会话与平台服务竞态

- 影响范围：启动、认证、刷新、ASR 模型下载/删除/识别器切换、前台服务启停并发时，可能重复请求、旧会话结果回写或资源释放竞态；测试环境还曾因真实 audioplayers channel 缺失而失败。
- 复现/证据：新增 `controller_service_lifecycle_test.dart` 覆盖名单并发加载、刷新等待、模型 URL/HTTP 状态；首次全量运行出现 `audioplayers.global MissingPluginException`。
- 根本原因：异步流程缺少 Future 去重、session generation/API 快照和串行操作；测试直接构造真实平台服务但未安装 channel mock。
- 涉及文件：`app/lib/state/app_controller.dart`、`app/lib/services/local_asr_service.dart`、`app/lib/services/settings.dart`、`app/lib/services/foreground_keep_alive.dart`、`app/test/controller_service_lifecycle_test.dart`。
- 修改方案：加入 single-flight、会话代次、旧 API 结果校验、串行 ASR/前台服务操作和失败可重试；仅在测试组安装 audioplayers mock。
- 修复状态：已修复；平台插件真实行为仍需 Android 设备验证。
- 验证结果：`flutter analyze` 0 issues；全量 JSON reporter `visible_tests=179 skipped=0 failures=0 done_success=True`。

### UI-UX-004-R1｜一般｜重试按钮调用一次性启动方法

- 影响范围：同步定时器已启动后，连接状态中的“重试同步”可能只返回，不立即执行同步。
- 复现/证据：页面 `ConnectionStatus.onRetry` 原绑定 `startSync`；`startSync` 在 `_syncStarted=true` 时不创建新定时器且无法表达等待结果。
- 根本原因：启动轮询和即时刷新复用了同一入口。
- 涉及文件：`app/lib/pages/board_page.dart`、`home_page.dart`、`notes_page.dart`、`settings_page.dart`、`stats_page.dart`。
- 修改方案：所有重试回调改为 `refreshNow`，由已有 `_syncFuture` 合并实际网络请求。
- 修复状态：已修复。
- 验证结果：相关页面复核、Flutter analyze 和全量 179/179 通过。

### UI-UX-011｜一般｜窄屏大字体标题区存在横向溢出风险

- 影响范围：320dp、系统文字约 2 倍时，火场日志标题/写日志/连接状态和统计排行标题/排序动作可能裁剪或溢出。
- 复现/证据：`notes_page.dart` 原标题区为不可换行 Row；`SectionTitle` 原标题和 trailing 共享固定 Row，已有看板/详情大字体测试未覆盖这两页。
- 根本原因：标题、操作和状态没有在窄屏/大字号时降级为纵向或可收缩布局。
- 涉及文件：`app/lib/pages/notes_page.dart`、`app/lib/theme/app_widgets.dart`、`app/test/widget_test.dart`。
- 修改方案：Notes 窄屏改为标题 + Wrap 操作区；SectionTitle 标题改为 Expanded/Flexible，允许换行；增加 Notes/Stats 320dp×2 倍字号测试。
- 修复状态：已修复；真实 TalkBack/厂商字体仍需设备验证。
- 验证结果：`flutter test test/widget_test.dart` 通过；全量 179/179，未捕获异常。

### WD-QA-20260828-01｜严重｜新增 App 测试的平台 channel 隔离缺口

- 影响范围：App 门禁会因测试环境未注册 audioplayers 平台实现而失败，不代表业务代码本身失败。
- 复现/证据：全量测试首次出现 `MissingPluginException`，堆栈落在 `AppController` 构造/释放相关的 `AudioPlayer` channel。
- 根本原因：测试直接使用真实 `AlarmService`，未为插件 channel 提供替身。
- 涉及文件：`app/test/controller_service_lifecycle_test.dart`。
- 修改方案：在该测试组 `setUp` 安装 `xyz.luan/audioplayers.global` MethodChannel mock，生产代码保持原平台行为。
- 修复状态：已修复测试隔离缺口。
- 验证结果：全量 App JSON reporter 179/179，skipped=0，failures=0，done_success=true。

### WD-QA-20260828-02｜严重｜CI 运行时数量门禁未拒绝 skipped/todo

- 影响范围：仅比较测试总数可能让 skipped/todo 用例满足数量下限，降低回归门禁可信度。
- 复现/证据：quality/release workflow 原只读取 Node `tests` 和 Flutter 可见 `testDone` 数量。
- 根本原因：门禁没有读取 Node 的 skipped/todo 汇总，也没有检查 Flutter JSON testDone 的 skipped 字段。
- 涉及文件：`.github/workflows/quality.yml`、`.github/workflows/release.yml`、`AGENTS.md`。
- 修改方案：Node 强制 `skipped=0`、`todo=0`；Flutter 强制 `skipped=0` 且要求 done success；App 基线同步为 179。
- 修复状态：已修复配置级问题；关键测试清单、覆盖率和远端 Actions 实跑仍属后续工程项。
- 验证结果：两份 YAML Ruby 解析通过；本机 Node 112/112、Flutter 179/179；不存在 `uses: ...@vN` 可变引用。

### PE-MODEL-001｜一般｜ASR 旧 generation/staging 清理不完整

- 影响范围：进程被杀或反复更新后，`.staging` 和旧 generation 可能持续占用设备磁盘；不影响当前 active 集合原子切换。
- 复现/证据：`app/lib/services/local_asr_service.dart` 仍主要在当前异常路径清理 staging，未做启动 sweep、generation GC 或低存储策略。
- 根本原因：资源保留策略涉及识别器正在使用的 generation、设备低存储和可回滚窗口，当前没有产品/设备约束。
- 涉及文件：`app/lib/services/local_asr_service.dart`。
- 修改方案：已增加下载前 orphan sweep，清理崩溃遗留 `.staging` 和 `.active.*.part`，不删除已提交 generation；旧 generation 保留数量和占用保护需设备/架构决策。
- 修复状态：部分修复；不阻塞当前代码回归和正式 APK 构建。
- 验证结果：新增清理回归和模型 staging/原子激活测试通过；Flutter 全量 179/179；进程杀、低存储和多次更新尚未实测。

## 本轮交叉结论

- 低风险且有直接证据的问题已直接修复并由主 Agent 重跑；涉及身份/RBAC、跨表事务、产品入口基线、真实 Android 插件和远端 Actions 的问题没有用猜测替代决策。
- 当前本机验证：后端 112/112；Flutter analyze 0 issues；Flutter 179/179、skipped=0；arm64 release APK 仅含 arm64，正式证书 v2 验证通过。
- 线上验证：`CLOUDBASE_ENV_ID=watchdog-prod-d6gch930m378d9a16 ./deploy/deploy.sh` 成功；`/api/health` 返回 `ok=true, ready=true, databaseReady=true, asrConfigured=true, llmConfigured=true`；未带 token 的 `/api/config` 返回 401。
- 未闭合的高风险项目仍见总台账：真实操作者身份/RBAC、管理授权、跨表原子幂等、多实例冷却/限流、PG 迁移事务、真实 Android/TalkBack/弱网和首屏设计基线。
