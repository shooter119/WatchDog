# 重点单位资料管理端

阶段 1 建立独立后台认证。App 扫码入口随界面整合阶段交付，完整链路验收前不要对外宣告可用。

## 初始化和恢复

在私有生产环境确认目标为已有、有效且已审批成员后执行：

```sh
docker compose exec backend node src/admin-initialize.js '<已有成员ID>'
```

只有不存在有效平台管理员时允许执行；全部平台管理员已失效时，同一命令可恢复。已有有效平台管理员时，由其登录后开通或撤销后台授权。单位 admin/manager 不会自动得到后台权限；unit_admin 还要求当前具有有效单位管理角色。

## 会话与接口

- `/admin/` 为公开登录外壳，资料和管理数据均由受保护接口提供。
- `/api/admin/login/challenges` 生成两分钟挑战，Cookie 绑定发起浏览器；`/login/claim` 一次性领取会话。
- App 认证后使用 `/api/admin-app/capability` 查询有效后台权限，`/confirm` 确认或取消；扫码凭据不得写入日志。
- 后台使用 `__Host-watchdog_admin` Secure / HttpOnly / SameSite=Strict Cookie。每请求校验有效成员与授权，空闲30分钟、绝对8小时过期。
- 写操作限定 `https://fireman119.xyz` 来源并校验 `X-CSRF-Token`。CSRF 只保存在页面内存，可通过已认证的 `/me` 恢复，不保存于 localStorage 或 URL。
- `/members`、`/grants/:memberId`、`/audit` 仅供平台管理员使用；不得撤销最后有效平台管理员。
- 成员状态、审批状态、单位和角色变化通过数据库触发器持久撤销后台会话。撤权同时取消已确认、尚未领取的挑战。
- 初始化、授权变更、确认、登录和退出进入独立审计表，不记录凭据或资料正文。

## 部署边界

后端 Docker 镜像包含 `admin/` 静态资源。正式路由将在联调阶段加入 Caddy，需精确转发 `/admin/*` 和 `/api/admin/*`，保留官网、OTA 和旧 App API。不要直接将私有附件目录配置为静态目录。

迁移 `008_admin_auth.sql` 新增后台表；`009_admin_member_revocation.sql` 新增成员变更撤销触发器。已执行迁移文件不可改写。部署前备份 PostgreSQL 与私有资料，保留旧镜像。旧代码不依赖新增表，可回切镜像；不以删表作为日常回滚方式。

当前阶段未部署、未初始化线上平台管理员，未修改版本或发布 APK。
