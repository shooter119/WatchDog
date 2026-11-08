# WatchDog Client API Layer (`app/lib/api`)

## Overview
负责移动客户端与后端服务通信的统一网络抽象层。封装全部 REST 请求、WebSocket 长连接元数据、短期会话 Token 传递、幂等操作 ID（`X-Op-Id`）与当前警情标识（`X-Incident-Id`）。

## Interface
- **核心客户端**: [`api_client.dart`](./api_client.dart)
  - 核心类：`ApiClient`
  - 导出的关键方法：
    - 认证与租户：`login(unitName, verificationCode, firefighterName)`、`guestLogin()`、`refreshToken()`、`getUnitRoster()`
    - 警情与状态：`getCurrentIncident()`、`createIncident(...)`、`archiveIncident(id)`
    - 进退场与压力：`submitEntries(...)`、`updatePressure(...)`、`exitEntry(...)`、`exitAllEntries(...)`
    - 火场日志：`addNote(...)`、`getIncidentNotes(...)`
    - 辅助与视觉：`chatWithAssistant(...)`、`uploadIncidentImage(...)`
    - 重点单位与地图：`fetchKeySites(...)`、`fetchMapList(...)`
    - 气象与路况：`getRouteTraffic(...)`

## Invariants
- `[api:headers]`：只要用户已进入警情，所有业务请求头必须自动注入 `X-Incident-Id`、`X-Device-Id` 与唯一操作防重码 `X-Op-Id`。
- `[api:auth-interceptor]`：收到 HTTP 401 时自动尝试会话平滑续期，续期失败且 Token 过期时清除敏感状态并触发重登通知。
- `[api:timeout]`：常规请求超时设为 10 秒，流式 ASR 与图片大文件上传支持动态超时设置。

## Side Effects
- 向后端 REST API 发起 HTTPS 网络请求。
- 维护设备 ID（持久化于本地 secure_store）并在每次网络请求头中上报。

## Verification
- Run: `flutter test test/api_test.dart`（在 `app/` 目录下）
