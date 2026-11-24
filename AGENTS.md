# WatchDog 项目约定

## 工作流

本项目研发协作全面遵循 **「Day Day Up」 标准闭环研发规范**。无论用户是否显式提及该 Skill，当遇到需求变更、功能新增、缺陷排查或架构优化时，智能体均应主动按以下七步标准化流程推进：

1. **需求接收、代码勘查与调研分级（Explore & Research Triaging）**：
   - 充分倾听并理解用户需求与痛点；
   - 凡能通过阅读代码、追溯历史（`git log` / `git diff`）或运行测试获知的信息，必须先自主探查代码库，严禁不做调查就盲目发问；深挖底层技术根因；
   - **技术调研智能分级机制**：本地已知问题与局部修复判定为「免调研」（0 额外 Token 消耗）；涉及第三方技术选型、重大架构演进、疑难底层报错或行业前沿范式借鉴时，智能体判定为「需调研」，提炼调研方向并在第 2 步征询用户授权。
2. **交互式深度盘问与调研征询（Interactive Grill-Me & Consent）**：
   - 若第 1 步触发「需调研」，在盘问首题或决策分支中明确呈现调研方向并征求用户意见；
   - 使用 `ask_question` 工具逐一向用户澄清关键需求与决策分支，单次只问一个问题，避免连续轰炸；
   - 必须提供清晰选项并将推荐方案置顶（标注 `(Recommended)`），层层推进，与用户建立 100% 认知共识。
3. **Issue 规格锚定（Spec-as-Issue）**：
   - 盘问对齐达成共识后，在正式写施工方案前，智能体自动通过 `gh issue create`（或 GitHub API）在仓库创建标准 GitHub Issue（包含需求背景、改造方案与验收条件 Acceptance Criteria）；
   - 提取生成的 `Issue #<id>`，作为后续施工方案、提交信息和审计跟踪的唯一上下文锚点。
4. **制定详尽施工方案（Implementation Plan）**：
   - 在正式动工编码前，必须通过 Artifact 编写并呈现结构化施工方案，头部标明关联的 `Issue #<id>`，明确现状根因、改造范围、防御性设计、测试及部署验证计划。
5. **严谨施工与全套门禁验证（Coding & Verification）**：
   - 最小必要改动，保持代码内聚并维护防御性兼容；
   - 编码完成后必须本地全套门禁通过（后端 `npm test` 322+、App `flutter analyze` 0 警告、App `flutter test` 471+），保持 0 报警 0 失败，测试用例只增不减。
6. **自动自检、提交直推主干与清理分支（Auto-Audit -> Commit & Push main -> Clean Branch）**：
   - 全套门禁全绿后，智能体自主检查 `git status` / `git diff`（确认无无关文件、无密钥或敏感信息泄露、文档按需同步），**无需反复打断用户询问是否提交或推主干/推分支**；
   - 自动执行精准 `git add` + `git commit -m "... (closes #<id>)"`（微型任务可免 Issue 锚点），并**默认直接推送至 `origin/main`**（兼容 Worktree 使用 `git push origin HEAD:main`），确认关联 Issue 自动关闭；仅在用户明确要求“先放分支”时以分支形式推送；
   - 推主干并确认无误后，**自动清理已完成任务的临时特性分支**（删除远端分支 `git push origin :<branch>` 与本地分支 `git branch -d <branch>`；若当前正处于活跃 Worktree 目录则自动跳过本地删除，避免报错）。
7. **部署联动、高危闸门与发版边界（Deploy & Release Gate）**：
   - **常规后端部署联动**：后端代码（`backend/src/`、`deploy/`）有修改且无破坏性数据库变更时，在本地测试全绿并推送后，可直接通过带自动备份与失败回滚保护的脚本执行 VPS Docker Compose 部署与公网健康检查验收；若涉及破坏性数据库迁移或核心生产配置大改，**必须先征询用户确认**；
   - **发版严格由用户决定**：版本号与构建号、`git tag`、正式 APK 构建、VPS OTA 清单更新、GitHub Release 等全部环节，必须等用户明确指令后才执行；
   - **人话版交付汇报**：完成后简洁汇报改动内容、测试结果、提交号、Issue 关闭及线上验收状态，便于用户直接验收效果或随时提出微调/撤回。

