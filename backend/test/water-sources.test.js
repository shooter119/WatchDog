'use strict';

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { Pool } = require('pg');
const express = require('express');

process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.WATCHDOG_SKIP_SEED = '1';

const baseUrl = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
const pool = new Pool({ connectionString: baseUrl });
const schema = `water_sources_test_${process.pid}_${Date.now()}`;

const {
  createWaterSources,
  normalizeIntakeMethods,
} = require('../src/water-sources');
const {
  createWaterSourceAppRouter,
  createWaterSourceAdminRouter,
} = require('../src/water-source-routes');
const { createAdminAuth } = require('../src/admin-auth');
const { createAdminRouter } = require('../src/admin-router');
const { createAmapJsService } = require('../src/amap-js-proxy');

let store;
let adminAuth;
let waterSources;
let clockMs = 1_750_000_000_000;

let appServer;
let appBase;
let currentAuth = null;

let adminServer;
let adminBase;
let currentAdmin = null;

async function startServer(expressApp) {
  const srv = expressApp.listen(0, '127.0.0.1');
  await new Promise((resolve) => srv.once('listening', resolve));
  return {
    server: srv,
    base: `http://127.0.0.1:${srv.address().port}`,
  };
}

before(async () => {
  await pool.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(baseUrl);
  url.searchParams.set('options', `-c search_path=${schema}`);
  process.env.DATABASE_URL = url.toString();

  store = require('../src/postgres-store');
  await store.ready;

  // 100% 脱敏虚拟测试单位与人员
  await store.query(
    "INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES('unit_a','示例县消防救援大队','1001',1,1),('unit_b','示例区消防救援大队','1002',1,1)",
  );
  await store.query(
    `INSERT INTO unit_members(id,unit_id,real_name,role,status,review_status,created_at,updated_at) VALUES
      ('member_a1','unit_a','张三','member','active','approved',1,1),
      ('member_a2','unit_a','李四','member','active','approved',1,1),
      ('admin_a','unit_a','王五','admin','active','approved',1,1),
      ('member_b1','unit_b','赵六','member','active','approved',1,1),
      ('platform_1','unit_a','周七','admin','active','approved',1,1)`,
  );

  adminAuth = createAdminAuth(store, () => clockMs);
  await adminAuth.setGrant('platform_1', 'platform_1', 'platform_admin', { bootstrap: true });
  await adminAuth.setGrant('platform_1', 'admin_a', 'unit_admin');

  waterSources = createWaterSources(store, { now: () => clockMs });

  const app = express();
  app.use(express.json());
  app.use((req, _res, next) => {
    if (currentAuth) req.auth = currentAuth;
    next();
  });
  app.use('/api/water-sources', createWaterSourceAppRouter(waterSources, { now: () => clockMs }));
  const startedApp = await startServer(app);
  appServer = startedApp.server;
  appBase = startedApp.base;

  const adminApp = express();
  adminApp.use(express.json());
  adminApp.use((req, _res, next) => {
    if (currentAdmin) req.admin = currentAdmin;
    next();
  });
  adminApp.use('/api/admin/water-sources', createWaterSourceAdminRouter(waterSources, adminAuth));
  const startedAdmin = await startServer(adminApp);
  adminServer = startedAdmin.server;
  adminBase = startedAdmin.base;
});

after(async () => {
  if (appServer) await new Promise((resolve) => appServer.close(resolve));
  if (adminServer) await new Promise((resolve) => adminServer.close(resolve));
  await store?.close();
  await pool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  await pool.end();
});

test('019 迁移表结构与数据库 CHECK 约束生效', async () => {
  // 1. 拒绝 natural 水源空取水方式
  await assert.rejects(
    store.query(
      `INSERT INTO water_sources(id,unit_id,category,name,lat,lng,status,intake_methods,note,created_at,updated_at)
       VALUES('chk_1','unit_a','natural','示例池塘',30.1,120.1,'available','{}','',1,1)`,
    ),
  );
  // 2. 拒绝 hydrant 水源带取水方式
  await assert.rejects(
    store.query(
      `INSERT INTO water_sources(id,unit_id,category,name,lat,lng,status,intake_methods,note,created_at,updated_at)
       VALUES('chk_2','unit_a','hydrant','示例消火栓',30.1,120.1,'available',ARRAY['fire_truck']::text[],'',1,1)`,
    ),
  );
  // 3. 拒绝 intake_methods 中包含 NULL 元素
  await assert.rejects(
    store.query(
      `INSERT INTO water_sources(id,unit_id,category,name,lat,lng,status,intake_methods,note,created_at,updated_at)
       VALUES('chk_3','unit_a','natural','示例水池',30.1,120.1,'available',ARRAY['fire_truck',NULL]::text[],'',1,1)`,
    ),
  );
  // 4. 拒绝越界经纬度
  await assert.rejects(
    store.query(
      `INSERT INTO water_sources(id,unit_id,category,name,lat,lng,status,intake_methods,note,created_at,updated_at)
       VALUES('chk_4','unit_a','hydrant','越界点',60.0,120.1,'available','{}','',1,1)`,
    ),
  );
});

