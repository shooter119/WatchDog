const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { Pool } = require('pg');
const express = require('express');
const xlsx = require('xlsx');

process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.WATCHDOG_SKIP_SEED = '1';

const baseUrl = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
const pool = new Pool({ connectionString: baseUrl });
const schema = `hazmat_test_${process.pid}_${Date.now()}`;
let store;
let hazmats;
let server;
let base;
let adminServer;
let adminBase;

const {
  createHazardousChemicals,
  cleanAliases,
  normalizeWaterReactivity,
  normalizeSignColor
} = require('../src/hazardous-chemicals');
const {
  createHazmatAdminRouter,
  createHazmatAppRouter
} = require('../src/hazmat-routes');

before(async () => {
  await pool.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(baseUrl);
  url.searchParams.set('options', `-c search_path=${schema}`);
  process.env.DATABASE_URL = url.toString();

  store = require('../src/postgres-store');
  await store.ready;

  await store.query(
    "INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES('unit_1','测试消防站','119',1,1)"
  );
  await store.query(
    "INSERT INTO unit_members(id,unit_id,real_name,role,created_at,updated_at) VALUES('admin_1','unit_1','测试管理员','admin',1,1)"
  );

  hazmats = createHazardousChemicals(store);

  // 模拟客户端查询 App
  const app = express();
  app.use(express.json());
  app.use('/api/hazmats', createHazmatAppRouter(hazmats));
  server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;

  // 模拟后台管理 Admin App
  const adminApp = express();
  adminApp.use(express.json());
  adminApp.use((req, res, next) => {
    req.admin = { id: 'admin_1', unit_id: 'unit_1', real_name: '测试管理员' };
    next();
  });
  adminApp.use('/api/admin/hazmats', createHazmatAdminRouter(hazmats, {
    audit: async () => {}
  }));
  adminServer = adminApp.listen(0, '127.0.0.1');
  await new Promise((resolve) => adminServer.once('listening', resolve));
  adminBase = `http://127.0.0.1:${adminServer.address().port}`;
});

after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  if (adminServer) await new Promise((resolve) => adminServer.close(resolve));
  await store?.close();
  await pool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  await pool.end();
});

test('工具函数：多别名清洗、水反应性与色标自动推断', () => {
  const aliases1 = cleanAliases('氯仿; 三氯代甲烷, CHCl3 | 甲基氯仿 / 氯仿');
  assert.deepEqual(aliases1, ['氯仿', '三氯代甲烷', 'CHCl3', '甲基氯仿']);

  const aliases2 = cleanAliases(['钠 ', ' Na', '金属钠', '']);
  assert.deepEqual(aliases2, ['钠', 'Na', '金属钠']);

  assert.equal(normalizeWaterReactivity('forbidden'), 'forbidden');
  assert.equal(normalizeWaterReactivity('', '严禁用水、泡沫扑救'), 'forbidden');
  assert.equal(normalizeWaterReactivity('遇水剧烈反应'), 'reactive');
  assert.equal(normalizeWaterReactivity('normal'), 'normal');

  assert.equal(normalizeSignColor('第3类 易燃液体'), 'red');
  assert.equal(normalizeSignColor('第4.3项 遇水放出易燃气体的物质'), 'blue');
  assert.equal(normalizeSignColor('第6.1项 毒性物质'), 'white');
  assert.equal(normalizeSignColor('第8类 腐蚀品'), 'black_white');
  assert.equal(normalizeSignColor('第5.1项 氧化性物质'), 'yellow');
});

test('核心业务：CRUD生命周期与多别名检索命中', async () => {
  // 1. 创建
  const created = await hazmats.create({
    name_cn: '三氯甲烷',
    name_en: 'Chloroform',
    aliases: ['氯仿', '三氯代甲烷', 'CHCl3'],
    un_number: '1888',
    cas_number: '67-66-3',
    danger_category: '第6.1项 毒性物质',
    water_reactivity: 'normal',
    danger_summary: '遇明火高温光解生成剧毒光气',
    forbidden_agents: '严禁直流水冲击液体飞溅',
    extinguishing_agents: '雾状水、二氧化碳、干粉、砂土',
    protective_level: '正压空呼 + 一级特级防化服',
    isolation_distance: '小泄漏隔离60m，大火下风向疏散300m'
  }, 'admin_1');

  assert.ok(created.id);
  assert.equal(created.name_cn, '三氯甲烷');
  assert.equal(created.un_number, '1888');
  assert.deepEqual(created.aliases, ['氯仿', '三氯代甲烷', 'CHCl3']);
  assert.equal(created.water_reactivity, 'normal');

  // 2. 根据 ID 查询
  const fetched = await hazmats.getById(created.id);
  assert.equal(fetched.name_cn, '三氯甲烷');

  // 3. 别名搜索（搜“氯仿”能搜出“三氯甲烷”并标记 matched_alias）
  const searchByAlias = await hazmats.list({ query: '氯仿' });
  assert.equal(searchByAlias.total, 1);
  assert.equal(searchByAlias.items[0].name_cn, '三氯甲烷');
  assert.equal(searchByAlias.items[0].matched_alias, '氯仿');

  // 4. UN号搜索
  const searchByUn = await hazmats.list({ query: '1888' });
  assert.equal(searchByUn.total, 1);
  assert.equal(searchByUn.items[0].un_number, '1888');

  // 5. 更新
  const updated = await hazmats.update(created.id, {
    isolation_distance: '小泄漏隔离100米，火灾警戒500米',
    water_reactivity: 'forbidden'
  }, 'admin_1');
  assert.equal(updated.isolation_distance, '小泄漏隔离100米，火灾警戒500米');
  assert.equal(updated.water_reactivity, 'forbidden');

  // 6. 按禁水属性筛选
  const forbiddenList = await hazmats.list({ water: 'forbidden' });
  assert.equal(forbiddenList.total, 1);

  // 7. 软删除
  await hazmats.remove(created.id, 'admin_1');
  const activeList = await hazmats.list({ query: '三氯甲烷' });
  assert.equal(activeList.total, 0);

  const deletedItem = await hazmats.getById(created.id);
  assert.equal(deletedItem.active, false);
});

