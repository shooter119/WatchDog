const { test, before, beforeEach, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { Pool } = require('pg');
const { pdfBuffer } = require('./helpers/key-site-fixtures');
const { validatePage } = require('../src/key-site-extraction');
const shape = require('../src/key-site-content');
process.env.WATCHDOG_DB_DRIVER = 'postgres'; process.env.WATCHDOG_SKIP_SEED = '1';
const baseDatabase = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
const pool = new Pool({ connectionString: baseDatabase }), schema = `key_site_ai_${process.pid}_${Date.now()}`;
let store, auth, sites, files, ai, site, attachment, root, server, base, clock = Date.now(), provider, calls = [];
const config = { apiKey: 'synthetic-test-only', baseUrl: 'https://api.deepseek.com' };
const reject = (fn, code) => assert.rejects(fn, { code });
function extracted(options, module = 'hazards') {
  const quantity = options.page === 1 ? '10升' : '20升';
  const raw = { rawText: `合成乙醇 ${quantity} 合成仓库`, classification: [module], toConfirm: [], entries: [{ module,
    title: '合成乙醇', body: '合成仓库', fields: module === 'hazards' ? { quantity, location: '合成仓库' } : {},
    evidence: { title: '合成乙醇', body: '合成仓库', fields: { quantity, location: '合成仓库' } }, toConfirm: [] }] };
  return validatePage(raw, options);
}
async function runTask(task, service = ai) {
  const claimed = await service.claim(); assert.equal(claimed.id, task.id); await service.run(claimed); return service.read('platform', task.id);
}
async function state() { return sites.draft('platform', site.id); }
async function apply(task, ids, revision, extras = {}) {
  return ai.apply('platform', task.id, { reviewed: true, generation: task.generation, revision, ids, ...extras });
}
before(async () => {
  await pool.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(baseDatabase); url.searchParams.set('options', `-c search_path=${schema}`); process.env.DATABASE_URL = url.toString();
  store = require('../src/postgres-store'); await store.ready;
  for (const unit of ['one','two']) await store.query('INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES($1,$1,$1,1,1)', [unit]);
  for (const [id, unit, role] of [['platform','one','member'],['manager','one','manager'],['other','two','admin'],['reader','two','member']]) {
    await store.query('INSERT INTO unit_members(id,unit_id,real_name,role,created_at,updated_at) VALUES($1,$2,$1,$3,1,1)', [id,unit,role]);
  }
  auth = require('../src/admin-auth').createAdminAuth(store, () => clock);
  await auth.setGrant(null, 'platform', 'platform_admin', { bootstrap: true });
  await auth.setGrant('platform', 'manager', 'unit_admin'); await auth.setGrant('platform', 'other', 'unit_admin');
  sites = require('../src/key-sites').createKeySites(store, auth, () => clock);
  root = await fs.mkdtemp(path.join(os.tmpdir(), 'watchdog-key-site-ai-'));
  files = require('../src/key-site-files').createKeySiteFiles(store, sites, auth, { root });
  site = await sites.create('manager', { name: 'AI合成单位', address: '仅供软件验收，不是真实资料' });
  attachment = await files.upload('manager', site.id, 'plans', { originalname: 'synthetic.pdf', buffer: pdfBuffer(2) });
  const fileTask = await files.claim(); await files.run(fileTask);
  assert.equal((await state()).attachments[0].status, 'ready');
  ai = require('../src/key-site-ai').createKeySiteAI(store, sites, files, auth, config, {
    now: () => clock, extract: async options => { calls.push(options.page); return provider(options); },
  });
  const express = require('express'), app = express(); app.use(express.json({ limit: '512kb' }));
  app.use('/api/admin', require('../src/admin-router').createAdminRouter(auth, { sites, files, ai }));
  server = app.listen(0, '127.0.0.1'); await new Promise(resolve => server.once('listening', resolve)); base = `http://127.0.0.1:${server.address().port}/api/admin`;
});
beforeEach(() => { clock += 61000; provider = extracted; calls = []; });
after(async () => {
  if (server) await new Promise(resolve => server.close(resolve));
  await store?.close(); await pool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`); await pool.end();
  if (root) await fs.rm(root, { recursive: true, force: true });
});

test('AI创建校验当前授权、维护归属、显式页码、已有任务和服务配置', async () => {
  await reject(() => ai.create('other', site.id, attachment.id, [1]), 'KEY_SITE_FORBIDDEN');
  await reject(() => ai.create('reader', site.id, attachment.id, [1]), 'ADMIN_FORBIDDEN');
  for (const pages of [[], [0], [3], [1,1], Array.from({length:21},(_,i)=>i+1)]) await reject(() => ai.create('manager', site.id, attachment.id, pages), 'KEY_SITE_AI_PAGES_INVALID');
  const disabled = require('../src/key-site-ai').createKeySiteAI(store, sites, files, auth, {});
  await reject(() => disabled.create('manager', site.id, attachment.id, [1]), 'KEY_SITE_AI_UNAVAILABLE');
  const task = await ai.create('manager', site.id, attachment.id, [1,2]);
  await reject(() => ai.create('manager', site.id, attachment.id, [1]), 'KEY_SITE_BUSY');
  await reject(() => ai.read('reader', task.id), 'ADMIN_FORBIDDEN');
  await reject(() => ai.read('other', task.id), 'KEY_SITE_FORBIDDEN');
  assert.equal((await state()).tasks.find(job => job.id === task.id).result, undefined);
  await ai.cancel('manager', task.id); assert.equal((await ai.read('manager', task.id)).status, 'cancelled');
});

test('逐页部分成功可核对，重试仅处理失败页，已采用后的人工修改完整保留', async () => {
  const baseline = shape.emptyContent(); baseline.cards.push({ title: '原有人工条目', body: '不得覆盖', sources: [] });
  await sites.saveDraft('platform', site.id, { revision: (await state()).draft.revision, content: baseline });
  provider = options => { if (options.page === 2) throw Object.assign(new Error('synthetic upstream failure'), { code:'KEY_SITE_AI_UPSTREAM_FAILED' }); return extracted(options); };
  const initial = await ai.create('manager', site.id, attachment.id, [1,2]);
  const partial = await runTask(initial); assert.equal(partial.status, 'partial'); assert.deepEqual(calls, [1,2]);
  const one = partial.summary.entries[0];
  await apply(partial, [one.id], (await state()).draft.revision);
  const human = await state(); human.draft.content.hazards[0].fields.quantity = '11升（人工修正）';
  await sites.saveDraft('manager', site.id, { revision: human.draft.revision, content: human.draft.content });
  provider = extracted; calls = [];
  await reject(() => ai.retry('manager', initial.id, [1]), 'KEY_SITE_AI_PAGES_INVALID');
  await ai.retry('manager', initial.id, [2]); const completed = await runTask(initial);
  assert.equal(completed.status, 'succeeded'); assert.deepEqual(calls, [2]); assert.deepEqual(completed.result.applied, [one.id]);
  const next = completed.summary.entries.find(entry => entry.entry.sources[0].page === 2);
  await apply(completed, [next.id], (await state()).draft.revision);
  const current = await state(); assert.equal(current.draft.content.cards[0].body, '不得覆盖');
  assert.equal(current.draft.content.hazards[0].fields.quantity, '11升（人工修正）'); assert.equal(current.draft.content.hazards[1].fields.quantity, '20升');
  assert.equal(current.site.published_version, 0);
  await sites.publish('manager', site.id, { revision: current.draft.revision, profileRevision: current.site.revision, confirmPlatformSharing: true });
  assert.equal((await sites.published('reader', site.id)).content.hazards.length, 2);
});

test('采用建议必须人工确认且修订号一致，人工修订仅追加并保持服务器来源', async () => {
  const task = await runTask(await ai.create('manager', site.id, attachment.id, [1]));
  const candidate = task.summary.entries[0], old = await state();
  const human = structuredClone(old.draft.content); human.cards[0].body = '期间新增的人工修订';
  const saved = await sites.saveDraft('manager', site.id, { revision: old.draft.revision, content: human });
  await reject(() => apply(task, [candidate.id], old.draft.revision), 'KEY_SITE_CONFLICT');
  await reject(() => apply(task, [candidate.id], saved.revision, { reviewed:false }), 'KEY_SITE_AI_REVIEW_REQUIRED');
  await reject(() => apply(task, ['unknown-id'], saved.revision), 'KEY_SITE_AI_SELECTION_INVALID');
  const edited = { module:'hazards', title:'人工核对名称', body:'人工核对后的摘录', fields:{quantity:'12升（人工核对）'}, sources:[{attachmentId:'forged'}] };
  const applied = await apply(task, [candidate.id], saved.revision, { edits:{[candidate.id]:edited} });
  assert.equal(applied.content.cards[0].body, '期间新增的人工修订');
  assert.equal(applied.content.hazards.at(-1).fields.quantity, '12升（人工核对）');
  assert.equal(applied.content.hazards.at(-1).sources[0].attachmentId, attachment.id);
  await reject(() => apply(task, [candidate.id], applied.revision), 'KEY_SITE_AI_SELECTION_INVALID');
});

test('地图建议没有独立切片不能采用，不改变人工草稿', async () => {
  provider = options => extracted(options, 'maps');
  const task = await runTask(await ai.create('manager', site.id, attachment.id, [1]));
  const before = (await state()).draft;
  await reject(() => apply(task, [task.summary.entries[0].id], before.revision), 'KEY_SITE_MAP_NOT_READY');
  assert.deepEqual((await state()).draft, before);
});

test('租约恢复隔离旧worker，取消后迟到结果不能写回', async () => {
  const task = await ai.create('manager', site.id, attachment.id, [1]);
  const stale = await ai.claim(); await store.query('UPDATE key_site_tasks SET lease_until=$2 WHERE id=$1', [task.id,clock-1]);
  const current = await ai.claim(); assert.equal(current.id, stale.id); assert.notEqual(current.lease_token, stale.lease_token);
  await ai.run(stale); assert.deepEqual(calls, []); assert.equal((await ai.read('manager',task.id)).status,'processing');
  await ai.run(current); assert.equal((await ai.read('manager',task.id)).status,'succeeded');
  let enter, release;
  const entered = new Promise(resolve => { enter=resolve; }), gate = new Promise(resolve => { release=resolve; });
  provider = async options => { enter(); await gate; return extracted(options); };
  const cancelled = await ai.create('manager',site.id,attachment.id,[1]);
  const claimed = await ai.claim(), running = ai.run(claimed); await entered;
  await ai.cancel('manager',cancelled.id); release(); await running;
  const state = await ai.read('manager',cancelled.id); assert.equal(state.status,'cancelled'); assert.equal(state.summary.entries.length,0);
});

test('授权撤销后停止向模型发送新页面，重试可由当前维护人员接管', async () => {
  const task = await ai.create('manager',site.id,attachment.id,[1]);
  await auth.setGrant('platform','manager',null);
  const failed = await runTask(task); assert.equal(failed.status,'failed'); assert.deepEqual(calls,[]);
  assert.equal(failed.result.pages[0].errorCode,'KEY_SITE_AI_ACCESS_REVOKED');
  await auth.setGrant('platform','manager','unit_admin');
  await ai.retry('platform',task.id,[1]); const ready=await runTask(task);
  assert.equal(ready.status,'succeeded'); assert.equal(ready.requested_by,'platform');
});

test('AI请求和重试受持久化频率限制，取消任务不改变已发布资料', async () => {
  const version = (await state()).site.published_version;
  for (let i=0;i<3;i++) { const task=await ai.create('manager',site.id,attachment.id,[1]); await ai.cancel('manager',task.id); }
  await reject(()=>ai.create('manager',site.id,attachment.id,[1]),'KEY_SITE_AI_RATE_LIMITED');
  assert.equal((await state()).site.published_version,version);
});

test('真实HTTP的AI结果、人工核对与采用独立鉴权，普通App会话不能操作', async () => {
  const challenge=await auth.challenge(); await auth.confirm(challenge.id,challenge.scan,'manager'); const session=await auth.claim(challenge.id,challenge.browser);
  async function request(route,body,method='POST',csrf=true) {
    return fetch(base+route,{method,headers:{Origin:'https://fireman119.xyz','Content-Type':'application/json',Cookie:`__Host-watchdog_admin=${session.token}`,...(csrf?{'X-CSRF-Token':session.csrf}:{})},...(body?{body:JSON.stringify(body)}:{})});
  }
  const response=await request(`/key-sites/${site.id}/attachments/${attachment.id}/ai`,{pages:[1]}); assert.equal(response.status,201);
  const created=await response.json(), ready=await runTask(created);
  assert.equal((await fetch(base+`/key-sites/tasks/${created.id}`,{headers:{Authorization:'Bearer ordinary-app-token'}})).status,401);
  const detail=await request(`/key-sites/tasks/${created.id}`,undefined,'GET'); assert.equal(detail.status,200);
  const payload={reviewed:true,revision:(await state()).draft.revision,generation:ready.generation,ids:[ready.summary.entries[0].id]};
  assert.equal((await request(`/key-sites/tasks/${created.id}/ai-apply`,payload,'POST',false)).status,403);
  assert.equal((await request(`/key-sites/tasks/${created.id}/ai-apply`,payload)).status,200);
  assert.equal((await state()).site.published_version,1);
});

test('连续三次进程中断保留已成功页面，剩余页面明确失败待人工重试', async () => {
  const task=await ai.create('manager',site.id,attachment.id,[1,2]);
  await ai.claim();
  const result={pages:[{page:1,status:'succeeded',extraction:extracted({attachmentId:attachment.id,page:1})},{page:2,status:'processing'}],applied:[]};
  await store.query("UPDATE key_site_tasks SET attempts=3,lease_until=$2,result=$3 WHERE id=$1",[task.id,clock-1,JSON.stringify(result)]);
  assert.equal(await ai.claim(),null);
  const recovered=await ai.read('manager',task.id);
  assert.equal(recovered.status,'partial'); assert.equal(recovered.result.pages[0].status,'succeeded');
  assert.equal(recovered.result.pages[1].errorCode,'KEY_SITE_AI_INTERRUPTED'); assert.deepEqual(calls,[]);
  await ai.retry('manager',task.id,[2]); const done=await runTask(task);
  assert.equal(done.status,'succeeded'); assert.deepEqual(calls,[2]);
});

test('结果大小硬限制生效，过大的识别结果不写入任务或人工草稿', async () => {
  const limited=require('../src/key-site-ai').createKeySiteAI(store,sites,files,auth,config,{now:()=>clock,extract:async options=>extracted(options)});
  limited.limits.aiResultBytes=500;
  const before=(await state()).draft;
  const task=await limited.create('manager',site.id,attachment.id,[1]);
  const failed=await runTask(task,limited);
  assert.equal(failed.status,'failed'); assert.equal(failed.result.pages[0].errorCode,'KEY_SITE_AI_RESULT_LIMIT');
  assert.ok(Buffer.byteLength(JSON.stringify(failed.result))<=500); assert.deepEqual((await state()).draft,before);
});

test('标准类型AI草稿采用及人工修订保留字段、类型和出处', async () => {
  provider = options => validatePage({rawText:'合成储罐 T-TEST 42',classification:['hazards'],entries:[{module:'hazards',kind:'storageTank',title:'合成储罐',fields:{tankNumber:'T-TEST',designVolume:'42'},evidence:{title:'合成储罐',fields:{tankNumber:'T-TEST',designVolume:'42'}}}]},options);
  const task = await runTask(await ai.create('manager',site.id,attachment.id,[1]));
  const candidate = task.summary.entries[0]; const before=(await state()).draft;
  const adopted = await apply(task,[candidate.id],before.revision,{edits:{[candidate.id]:{module:'hazards',kind:'storageTank',title:candidate.entry.title,body:'',fields:{...candidate.entry.fields,notes:'人工核对备注'}}}});
  const item=adopted.content.hazards.at(-1);
  assert.equal(item.kind,'storageTank'); assert.equal(item.fields.designVolume,'42'); assert.equal(item.fields.quantity,'');
  assert.equal(item.fields.notes,'人工核对备注'); assert.equal(item.sources[0].attachmentId,attachment.id);
});