- commit 前检查 `git status` / `git diff`，只提交本次相关的改动。
- 提交信息简洁中文，符合仓库现有风格。
- 临时调试文件（含密钥等）不入库。
- 设计任务的辅助文件、UI 风格规范、个人介绍网站和过程资料仅保存在本地，不进入公开代码仓库；正式运行资源按用途放入 App 资产目录。
- **README 同步核查**：每次改动完成后核查 README 是否有必要更新（品牌、功能、架构、入口变化都算）；README 有实质内容变更时，App 内「关于我们」页（`app/lib/features/settings/ui/about_page.dart`）必须同步更新，反之亦然。
- 提交前必须通过验证（见下），构建/测试失败不允许提交。
- **后端代码（backend/src/、deploy/）有修改时，先完成本地验证；由研发流程在本地验证通过后执行部署与数据库迁移。** 当前线上部署使用 VPS Docker Compose；在本地测试全绿（后端 npm test 322、App flutter analyze 0 警告 + flutter test 471，CI 门禁基线分别为 300 / 444）且确认接口兼容后，可执行 VPS 部署与迁移，并在部署完成后完成线上健康检查与路由验收。
  本机文档转换用例（key-sites）需要 `soffice`（LibreOffice）与 `pdfinfo`/`pdftoppm`（poppler）在 PATH 上，否则这 14 条必然失败；发版脚本只在这两个组件缺失、且失败用例与已知清单逐条一致时放行，否则一律判为真实失败。
- **版本号与发版由用户决定**：用户要求发版时，依据改动规模判断升级幅度（小优化/修复 → 补丁 +0.0.1；新功能 → 次版本 +0.1.0；重大重构/首个稳定版 → 主版本 +1.0.0），`+` 号后构建号必须递增。同步更新 `app/pubspec.yaml` 的 `version:` 与 `app/lib/app/app_version.dart` 的 `appVersion` 常量。
- **发版流程**：验证通过后按用户要求 commit + push，再 `git tag v<版本号>+<构建号>` + `git push origin <tag>`；当前公开仓库不再包含正式 APK 发布 workflow，签名构建与发布需按私有流程执行。
- 发版前兜底检查：`git status` 确认改动已全部提交；`git diff HEAD` 确认版本号常量与要打的 tag 一致。
- **CI 触发注意**：GitHub 对**已存在 tag 的 force push 不触发 workflow**。若需用新提交更新已发布版本，必须先删远端 tag（`git push origin :refs/tags/<tag>`）再重新创建并 push。
- 发布后如有外部构建或发布任务，需手动确认结果；GitHub 保护分支要求通过 `Quality Checks / backend` 和 `Quality Checks / app`。
- **版本发布链路**：版本号与构建号由用户决定；GitHub Release 只作为版本记录和备份，不作为国内手机的实际下载源。正式 arm64 APK 必须上传到 VPS 的 `/opt/watchdog/ota/versions/`，并原子更新 `/opt/watchdog/ota/latest.json`；清单中的 `tag_name`、`version_code`、`apk_url`、`size_bytes` 和 `sha256` 必须与实际 APK 一致；**缺 `sha256` 的清单会被 App 整份拒收**（不再先提示有新版再在安装阶段报错）。App 端 `app/lib/services/update_service.dart` 固定从 `https://fireman119.xyz/ota/latest.json` 检查版本，从同一 VPS 下载并校验 APK。
- **更新发布验收**：发布后必须从公网验证 `https://fireman119.xyz/ota/latest.json` 返回目标版本，检查 APK HTTP 状态、文件大小和 SHA-256；确认旧版本手机能识别新版本后，才算 OTA 发布完成。GitHub Release 没有 APK 附件或 GitHub Actions 没有运行，不代表 VPS OTA 已发布。
- **一键发版脚本**：`scripts/release.sh --version x.y.z --notes-file notes.md` 会依次完成版本号同步、门禁（analyze/test/后端测试）、提交推送、打 tag、构建 arm64 分包、OTA 上传、`latest.json` 原子替换、公网校验、官网同步与容器重建；`--dry-run` 只打印计划，`--skip-website`/`--skip-upload`/`--skip-gates` 可按需跳过。手工发版时也必须遵守同样的顺序与校验。
- **后端门禁的唯一例外**：转换工具链不齐（`soffice`、`pdfinfo`、`pdftoppm` 任一不在 PATH）时，`test/key-sites.test.js` 与 `test/key-site-ai.test.js` 的 14 条文档转换用例必然失败；`scripts/release.sh` 只在「工具链确实不齐 + 失败用例与固定清单逐条一致 + 失败全部落在这两个文件」时放行并打印，任一条件不满足即判真实失败。本机已装齐 `soffice`（LibreOffice 26.8.1）与 `poppler`，因此当前是 `fail 0` 严格门禁；**不要为了过门禁删清单或加 `--skip-gates`**。
- **异地备份**：线上 `/opt/watchdog/backups/` 与数据库同盘，必须另有一份离开 VPS 的副本。`scripts/backup-pull.sh`（默认 `BACKUP_HOST=ali`、落到仓库之外的 `~/WatchDog-backups`，`--keep` 控制份数、`--dry-run` 只打印）打包 `pg_dump -Fc`、后端 `/app/data` 私有卷和 `ota/latest.json`，双向 sha256 比对并校验包内成员，只清理 `offsite-*` 旧副本。
- **官网同步**：`website/` 为本地私有目录（已 gitignore，不入公开仓库）。每次 Release 必须同步官网版本号与下载链接并重建 `website` 容器，或直接运行发版脚本；页面运行时会读取 `/ota/latest.json` 兜底，静态值仍应与最新 Release 一致。

