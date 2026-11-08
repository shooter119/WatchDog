# WatchDog Management Admin Web (`backend/admin`)

## Overview
重点单位与现场资料的 Web 管理控制台前端模块，提供纯原生轻量化 SPA（HTML5 + ES Modules + CSS），内嵌 Pannellum 360° 全景漫游引擎与标准化重点单位九大分项表单录入。

## Interface
- **入口页面与脚本**:
  - `index.html`: 管理后台主入口页面
  - `pano.html`: 360° 全景漫游全屏预览容器
  - `app.js`: 核心控制器、鉴权状态维护、扫码登录轮询与页面路由
  - `sites.js`: 重点单位九大分项录入、草稿保存与正式发布逻辑
  - `hazmats.js`: 危化品速查名录管理与处置规程维护
  - `pano.js`: 基于自建 Pannellum 2.5.7 引擎的全景热点与多机位漫游渲染
  - `key-site-schema.json`: 重点单位九大分项字段元数据模式约束
- **核心数据分项契约**:
  - 单位概况、毗邻道路、生产装置、消防设施及水源、工艺流程、重点提示、仓库库存、储罐、联系人

## Invariants
- `[admin:auth]`：除登录页面与二维码显示外，所有接口交互必须依赖安全的 HttpOnly Cookie（`watchdog_admin_token`）及 CSRF 检验。
- `[admin:draft-publish]`：修改重点单位信息仅暂存草稿，必须经显式「发布到 App」操作后方对移动客户端全员可见，且保留完整历史审计轨迹。
- `[pano:resolution]`：上传的全景图必须为 2:1 等距圆柱投影（equirectangular），前端自动校验尺寸比例并做防崩溃缩放。

## Side Effects
- 与后端管理路由（`/api/admin/*`）交互，修改重点单位草稿及发布状态。
- 操作浏览器本地缓存（`localStorage`）以保存临时未提交表单状态。

## Verification
- Run: `node ../test/key-sites.test.js`（验证管理端相关接口协议）
