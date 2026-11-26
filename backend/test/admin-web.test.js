const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { Pool } = require('pg');
const express = require('express');
const xlsx = require('xlsx');

process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.WATCHDOG_SKIP_SEED = '1';

const baseUrl = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
const pool = new Pool({ connectionString: baseUrl });
const schema = `admin_web_${process.pid}_${Date.now()}`;
const adminDir = path.join(__dirname, '..', 'admin');

let store;
let auth;
let hazmats;
let server;
let base;
let now = Date.now();

const { createAdminAuth } = require('../src/admin-auth');
const { createAdminRouter } = require('../src/admin-router');
const {
  createHazardousChemicals,
  normalizeSignColor,
  escapeIlike,
} = require('../src/hazardous-chemicals');
const { createHazmatAdminRouter } = require('../src/hazmat-routes');

function walkFiles(dir, ext) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walkFiles(full, ext));
    else if (!ext || full.endsWith(ext)) out.push(full);
  }
  return out;
}

before(async () => {
  await pool.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(baseUrl);
  url.searchParams.set('options', `-c search_path=${schema}`);
  process.env.DATABASE_URL = url.toString();

  store = require('../src/postgres-store');
  await store.ready;

  await store.query(
    "INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES('unit_a','示例市消防救援大队','119',1,1)",
  );
  await store.query(
    "INSERT INTO unit_members(id,unit_id,real_name,role,created_at,updated_at) VALUES('platform_1','unit_a','张三','admin',1,1)",
  );

  auth = createAdminAuth(store, () => now);
  await auth.setGrant(null, 'platform_1', 'platform_admin', { bootstrap: true });
  hazmats = createHazardousChemicals(store);

  const app = express();
  app.use((req, res, next) => {
    const isAdminRoute = req.path === '/admin' || req.path.startsWith('/admin/') || req.path === '/api/admin' || req.path.startsWith('/api/admin/');
    if (isAdminRoute) {
      if (req.method === 'OPTIONS') return res.status(403).end();
      return next();
    }
    res.setHeader('Access-Control-Allow-Origin', '*');
    next();
  });
  app.use(express.json());
  app.use('/api/admin', createAdminRouter(auth, {
    origin: 'https://fireman119.xyz',
  }));
  app.use('/api/admin-hazmats-test', (req, _res, next) => {
    req.admin = { id: 'platform_1', unit_id: 'unit_a', real_name: '张三' };
    next();
  }, createHazmatAdminRouter(hazmats, { audit: async () => {} }));

  server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});

after(async () => {
  if (server) await new Promise((resolve) => server.close(resolve));
  await store?.close();
  await pool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  await pool.end();
});

test('CSS 与 HTML 壳体强约束：[hidden] 显式隐藏、扫码落地页存在、ES 模块零内联 HTML 拼接', () => {
  const baseCss = fs.readFileSync(path.join(adminDir, 'css', 'base.css'), 'utf8');
  const panoCss = fs.readFileSync(path.join(adminDir, 'css', 'pano.css'), 'utf8');
  assert.match(baseCss, /\[hidden\]\s*\{[^}]*display:\s*none\s*!important/i);
  assert.match(panoCss, /\[hidden\]\s*\{[^}]*display:\s*none\s*!important/i);

  const indexHtml = fs.readFileSync(path.join(adminDir, 'index.html'), 'utf8');
  assert.match(indexHtml, /href="\/admin\/css\/main\.css"/);
  assert.match(indexHtml, /<script type="module" src="\/admin\/js\/main\.js"><\/script>/);
  assert.match(indexHtml, /id="login"/);
  assert.match(indexHtml, /id="workspace"[^>]*hidden/);

  const scanHtml = fs.readFileSync(path.join(adminDir, 'scan.html'), 'utf8');
  assert.match(scanHtml, /火场智控/);
  assert.match(scanHtml, /扫一扫/);

  const jsFiles = walkFiles(path.join(adminDir, 'js'), '.js');
  assert.ok(jsFiles.length >= 18, `expected modular admin JS files, found ${jsFiles.length}`);
  for (const file of jsFiles) {
    const content = fs.readFileSync(file, 'utf8');
    assert.doesNotMatch(content, /\b(innerHTML|outerHTML|insertAdjacentHTML|document\.write)\b/, `unsafe HTML sink in ${file}`);
  }

  for (const legacy of ['app.js', 'sites.js', 'hazmats.js', 'pano.js', 'style.css', 'pano.css']) {
    assert.equal(fs.existsSync(path.join(adminDir, legacy)), false, `legacy file ${legacy} should be removed`);
  }
});