## 验证命令

- 后端：在 `backend/` 下运行 `npm test`（node:test），改 server/db/parse/calc 必须通过。
- App：在 `app/` 下运行 `flutter analyze`（0 问题）+ `flutter test`。
- 两套测试目前后端基线 300 个用例（本地 322 个通过）、App 基线 444 个用例（本地 471 个通过）；改动后不应减少，`flutter analyze` 必须保持 0 问题。

## UI 与 App 调试规范

- **唯一 UI 设计规范（Design System v3.0）**：本地 `fire-rescue-safety-app-ui-spec-v3.0.md` 与代码实现 `app/lib/design_system/`（`DsTheme` / `buildCommandTheme`、Tokens 与标准组件库）是全仓**唯一 UI 规范标准**（旧版 `app/lib/theme/`、`app/lib/pages/`、`app/lib/widgets/` 已在 M4 彻底清退，由 `app/test/theme_static_gate_test.dart` 与 `app/test/architecture/` 静态门禁守护）。
  1. **单入口与主题读取**：业务代码仅允许通过 `design_system.dart` 单一出口引入（如 `import '../design_system/design_system.dart';` 或 `package:watchdog/design_system/design_system.dart`），并统一通过 `context.ds` 读取语义色彩（`context.ds.colors`）与字阶（`context.ds.typography`）；严禁将 `context.ds`/`DsColors` 写入 `static final`；严禁 `app/lib/design_system/` 反向引入业务层或状态层（由 `app/test/design_system/ds_isolation_gate_test.dart` 静态门禁守护）。
  2. **调试预览隔离**：`DsPreviewPage` 与原型页面仅在 `app/lib/features/settings/ui/component_gallery_page.dart` 中通过 `kDebugMode` 守卫暴露，正式包编译时整段剔除。
  3. **主题模式与无损切换**：`ThemeController` 仅维护 `AppThemePreference`（`daylight` / `night-tactical` / `system`），`CommandAppShell` 通过 `MaterialApp(theme: ..., darkTheme: ..., themeMode: ...)` 无损切换昼白/暗曜/跟随系统（不销毁页面树，保留滚动位置与草稿）；历史 `warm-sand` 启动时自动平滑迁移至 `daylight` 并仅提示一次。
