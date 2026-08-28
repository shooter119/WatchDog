# WatchDog 第三轮多 Agent 交叉复核记录

审核日期：2026-08-28
审核负责人：WatchDog 主 Agent
参与小组：后端与架构、Flutter App 功能、UI/UX、安全与隐私、测试与质量、性能与工程质量。
范围：第三轮对 `backend/src/server.js`、CloudBase 驱动、Flutter 问答/同步/看板/语义交互、Android 签名与测试门禁的复核。各小组先按不重叠写入范围并行检查，主 Agent 汇总后统一修复和回归。

## 问题记录

### BACK-R3-001｜严重｜SSE 下游断开未释放上游请求

- 影响范围：`/api/chat?stream=1` 的 DeepSeek 上游连接、请求额度和 Node 资源。
- 复现/证据：客户端在 SSE 流返回前断开，原实现没有绑定 `req.close`/`res.close` 生命周期，上游请求仍可能运行到超时。
- 根本原因：下游 HTTP 生命周期与上游 `fetch`/reader 没有共享取消信号。
- 涉及文件：`backend/src/server.js`、`backend/test/sse_disconnect.test.js`。
- 修改方案：为每个流式请求创建 `AbortController`，监听下游断开，取消上游 fetch 和 response reader，并清理监听器。
- 修复状态：已修复。
- 验证结果：SSE 断开回归 1/1；`npm test` 112/112。

### BACK-R3-002｜一般｜上游错误正文回显给客户端

- 影响范围：上游模型或网关错误正文可能泄露供应商细节、请求标识或内部信息。
- 复现/证据：模拟上游返回带敏感内容的错误正文，原路由将其拼入 SSE error 事件。
- 根本原因：错误处理直接使用上游响应文本作为客户端错误消息。
- 涉及文件：`backend/src/server.js`、`backend/test/sse_disconnect.test.js`。
- 修改方案：客户端只收到固定通用错误；服务端日志保留经过统一脱敏的诊断信息。
- 修复状态：已修复。
- 验证结果：错误正文脱敏回归 1/1；`npm test` 112/112。

### R3-FLT-001｜一般｜问答历史晚到覆盖当前页面状态

- 影响范围：ChatPage 先发送/清空后，异步历史读取可能恢复旧消息、丢失当前用户问题或流式占位。
- 复现/证据：延迟 `fetchChatHistory()`，随后发送问题或完成清空；原实现以旧快照直接覆盖 `_messages`。
- 根本原因：页面没有历史读取代际和清空屏障，持久化层也存在读-改-写并发窗口。
- 涉及文件：`app/lib/pages/chat_page.dart`、`app/lib/services/chat_history.dart`、`app/test/chat_history_concurrency_test.dart`、`app/test/chat_history_test.dart`。
- 修改方案：页面用历史代际合并仍有效的本地消息；清空后丢弃旧快照；发送/清空互斥；持久化通过单一 mutation queue 串行化，UI 不等待本地 I/O。
- 修复状态：已修复。
- 验证结果：页面并发回归 3/3，持久化并发回归 2/2，ChatPage 8/8，Flutter 全量 172/172。

### R3-UI-001｜一般｜同步状态反馈时序不完整

- 影响范围：用户可能看不到短同步的“同步中”，或在同步进行时错误看到“已中断”。
- 复现/证据：`sync()` 设置 `syncing=true` 后未立即通知；连接组件此前优先判断 `connectionLost`。
- 根本原因：状态写入与通知时序、显示优先级不一致。
- 涉及文件：`app/lib/state/app_controller.dart`、`app/lib/theme/app_widgets.dart`。
- 修改方案：同步开始立即 `notifyListeners()`；连接状态优先显示同步中，其次失败/中断/已连接。
- 修复状态：已修复。
- 验证结果：`flutter analyze` 0 问题，Flutter 全量 172/172。

### R3-UI-002｜一般｜嵌套动作造成重复无障碍语义

- 影响范围：TalkBack/语义树可能把同一折叠、排序或设置动作暴露成两个重复可点击节点，增加误触风险。
- 复现/证据：外层 `Semantics(onTap)` 与内层 `InkWell(onTap)` 同时声明动作。
- 根本原因：视觉容器与真正交互控件没有划分语义所有权。
- 涉及文件：`app/lib/pages/op_log_page.dart`、`app/lib/pages/settings_page.dart`、`app/lib/pages/stats_page.dart`。
- 修改方案：外层排除子语义，内层排除重复 InkWell 语义，让一个动作只保留一个可操作语义节点。
- 修复状态：已修复。
- 验证结果：Flutter 全量 172/172；真实 TalkBack 仍需 Android 设备验收。

### R3-UI-003｜一般｜看板窄屏大字体横向溢出

