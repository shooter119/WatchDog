# WatchDog ASR Models & Manifest (`deploy/models`)

## Overview
用于火场极端断网场景下的端侧离线语音识别模型分发清单与完整性校验模块。管理 `sherpa-onnx` 流式语音识别主模型（约 75MB）及可选降噪模型（约 9.8MB）的文件哈希与版本基线。

## Interface
- **模型清单契约**: [`manifest.json`](./manifest.json)
  - 核心属性：
    - `schemaVersion`：清单模式版本号
    - `modelVersion`：当前离线声学模型标识（`multi-zh-hans-2023-9-2`）
    - `files`：分块 ONNX 模型文件（encoder, decoder, joiner, tokens, vocab, denoiser）的大小 `sizeBytes` 与 SHA-256 哈希值
- **校验工具**: [`../verify-model-manifest.js`](../verify-model-manifest.js)

## Invariants
- `[model:integrity]`：App 端下载模型后必须逐字节验证 SHA-256 哈希，完全匹配清单后方可载入内存启用；任何哈希不符的模型文件立即丢弃。
- `[model:storage-protection]`：低存储空间预警时，禁止静默删除已成功加载的本地离线模型文件或现场业务数据。

## Side Effects
- 在 VPS 上通过 Caddy 向具备认证权限的移动客户端分发静态模型文件。

## Verification
- Run: `node deploy/verify-model-manifest.js`