- **现场可用性硬指标（新 UI 强制门禁）**：
  1. **触控热区**：常规交互触控目标 ≥ 48dp（`DsSizes.touchTarget`）；**进出场、报压、确认等主操作与紧急操作 ≥ 56dp**（`DsSizes.primaryAction`）；底部中置语音指令键直径 **64dp**（`DsSizes.voiceButton`）且向上凸出 **12dp**（`DsSizes.voiceProtrusion`）。
  2. **大字号零溢出**：在 360dp 窄屏与系统 **130% 字号**缩放下，全部组件与页面必须保持零溢出、不截断、不重叠（由 `app/test/design_system/ds_text_scale_test.dart` 守护）。
  3. **双通道状态表达**：`StatusPill` 等状态指示必须**同时包含图标与文字**（严禁纯色表达），最小高度自适应字号且不截断；填充色与文本色双通道分离，满足 WCAG 对比度要求（文本及状态字 ≥ 4.5:1，`metric*` 关键读数 ≥ 7.0:1，由 `app/test/design_system/ds_contrast_test.dart` 校验）。
  4. **等宽数字**：压力、倒计时、时长、时间戳等所有数值读数统一启用 `FontFeature.tabularFigures()`（`DsTypography.metric` / `metricLarge` / `tabular(...)` / `MetricReadout`），确保跳秒时不左右抖动。
  5. **卡片层次与防误触**：卡片（`SurfaceCard`）统一采用 1px 细描边区分层次，严禁厚重阴影与双层边框叠加（仅 `CommandSheet`、中置语音键等浮层允许轻柔悬浮阴影）；危险/不可逆操作（如 `CommandButtonVariant.danger`）默认通过 `CommandSheet` 弹出**二次确认**后方可生效，关键操作配触感反馈。
- **视觉回归（Golden）门禁**：
  1. `app/test/design_system/golden/` 通过目录级 `flutter_test_config.dart` 配置 **0.5% (`0.005`) 像素差异容差**比较器（作用域仅限 `test/design_system/golden/`，不影响其他测试），用于吸收同平台细微抗锯齿差异。
  2. **跨平台执行策略**：所有黄金截图测试文件均标注 `@Tags(['golden'])`；在 macOS 本机开发与验收阶段通过 `flutter test` 全量执行，在 Linux CI 中通过 `flutter test --exclude-tags golden` 排除，避免跨操作系统字体与光栅化差异导致的误报（且不触发 `skipped > 0` 门禁失败）。
  3. 基准图生成/更新命令（在 `app/` 目录下执行）：`flutter test --update-goldens test/design_system/golden`。
  4. **人工视觉复核**：每次生成或更新基准图后，**提交前必须人工逐张打开核查所有基准 PNG**，确认布局、配色、圆角与状态呈现无误后方可提交，严禁未核查直接覆盖。
- **默认调试方案（真机 + scrcpy）**：当用户指示「调试」或进行 App UI 效果预览时，默认执行方案一：
  1. 依托 Android 实体机调试，拒绝使用或启动重型 QEMU / AVD 虚拟机；
  2. 使用 `scrcpy` 实现低延迟、高帧率桌面投屏，直接在 Mac 窗口中查看真机 UI、字体、圆角与交互效果；
  3. 配合 `flutter run -d <device_id>`（或直接推送构建包）实现毫秒级热重载调试。
