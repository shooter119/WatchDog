# WatchDog Technical Design Documents (RFC SITEMAP)

## Approved Designs
- [四岗极简战术协同闭环 (`four-role-tactical-loop.md`)](./four-role-tactical-loop.md): 面向通讯员一键公文速报生成器与指挥员 3 秒态势卡架构设计（Author: shooter119, Status: Approved）。
- [动态自适应战况速报引擎 (`dynamic-tactical-brief-engine.md`)](./dynamic-tactical-brief-engine.md): 高级指挥员视角的高权重战术要事抽取与场景自适应脚手架设计（Author: shooter119, Status: Approved）。
- [大队级自建水源库与周边水源查找 (`unit-water-sources.md`)](./unit-water-sources.md): 替代高德工作地图小程序的单位自有水源库、三类水源模型（市政消火栓/天然水源/水泵接合器）、独立周边水源页、Web 后台回收站与两阶段存量清洗方案（Date: 2026-11-21, Author: shooter119, Components: `backend/migrations/019_water_sources.sql`, `backend/src/water-sources.js`, `backend/admin`, `app/lib/pages/water_sources_page.dart`, Status: Approved）。