test('后端鉴权路由：返回 expiresInMs、空请求体安全兜底、CORS 隔离与拆分限流', async () => {
  const TRUSTED_ORIGIN = 'https://fireman119.xyz';
  const preflight = await fetch(`${base}/api/admin/me`, { method: 'OPTIONS' });
  assert.equal(preflight.status, 403);
  assert.equal(preflight.headers.get('access-control-allow-origin'), null);

  // Mismatched Origin must be rejected with 403 ADMIN_ORIGIN_INVALID
  const badOriginRes = await fetch(`${base}/api/admin/login/challenges`, {
    method: 'POST',
    headers: { Origin: base },
  });
  assert.equal(badOriginRes.status, 403);
  assert.equal((await badOriginRes.json()).code, 'ADMIN_ORIGIN_INVALID');

  const res = await fetch(`${base}/api/admin/login/challenges`, {
    method: 'POST',
    headers: { Origin: TRUSTED_ORIGIN },
  });
  assert.equal(res.status, 200);
  const data = await res.json();
  assert.ok(data.expiresInMs > 100000 && data.expiresInMs <= 120000);
  assert.match(data.qrPayload, /^https:\/\/fireman119\.xyz\/admin\/scan#/);

  // Empty/missing JSON body on claim must return clean 409 rather than 500 TypeError
  const emptyClaim = await fetch(`${base}/api/admin/login/claim`, {
    method: 'POST',
    headers: { Origin: TRUSTED_ORIGIN },
  });
  assert.equal(emptyClaim.status, 409);
  assert.equal((await emptyClaim.json()).code, 'ADMIN_CHALLENGE_INVALID');

  // Claim polling limit (240/min) is independent from challenge creation limit (30/min)
  const cookie = res.headers.getSetCookie().find((c) => c.startsWith('__Host-watchdog_browser=') || c.startsWith('watchdog_browser='));
  assert.ok(cookie);
  const cookiePair = cookie.split(';')[0];
  for (let i = 0; i < 35; i += 1) {
    const poll = await fetch(`${base}/api/admin/login/claim`, {
      method: 'POST',
      headers: { Origin: TRUSTED_ORIGIN, 'Content-Type': 'application/json', Cookie: cookiePair },
      body: JSON.stringify({ id: data.id }),
    });
    assert.equal(poll.status, 202, `claim poll #${i + 1} should not be rate limited by challenge limiter`);
  }

  // Fast-fail empty token in admin-auth session()
  await assert.rejects(() => auth.session(''), { code: 'ADMIN_SESSION_INVALID' });
});

test('危化品后端加固：2.3类有毒气体颜色、精准类别匹配、ILIKE 转义、更新重算色标与批量导入去重/上限', async () => {
  // Class 2.3 toxic gas MUST be white, not red!
  assert.equal(normalizeSignColor('2.3 有毒气体'), 'white');
  assert.equal(normalizeSignColor('6.1 毒害品'), 'white');
  assert.equal(normalizeSignColor('3 易燃液体'), 'red');
  assert.equal(normalizeSignColor('4.3 遇湿易燃物品'), 'blue');
  assert.equal(escapeIlike('50%_硫酸\\液'), '50\\%\\_硫酸\\\\液');

  const gas = await hazmats.create({
    name_cn: '氯气测试样',
    un_number: '1017',
    danger_category: '2.3 有毒气体',
    water_reactivity: 'normal',
  }, 'platform_1');
  assert.equal(gas.danger_sign_color, 'white');

  const liq = await hazmats.create({
    name_cn: '乙醇测试样',
    un_number: '1170',
    danger_category: '3 易燃液体',
    water_reactivity: 'normal',
  }, 'platform_1');
  assert.equal(liq.danger_sign_color, 'red');

  const wet = await hazmats.create({
    name_cn: '金属钠测试样',
    un_number: '1428',
    danger_category: '4.3 遇湿易燃物品',
    water_reactivity: 'forbidden',
  }, 'platform_1');
  assert.equal(wet.danger_sign_color, 'blue');

  await hazmats.create({
    name_cn: '100%_特异介质',
    un_number: '9991',
    danger_category: '8 腐蚀品',
    water_reactivity: 'reactive',
  }, 'platform_1');

  // Filtering by category '3' must ONLY return '3 易燃液体', NOT '2.3' or '4.3'
  const cat3 = await hazmats.list({ category: '3' });
  assert.deepEqual(cat3.items.map((x) => x.name_cn), ['乙醇测试样']);

  // ILIKE wildcard '%' must NOT match unrelated rows
  const pctSearch = await hazmats.list({ query: '%_' });
  assert.deepEqual(pctSearch.items.map((x) => x.name_cn), ['100%_特异介质']);

  // Updating danger_category without explicit danger_sign_color auto-recalculates color
  const updated = await hazmats.update(liq.id, { danger_category: '8 腐蚀品' }, 'platform_1');
  assert.equal(updated.danger_sign_color, 'black_white');

  // importBatch matches existing by UN number & accepts both 蒸气密度 / 蒸汽密度
  const mkXlsx = (rows) => {
    const wb = xlsx.utils.book_new();
    const ws = xlsx.utils.json_to_sheet(rows);
    xlsx.utils.book_append_sheet(wb, ws, 'Sheet1');
    return xlsx.write(wb, { type: 'buffer', bookType: 'xlsx' });
  };
  const imported = await hazmats.importBatch(
    mkXlsx([
      {
        中文名: '氯气（别名更新）',
        UN号: '1017',
        危险类别: '2.3 有毒气体',
        蒸汽密度: '2.49 (相对空气)',
      },
    ]),
    'update.xlsx',
    'platform_1',
    { overwrite: true },
  );
  assert.equal(imported.updated, 1);
  assert.equal(imported.imported, 0);
  const reloadedGas = await hazmats.getById(gas.id);
  assert.equal(reloadedGas.vapor_density, '2.49 (相对空气)');

  // Batch size cap (>2000 rows) throws 400 HAZMAT_IMPORT_TOO_MANY_ROWS
  const tooManyBuf = mkXlsx(Array.from({ length: 2001 }, (_, i) => ({ 中文名: `介质_${i}` })));
  await assert.rejects(
    () => hazmats.importBatch(tooManyBuf, 'huge.xlsx', 'platform_1'),
    { code: 'HAZMAT_IMPORT_TOO_MANY_ROWS' },
  );

  // Route sanitizes NaN / negative limit & offset cleanly
  const routeRes = await fetch(`${base}/api/admin-hazmats-test?limit=notanumber&offset=-10`);
  assert.equal(routeRes.status, 200);
  const routeJson = await routeRes.json();
  assert.ok(Array.isArray(routeJson.items));
  assert.equal(routeJson.offset, 0);

  // Route handles valid xlsx import cleanly and rejects missing file with 400 JSON
  const missingFile = await fetch(`${base}/api/admin-hazmats-test/import`, { method: 'POST' });
  assert.equal(missingFile.status, 400);
  const buf = mkXlsx([{ 中文名: '氨气导入测试', UN号: '1005', 危险类别: '2.3 有毒气体' }]);
  const form = new FormData();
  form.append('file', new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), 'hazmats.xlsx');
  const importRes = await fetch(`${base}/api/admin-hazmats-test/import`, { method: 'POST', body: form });
  assert.equal(importRes.status, 200);
  const importData = await importRes.json();
  assert.equal(importData.imported, 1);
});

