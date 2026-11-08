# WatchDog Client Data Models (`app/lib/models`)

## Overview
Flutter 移动客户端的强类型领域模型与不可变数据实体集合，负责 JSON 序列化/反序列化、业务状态枚举、字段校验与本地 SQLite 映射。

## Interface
- **核心数据模型定义**:
  - [`models.dart`](./models.dart):
    - `Entry` / `FiregroundEntry`：在场人员记录，包含姓名、气瓶容量、初始压力、当前读数、入场时间、预计耗尽时间、版本号 `version`
    - `Incident`：当前警情，包含警情名称、单位归属、力量编制、灾情等级、状态（`active` / `archived`）
    - `IncidentNote`：火场日志记录，包含实战分类（部署/搜救/出水/撤离/异常/随手记）、时间戳、创建人
    - `UserProfile`：当前登录指战员身份与权限（管理员、普通队员、游客）
    - `VoiceParseResult`：语义解析返回结构（意图、槽位、人员名单、压力读数）
  - [`key_sites.dart`](./key_sites.dart), [`key_site_schema.dart`](./key_site_schema.dart):
    - `KeySite`、九大分项数据（概况、道路、装置、设施、流程、提示、库存、储罐、联系人）
  - [`video_resources.dart`](./video_resources.dart):
    - `VideoResource`：监控流地址与探针状态
  - [`admin_login.dart`](./admin_login.dart):
    - 扫码登录挑战与状态模型

## Invariants
- `[model:immutability]`：所有模型类均为不可变设计（推荐使用 `copyWith` 进行状态演进）。
- `[model:safe-parse]`：`fromJson` 工厂构造函数必须对缺失键或异常类型实施防御性降级，严禁因单字段格式不符导致全局崩溃。
- `[model:version-tracking]`：`FiregroundEntry` 包含 `version` 字段，服务端与客户端对比时单调递增，杜绝旧状态覆盖。

## Side Effects
- 无直接外部 I/O 副作用；专注于内存对象解析与序列化。

## Verification
- Run: `flutter test test/models_test.dart`（在 `app/` 目录下）
