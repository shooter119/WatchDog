const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { Pool } = require('pg');
const sharp = require('sharp');
process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.WATCHDOG_SKIP_SEED = '1';
const pool = new Pool({ connectionString: process.env.DATABASE_URL || 'postgresql:///watchdog_test' });
const schema = `key_sites_${process.pid}_${Date.now()}`;
let store, auth, sites, files, root, server, base, platform, manager;
const shape = require('../src/key-site-content');
const { createKeySiteFiles, inspectDocx } = require('../src/key-site-files');
const reject = (fn, code) => assert.rejects(fn, { code });

const { pdfBuffer } = require('./helpers/key-site-fixtures');
async function docxBuffer(extra = {}) {
  const zip = new (require('yazl').ZipFile)();
  const files = {
    '[Content_Types].xml': '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>',
    '_rels/.rels': '<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>',
    'word/document.xml': '<?xml version="1.0"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>SYNTHETIC EMERGENCY PLAN</w:t></w:r></w:p></w:body></w:document>',
    ...extra,
  };
  for (const [name, text] of Object.entries(files)) zip.addBuffer(Buffer.from(text), name);
  const chunks = []; zip.outputStream.on('data', chunk => chunks.push(chunk));
  const done = new Promise((resolve, reject) => { zip.outputStream.on('end', resolve); zip.outputStream.on('error', reject); });
  zip.end(); await done; return Buffer.concat(chunks);
}
async function create(name = '合成样例工厂', actor = 'manager') {
  return sites.create(actor, { name, address: '合成地址，不是真实资料', district: '样例辖区', site_type: '工厂' });
}
async function save(site, content) {
  const current = await sites.draft('platform', site.id);
  return sites.saveDraft('platform', site.id, { revision: current.draft.revision, content });
}
async function publish(site) {
  const current = await sites.draft('platform', site.id);
  return sites.publish('platform', site.id, { revision: current.draft.revision, profileRevision: current.site.revision, confirmPlatformSharing: true });
}
async function finishAttachment(id) {
  let task;
  // Tests explicitly drive durable workers instead of relying on background timers.
  for (let i = 0; i < 30; i++) {
    const record = (await store.query('SELECT * FROM key_site_attachments WHERE id=$1', [id])).rows[0];
    if (['ready','failed'].includes(record.status)) return record;
    task = await files.claim(); assert.ok(task); await files.run(task);
  }
  throw new Error('attachment did not finish');
}
before(async () => {
  await pool.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(process.env.DATABASE_URL || 'postgresql:///watchdog_test'); url.searchParams.set('options', `-c search_path=${schema}`); process.env.DATABASE_URL = url.toString();
  store = require('../src/postgres-store'); await store.ready;
  for (const unit of ['one','two']) await store.query('INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES($1,$1,$1,1,1)', [unit]);
  for (const [id, unit, role] of [['platform','one','member'],['manager','one','manager'],['other','two','admin'],['reader','two','member'],['pending','one','member']]) {
    await store.query('INSERT INTO unit_members(id,unit_id,real_name,role,created_at,updated_at) VALUES($1,$2,$1,$3,1,1)', [id,unit,role]);
  }
  await store.query("UPDATE unit_members SET review_status='pending' WHERE id='pending'");
  auth = require('../src/admin-auth').createAdminAuth(store);
  await auth.setGrant(null, 'platform', 'platform_admin', { bootstrap: true });
  await auth.setGrant('platform', 'manager', 'unit_admin'); await auth.setGrant('platform', 'other', 'unit_admin');
  sites = require('../src/key-sites').createKeySites(store, auth); root = await fs.mkdtemp(path.join(os.tmpdir(), 'watchdog-key-sites-'));
  files = createKeySiteFiles(store, sites, auth, { root });
  const express = require('express'), app = express(); app.use(express.json({ limit: '512kb' }));
  app.use('/api/admin', require('../src/admin-router').createAdminRouter(auth, { sites, files }));
  // Emulate the already-verified App authentication boundary with a server-selected member, never a role declaration.
  app.use('/api/key-sites', (req, res, next) => { req.auth = { memberId: req.get('X-Test-Member') }; next(); }, require('../src/key-site-routes').createKeySiteAppRouter(sites, files));
  const links = require('../src/incident-key-sites').createIncidentKeySites(store, require('../src/db-postgres'), sites);
  app.use('/api/incidents', (req, res, next) => { req.auth = { memberId: req.get('X-Test-Member') }; next(); }, require('../src/incident-key-sites').createIncidentKeySiteRouter(links));
  server = app.listen(0, '127.0.0.1'); await new Promise(resolve => server.once('listening', resolve)); base = `http://127.0.0.1:${server.address().port}`;
  platform = await login('platform'); manager = await login('manager');
});
after(async () => {
  if (server) await new Promise(resolve => server.close(resolve));
  await store?.close(); await pool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`); await pool.end();
  if (root) await fs.rm(root, { recursive: true, force: true });
});
async function login(member) {
  const c = await auth.challenge(); await auth.confirm(c.id, c.scan, member); return auth.claim(c.id, c.browser);
}
async function request(route, { session = platform, member, body, method = 'GET', form } = {}) {
  const headers = { Origin: 'https://fireman119.xyz' };
  if (session) { headers.Cookie = `__Host-watchdog_admin=${session.token}`; headers['X-CSRF-Token'] = session.csrf; }
  if (member) headers['X-Test-Member'] = member;
  if (body) headers['Content-Type'] = 'application/json';
  return fetch(base + route, { method, headers, body: form || (body ? JSON.stringify(body) : undefined) });
}

test('消防单位与重点单位独立建模，归属维护、授权和审批均由服务端判断', async () => {
  const site = await create(); assert.equal(site.owner_unit_id, 'one');
  await reject(() => sites.draft('other', site.id), 'KEY_SITE_FORBIDDEN');
  await reject(() => sites.create('reader', { name: '越权', address: '无' }), 'ADMIN_FORBIDDEN');
  await reject(() => sites.create('manager', { name: '越权归属', address: '无', owner_unit_id: 'two' }), 'KEY_SITE_FORBIDDEN');
  await reject(() => sites.update('manager', site.id, { ...site, owner_unit_id: 'two' }), 'KEY_SITE_FORBIDDEN');
  assert.equal((await sites.update('platform', site.id, { ...site, owner_unit_id: 'two' })).owner_unit_id, 'two');
  await reject(() => sites.draft('manager', site.id), 'KEY_SITE_FORBIDDEN');
  await reject(() => sites.list('pending'), 'KEY_SITE_AUTH_REQUIRED');
  await reject(() => sites.list(undefined), 'KEY_SITE_AUTH_REQUIRED');
});

test('草稿CAS、共享确认、档案快照及不可变版本构成人工发布闭环', async () => {
  const site = await create('版本样例'); const content = shape.emptyContent(); content.cards.push({ title: '风险与水源', body: '人工核对样例，不是真实作战资料', sources: [] });
  const draft = await save(site, content);
  await reject(() => sites.saveDraft('manager', site.id, { revision: 1, content }), 'KEY_SITE_CONFLICT');
  await reject(() => sites.publish('manager', site.id, { revision: draft.revision, profileRevision: site.revision }), 'KEY_SITE_SHARING_CONFIRM_REQUIRED');
  await reject(() => sites.published('reader', site.id), 'KEY_SITE_VERSION_NOT_FOUND');
  const first = await publish(site); assert.equal(first.version, 1);
  await sites.update('manager', site.id, { ...site, name: '未发布的新名称' });
  assert.equal((await sites.published('reader', site.id)).profile.name, '版本样例');
  content.cards[0].body = '第二版'; await save(site, content); await publish(site);
  assert.equal((await sites.published('reader', site.id, 1)).content.cards[0].body, '人工核对样例，不是真实作战资料');
  assert.equal((await sites.published('reader', site.id, 2)).content.cards[0].body, '第二版');
  assert.equal((await sites.versionForAdmin('manager', site.id, 1)).content.cards[0].body, '人工核对样例，不是真实作战资料');
  await reject(() => sites.versionForAdmin('other', site.id, 1), 'KEY_SITE_FORBIDDEN');
  const state = await sites.draft('manager', site.id); await sites.discardDraft('manager', site.id, state.draft.revision);
  assert.equal((await sites.history('manager', site.id)).length, 2);
});

test('150家合成单位按名称简称地址检索、辖区类型过滤并稳定分页', async () => {
  await store.query(`INSERT INTO key_sites(id,owner_unit_id,name,short_name,address,district,site_type,created_at,updated_at)
    SELECT 'bulk-'||n,'one','样例'||lpad(n::text,3,'0'),'简称'||n,'测试路'||n,CASE WHEN n%2=0 THEN '东区' ELSE '西区' END,'医院',1,1 FROM generate_series(1,150) n`);
  const seen = new Set();
  for (let offset = 0; offset < 150; offset += 20) {
    const result = await sites.list('platform', { q: '测试路', site_type: '医院', offset }, true);
    for (const item of result.sites) { assert.ok(!seen.has(item.id)); seen.add(item.id); }
  }
  assert.equal(seen.size, 150);
  const east = await sites.list('manager', { district: '东区', site_type: '医院', limit: 50 }, true);
  assert.equal(east.sites.length, 50); assert.equal(east.hasMore, true);
  assert.equal((await sites.list('manager', { q: '简称150' }, true)).sites[0].id, 'bulk-150');
  assert.equal((await sites.list('reader', { q: '样例' })).sites.some(site => site.id.startsWith('bulk-')), false);
  await store.query(`INSERT INTO key_site_versions(id,site_id,version,profile,content,attachment_ids,published_by,published_at)
    SELECT id||'-v1',id,1,jsonb_build_object('name',name,'short_name',short_name,'address',address,'district',district,'site_type',site_type),
    $1::jsonb,'[]'::jsonb,'platform',1 FROM key_sites WHERE id LIKE 'bulk-%'`, [JSON.stringify(shape.emptyContent())]);
  await store.query("UPDATE key_sites SET published_version=1 WHERE id LIKE 'bulk-%'");
  const publicSeen = new Set();
  for (let offset = 0; offset < 150; offset += 20) {
    const page = await sites.list('reader', { q: '测试路', offset });
    for (const entry of page.sites) { assert.ok(!publicSeen.has(entry.id)); publicSeen.add(entry.id); }
  }
  assert.equal(publicSeen.size, 150);
  assert.equal((await sites.list('reader', { q: '简称150', district: '东区', site_type: '医院' })).sites[0].id, 'bulk-150');
});

test('图片与地图持久化任务可处理，瓦片边界和来源页码被校验', async () => {
  const site = await create('地图样例');
  const image = await sharp({ create: { width: 600, height: 400, channels: 3, background: '#d7e0db' } }).png().toBuffer();
  const uploaded = await files.upload('manager', site.id, 'maps', { originalname: '合成总图.png', buffer: image });
  const ready = await finishAttachment(uploaded.id); assert.equal(ready.status, 'ready'); assert.equal(ready.metadata.map.coordinateSystem, 'image-pixels');
  const tile = await files.filePath(ready, 'tile', ['2','0','0']); assert.equal((await sharp(tile).metadata()).width, 256);
  await reject(() => files.filePath(ready, 'tile', ['2','99','0']), 'KEY_SITE_FILE_NOT_FOUND');
  const content = shape.emptyContent(); content.maps.push({ title: '总图（合成样例）', fields: { capturedAt: '2026-10-19', versionLabel: '合成样例 v1' }, sources: [{ attachmentId: uploaded.id, page: 1 }] });
  await save(site, content); const version = await publish(site); assert.deepEqual(version.attachment_ids, [uploaded.id]);
  const access = await files.attachmentFor('reader', site.id, uploaded.id, 1); assert.equal(access.id, uploaded.id);
  content.maps[0].sources[0].page = 2; await save(site, content);
  await reject(() => publish(site), 'KEY_SITE_SOURCE_INVALID');
});

test('PDF和DOCX真实转换成可阅读页，原件保留，来源可追溯', async () => {
  const site = await create('文档样例');
  const pdf = await files.upload('manager', site.id, 'plans', { originalname: '合成预案.pdf', buffer: pdfBuffer(2) });
  const ready = await finishAttachment(pdf.id); assert.equal(ready.status, 'ready'); assert.equal(ready.metadata.pages, 2);
  const page = await files.filePath(ready, 'page', [2]); assert.ok((await sharp(page).metadata()).width > 0);
  assert.ok((await sharp(page).stats()).channels.some(channel => channel.min < 200 && channel.max > 240));
  const original = await fs.readFile(await files.filePath(ready, 'source')); assert.deepEqual(original, pdfBuffer(2));
  const docx = await files.upload('manager', site.id, 'plans', { originalname: '合成文档.docx', buffer: await docxBuffer() });
  const converted = await finishAttachment(docx.id); assert.equal(converted.status, 'ready');
  assert.equal((await fs.readFile(await files.filePath(converted, 'pdf'))).subarray(0,5).toString(), '%PDF-');
  assert.equal((await fs.readFile(await files.filePath(converted, 'source'))).subarray(0,2).toString(), 'PK');
  const content = shape.emptyContent(); content.plans.push({ title:'合成预案阅读', sources:[{attachmentId:pdf.id,page:2},{attachmentId:docx.id,page:1}] });
  await save(site,content); await publish(site);
  const prefix = `/api/key-sites/${site.id}/versions/1/attachments`;
  const formal = await request(`${prefix}/${docx.id}/document.pdf`,{session:null,member:'reader'});
  assert.equal(formal.status,200); assert.match(formal.headers.get('content-type'),/application\/pdf/);
  assert.equal((await request(`${prefix}/${docx.id}/source`,{session:null,member:'reader'})).status,403);
  assert.equal((await request(`${prefix}/${pdf.id}/pages/2.jpg`,{session:null,member:'reader'})).status,200);
});

test('文件伪装、旧DOC、DOCX宏和外部模板、页数及像素上限均拒绝', async () => {
  await reject(() => files.inspect(Buffer.from('not a PDF'), 'test.pdf', 'plans'), 'KEY_SITE_FILE_INVALID');
  await reject(() => files.inspect(Buffer.from('old doc'), 'test.doc', 'plans'), 'KEY_SITE_FILE_INVALID');
  assert.equal((await files.inspect(pdfBuffer(), 'map.pdf', 'maps')).mime, 'application/pdf');
  const encryptedSite = await create('加密PDF合成样例');
  const encrypted = await files.upload('manager', encryptedSite.id, 'plans', { originalname: 'encrypted.pdf', buffer: Buffer.from('JVBERi0xLjMKJeLjz9MKMSAwIG9iago8PAovUHJvZHVjZXIgPGNlODBiM2UzYzY+Cj4+CmVuZG9iagoyIDAgb2JqCjw8Ci9UeXBlIC9QYWdlcwovQ291bnQgMQovS2lkcyBbIDQgMCBSIF0KPj4KZW5kb2JqCjMgMCBvYmoKPDwKL1R5cGUgL0NhdGFsb2cKL1BhZ2VzIDIgMCBSCj4+CmVuZG9iago0IDAgb2JqCjw8Ci9UeXBlIC9QYWdlCi9SZXNvdXJjZXMgPDwKPj4KL01lZGlhQm94IFsgMC4wIDAuMCAzMDAgMjAwIF0KL1BhcmVudCAyIDAgUgo+PgplbmRvYmoKNSAwIG9iago8PAovViAyCi9SIDMKL0xlbmd0aCAxMjgKL1AgNDI5NDk2NzI5MgovRmlsdGVyIC9TdGFuZGFyZAovTyA8MzY1ODkxMzI0Yjk2Y2U4NjFhYjFmMTRjZTRjZDkxZDQyYWEwOTY5NzRkNDNlYTlhZjMzNjFkMmY1ODNjYjY4MD4KL1UgPGM5MGQ2ZGZkYTc3MGVhMjU4ZjNiZGMxNDJjNTNiNGEwMjhiZjRlNWU0ZTc1OGE0MTY0MDA0ZTU2ZmZmYTAxMDg+Cj4+CmVuZG9iagp4cmVmCjAgNgowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMTUgMDAwMDAgbiAKMDAwMDAwMDA1OSAwMDAwMCBuIAowMDAwMDAwMTE4IDAwMDAwIG4gCjAwMDAwMDAxNjcgMDAwMDAgbiAKMDAwMDAwMDI2MSAwMDAwMCBuIAp0cmFpbGVyCjw8Ci9TaXplIDYKL1Jvb3QgMyAwIFIKL0luZm8gMSAwIFIKL0lEIFsgPDMzMzYzMDY0MzAzNzM0NjUzMjM3MzYzMDMzMzEzMTM2MzA2MzYzMzU2MTYxMzAzNzY0NjUzNzM0Mzc2MjYzNjU+IDwzMzM2MzA2NDMwMzczNDY1MzIzNzM2MzAzMzMxMzEzNjMwNjM2MzM1NjE2MTMwMzc2NDY1MzczNDM3NjI2MzY1PiBdCi9FbmNyeXB0IDUgMCBSCj4+CnN0YXJ0eHJlZgo0NzYKJSVFT0YK', 'base64') });
  assert.equal((await finishAttachment(encrypted.id)).status, 'failed');

  await reject(async () => inspectDocx(await docxBuffer({ 'word/vbaProject.bin': 'macro' })), 'KEY_SITE_FILE_INVALID');
  await reject(async () => inspectDocx(await docxBuffer({ 'word/_rels/document.xml.rels': '<Relationships><Relationship TargetMode="External" Type="image" Target="https://example.invalid/test"/></Relationships>' })), 'KEY_SITE_FILE_INVALID');
  const small = createKeySiteFiles(store, sites, auth, { root, limits: { pixels: 100, pages: 1 } });
  const png = await sharp({ create: { width: 20, height: 20, channels: 3, background: 'white' } }).png().toBuffer();
  await reject(() => small.inspect(png, 'large.png', 'cards'), 'KEY_SITE_FILE_INVALID');
  const site = await create('页数上限样例'); const file = await files.upload('manager', site.id, 'plans', { originalname: 'too-many.pdf', buffer: pdfBuffer(2) });
  const task = await small.claim(); await small.run(task);
  const failed = (await store.query('SELECT * FROM key_site_tasks WHERE attachment_id=$1', [file.id])).rows[0];
  assert.equal(failed.status, 'failed'); assert.equal(failed.error_code, 'KEY_SITE_PAGE_LIMIT');
  await files.retry('manager', failed.id); assert.equal((await finishAttachment(file.id)).status, 'ready');
});

test('草稿原件、跨单位附件、其他版本附件与游客读取均在HTTP层拒绝', async () => {
  const a = await create('甲单位'), b = await create('乙单位');
  const image = await sharp({ create: { width: 20, height: 20, channels: 3, background: 'white' } }).png().toBuffer();
  const uploaded = await files.upload('manager', a.id, 'cards', { originalname: 'source.png', buffer: image }); await finishAttachment(uploaded.id);
  const c = shape.emptyContent(); c.cards.push({ title: '甲资料', sources: [{ attachmentId: uploaded.id }] }); await save(a, c); await publish(a);
  const blankSource = shape.emptyContent(); blankSource.cards.push({ title: '甲二版', sources: [] }); await save(a, blankSource); await publish(a);
  const prefix = `/api/key-sites/${a.id}/versions`;
  assert.equal((await request(`${prefix}/1/attachments/${uploaded.id}/pages/1.jpg`, { session: null, member: 'reader' })).status, 200);
  assert.equal((await request(`${prefix}/1/attachments/${uploaded.id}/source`, { session: null, member: 'reader' })).status, 403);
  assert.equal((await request(`${prefix}/2/attachments/${uploaded.id}/source`, { session: null, member: 'reader' })).status, 404);
  assert.equal((await request(`${prefix}/1/attachments/${uploaded.id}/source`, { session: null })).status, 401);
  assert.equal((await request(`/api/admin/key-sites/${a.id}`, { session: null, member: 'reader' })).status, 401);
  await save(b, c); await reject(() => publish(b), 'KEY_SITE_SOURCE_INVALID');
  const state = await sites.draft('manager', a.id); await sites.update('manager', a.id, { ...state.site, active: false });
  assert.equal((await request(`/api/key-sites/${a.id}`, { session: null, member: 'reader' })).status, 404);
});

test('过期任务租约恢复并隔离旧处理结果，上传配额和待处理数量有硬限制', async () => {
  const site = await create('恢复样例'); const image = await sharp({ create: { width: 10, height: 10, channels: 3, background: 'white' } }).png().toBuffer();
  const upload = await files.upload('manager', site.id, 'cards', { originalname: 'source.png', buffer: image }); const stale = await files.claim();
  await store.query('UPDATE key_site_tasks SET lease_until=1 WHERE id=$1', [stale.id]);
  const resumed = await files.claim(); assert.equal(resumed.id, stale.id); assert.notEqual(resumed.lease_token, stale.lease_token);
  await files.run(stale); assert.equal((await store.query('SELECT status FROM key_site_tasks WHERE id=$1', [stale.id])).rows[0].status, 'processing');
  await files.run(resumed); assert.equal((await finishAttachment(upload.id)).status, 'ready');
  const quota = createKeySiteFiles(store, sites, auth, { root, limits: { quotaBytes: 10 } });
  await reject(() => quota.upload('manager', site.id, 'cards', { originalname: 'source.png', buffer: image }), 'KEY_SITE_QUOTA_EXCEEDED');
});

test('真实HTTP人工闭环：建档、上传、核对草稿、主动发布后跨消防单位可读', async () => {
  const created = await request('/api/admin/key-sites', { session: manager, method: 'POST', body: { name: 'HTTP合成单位', address: '软件验收用地址' } });
  assert.equal(created.status, 201); const site = await created.json();
  const png = await sharp({ create: { width: 32, height: 24, channels: 3, background: 'white' } }).png().toBuffer();
  const form = new FormData(); form.append('file', new Blob([png], { type: 'image/png' }), 'source.png');
  const upload = await request(`/api/admin/key-sites/${site.id}/attachments/cards`, { session: manager, method: 'POST', form });
  assert.equal(upload.status, 201); const attachment = await upload.json();
  assert.equal((await request(`/api/key-sites/${site.id}/versions/1/attachments/${attachment.id}/source`, { session: null, member: 'reader' })).status, 404);
  await finishAttachment(attachment.id);
  const state = await (await request(`/api/admin/key-sites/${site.id}`, { session: manager })).json();
  const content = shape.emptyContent(); content.cards.push({ title: '已核对信息', body: '仅供软件验收', sources: [{ attachmentId: attachment.id, page: 1 }] });
  const saved = await request(`/api/admin/key-sites/${site.id}/draft`, { session: manager, method: 'PUT', body: { revision: state.draft.revision, content } });
  assert.equal(saved.status, 200); const draft = await saved.json();
  const shared = await request(`/api/admin/key-sites/${site.id}/publish`, { session: manager, method: 'POST', body: { revision: draft.revision, profileRevision: state.site.revision, confirmPlatformSharing: true } });
  assert.equal(shared.status, 200);
  const read = await request(`/api/key-sites/${site.id}`, { session: null, member: 'reader' });
  assert.equal(read.status, 200); const result = await read.json();
  assert.equal(result.content.cards[0].title, '已核对信息'); assert.equal(result.attachments[0].id, attachment.id);
  assert.equal((await request(`/api/key-sites/${site.id}`, { session: null, member: 'pending' })).status, 401);
});

test('多页PDF地图独立切片，第二页来源与瓦片不串页', async () => {
  const site = await create('多页地图合成样例');
  const maps = createKeySiteFiles(store, sites, auth, { root, limits: { pixels: 1000000 } });
  const uploaded = await maps.upload('manager', site.id, 'maps', { originalname: '分区图.pdf', buffer: pdfBuffer(2) });
  const task = await maps.claim(); await maps.run(task);
  const ready = (await store.query('SELECT * FROM key_site_attachments WHERE id=$1', [uploaded.id])).rows[0];
  assert.equal(ready.status, 'ready'); assert.equal(Object.keys(ready.metadata.mapPages).length, 2);
  const tile1 = await maps.filePath(ready, 'tile', [1, 0, 0, 0]);
  const tile2 = await maps.filePath(ready, 'tile', [2, 0, 0, 0]);
  assert.notDeepEqual(await fs.readFile(tile1), await fs.readFile(tile2));
  const content = shape.emptyContent();
  content.maps.push({ title: '第二区域', sources: [{ attachmentId: uploaded.id, page: 2 }] });
  await save(site, content); await publish(site);
  const response = await request(`/api/key-sites/${site.id}/versions/1/attachments/${uploaded.id}/maps/2/tiles/0/0/0.jpg`, { session: null, member: 'reader' });
  assert.equal(response.status, 200);
  const wrong = shape.emptyContent(); wrong.cards = content.maps; await save(site, wrong);
  assert.equal((await publish(site)).version, 2); // An explicit source may support multiple module types.
});

test('警情关联固定版本、范围权限、人工更新及历史保留', async () => {
  const db = require('../src/db-postgres');
  const links = require('../src/incident-key-sites').createIncidentKeySites(store, db, sites);
  const site = await create('警情版本关联样例');
  const content = shape.emptyContent(); content.cards.push({ title: '核对样例', body: '合成资料', sources: [] });
  await save(site, content); await publish(site);
  const incident = await db.createIncident({ unitId: 'one' });
  const input = { siteId: site.id, version: 1, revision: 0, confirmName: site.name, confirmAddress: site.address };
  await reject(() => links.change('manager', incident.id, { ...input, confirmAddress: '错误地址' }, { operationId: 'link-wrong' }), 'KEY_SITE_LINK_REVIEW_REQUIRED');
  await reject(() => links.change('reader', incident.id, input, { operationId: 'link-cross-unit' }), 'INCIDENT_NOT_FOUND');
  await reject(() => links.change('pending', incident.id, input, { operationId: 'link-pending' }), 'KEY_SITE_AUTH_REQUIRED');
  const first = await links.change('manager', incident.id, input, { operationId: 'link-once' });
  assert.equal(first.incident.key_site_link.version, 1);
  assert.equal(first.event.actor_name, 'manager');
  assert.equal(first.event.sync.event_type, 'incident.updated');
  assert.equal(first.event.sync.payload.key_site_link.siteId, site.id);
  assert.equal((await links.change('manager', incident.id, input, { operationId: 'link-once' })).replayed, true);
  await reject(() => links.change('platform', incident.id, input, { operationId: 'link-once' }), 'CLIENT_OP_ID_CONFLICT');
  await reject(() => links.change('manager', incident.id, input, { operationId: 'link-stale' }), 'KEY_SITE_LINK_CONFLICT');
  await publish(site);
  const state = await links.read('manager', incident.id);
  assert.equal(state.link.version, 1); assert.equal(state.newVersionAvailable, true);
  await reject(() => links.change('manager', incident.id, { ...input, revision: 1 }, { operationId: 'link-old' }), 'KEY_SITE_NEW_VERSION');
  await links.change('platform', incident.id, { ...input, version: 2, revision: 1 }, { operationId: 'link-update' });
  await links.change('manager', incident.id, { siteId: null, revision: 2 }, { operationId: 'link-remove' });
  assert.equal((await links.read('manager', incident.id)).history.length, 2);
  await sites.update('manager', site.id, { ...await sites.site(site.id), active: false });
  await reject(() => sites.published('manager', site.id, 1), 'KEY_SITE_INACTIVE');
  assert.equal((await sites.published('manager', site.id, 1, incident.id)).version, 1);
  await reject(() => sites.published('reader', site.id, 1, incident.id), 'KEY_SITE_INACTIVE');
  await reject(() => links.change('manager', incident.id, { ...input, version: 2, revision: 3 }, { operationId: 'link-inactive' }), 'KEY_SITE_INACTIVE');
  await store.query("UPDATE incidents SET status='archived' WHERE id=$1", [incident.id]);
  await reject(() => links.change('manager', incident.id, { siteId: null, revision: 3 }, { operationId: 'link-archived' }), 'INCIDENT_ARCHIVED');
  assert.equal((await links.read('platform', incident.id)).history.length, 2);
});

test('筛选及最近查看仅返回当前已发布有效档案', async () => {
  const site = await create('最近查看样例');
  const content = shape.emptyContent(); content.cards.push({ title: '合成资料', sources: [] });
  await save(site, content); await publish(site);
  assert.ok((await sites.filters('reader')).districts.includes('样例辖区'));
  const rows = await sites.recent('reader', [site.id, 'not-present']);
  assert.equal(rows.length, 1); assert.equal(rows[0].name, site.name);
  await reject(() => sites.recent('pending', [site.id]), 'KEY_SITE_AUTH_REQUIRED');
  await reject(() => sites.recent('reader', Array(21).fill(site.id)), 'KEY_SITE_INVALID');
});


test('停用后的历史附件按警情协作范围鉴权，解除关联后仍可读，源文件始终私有', async () => {
  const db = require('../src/db-postgres');
  const links = require('../src/incident-key-sites').createIncidentKeySites(store, db, sites);
  const site = await create('历史附件合成样例');
  const buffer = await sharp({ create: { width: 100, height: 80, channels: 3, background: '#ffffff' } }).png().toBuffer();
  const attachment = await files.upload('manager', site.id, 'plans', { originalname: '历史合成图.png', buffer });
  await finishAttachment(attachment.id);
  const content = shape.emptyContent(); content.plans.push({ title: '合成预案', sources: [{ attachmentId: attachment.id, page: 1 }] });
  await save(site, content); await publish(site);
  const incident = await db.createIncident({ unitId: 'one' });
  await links.change('manager', incident.id, { revision: 0, siteId: site.id, version: 1, confirmName: site.name, confirmAddress: site.address }, { operationId: 'historical-attach' });
  await links.change('manager', incident.id, { revision: 1, siteId: null }, { operationId: 'historical-detach' });
  await sites.update('manager', site.id, { ...await sites.site(site.id), active: false });
  const prefix = `/api/key-sites/${site.id}/versions/1/attachments/${attachment.id}`;
  assert.equal((await request(`${prefix}/pages/1.jpg?incidentId=${incident.id}`, { session: null, member: 'manager' })).status, 200);
  assert.equal((await request(`${prefix}/pages/1.jpg?incidentId=${incident.id}`, { session: null, member: 'reader' })).status, 404);
  assert.equal((await request(`${prefix}/pages/1.jpg`, { session: null, member: 'manager' })).status, 404);
  assert.equal((await request(`${prefix}/source?incidentId=${incident.id}`, { session: null, member: 'manager' })).status, 403);
  const response = await request(`/api/incidents/${incident.id}/key-site`, { session: null, member: 'manager' });
  assert.match(response.headers.get('cache-control'), /no-store/);
  const state = await response.json(); assert.equal(state.link, null); assert.equal(state.history.length, 1);
  assert.equal((await request(`/api/incidents/${incident.id}/key-site`, { session: null, member: 'reader' })).status, 404);
});

test('标准记录HTTP保存发布保留独立储量与来源，旧发布版本不被新版覆盖', async () => {
  const caps = await (await request('/api/admin/key-sites/limits')).json();
  assert.ok(caps.schema.kinds.storageTank.fields.includes('designVolume'));
  const site = await create('标准化合成单位');
  const data = shape.emptyContent();
  data.cards.push({kind:'siteOverview',title:'概况',fields:{dayStaff:'约30人'}});
  data.hazards.push({kind:'storageTank',title:'合成介质 V-TEST',fields:{tankNumber:'V-TEST',designVolume:'42',quantity:'',designPressure:'-0.0005/0.008'}});
  const draft = await sites.draft('manager',site.id);
  const saved = await request(`/api/admin/key-sites/${site.id}/draft`,{session:manager,method:'PUT',body:{revision:draft.draft.revision,content:data}});
  assert.equal(saved.status,200); await publish(site);
  const v1 = await (await request(`/api/key-sites/${site.id}`,{session:null,member:'reader'})).json();
  assert.equal(v1.content.hazards[0].kind,'storageTank'); assert.equal(v1.content.hazards[0].fields.quantity,'');
  assert.equal(v1.content.cards[0].fields.dayStaff,'约30人');
  data.hazards[0].fields.designVolume='43'; await save(site,data); await publish(site);
  const old = await sites.versionForAdmin('platform',site.id,1);
  assert.equal(old.content.hazards[0].fields.designVolume,'42');
  const latest = await sites.versionForAdmin('platform',site.id,2);
  assert.equal(latest.content.hazards[0].fields.designVolume,'43');
});

test('发布毫秒时间在列表、最近查看、版本和历史HTTP响应中均为JSON数字', async () => {
  const site = await create('发布时间类型合成样例');
  const content = shape.emptyContent();
  content.cards.push({ title: '合成资料', body: '仅供接口契约回归' });
  await save(site, content);
  const version = await publish(site);
  const timestamp = version.published_at;
  assert.equal(typeof timestamp, 'number');
  assert.ok(Number.isSafeInteger(timestamp) && timestamp > 1700000000000);
  const routes = [
    [`/api/key-sites?q=${encodeURIComponent(site.name)}`, result => result.sites[0]],
    [`/api/key-sites/recent?ids=${site.id}`, result => result.sites[0]],
    [`/api/key-sites/${site.id}`, result => result],
    [`/api/key-sites/${site.id}/versions/1`, result => result],
    [`/api/admin/key-sites/${site.id}/history`, result => result.versions[0]],
    [`/api/admin/key-sites/${site.id}/history/1`, result => result],
  ];
  for (const [route, pick] of routes) {
    const response = await request(route, route.startsWith('/api/key-sites') ? { session: null, member: 'reader' } : {});
    assert.equal(response.status, 200, route);
    const record = pick(await response.json());
    assert.equal(typeof record.published_at, 'number', route);
    assert.equal(record.published_at, timestamp, route);
  }
});

test('警情历史引用首次关联时间在HTTP响应中为JSON数字', async () => {
  const db = require('../src/db-postgres');
  const links = require('../src/incident-key-sites').createIncidentKeySites(store, db, sites);
  const site = await create('关联历史时间类型合成样例');
  const content = shape.emptyContent(); content.cards.push({ title: '合成记录', body: '接口契约回归' });
  await save(site, content); await publish(site);
  const incident = await db.createIncident({ unitId: 'one' });
  await links.change('manager', incident.id, { siteId: site.id, version: 1, revision: 0,
    confirmName: site.name, confirmAddress: site.address }, { operationId: 'history-time-link' });
  const state = await links.read('manager', incident.id);
  assert.equal(typeof state.history[0].first_linked_at, 'number');
  assert.ok(Number.isSafeInteger(state.history[0].first_linked_at));
  assert.ok(state.history[0].first_linked_at >= state.link.linkedAt);
  const response = await request(`/api/incidents/${incident.id}/key-site`, { session: null, member: 'manager' });
  assert.equal(response.status, 200);
  const data = await response.json();
  assert.equal(typeof data.history[0].first_linked_at, 'number');
  assert.equal(data.history[0].first_linked_at, state.history[0].first_linked_at);
});
