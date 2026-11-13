# WatchDog Client Pages & Navigation (`app/lib/pages`)

## Overview
Flutter 移动客户端的视图层，承载五大底部常驻导航入口（日志、看板、语音处置、辅助问答、设置）以及关联的子功能全屏/弹窗页面（重点单位、全景漫游、水印相机、审批核对等）。

## Interface
- **底部核心导航页面**:
  - [`home_page.dart`](./home_page.dart): 首页与语音处置中枢。常驻麦克风交互、单行警情折叠卡、在场人数与最高风险胶囊快捷入口、现场工具面板。
  - [`board_page.dart`](./board_page.dart): 实时现场监控看板。展示全部在场战斗员空呼倒计时进度条、气瓶压力复核、进场批次与紧急撤离告警。
  - [`notes_page.dart`](./notes_page.dart): 火场时间线日志。按实战环节（部署/搜救/出水/撤离/异常）分类过滤与快速录入。
  - [`chat_page.dart`](./chat_page.dart): 火场智囊「水元素」辅助问答。流式问答、危化品联网速查、拍照单图辅助识别，对话历史仅留本机。
  - [`settings_page.dart`](./settings_page.dart): 设置与复盘。单位认证、离线词库、多设备管理、昼夜主题切换、关于我们与 OTA 检测。
- **业务详情与专项目录**:
  - [`key_sites_page.dart`](./key_sites_page.dart): 重点单位九大分项信息查阅、正射地图影像及 360° 全景漫游。
  - [`incident_import_page.dart`](./incident_import_page.dart): 警情信息多图 OCR 导入与通报文字合并提取。
  - [`camera_page.dart`](./camera_page.dart), [`media_review_page.dart`](./media_review_page.dart): 现场水印相机拍摄与双轨成对存盘核对。
  - [`route_traffic_page.dart`](./route_traffic_page.dart): 赶赴现场路径规划与天气路况多路线切换。
  - [`hazmat_page.dart`](./hazmat_page.dart): 危化品 UN 码离线速查、电台战术复诵卡展示与 AI 应急提炼页。
  - [`video_resources_page.dart`](./video_resources_page.dart), [`video_playback_surface.dart`](./video_playback_surface.dart): 现场监控流播放与画中画切换。
  - [`member_review_page.dart`](./member_review_page.dart): 入队申请多管理员协同在线审批。
  - [`offline_review_page.dart`](./offline_review_page.dart): 离线补传记录版本冲突人工比对与确认。
  - [`about_page.dart`](./about_page.dart): 关于我们页面（严格与根目录 `README.md` 内容保持同步）。

## Invariants
- `[ui:home-vs-board]`：职责绝对分明——主页「现场监控」仅展示单行在场人数与最高风险胶囊，点击跳转至看板；详细人员空呼压力卡片与倒计时统一在看板页展示。
- `[ui:glove-friendly]`：核心交互控件（如语音按钮、确认进场、撤离按钮）必须保持大触控面积，满足佩戴消防战术手套时的操作要求。
- `[ui:about-sync]`：`about_page.dart` 中的功能说明与免责声明必须与根目录 `README.md` 保持逐项同步。

## Side Effects
- 控制页面栈与路由跳转（`Navigator.push` / `pop`）。
- 触发软键盘唤起、系统相机与文件选择器调用。

## Verification
- Run: `flutter test test/pages_test.dart`（在 `app/` 目录下）
