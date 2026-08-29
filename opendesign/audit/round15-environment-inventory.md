# 第十五轮：隔离环境资源盘点

日期：2026-08-29

## 目标

确认当前已授权 CloudBase 账号是否已有可用于 PostgreSQL 迁移、RLS/RPC、双实例并发和恢复演练的隔离环境，避免把生产或不明环境误当测试环境。

## 只读证据

| 环境 | CloudRun | PostgreSQL 迁移查询 | 结论 |
|---|---:|---|---|
| `cloud1-1ge0yd11155f7616` | `ServerList=[]`、`Total=0` | `PG instance not found` | 没有可识别的 WatchDog 服务或 PG 实例，不能作为隔离环境 |
| `watchdog-prod-d6gch930m378d9a16` | 已有 `watchdog-api-prod` | 远端迁移 `total=0` | 生产环境；只读确认缺口，不执行迁移 |

执行命令均为 CloudBase CLI 只读查询：

- `tcb env list --json`
- `tcb cloudrun list -e <env> --json`
- `tcb db pg migration list -e <env> --remote-only --json`

## 结论与安全边界

当前账号下没有可由主 Agent 安全判定为 WatchDog 隔离 PostgreSQL 的环境。生产 PG 尚未应用迁移，且此前已确认共享集群没有可用备份能力，因此本轮不执行 `004`～`009` 迁移、不创建 RLS/RPC/bucket、不打开生产开关，也不导出业务数据。

后续条件必须同时满足：明确的预生产/隔离环境、专用测试数据、可验证恢复点、两个连接同一 PG 的实例，以及不含生产密钥的迁移凭据。满足后按 [外部验收手册](external-acceptance-runbook.md) 继续。

## Android 设备附带复核

同一轮复核发现实体设备 `PKX110`（Android 16/API 36，`android-arm64`）已通过 ADB 连接，当前工作区 arm64 release APK 安装成功，启动日志未发现崩溃。设备随后处于系统锁屏，正常唤醒和滑动未解锁；未绕过 PIN/生物识别，因此 Android 运行时验收仍保持未完成。