test('批量导入：模板生成、XLSX与CSV解析、查重跳过与覆盖更新', async () => {
  // 生成 Excel 模板
  const xlsxBuffer = hazmats.generateTemplate('xlsx');
  assert.ok(xlsxBuffer instanceof Buffer);
  assert.ok(xlsxBuffer.length > 0);

  // 导入生成的模板（含三氯甲烷和金属钠样例）
  const importResult1 = await hazmats.importBatch(xlsxBuffer, 'template.xlsx', 'admin_1', { overwrite: false });
  assert.equal(importResult1.totalRows, 2);
  assert.equal(importResult1.imported, 2);
  assert.equal(importResult1.skipped, 0);

  // 验证金属钠（第4.3项遇水放出易燃气体）入库正确性
  const naList = await hazmats.list({ query: '金属钠' });
  assert.equal(naList.total, 1);
  const na = naList.items[0];
  assert.equal(na.water_reactivity, 'forbidden');
  assert.equal(na.danger_sign_color, 'blue');
  assert.equal(na.un_number, '1428');

  // 再次不覆盖导入 -> 全部跳过
  const importResult2 = await hazmats.importBatch(xlsxBuffer, 'template.xlsx', 'admin_1', { overwrite: false });
  assert.equal(importResult2.imported, 0);
  assert.equal(importResult2.skipped, 2);

  // 覆盖更新导入 -> 全部 updated
  const importResult3 = await hazmats.importBatch(xlsxBuffer, 'template.xlsx', 'admin_1', { overwrite: true });
  assert.equal(importResult3.imported, 0);
  assert.equal(importResult3.updated, 2);

  // 测试 CSV 导入
  const csvBuffer = hazmats.generateTemplate('csv');
  assert.ok(csvBuffer instanceof Buffer);
  const importCsvResult = await hazmats.importBatch(csvBuffer, 'template.csv', 'admin_1', { overwrite: true });
  assert.equal(importCsvResult.totalRows, 2);
  assert.equal(importCsvResult.updated, 2);
});

test('HTTP 接口测试：管理端 CRUD/模板下载/导入 与 客户端只读检索', async () => {
  // 1. 管理端下载模板
  const tmplRes = await fetch(`${adminBase}/api/admin/hazmats/template?format=xlsx`);
  assert.equal(tmplRes.status, 200);
  assert.ok(tmplRes.headers.get('content-disposition').includes('attachment; filename='));

  // 2. 管理端手工录入
  const createRes = await fetch(`${adminBase}/api/admin/hazmats`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      name_cn: '环氧乙烷',
      name_en: 'Ethylene oxide',
      aliases: ['氧化乙烯', '恶烷'],
      un_number: '1040',
      danger_category: '第2.1项 易燃气体',
      water_reactivity: 'normal',
      forbidden_agents: '严禁直流水冲击'
    })
  });
  assert.equal(createRes.status, 201);
  const createData = await createRes.json();
  assert.equal(createData.item.name_cn, '环氧乙烷');
  const eoId = createData.item.id;

  // 3. 客户端只读检索（支持搜别名“恶烷”）
  const clientRes = await fetch(`${base}/api/hazmats?q=恶烷`);
  assert.equal(clientRes.status, 200);
  const clientData = await clientRes.json();
  assert.equal(clientData.total, 1);
  assert.equal(clientData.items[0].name_cn, '环氧乙烷');
  assert.equal(clientData.items[0].matched_alias, '恶烷');

  // 4. 管理端单条详情与更新
  const updateRes = await fetch(`${adminBase}/api/admin/hazmats/${eoId}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      isolation_distance: '起火警戒800米'
    })
  });
  assert.equal(updateRes.status, 200);
  const updateData = await updateRes.json();
  assert.equal(updateData.item.isolation_distance, '起火警戒800米');

  // 5. 管理端删除
  const delRes = await fetch(`${adminBase}/api/admin/hazmats/${eoId}`, {
    method: 'DELETE'
  });
  assert.equal(delRes.status, 200);

  // 6. 删除后客户端再查返回空
  const clientAfterDel = await fetch(`${base}/api/hazmats?q=环氧乙烷`);
  const clientAfterDelData = await clientAfterDel.json();
  assert.equal(clientAfterDelData.total, 0);
});