- **正式版与测试版双轨隔离规范（避免签名冲突与混淆）**：
  1. **正式发布版（Release）**：桌面显示名称为「火场智控」，应用 ID 为 `com.firewatch.watchdog`，使用生产密钥库 `watchdog-release.keystore` 签名，支持通过 VPS OTA 检查与在线无缝覆盖升级；
  2. **本地测试版（Debug / Profile）**：桌面显示名称为「火场智控·测试」，应用 ID 自动追加后缀为 `com.firewatch.watchdog.debug`，使用开发机本地 debug 签名；
  3. **实体机并排共存**：两版本完全物理隔离，支持在同一台实体机上同时安装共存，两者的本地数据库（SQLite）、配置缓存（SharedPreferences）及 FileProvider 互不串扰；
  4. **彻底杜绝签名冲突**：正式版的 OTA 在线更新专属于 `com.firewatch.watchdog`，不会受测试版干扰，从根本上杜绝 Android 系统底层签名不兼容拦截（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）；测试版在设置中明确提示测试版环境，不触发生产 OTA 覆盖。
- **免虚拟机原则**：保持本地环境轻量，不创建和常驻几 GB 至十几 GB 的本地 AVD/QEMU 镜像。

## 协作与脱敏安全规范

- **指令唯一来源**：本项目规则以本地 `AGENTS.md` 为统一标准。
- **严禁泄露敏感信息**：在项目任何说明文档、代码注释、提示词、示例配置或单元测试中，**严禁出现真实的消防单位名称、队站名称、真实人名、具体地址或单位登录验证码/密钥**；所有示例与测试一律使用「示例省/示例市/示例县消防救援大队」「示例路站」「张三/李四」「1001」等虚拟脱敏占位。
- **严禁出现外部编辑软件名称**：项目文档、代码、配置及提交信息中，**不得出现任何具体编辑软件或代码辅助工具的名称**；分支命名必须按业务功能或问题命名（如 `feat/<模块>`、`fix/<问题>`、`refactor/<目标>`）。
- **绿色交接原则（交接门禁）**：在每次会话结束或交接前，本地工作区代码必须保持可编译且测试全过（后端 `npm test` 302、门禁基线 300，App `flutter analyze` 0 警告 + `flutter test` 471、门禁基线 444），严禁留下编译报错或半成品的脏代码。
- **小粒度交接提交**：阶段性修改建议进行小粒度的本地 commit（如 `wip: <已完成内容>，待<下一阶段>`），并在提交信息中明确当前进度和待办项。
- **临时缓存与配置不入库**：临时会话、缓存、运行日志及私有配置目录不得提交入库。

## 架构速览

