# 第三方组件许可说明

本项目自身以 [MIT 许可证](LICENSE) 发布。以下第三方组件各自遵循其原始许可证，本文件仅作声明与致谢，不改变其许可条款。

## 运行时会直接分发的主要组件

| 组件 | 用途 | 许可证 |
|---|---|---|
| [Flutter](https://flutter.dev) | 跨平台 UI 框架 | BSD-3-Clause |
| [Dart](https://dart.dev) | 语言运行时 | BSD-3-Clause |
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | 本地离线语音识别与降噪 | Apache-2.0 |
| [onnxruntime](https://github.com/microsoft/onnxruntime) | 模型推理（经 sherpa-onnx 分发） | MIT |
| [PostgreSQL](https://www.postgresql.org) | 服务端数据库 | PostgreSQL License |
| [Caddy](https://caddyserver.com) | 服务端反向代理与 HTTPS | Apache-2.0 |

## Flutter 依赖

App 直接依赖的 Dart 包均为宽松许可证（BSD / MIT / Apache-2.0），包括但不限于：

`record`、`path_provider`、`path`、`http`、`http_parser`、`flutter_tts`、`shared_preferences`、
`flutter_secure_storage`、`sqflite`、`audioplayers`、`flutter_local_notifications`、`timezone`、
`crypto`、`convert`、`sherpa_onnx`、`flutter_markdown`、`flutter_foreground_task`、
`package_info_plus`、`remixicon`、`image_picker`、`image`、`media_kit`、
`media_kit_video`、`media_kit_libs_video`

完整的传递依赖清单与逐包许可证文本，可在 App 内通过 Flutter 自动生成的许可证页面查看，或执行
`flutter pub deps` 获取依赖树。

## 后端依赖

`backend/package.json` 中列出的 Node.js 依赖均为 MIT 或 Apache-2.0 许可证，可通过
`npm ls --all` 查看完整依赖树。

## 图像素材

| 素材 | 用途 | 来源与许可 |
|---|---|---|
| 中国消防救援队徽（`app/android/.../res/drawable-nodpi/fire_rescue_badge.png`） | 水印相机信息卡左侧标识 | Wikimedia Commons `CHINA FIRE AND RESCUE badge.svg`，标注 **Public domain**（中华人民共和国官方标志不受著作权保护）。原图为 SVG，本项目使用其 960px 光栅化版本并缩放至 384px |

## 参考与致谢

相机与水印功能的实现思路参考了开源社区的通用做法（CameraX `camera-effects` 的 `OverlayEffect`
叠加绘制、MediaCodec 编码管线）。凡直接复用第三方代码之处，均保留原版权声明；未复用代码者仅借鉴
技术思路，不在本项目中包含其源码。

## 维护约定

新增依赖时需确认许可证与本项目 MIT 兼容，并在此文件补充条目。引入 GPL / AGPL 等强著佐权许可证的
依赖会改变本项目的分发条款，必须显式评审后再引入。
