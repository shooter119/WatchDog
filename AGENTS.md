# WatchDog 项目约定

## 工作流

- **commit / push 全自动**：修改完成并通过验证后，自动执行 `git add` + `commit` + `push`，无需请示用户；只提交本次相关的改动，提交信息简洁中文、符合仓库风格。
- **发版严格由用户决定**：版本号与构建号、`git tag`、正式 APK 构建、VPS OTA 清单更新、GitHub Release 等全部环节，必须等用户明确指令后才执行。
- **后端部署与数据库迁移由智能体在本地验证通过后自主决定执行**。
- commit 前检查 `git status` / `git diff`，只提交本次相关的改动。
- 提交信息简洁中文，符合仓库现有风格。
- 临时调试文件（含密钥等）不入库。
- 设计任务的辅助文件、UI 风格规范、个人介绍网站和过程资料仅保存在本地，不进入公开代码仓库；正式运行资源按用途放入 App 资产目录。
- **README 同步核查**：每次改动完成后核查 README 是否有必要更新（品牌、功能、架构、入口变化都算）；README 有实质内容变更时，App 内「关于我们」页（`app/lib/pages/about_page.dart`）必须同步更新，反之亦然。
- 提交前必须通过验证（见下），构建/测试失败不允许提交。
- **后端代码（backend/src/、deploy/）有修改时，先完成本地验证；由智能体自主决定是否部署到线上及执行数据库迁移。** 当前线上部署使用 VPS Docker Compose；智能体在本地测试全绿（后端 npm test 302、App flutter analyze 0 警告 + flutter test 454，CI 门禁基线分别为 300 / 444）且确认接口兼容后，可自主执行 VPS 部署与迁移，并在部署完成后完成线上健康检查与路由验收。
  本机文档转换用例（key-sites）需要 `soffice`（LibreOffice）与 `pdfinfo`/`pdftoppm`（poppler）在 PATH 上，否则这 14 条必然失败；发版脚本只在这两个组件缺失、且失败用例与已知清单逐条一致时放行，否则一律判为真实失败。
- **版本号与发版由用户决定**：用户要求发版时，依据改动规模判断升级幅度（小优化/修复 → 补丁 +0.0.1；新功能 → 次版本 +0.1.0；重大重构/首个稳定版 → 主版本 +1.0.0），`+` 号后构建号必须递增。同步更新 `app/pubspec.yaml` 的 `version:` 与 `app/lib/pages/settings_page.dart` 的 `appVersion` 常量。
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
- 两套测试目前后端基线 300 个用例（本地 302 个通过）、App 基线 444 个用例（本地 454 个通过）；改动后不应减少，`flutter analyze` 必须保持 0 问题。

## 多工具与多 Agent 协作规范

- **指令唯一来源**：本项目规则以本地 `AGENTS.md` 为统一标准。使用 Antigravity、Codex、Cursor、Claude Code 等任何 AI 工具时，均须遵守本文件的全部规范。
- **严禁按工具名建分支**：不得创建类似 `codex-dev`、`antigravity-branch` 等分支。所有分支必须按功能或问题命名（如 `feat/<模块>`、`fix/<问题>`、`refactor/<目标>`），不同工具在同一业务分支上接力协同。
- **绿色交接原则（交接门禁）**：任何 AI 工具在会话结束或转交给下一工具前，本地工作区代码必须保持可编译且测试全过（后端 `npm test` 302、门禁基线 300，App `flutter analyze` 0 警告 + `flutter test` 454、门禁基线 444），严禁留下编译报错或半成品的脏代码交给下一个工具。
- **小粒度交接提交**：工具切换前建议进行小粒度的本地 commit（如 `wip: <已完成内容>，待<下一阶段>`），并在提交信息中明确当前进度和待办项，避免未提交的改动在切换工具时被意外覆盖或误报。
- **工具专用缓存与配置不入库**：各 AI 工具生成的临时会话、缓存、运行日志及专有配置目录（如 `.cursor/`、`.claude/`、`scratch/` 等）不得提交入库。

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
app/                     Flutter 客户端（org com.firewatch.watchdog，版本 1.13.1+96）
  lib/pages/             home(语音处置) / board(看板) / notes(火场日志) / chat(辅助问答/视觉) / roster(名单热词) / settings / archived_incidents / entry_detail / op_log / stats
  lib/api/api_client.dart 全部接口调用（X-Incident-Id / X-Device-Id / X-Op-Id / 短期会话 Token）
  lib/state/app_controller.dart 实时同步、当前警情、现场数据、每秒阈值检查、TTS/通知调度、离线队列调度
  lib/services/sync_coordinator.dart bootstrap、重连、补拉和 30 秒校准
  lib/services/sync_reducer.dart 事件去重、游标连续性和词库快照转换
  lib/services/realtime_sync_client.dart 单设备 WebSocket、鉴权和心跳
  lib/services/offline_queue.dart 本地 SQLite 现场操作队列（进退场/压力/随手记，联网幂等补传）
  lib/services/local_asr_service.dart sherpa-onnx 本地离线语音识别与降噪
  lib/services/          audio / tts / alarm / screen_on / settings / op_log / diagnostic_log
  test/                  widget 测试 + 姓名解析测试（454 个用例，CI 门禁基线 444）
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
