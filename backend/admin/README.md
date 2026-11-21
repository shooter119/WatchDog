# WatchDog Management Admin Web (`backend/admin`)

## Overview
重点单位档案、360° 全景漫游、危化品速查库、大队水源台账与后台授权审计的 Web 管理控制台前端模块。采用零构建原生 ES Modules + CSS `@layer` 分层架构，视觉令牌对齐火场智控官方 `AppPalette`（支持白昼指挥 / 暗夜指挥室双主题切换），内嵌自托管 Pannellum 2.5.7 360° 全景渲染引擎。

## Interface
- **入口页面**:
  - `index.html`: 管理后台主入口页面（扫码登录视图 + 左侧栏工作台壳体 + 全局 Toast / Overlay 根容器）
  - `pano.html`: 360° 全景漫游全屏预览容器（兼容桌面后台 Cookie 会话与移动端 Flutter WebView Bearer Token）
  - `scan.html`: 扫码落地指引页（`GET /admin/scan`），用于提示用户使用火场智控 App 内置扫一扫完成认证
- **样式架构 (`css/`)**:
  - `main.css`: `@layer tokens, base, layout, components, views, utilities;` 统一入口
  - `tokens.css`: 白昼指挥 (`daylight`) 与暗夜指挥室 (`night-tactical`) 语义设计令牌
  - `base.css`: 全局重置、无障碍焦点环与 `[hidden] { display: none !important; }` 强约束
  - `layout.css`, `components.css`, `views.css`: 壳体布局、弹窗/抽屉/表单/标签输入/拖拽上传与各视图专属样式
  - `pano.css`: 全景查看器独立样式（含 `100dvh`、`safe-area-inset` 与 VR 双目分屏）
- **脚本架构 (`js/`)**:
  - `main.js`: 应用壳体引导（挂载主题、会话管理器、Hash 路由与各业务视图）
  - `core/`: `dom.js`（安全 DOM 构建与异步按钮锁）、`api.js`（CSRF 注入、会话代次防并发、401 统一派发）、`session.js`（15s 心跳与断网保护）、`router.js`（Hash 路由与未保存离开守卫）、`draft-store.js`（`sessionStorage` 会话级草稿自动暂存与恢复）、`theme.js`（双主题切换）
  - `ui/`: `toast.js`、`modal.js`、`drawer.js`、`tag-input.js`、`dropzone.js`
  - `views/login.js`: 扫码登录状态机（生成、单飞轮询、基于 `expiresInMs` 倒计时、成功即销毁 DOM 与定时器）
  - `views/sites/`: 重点单位列表、基本信息表单、九大分项左纲右编编辑器（含吸底操作栏、应急预案正文与附件管理、历史版本预览）
  - `views/hazmats/`: 危化品速查表、安全详情抽屉（空字段绝不兜底推荐用水）、新增/编辑弹窗、Excel 批量导入弹窗
  - `views/water-sources/`: 大队级水源台账与回收站视图（平台管理员大队切换、分类统计卡片、筛选分页、GCJ-02 数值编辑弹窗与回收站恢复，严格遵守 `script-src 'self'` CSP 不加载外部地图脚本）
  - `views/access/`: 平台管理员成员授权与审计日志
  - `pano/main.js`: 360° 全景查看器（请求取消防竞态、WebGL `MAX_TEXTURE_SIZE` 自动降级 `page-1.jpg`、`requestAnimationFrame` VR 同步与离页资源释放）
- **模式约束**:
  - `key-site-schema.json`: 重点单位九大分项字段元数据模式约束

## Invariants
- `[admin:hidden]`：`css/base.css` 与 `css/pano.css` 必须声明 `[hidden] { display: none !important; }`，确保登录视图与工作台切换绝不因 Flex/Grid 规则导致二维码或隐藏面板残留。
- `[admin:auth]`：除登录挑战与扫码指引页外，所有接口交互依赖 `HttpOnly; Secure; SameSite=Strict` 会话 Cookie 及 `X-Admin-CSRF` 校验；`session.on('refreshed')` 仅更新顶栏身份文案，不重绘活动表单。
- `[admin:xss]`：前端脚本禁止使用未转义的 `innerHTML` 模板拼接，统一通过 `core/dom.js` 的 `el()` 与 `textContent` 构建节点。
- `[admin:csp]`：管理后台严格遵循 `script-src 'self'`，水源管理等视图不加载任何外部地图或第三方脚本，经纬度采用 GCJ-02 数值输入。
- `[admin:draft-publish]`：重点单位修改先保存草稿（支持 `sessionStorage` 崩溃恢复与 `Ctrl/Cmd+S` 保存），经显式「发布到 App」后生成只读版本并写入审计轨迹。
- `[hazmat:safety]`：危化品详情抽屉对未录入的灭火剂/急救字段仅展示「未录入（请核对 SDS / ERG）」，严禁自动填充默认灭火建议。
- `[pano:lifecycle]`：切换全景机位或退出页面时必须取消在途 `fetch`、销毁 Pannellum WebGL 实例并调用 `URL.revokeObjectURL`。

## Side Effects
- 与后端管理路由（`/api/admin/*`）交互，读写重点单位草稿/发布版本、危化品目录及后台授权。
- 使用 `localStorage` 保存主题偏好（`watchdog_admin_theme`），使用 `sessionStorage` 暂存当前会话的重点单位未提交草稿与移动端全景临时令牌（登出或鉴权失效自动清除）。

## Verification
- Run: `cd backend && npm test`（覆盖 `test/admin-auth.test.js`、`test/admin-web.test.js`、`test/key-sites.test.js`、`test/hazmat.test.js`）