test('App 端鉴权守卫：缺失 memberId 或 unitId 返回 401 SESSION_REQUIRED', async () => {
  currentAuth = null;
  const r1 = await fetch(`${appBase}/api/water-sources`);
  assert.equal(r1.status, 401);
  assert.equal((await r1.json()).code, 'SESSION_REQUIRED');

  currentAuth = { memberId: 'member_a1' };
  const r2 = await fetch(`${appBase}/api/water-sources`);
  assert.equal(r2.status, 401);
  assert.equal((await r2.json()).code, 'SESSION_REQUIRED');
});

test('三类水源 CRUD、字段数值类型转换与取水方式规范化', async () => {
  assert.deepEqual(
    normalizeIntakeMethods('natural', ['remote_supply', 'portable_pump', 'remote_supply']),
    ['portable_pump', 'remote_supply'],
  );

  currentAuth = { memberId: 'member_a1', unitId: 'unit_a', realName: '张三' };

  // 创建市政消火栓
  const resHydrant = await fetch(`${appBase}/api/water-sources`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      category: 'hydrant',
      name: '示例一路与平安街交叉口消火栓',
      lat: 30.251234,
      lng: 120.155678,
      note: '水压正常，缺一侧闷盖',
    }),
  });
  assert.equal(resHydrant.status, 201);
  const hydrant = (await resHydrant.json()).item;
  assert.equal(hydrant.category, 'hydrant');
  assert.equal(hydrant.status, 'available');
  assert.deepEqual(hydrant.intake_methods, []);
  assert.equal(typeof hydrant.created_at, 'number');
  assert.equal(typeof hydrant.updated_at, 'number');
  assert.equal(hydrant.deleted_at, null);
  assert.equal(hydrant.created_by, 'member_a1');
  assert.equal(hydrant.created_by_name, '张三');

  // 创建天然水源（自动去重并按固定顺序排序）
  const resNatural = await fetch(`${appBase}/api/water-sources`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      category: 'natural',
      name: '示例村消防水池',
      lat: 30.253,
      lng: 120.158,
      status: 'available',
      intake_methods: ['remote_supply', 'fire_truck', 'fire_truck'],
      note: '蓄水量 120 立方米',
    }),
  });
  assert.equal(resNatural.status, 201);
  const natural = (await resNatural.json()).item;
  assert.deepEqual(natural.intake_methods, ['fire_truck', 'remote_supply']);

  // 创建水泵接合器（不可用）
  const resPump = await fetch(`${appBase}/api/water-sources`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      category: 'pump_connector',
      name: '示例大厦北侧水泵接合器',
      lat: 30.255,
      lng: 120.16,
      status: 'unavailable',
      note: '接口锈蚀待修',
    }),
  });
  assert.equal(resPump.status, 201);

  // 列表与统计摘要（确认 COUNT(*) 为 Number）
  const listRes = await fetch(`${appBase}/api/water-sources`);
  assert.equal(listRes.status, 200);
  const listBody = await listRes.json();
  assert.equal(listBody.items.length, 3);
  assert.deepEqual(listBody.summary, {
    total: 3,
    available: 2,
    unavailable: 1,
    by_category: {
      hydrant: 1,
      natural: 1,
      pump_connector: 1,
    },
  });
  assert.equal(typeof listBody.summary.total, 'number');

  // PATCH: 天然水源切换为市政消火栓时自动清空 intake_methods
  clockMs += 5000;
  const patchRes = await fetch(`${appBase}/api/water-sources/${natural.id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      category: 'hydrant',
      status: 'unavailable',
      note: '已改造为市政栓，待通水',
    }),
  });
  assert.equal(patchRes.status, 200);
  const patched = (await patchRes.json()).item;
  assert.equal(patched.category, 'hydrant');
  assert.deepEqual(patched.intake_methods, []);
  assert.equal(patched.status, 'unavailable');
  assert.equal(patched.updated_at, clockMs);

  // PATCH: 从非天然切换为天然但未提供取水方式 -> 400 INVALID_INTAKE_METHODS
  const badSwitch = await fetch(`${appBase}/api/water-sources/${patched.id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ category: 'natural' }),
  });
  assert.equal(badSwitch.status, 400);
  assert.equal((await badSwitch.json()).code, 'INVALID_INTAKE_METHODS');
});

