# 单位正射影像地图

App 入口：设置 → 现场地图。首版仅在线查看、拖动、缩放及恢复全图；没有定位、标注或离线下载。坐标为图片像素，不可当作经纬度或导航使用。

沿用后端 `/api/maps` 的单位会话认证。列表及每张瓦片均鉴权，禁止在 Caddy 添加绕过认证的静态映射；认证信息仅放请求头。地图数据是私有运行数据，禁止提交原图和瓦片到公开仓库。普通单位仅能查看本单位目录，`demo` 是唯一共享的合成演示数据。

## 演示部署

本地 Python 需 Pillow（Ubuntu 可安装 `python3-pil`）。下列脚本只生成合成示意图，不下载、不上传任何真实现场数据：

```bash
python3 deploy/maps/prepare.py /tmp/watchdog-map-demo --demo
# 复制到服务器 /opt/watchdog/maps/demo，确保容器 node 用户可以读取
```

Docker Compose 将 `/opt/watchdog/maps` 只读挂载至 `/app/data/orthomaps`，无需新增容器、端口或数据库迁移。其他部署方式可设置 `WATCHDOG_MAP_DIR`。

## 导入实际 JPG

先确认单位 ID（数据库 `units.id`，不是单位名称或单位码）。每份地图使用新的 ASCII 字母、数字、下划线或短横线 ID，最长128字符；`demo` 保留。先在本机切片，核对后再上传私有服务器：

```bash
python3 deploy/maps/prepare.py /tmp/training-yard-v1 --image /path/to/photo.jpg --name '训练场影像'
# 将整个目录上传至 /opt/watchdog/maps/units/<单位ID>/training-yard-v1
```

目录包含 `map.json` 和 `tiles/<z>/<x>/<y>.jpg`，瓦片固定256像素，0级最小、maxZoom为原图分辨率。先上传到私有暂存目录，完成文件数/哈希核对后在同一文件系统 rename 成最终 ID；更新使用新 ID，避免查看中混用两批瓦片。禁止使用符号链接。不要把原图放进瓦片目录。数据量和内存需求取决于原图；Pillow 默认拒绝超过2亿像素的影像，大图应使用 libvips 流式预处理，不能直接在生产后端进程中切片。

## 验收与回滚

- 未认证访问列表/瓦片返回401；跨单位同名地图不得读到其他单位影像。
- 已认证可获取列表及JPEG，App可查看演示、拖动、缩放、恢复全图；断网显示加载失败并可重试。
- 无地图时显示空态；演示图始终标为非真实现场。
- 本功能不修改版本号、不打tag、不发布APK。已有安装版须在用户要求的新版本发布后才能出现新入口。
- 回滚后端到部署前镜像并恢复部署前 Compose；私有地图目录可保留，不影响原业务数据。