```
backend/                 Node.js 后端（Express + ws + pg PostgreSQL 17，端口 3000）
  src/server.js          全部 REST API + Token/单位认证 + CORS + 请求日志 + 归档/参战力量 + 辅助问答(/api/chat，限流+搜索+视觉)
  src/db.js              PostgreSQL 运行时入口（SQLite 仅保留旧数据兼容单测）
  src/postgres-store.js  参数化 PostgreSQL 仓储、事务上下文和 LISTEN/NOTIFY
  src/db-postgres.js     业务仓储、永久审计事件和事务 Outbox
  migrations/            标准 PostgreSQL 基线迁移，带事务、校验和与 advisory lock
  src/asr.js             豆包 Seed-ASR WebSocket 客户端
  src/parse.js           DeepSeek 语义解析（intent: entry/exit/note/ask/ignore + action + 姓名 + 压力，含 guardrail）
  src/calc.js            可用时间 = 容量(L) × 压力(MPa) × 10 ÷ 消耗率(L/min)
  src/logger.js          统一日志
  test/                  node:test 单测（302 个用例，CI 门禁基线 300）
app/                     Flutter 客户端（正式版 com.firewatch.watchdog「火场智控」，测试版 com.firewatch.watchdog.debug「火场智控·测试」）
  lib/main.dart          纯启动入口（≤ 200 行），唯一挂载 CommandAppShell
  lib/app/               AppBootstrap / app_version.dart / CommandAppShell（4 Tab + 中置 64dp 语音键）/ 跨域编排器
  lib/core/              网络传输 / SSE / AppLogger & LogSanitizer / SyncStore / PhoneText
  lib/design_system/     Design System v3.0 Tokens、DsTheme 与标准组件库（design_system.dart 单入口）
  lib/features/          按业务域划分的 12 个功能模块（command_home / monitor / voice / notes / copilot / incident / auth / roster / settings / map / key_sites / hazmat / water_sources / video / media）
  lib/api/api_client.dart 接口兼容门面（X-Incident-Id / X-Device-Id / X-Op-Id / 短期会话 Token）
  lib/state/             按业务域 URI part 分片组织的 AppController（每文件 ≤ 500 行）
  lib/services/sync_coordinator.dart bootstrap、重连、补拉和 30 秒校准
  lib/services/sync_reducer.dart 事件去重、游标连续性和词库快照转换
  lib/services/realtime_sync_client.dart 单设备 WebSocket、鉴权和心跳
  lib/services/offline_queue.dart 本地 SQLite 现场操作队列（进退场/压力/随手记，联网幂等补传）
  lib/services/local_asr_service.dart sherpa-onnx 本地离线语音识别与降噪
  lib/services/          audio / tts / alarm / screen_on / settings / theme_controller / op_log / diagnostic_log
  test/                  widget 测试 + 姓名解析测试（471 个用例，CI 门禁基线 444）
deploy/                  部署脚本与配置（VPS Docker Compose + Caddy + 模型分发）
```

## 语音意图路由

- 底部语音按钮长按 → 转写 → AI 判断意图，按意图跳转：entry/exit → 语音页确认面板；note → 自动记入日志并跳日志页；ask → 跳「辅助」问答页自动发送；ignore（环境音/无关内容）→ 丢弃并提示重新录入，不跳转。
- 问答页长按语音按钮 → 就地录音，识别为提问直接发送；其余按上述规则路由。
- 进出场登记（进场确认/出场/全员离场）同步写一条火场日志，只记名字+动作（如"张伟进场、李娜进场"），不带压力读数。
- 意图判断：后端 `parse.js` guardrailIntent（宁记不错过——环境音文本含名单/火场痕迹时降级 note）；App 端 `LocalParser._intentFor` 规则版兜底离线场景。

## 密钥与不入库清单

- `backend/.env`（VOLC_APP_ID / VOLC_ACCESS_TOKEN / DEEPSEEK_API_KEY / API_TOKEN）不入库，只维护 `.env.example`。
- `app/android/key.properties` 与 `watchdog-release.keystore` 不入库（正式签名）。
- 涉及真实 key 的临时调试脚本不入库（如 `backend/asr-debug.js`）。
- 正式签名文件和签名凭据只在私有发布环境维护；公开仓库当前仅保留质量检查 workflow，不承担正式 APK 发布。

## 部署（VPS Docker Compose）

- 当前线上拓扑为 VPS Docker Compose：PostgreSQL 17、Node.js 后端、Caddy 反向代理和模型文件分发。
- 部署配置位于 `deploy/vps/`：`docker-compose.yml` 负责服务编排，`Caddyfile` 负责 HTTPS、反向代理和静态文件路由。
- 后端容器使用 PostgreSQL 驱动，内部监听 3000 端口；生产密钥通过 VPS 上的私有环境文件注入，不入库。
- `deploy/vps/website.Dockerfile` 依赖本地私有 `website/` 目录；该目录已从公开仓库移除，因此从公开仓库新 checkout 后不能直接构建网站容器，部署时需从私有备份准备网站文件，或由用户另行决定是否调整该服务。
- 模型清单和模型文件位于 `deploy/models/`，修改模型或部署相关代码后先进行本地清单校验和部署配置检查，由智能体在验证充分后自主决定上线与部署。
- 当前平台决策：iOS 暂缓，集中开发 Android；App 的 Android 工程是公开客户端的主要构建目标。