- 影响范围：320dp、较大系统字号下，人员姓名、状态和更新压力操作可能裁剪或不可用。
- 复现/证据：Widget test 设置 320dp、DPR 3、2 倍文字缩放时出现 `RenderFlex overflowed by 22 pixels`。
- 根本原因：看板标题和人员卡的标题/状态/动作均按横向固定组合布局。
- 涉及文件：`app/lib/pages/board_page.dart`、`app/test/widget_test.dart`。
- 修改方案：窄屏或大字号下标题改为纵向排列；人员卡姓名与状态/动作改为纵向 + `Wrap`，保留 48dp 操作命中区。
- 修复状态：已修复。
- 验证结果：窄屏大字体回归 1/1，Flutter 全量 172/172。

### SEC-R3-001｜严重｜非 HTTPS CloudBase 地址可能携带 service role

- 影响范围：CloudBase PostgREST 服务端凭据、App 已保存的服务端地址和前台保活请求。
- 复现/证据：将 CloudBase REST 地址设为 `http://...`，原客户端仍可构造带 Authorization 的请求；旧保存地址也可能绕过新默认值检查。
- 根本原因：服务端只检查地址非空，App 只在部分入口校验 URL。
- 涉及文件：`backend/src/cloudbase-postgrest.js`、`backend/test/cloudbase-driver.test.js`、`app/lib/services/settings.dart`、`app/lib/services/foreground_keep_alive.dart`。
- 修改方案：CloudBase 驱动强制 HTTPS；App 服务器地址和前台保活对非本地地址强制 HTTPS，并在读取旧配置时迁移为默认安全地址。
- 修复状态：代码级已修复；自定义可信域名 allowlist 仍待部署模型决策。
- 验证结果：HTTP CloudBase 回归 1/1；后端 112/112；Flutter analyze/test 通过。

### SEC-R3-002｜一般｜本机敏感文件权限过宽

- 影响范围：同机其他用户读取 `backend/.env`、Android 签名配置和 keystore。
- 复现/证据：审计初始 `stat` 显示这些文件为 0644。
- 根本原因：本地文件创建/复制未收紧 umask 或权限。
- 涉及文件：`backend/.env`、`app/android/key.properties`、`app/android/app/watchdog-release.keystore`（均为本地忽略文件）。
- 修改方案：将三个文件权限收紧为 0600；保留运维平台和 CI secret 权限作为外部验收项。
- 修复状态：已完成本机修复。
- 验证结果：三文件均为 `-rw-------`；Git tracked 敏感文件扫描为空。

### TQ-R3-001｜一般｜测试组间后台 SharedPreferences 写入导致挂起

- 影响范围：Flutter 全量测试稳定性和持续集成耗时。
- 复现/证据：ChatPage 测试使用后台历史写入但未安装 SharedPreferences 内存实现；下一测试组清空队列时一直等待，测试在约 1 分钟后不结束。
- 根本原因：测试环境未隔离平台插件，测试清理动作等待不可观测的后台 I/O。
- 涉及文件：`app/test/widget_test.dart`、`app/lib/state/app_controller.dart`、`app/lib/services/chat_history.dart`。
- 修改方案：ChatPage 测试组安装内存 SharedPreferences；页面发送不阻塞等待持久化；生产持久化仍由队列保证追加/清空顺序。
- 修复状态：已修复。
- 验证结果：ChatPage 8/8；Flutter JSON reporter 可见测试 172/172；无挂起。

### PE-R3-001｜优化｜质量/发布 Job 缺少执行超时

- 影响范围：测试或构建异常挂起时持续占用 CI runner。
- 复现/证据：检查 workflow 的 job 配置未发现 `timeout-minutes`。
- 根本原因：质量门禁和发布任务没有设置明确的最长执行时间。
- 涉及文件：`.github/workflows/quality.yml`、`.github/workflows/release.yml`。
- 修改方案：质量 Job 设置 15/20 分钟超时，发布 Job 设置 30 分钟超时。
- 修复状态：已修复代码配置。
- 验证结果：YAML 解析通过；GitHub Actions 实跑仍需远程环境。

## 仍未闭合的交叉风险

- 操作者身份、会话、RBAC 和管理 Token 仍没有项目级产品/部署契约（BACK-003/BACK-004/SEC-003/SEC-005）。继续硬编码角色会改变核心权限规则，因此不擅自修改。
- 多实例限流、真实 PostgreSQL/CloudBase 迁移事务、生产部署和健康检查需要 `CLOUDBASE_ENV_ID` 与预生产环境。
- Android 真机权限、录音、本地 ASR、通知、前台服务、TalkBack、弱网与不同厂商渲染仍不能由本机 Widget 测试替代。
- `flutter_markdown` 已标记 discontinued，依赖升级需独立兼容性窗口，不在本轮冒险升级。

## 交叉复核结果

- 后端组修复后由测试组复跑后端 112/112，SSE 资源释放和错误脱敏均有独立回归。
- Flutter 功能组的页面竞态修复由质量组通过 3 个页面并发用例、2 个持久化并发用例和全量 172/172 复核。
- UI/UX 组提出的同步反馈、重复语义、窄屏大字体问题均由主 Agent 修改后再通过 analyze、定向测试和全量测试。
- 安全组提出的 CloudBase HTTPS 与本机 secret 权限问题均完成低风险闭环；身份模型、模型签名和生产 Actions 安全仍保留为外部边界。
