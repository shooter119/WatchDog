# WatchDog Mobile Client Subsystem Blueprint (`app`)

## System Overview
WatchDog 移动客户端子系统，面向一线消防安全员设计与实现的 Android 专事实战智能体。通过多模态语音交互（云端豆包 Seed-ASR / 本地离线 sherpa-onnx）、多端实时协同看板、气瓶消耗智能测算、AI 火场智囊与重点单位全景资料，为灭火救援现场提供全天候、全断网可用的安全管控支撑。

## Subdirectories & System Boundaries
- [`lib/`](./lib/README.md): 客户端 Dart 源码核心架构（含 api、models、services、state、theme、widgets、pages）。
- `android/`: Android 原生工程封装、双轨签名配置、前台服务保活通道与原生画中画（PiP）绑定。
- `assets/`: 本地资源目录，包含品牌图元、警报提示音（`sounds/`）、语音模型基础资产。

## Global Invariants
- `[release:dual-track]`：正式发布版与测试版双轨物理隔离：
  - 正式发布版（Release）：包名 `com.firewatch.watchdog`，名称「火场智控」，使用生产私有 keystore 签名，支持 VPS OTA 在线无缝平滑升级；
  - 本地测试版（Debug/Profile）：包名自动追加 `.debug`（`com.firewatch.watchdog.debug`），名称「火场智控·测试」，使用本地 debug 签名；
  - 彻底杜绝签名冲突与更新拦截（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`），支持实体机并排共存测试。
- `[qa:zero-tolerance]`：静态代码分析必须保证 0 issue（`flutter analyze` 无任何 warning/error）。
- `[test:regression-free]`：自动化单元与部件测试用例只增不减（本地基线 471+ 全部通过）。
- `[ui:spec-v2]`：UI 严格落实 `fire-rescue-safety-app-ui-spec-v2.0.md`，禁止手动堆叠带阴影 Container。

## Global Side Effects
- 在实体机读写应用沙盒文件系统（SQLite 数据库、图片草稿、日志滚动文件）。
- 通过 WebSocket 与 HTTPS 同步现场状态，下载与校验 VPS OTA 安装包及 ASR 离线模型文件。

## System Verification
- Run: `flutter analyze`
- Run: `flutter test`