test('前端 ES 模块纯函数：出处保留、地图互斥、危化品无兜底用水、全景场景构造与会话草稿恢复', async () => {
  const sitesModel = await import(pathToFileURL(path.join(adminDir, 'js', 'views', 'sites', 'model.js')).href);
  const hazmatDrawer = await import(pathToFileURL(path.join(adminDir, 'js', 'views', 'hazmats', 'drawer.js')).href);
  const panoMain = await import(pathToFileURL(path.join(adminDir, 'js', 'pano', 'main.js')).href);
  const draftStore = await import(pathToFileURL(path.join(adminDir, 'js', 'core', 'draft-store.js')).href);

  // 1. Non-maps modules MUST preserve originalSources (fixes legacy data-loss bug)
  const serializedCards = sitesModel.serializeModuleEntries('cards', [
    {
      kind: 'siteOverview',
      title: '厂区概况',
      body: '',
      fields: { address: '示例大道 1 号', ignoredBlank: '   ' },
      originalSources: [{ attachmentId: 'att-pdf-1', page: 2, paragraph: '第 2 页' }],
      removed: false,
      isBlankTemplate: false,
    },
  ]);
  assert.equal(serializedCards.length, 1);
  assert.deepEqual(serializedCards[0].sources, [{ attachmentId: 'att-pdf-1', page: 2, paragraph: '第 2 页' }]);
  assert.deepEqual(serializedCards[0].fields, { address: '示例大道 1 号' });

  // 2. Maps module enforces mutual exclusion (selectedPanos wins over flatMap) & preserves plans body
  const serializedMaps = sitesModel.serializeModuleEntries('maps', [
    {
      kind: null,
      title: '罐区全景',
      body: '',
      fields: { area: '南罐区' },
      selectedPanos: [{ attachmentId: 'pano-1', paragraph: '北门机位' }],
      flatMapAttachmentId: 'flat-1',
      flatMapPage: 1,
      preservedSources: [],
      removed: false,
      isBlankTemplate: false,
    },
  ]);
  assert.deepEqual(serializedMaps[0].sources, [{ attachmentId: 'pano-1', page: 1, paragraph: '北门机位' }]);

  const serializedPlans = sitesModel.serializeModuleEntries('plans', [
    {
      kind: null,
      title: '储罐泄漏专项预案',
      body: '1. 划定 300 米警戒区\n2. 优先关阀断料',
      fields: {},
      originalSources: [{ attachmentId: 'plan-doc-1' }],
      removed: false,
      isBlankTemplate: false,
    },
  ]);
  assert.equal(serializedPlans[0].body, '1. 划定 300 米警戒区\n2. 优先关阀断料');
  assert.deepEqual(serializedPlans[0].sources, [{ attachmentId: 'plan-doc-1' }]);

  // 3. Profile payload sanitization
  const cleanProfile = sitesModel.sanitizeSiteProfilePayload(
    {
      name: '  示例化工园  ',
      short_name: ' 化工园 ',
      address: '  北环路 88 号 ',
      district: ' 高新区 ',
      site_type: ' 化工企业 ',
      owner_unit_id: 'unit_a',
      active: true,
      revision: 3,
    },
    { active: false },
  );
  assert.equal(cleanProfile.name, '示例化工园');
  assert.equal(cleanProfile.short_name, '化工园');
  assert.equal(cleanProfile.address, '北环路 88 号');
  assert.equal(cleanProfile.active, false);
  assert.equal(cleanProfile.revision, 3);

  // 4. Hazmat tactical field MUST NEVER fabricate water/foam recommendations when blank
  const blankField = hazmatDrawer.formatTacticalField('   ');
  assert.equal(blankField.empty, true);
  assert.equal(blankField.text, '未录入（请核对 SDS / ERG）');
  assert.doesNotMatch(blankField.text, /水|泡沫|干粉|冲洗/);

  // 5. Pano buildScenesFromSite produces ordered scenes + fallback preview URLs
  const scenes = panoMain.buildScenesFromSite(
    '示例储罐区',
    [{ title: '东门全景', fields: { area: '东门' }, sources: [{ attachmentId: 'p1', paragraph: '主入口' }] }],
    [
      { id: 'p1', filename: 'east.jpg', status: 'ready', metadata: { width: 8192, panorama: { hfov: 100 } } },
      { id: 'p2', filename: 'unlinked.jpg', status: 'ready', metadata: { width: 4096, panorama: true } },
      { id: 'p3', filename: 'failed.jpg', status: 'failed', metadata: { panorama: true } },
    ],
    (id) => `/pano/${id}.jpg`,
    (id) => `/preview/${id}.jpg`,
  );
  assert.equal(scenes.length, 2);
  assert.equal(scenes[0].label, '主入口');
  assert.equal(scenes[0].imageUrl, '/pano/p1.jpg');
  assert.equal(scenes[0].fallbackImageUrl, '/preview/p1.jpg');
  assert.equal(scenes[0].width, 8192);
  assert.equal(scenes[1].attachmentId, 'p2');

  // 6. SessionStorage draft-store save/load/revision-mismatch/clear
  const mem = new Map();
  globalThis.sessionStorage = {
    get length() { return mem.size; },
    key: (i) => Array.from(mem.keys())[i] ?? null,
    getItem: (k) => (mem.has(k) ? mem.get(k) : null),
    setItem: (k, v) => { mem.set(k, String(v)); },
    removeItem: (k) => { mem.delete(k); },
  };
  draftStore.saveLocalDraft('site-1', 'cards', 5, [{ title: '草稿条目' }]);
  const restored = draftStore.loadLocalDraft('site-1', 'cards', 5);
  assert.deepEqual(restored.records, [{ title: '草稿条目' }]);
  assert.equal(draftStore.loadLocalDraft('site-1', 'cards', 6), null);
  assert.equal(mem.size, 0);
  draftStore.saveLocalDraft('site-1', 'plans', 2, [{ title: '预案' }]);
  draftStore.clearAllLocalDrafts();
  assert.equal(mem.size, 0);
  delete globalThis.sessionStorage;
});