test('参数校验错误码覆盖：类别、状态、坐标、名称、备注、取水方式', async () => {
  currentAuth = { memberId: 'member_a1', unitId: 'unit_a', realName: '张三' };

  const cases = [
    { body: { category: 'unknown', name: '点位', lat: 30, lng: 120 }, code: 'INVALID_CATEGORY' },
    { body: { category: 'hydrant', name: '点位', lat: 30, lng: 120, status: 'broken' }, code: 'INVALID_STATUS' },
    { body: { category: 'hydrant', name: '   ', lat: 30, lng: 120 }, code: 'INVALID_NAME' },
    { body: { category: 'hydrant', name: '名'.repeat(121), lat: 30, lng: 120 }, code: 'INVALID_NAME' },
    { body: { category: 'hydrant', name: '点位', lat: 2.9, lng: 120 }, code: 'INVALID_COORDINATES' },
    { body: { category: 'hydrant', name: '点位', lat: 30, lng: 137 }, code: 'INVALID_COORDINATES' },
    { body: { category: 'hydrant', name: '点位', lat: 'abc', lng: 120 }, code: 'INVALID_COORDINATES' },
    { body: { category: 'hydrant', name: '点位', lat: 30, lng: 120, note: '备'.repeat(501) }, code: 'INVALID_NOTE' },
    { body: { category: 'natural', name: '水池', lat: 30, lng: 120, intake_methods: [] }, code: 'INVALID_INTAKE_METHODS' },
    { body: { category: 'natural', name: '水池', lat: 30, lng: 120, intake_methods: ['invalid'] }, code: 'INVALID_INTAKE_METHODS' },
    { body: { category: 'hydrant', name: '栓', lat: 30, lng: 120, intake_methods: ['fire_truck'] }, code: 'INVALID_INTAKE_METHODS' },
  ];

  for (const tc of cases) {
    const res = await fetch(`${appBase}/api/water-sources`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(tc.body),
    });
    assert.equal(res.status, 400, `期望 ${tc.code} 返回 400`);
    assert.equal((await res.json()).code, tc.code);
  }
});

