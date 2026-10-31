# 组织种子

公开仓库不包含真实人员、消防站、单位名称或验证码。`org.example.json` 只用于开发、测试和 CI。

生产部署准备一份私有 JSON（不要提交），结构与示例相同：

- `organization.id`：稳定组织 ID，创建后不要改。用户按单位名称和验证码登录，库内关联这个 ID。
- `organization.name` / `verificationCode`：登录时填写的单位名称和验证码。
- `firefighters`：语音名单。`group` 只给管理员阅读，不入库，也不授予登录权限。
- `stations`：本组织预设消防站。
- `hotwords`：本组织专有热词。通用战术词（头车、内攻、搜救、初战等）会自动补齐。
- 可选 `members`：登录白名单，格式与 `WATCHDOG_SEED_UNIT_MEMBERS` 相同。

任选一种方式，在后端进程启动前配置：

```bash
# 推荐：私有文件。路径放在仓库外，或使用已被 gitignore 的 *.private.json / *.local.json。
WATCHDOG_ORG_SEED_FILE=/secure/watchdog-org.json

# 或者只用环境变量。名单、站名、热词接受 JSON 数组或逗号分隔。
WATCHDOG_SEED_UNIT_ID=your-org-id
WATCHDOG_SEED_UNIT_NAME=你的单位名称
WATCHDOG_SEED_UNIT_CODE=你的验证码
WATCHDOG_SEED_FIREFIGHTERS='["张三","李四"]'
WATCHDOG_SEED_STATIONS='["示例路站"]'
WATCHDOG_SEED_HOTWORDS='["你的大队简称"]'
```

同时设置文件和环境变量时，环境变量里的单位 ID、名称、验证码以及非空名单会覆盖文件中的对应字段。`WATCHDOG_SKIP_SEED=1` 跳过导入。

导入是启动时的补齐，不会删除已有人员、热词或消防站，也不会改写已有警情的单位归属。已有库如果只有一个单位，迁移会把尚未归属的预设消防站挂到该单位；私有种子里的站名也会认领仍未归属的同名站。多单位旧库请用私有种子里的站名完成认领，不要指望迁移猜测归属。

未配置组织的新库不会写入示例单位。不属于任何组织的会话拿到空名单和空消防站，识别退回通用战术词。