test('危化品表格排版 CSS 与交互纯函数：列宽防折行、两行摘要截断、浮层边界适配与行点击防误触', async () => {
  const viewsCss = fs.readFileSync(path.join(adminDir, 'css', 'views.css'), 'utf8');
  assert.match(viewsCss, /\.hazmat-table\s*\{[^}]*table-layout:\s*fixed/i);
  assert.match(viewsCss, /\.hazmat-table\s+\.col-un-cas\s*\{[^}]*white-space:\s*nowrap/i);
  assert.match(viewsCss, /\.hazmat-category-pill\s*\{[^}]*white-space:\s*normal/i);
  assert.match(viewsCss, /\.hazmat-risk-summary\s*\{[^}]*-webkit-line-clamp:\s*2/i);
  assert.match(viewsCss, /\.hazmat-risk-popover\s*\{[^}]*position:\s*fixed/i);

  const hazmatsView = await import(pathToFileURL(path.join(adminDir, 'js', 'views', 'hazmats', 'table-helpers.js')).href);

  // 普通单元格点击应打开处置卡抽屉
  assert.equal(
    hazmatsView.shouldOpenDrawerFromRowClick({ target: { closest: () => null } }, () => ''),
    true,
  );
  // 点击按钮/表单控件时不触发行点击
  assert.equal(
    hazmatsView.shouldOpenDrawerFromRowClick({ target: { closest: () => ({ tagName: 'BUTTON' }) } }, () => ''),
    false,
  );
  // 划词复制文本时不触发行点击
  assert.equal(
    hazmatsView.shouldOpenDrawerFromRowClick({ target: { closest: () => null } }, () => '7664-93-9'),
    false,
  );

  // 浮层默认位于锚点下方
  const below = hazmatsView.computeRiskPopoverPosition(
    { left: 200, top: 120, bottom: 160 },
    { width: 300, height: 100 },
    { width: 1280, height: 800 },
  );
  assert.deepEqual(below, { left: 200, top: 168 });

  // 底部空间不足时自动翻转至上方，右侧溢出时钳制到视口内
  const flipped = hazmatsView.computeRiskPopoverPosition(
    { left: 1080, top: 700, bottom: 740 },
    { width: 320, height: 120 },
    { width: 1280, height: 800 },
  );
  assert.deepEqual(flipped, { left: 948, top: 572 });
});