test('跨单位隔离与 App 端 60 秒原删除人撤销窗口', async () => {
  currentAuth = { memberId: 'member_a1', unitId: 'unit_a', realName: '张三' };
  const created = (await (await fetch(`${appBase}/api/water-sources`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      category: 'hydrant',
      name: '示例二路消火栓',
      lat: 30.26,
      lng: 120.17,
    }),
  })).json()).item;

  // 异单位成员不可查看/编辑/删除
  currentAuth = { memberId: 'member_b1', unitId: 'unit_b', realName: '赵六' };
  const bList = await (await fetch(`${appBase}/api/water-sources`)).json();
  assert.equal(bList.items.some((i) => i.id === created.id), false);

  const bPatch = await fetch(`${appBase}/api/water-sources/${created.id}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: '越权修改' }),
  });
  assert.equal(bPatch.status, 404);
  assert.equal((await bPatch.json()).code, 'WATER_SOURCE_NOT_FOUND');

  // 原单位张三软删除
  currentAuth = { memberId: 'member_a1', unitId: 'unit_a', realName: '张三' };
  const delRes = await fetch(`${appBase}/api/water-sources/${created.id}`, { method: 'DELETE' });
  assert.equal(delRes.status, 200);
  const delBody = await delRes.json();
  assert.equal(delBody.id, created.id);
  assert.equal(typeof delBody.deleted_at, 'number');

  // 同单位他人李四在 60 秒内尝试撤销 -> 409 RESTORE_WINDOW_EXPIRED
  currentAuth = { memberId: 'member_a2', unitId: 'unit_a', realName: '李四' };
  const otherRestore = await fetch(`${appBase}/api/water-sources/${created.id}/restore`, { method: 'POST' });
  assert.equal(otherRestore.status, 409);
  assert.equal((await otherRestore.json()).code, 'RESTORE_WINDOW_EXPIRED');

  // 原删除人张三在 30 秒内撤销 -> 200
  clockMs += 30_000;
  currentAuth = { memberId: 'member_a1', unitId: 'unit_a', realName: '张三' };
  const okRestore = await fetch(`${appBase}/api/water-sources/${created.id}/restore`, { method: 'POST' });
  assert.equal(okRestore.status, 200);
  assert.equal((await okRestore.json()).item.deleted_at, null);

  // 对未删除记录再次 restore -> 幂等返回 200
  const idempotentRestore = await fetch(`${appBase}/api/water-sources/${created.id}/restore`, { method: 'POST' });
  assert.equal(idempotentRestore.status, 200);

  // 再次删除并超过 60 秒后，原删除人也无法在 App 端撤销 -> 409 RESTORE_WINDOW_EXPIRED
  await fetch(`${appBase}/api/water-sources/${created.id}`, { method: 'DELETE' });
  clockMs += 61_000;
  const expiredRestore = await fetch(`${appBase}/api/water-sources/${created.id}/restore`, { method: 'POST' });
  assert.equal(expiredRestore.status, 409);
  assert.equal((await expiredRestore.json()).code, 'RESTORE_WINDOW_EXPIRED');

  // 管理员在后台恢复不受 60 秒窗口限制且写入 admin_audit
  currentAdmin = { id: 'admin_a', unit_id: 'unit_a', real_name: '王五', admin_role: 'unit_admin' };
  const adminRestore = await fetch(`${adminBase}/api/admin/water-sources/${created.id}/restore`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({}),
  });
  assert.equal(adminRestore.status, 200);
  assert.equal((await adminRestore.json()).item.deleted_at, null);

  const auditRes = await store.query(
    "SELECT * FROM admin_audit WHERE actor_id = 'admin_a' AND action = 'water_source_restored' AND target_id = $1",
    [created.id],
  );
  assert.equal(auditRes.rows.length, 1);
});

test('Admin 路由权限边界：unit_admin 锁定本单位、platform_admin 可切换单位、分页检索与审计落库', async () => {
  // unit_admin 访问异单位 -> 403 UNIT_FORBIDDEN
  currentAdmin = { id: 'admin_a', unit_id: 'unit_a', real_name: '王五', admin_role: 'unit_admin' };
  const forbiddenGet = await fetch(`${adminBase}/api/admin/water-sources?unit_id=unit_b`);
  assert.equal(forbiddenGet.status, 403);
  assert.equal((await forbiddenGet.json()).code, 'UNIT_FORBIDDEN');

  const forbiddenPost = await fetch(`${adminBase}/api/admin/water-sources`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      unit_id: 'unit_b',
      category: 'hydrant',
      name: '越权新增',
      lat: 30.2,
      lng: 120.2,
    }),
  });
  assert.equal(forbiddenPost.status, 403);
  assert.equal((await forbiddenPost.json()).code, 'UNIT_FORBIDDEN');

  // platform_admin 切换到 unit_b 新增、查询、编辑、软删并验证回收站与审计
  currentAdmin = { id: 'platform_1', unit_id: 'unit_a', real_name: '周七', admin_role: 'platform_admin' };
  const createB = await fetch(`${adminBase}/api/admin/water-sources`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      unit_id: 'unit_b',
      category: 'natural',
      name: '示例区南河取水点',
      lat: 30.31,
      lng: 120.21,
      intake_methods: ['portable_pump'],
      note: '枯水期水位较浅',
    }),
  });
  assert.equal(createB.status, 201);
  const itemB = (await createB.json()).item;
  assert.equal(itemB.unit_id, 'unit_b');

  // 关键词 ILIKE 命中备注与分页
  const queryB = await fetch(`${adminBase}/api/admin/water-sources?unit_id=unit_b&q=${encodeURIComponent('枯水期')}&limit=10&offset=0`);
  assert.equal(queryB.status, 200);
  const queryBody = await queryB.json();
  assert.equal(queryBody.total, 1);
  assert.equal(queryBody.items.length, 1);
  assert.equal(queryBody.items[0].id, itemB.id);
  assert.equal(queryBody.summary.by_category.natural, 1);

  // 编辑 + 软删 + 回收站筛选
  const patchB = await fetch(`${adminBase}/api/admin/water-sources/${itemB.id}?unit_id=unit_b`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ status: 'unavailable' }),
  });
  assert.equal(patchB.status, 200);

  const delB = await fetch(`${adminBase}/api/admin/water-sources/${itemB.id}?unit_id=unit_b`, {
    method: 'DELETE',
  });
  assert.equal(delB.status, 200);

  const trashRes = await fetch(`${adminBase}/api/admin/water-sources?unit_id=unit_b&deleted=only`);
  const trashBody = await trashRes.json();
  assert.equal(trashBody.total, 1);
  assert.equal(trashBody.items[0].id, itemB.id);

  // 验证 create/update/delete 审计均写入 admin_audit
  const auditRows = (await store.query(
    "SELECT action FROM admin_audit WHERE actor_id = 'platform_1' AND target_id = $1 ORDER BY created_at ASC",
    [itemB.id],
  )).rows.map((r) => r.action);
  assert.deepEqual(auditRows, ['water_source_created', 'water_source_updated', 'water_source_deleted']);
});

test('普通未授权 member 无法通过真实 adminRouter 访问 /api/admin/water-sources', async () => {
  const realAdminApp = express();
  realAdminApp.use(express.json());
  realAdminApp.use('/api/admin', createAdminRouter(adminAuth, {
    origin: 'https://fireman119.xyz',
    waterSources,
  }));
  const srv = await startServer(realAdminApp);
  try {
    const res = await fetch(`${srv.base}/api/admin/water-sources`);
    assert.equal(res.status, 401);
    assert.equal((await res.json()).code, 'ADMIN_SESSION_INVALID');

    // 普通成员扫码确认也应返回 ADMIN_FORBIDDEN
    const ch = await adminAuth.challenge();
    await assert.rejects(
      adminAuth.confirm(ch.id, ch.scan, 'member_a1'),
      (err) => err.code === 'ADMIN_FORBIDDEN' && err.status === 403,
    );
  } finally {
    await new Promise((resolve) => srv.server.close(resolve));
  }
});

test('App 写限流（30/min/memberId）与单单位活跃上限守卫', async () => {
  const cappedService = createWaterSources(store, {
    now: () => clockMs,
    maxActivePerUnit: 2,
  });
  const limitedApp = express();
  limitedApp.use(express.json());
  limitedApp.use((req, _res, next) => {
    req.auth = { memberId: 'member_limit', unitId: 'unit_b', realName: '测试限流员' };
    next();
  });
  limitedApp.use('/api/water-sources', createWaterSourceAppRouter(cappedService, {
    now: () => clockMs,
    writeLimitPerMin: 2,
  }));
  const srv = await startServer(limitedApp);

  try {
    const r1 = await fetch(`${srv.base}/api/water-sources`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ category: 'hydrant', name: '限流测试栓1', lat: 30.11, lng: 120.11 }),
    });
    assert.equal(r1.status, 201);

    const r2 = await fetch(`${srv.base}/api/water-sources`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ category: 'hydrant', name: '限流测试栓2', lat: 30.12, lng: 120.12 }),
    });
    assert.equal(r2.status, 201);

    // 第 3 次写操作触发写限流 429
    const r3 = await fetch(`${srv.base}/api/water-sources`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ category: 'hydrant', name: '限流测试栓3', lat: 30.13, lng: 120.13 }),
    });
    assert.equal(r3.status, 429);
    assert.equal((await r3.json()).code, 'WATER_SOURCE_RATE_LIMITED');

    // 推进 61 秒解除限流后，验证活跃上限 409 WATER_SOURCE_LIMIT_REACHED
    clockMs += 61_000;
    const r4 = await fetch(`${srv.base}/api/water-sources`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ category: 'hydrant', name: '超上限栓', lat: 30.14, lng: 120.14 }),
    });
    assert.equal(r4.status, 409);
    assert.equal((await r4.json()).code, 'WATER_SOURCE_LIMIT_REACHED');
  } finally {
    await new Promise((resolve) => srv.server.close(resolve));
  }
});

test('upsertImportedBatch: 单事务幂等入库、保护人工修改与 forceOverwrite 守卫', async () => {
  const batch = [
    {
      import_key: 'imp_key_1',
      category: 'hydrant',
      name: '示例三路导入栓1',
      lat: 30.281,
      lng: 120.181,
      status: 'available',
      note: '初始导入备注',
    },
    {
      import_key: 'imp_key_2',
      category: 'natural',
      name: '示例三路导入水池2',
      lat: 30.282,
      lng: 120.182,
      status: 'available',
      intake_methods: ['fire_truck', 'portable_pump'],
      note: '初始水池备注',
    },
  ];

  // 首次导入
  const first = await waterSources.upsertImportedBatch('unit_a', batch);
  assert.deepEqual(first, { total: 2, inserted: 2, updated: 0, skipped: 0 });

  // 默认二次导入：完全幂等，0 新增 0 更新 2 跳过
  const second = await waterSources.upsertImportedBatch('unit_a', [
    { ...batch[0], note: '尝试覆盖备注' },
    { ...batch[1], status: 'unavailable' },
  ]);
  assert.deepEqual(second, { total: 2, inserted: 0, updated: 0, skipped: 2 });

  // 模拟一线消防员人工编辑了第 1 条记录
  const row1 = (await store.query(
    "SELECT id FROM water_sources WHERE unit_id = 'unit_a' AND import_key = 'imp_key_1'",
  )).rows[0];
  await waterSources.update(
    'unit_a',
    row1.id,
    { status: 'unavailable', note: '一线核实无水' },
    { actorId: 'member_a1', actorName: '张三' },
  );

  // 开启 forceOverwrite 重新导入：
  // - imp_key_1 已被人工修改（updated_by !== 'import_script'），必须跳过保护
  // - imp_key_2 仍为 import_script，允许覆盖更新
  const third = await waterSources.upsertImportedBatch(
    'unit_a',
    [
      { ...batch[0], status: 'available', note: '脚本强覆写不应生效' },
      { ...batch[1], status: 'unavailable', note: '脚本修正水池状态' },
    ],
    { forceOverwrite: true },
  );
  assert.deepEqual(third, { total: 2, inserted: 0, updated: 1, skipped: 1 });

  const after1 = await waterSources.getById('unit_a', row1.id);
  assert.equal(after1.status, 'unavailable');
  assert.equal(after1.note, '一线核实无水');

  const row2 = (await store.query(
    "SELECT * FROM water_sources WHERE unit_id = 'unit_a' AND import_key = 'imp_key_2'",
  )).rows[0];
  assert.equal(row2.status, 'unavailable');
  assert.equal(row2.note, '脚本修正水池状态');
});

test('amap-js-proxy 代理限流键优先按 sessionId 隔离，缺失时回退 unitId', async () => {
  const service = createAmapJsService({
    getConfig: () => ({ jsKey: 'demo-key', jsSecret: 'demo-secret' }),
    secretSeed: 'water-source-proxy-test',
    fetchImpl: async () => new Response('ok', { status: 200 }),
    webapiBase: 'https://webapi.example.test',
    restapiBase: 'https://restapi.example.test',
  });
  const srv = await startServer(express().use('/api/amap-proxy', service.proxyRouter));
  try {
    const ticketSess1 = service.issueTicket({ unitId: 'unit_shared', sessionId: 'sess_a' });
    const ticketSess2 = service.issueTicket({ unitId: 'unit_shared', sessionId: 'sess_b' });
    const ticketNoSess = service.issueTicket({ unitId: 'unit_shared', sessionId: '' });

    // 打满 sess_a 的 360 次配额
    for (let i = 0; i < 360; i++) {
      const r = await fetch(`${srv.base}/api/amap-proxy/${ticketSess1}/_AMapService/v3/config/district`);
      assert.equal(r.status, 200);
    }
    const limitedA = await fetch(`${srv.base}/api/amap-proxy/${ticketSess1}/_AMapService/v3/config/district`);
    assert.equal(limitedA.status, 429);

    // 同 unitId 下的 sess_b 与无 sessionId 的回退桶不受影响
    const okB = await fetch(`${srv.base}/api/amap-proxy/${ticketSess2}/_AMapService/v3/config/district`);
    assert.equal(okB.status, 200);
    const okFallback = await fetch(`${srv.base}/api/amap-proxy/${ticketNoSess}/_AMapService/v3/config/district`);
    assert.equal(okFallback.status, 200);
  } finally {
    await new Promise((resolve) => srv.server.close(resolve));
  }
});
