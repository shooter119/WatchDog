# 第十四轮：本地门禁与台账一致性复核

日期：2026-08-29

## 审核范围

- Quality/Release workflow 的测试数量门禁与 YAML 结构；
- 后端、Flutter 静态分析和全量测试；
- 生产健康接口、模型清单和网关资源限频只读回读；
- GitHub 授权状态与签名/OTA Secrets 名称清单；
- 审计目录敏感值扫描、`git diff --check` 和工作区改动边界。

## 证据与结果

| 项目 | 结果 | 证据 |
|---|---|---|
| 后端测试 | 通过 | `cd backend && npm test`，161/161，0 failed、0 skipped、0 todo |
| Flutter 静态分析 | 通过 | `cd app && flutter analyze`，0 issues |
| Flutter 测试 | 通过 | `cd app && flutter test`，223/223，0 failed、0 skipped |
| workflow YAML | 通过 | Ruby `YAML.load_file` 解析 `quality.yml` 与 `release.yml` 成功 |
| 数量门禁 | 已收口 | Quality/Release 当前均为后端 161、App 223，且继续拒绝 skipped/todo |
| 生产健康 | 通过 | 网关 `/api/health` HTTP 200；返回 `ok=true`、`ready=true`、`databaseReady=true`、`asrConfigured=true`、`llmConfigured=true` |
| 模型清单 | 通过 | `/models/manifest.json` HTTP 200；部署清单结构与既有逐文件哈希验收保持一致 |
| 网关限频 | 部分通过 | HTTPSERVICE `/` 路由回读 `QPSPolicy.QPSTotal=100`；客户端维度与多实例压力校准仍待隔离环境 |
| GitHub 授权 | 通过 | `gh auth status` 显示当前账户已登录；未输出 Token 内容 |
| GitHub Secrets | 部分通过 | 四项签名 Secrets 存在；四项国内 OTA 专用 Secrets 不存在，未读取 Secret 值 |
| 工作区卫生 | 通过 | `git diff --check` 通过；`opendesign/audit/` 敏感值扫描通过；无 commit/push/tag/Release |

## 未闭合事项

本轮不把本地门禁或生产健康通过误写成项目整体验收通过。以下项目继续留在主台账：

1. 生产 PostgreSQL 迁移、RLS、原子 RPC、双实例并发和恢复演练；
2. 国内 OTA 专用 Secrets、`watchdog-ota` 公开 bucket 和新递增 tag 实跑；
3. 网关多实例突发流量/429 校准；
4. Android 真机录音、权限、前台服务、通知、低存储、备份恢复、无障碍和正式包运行时验证；
5. 生产运行时敏感配置的轮换与历史日志角色隔离。

这些事项需要外部环境、生产恢复条件或设备证据；本轮不执行不可逆生产写入。
