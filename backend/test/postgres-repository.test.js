const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');

process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql:///watchdog_test';
process.env.WATCHDOG_SKIP_SEED = '1';

const { Pool } = require('pg');
const adminPool = new Pool({ connectionString: process.env.DATABASE_URL });
const testSchema = `import_repo_${process.pid}_${Date.now()}`;
let db, store, imports, importTasks;

async function seedUnit(id) {
  await store.query(`
    INSERT INTO units (id, name, verification_code, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $4)
    ON CONFLICT (id) DO NOTHING
  `, [id, `测试单位-${id}`, `code-${id}`.slice(0, 32), Date.now()]);
}

before(async () => {
  await adminPool.query(`CREATE SCHEMA "${testSchema}"`);
  const url = new URL(process.env.DATABASE_URL);
  const existingOptions = url.searchParams.get('options') || '';
  url.searchParams.set('options', `${existingOptions} -c search_path=${testSchema}`.trim());
  process.env.DATABASE_URL = url.toString();
  db = require('../src/db');
  store = require('../src/postgres-store');
  imports = require('../src/incident-import-repository');
  importTasks = require('../src/incident-import-tasks');
  await db.ready;
  await seedUnit('unit-test');
});

after(async () => {
  await store?.close();
  await adminPool.query(`DROP SCHEMA IF EXISTS "${testSchema}" CASCADE`);
  await adminPool.end();
});

test('PostgreSQL 仓储保留警情、事件幂等和进退场行为', async () => {
  const incident = await db.createIncident({ unitId: 'unit-test', createdBy: 'test-device', createdAt: 1000 });
  assert.equal(incident.status, 'active');
  const firstEvent = await db.appendIncidentEvent({ incidentId: incident.id, type: 'incident_created', clientOpId: 'op-1', payload: { title: '测试' } });
  const duplicateEvent = await db.appendIncidentEvent({ incidentId: incident.id, type: 'incident_created', clientOpId: 'op-1', payload: { title: '不同内容' } });
  assert.equal(duplicateEvent.id, firstEvent.id);
  assert.deepEqual(duplicateEvent.payload, { title: '测试' });
  assert.equal(firstEvent.sync.sequence, '1');

  const entry = await db.createEntry({ id: 'entry-1', scene: incident.id, name: '张三', pressureMpa: 20, durationMin: 17, entryAtMs: 2000, exitAtMs: 100000 });
  assert.equal(entry.name, '张三');
  assert.equal((await db.listEntries({ activeOnly: true, scene: incident.id })).length, 1);
  const exited = await db.markExited(entry.id, 3000);
  assert.equal(Number(exited.exited_at), 3000);
  assert.equal((await db.listEntries({ activeOnly: true, scene: incident.id })).length, 0);
});

test('PostgreSQL 警情列表将单位过滤和上限下推到仓储', async () => {
  await seedUnit('unit-a');
  await seedUnit('unit-b');
  await db.createIncident({ id: 'unit-a-incident-1', unitId: 'unit-a', createdAt: 3000 });
  await db.createIncident({ id: 'unit-a-incident-2', unitId: 'unit-a', createdAt: 4000 });
  await db.createIncident({ id: 'unit-b-incident-1', unitId: 'unit-b', createdAt: 5000 });
  const rows = await db.listIncidents('active', { unitId: 'unit-a', limit: 1 });
  assert.equal(rows.length, 1);
  assert.equal(rows[0].unit_id, 'unit-a');
});

test('PostgreSQL 警情列表分页将 offset 下推并保持单位边界', async () => {
  await seedUnit('unit-page');
  await db.createIncident({ id: 'unit-page-1', unitId: 'unit-page', createdAt: 1000 });
  await db.createIncident({ id: 'unit-page-2', unitId: 'unit-page', createdAt: 2000 });
  await db.createIncident({ id: 'unit-page-3', unitId: 'unit-page', createdAt: 3000 });
  const first = await db.listIncidents('active', { unitId: 'unit-page', limit: 2, offset: 0 });
  const second = await db.listIncidents('active', { unitId: 'unit-page', limit: 2, offset: 2 });
  assert.equal(first.length, 2);
  assert.equal(second.length, 1);
  assert.ok([...first, ...second].every((item) => item.unit_id === 'unit-page'));
});

test('PostgreSQL 参战力量列表支持按警情批量读取', async () => {
  await seedUnit('unit-force');
  const incidentA = await db.createIncident({ id: 'incident-pg-a', unitId: 'unit-force', createdAt: 1000 });
  const incidentB = await db.createIncident({ id: 'incident-pg-b', unitId: 'unit-force', createdAt: 2000 });
  await db.upsertIncidentForce({ id: 'force-pg-1', incidentId: incidentA.id, stationName: '一站' });
  await db.upsertIncidentForce({ id: 'force-pg-2', incidentId: incidentB.id, stationName: '二站' });
  const rows = await db.listIncidentForcesBatch([incidentA.id, incidentB.id]);
  assert.equal(rows.length, 2);
});

test('PostgreSQL 认证仓储保留成员角色并拒绝过期/已撤销会话', async () => {
  await seedUnit('unit-auth');
  const member = await db.addUnitMember({ id: 'member-pg-1', unitId: 'unit-auth', realName: '管理员', role: 'manager' });
  assert.equal(member.role, 'manager');
  const expired = await db.createAuthSession({ id: 'session-pg-expired', tokenHash: 'hash-pg-expired', unitId: 'unit-auth', memberId: member.id, deviceId: 'device-pg', realName: member.real_name, role: member.role, expiresAt: Date.now() - 1 });
  assert.equal(expired.id, 'session-pg-expired');
  assert.equal(await db.getAuthSession('hash-pg-expired'), undefined);
  assert.equal((await db.getAuthSessionRecord('hash-pg-expired')).id, 'session-pg-expired');
  assert.equal(await db.refreshAuthSession('hash-pg-expired', { expiresAt: Date.now() + 60_000 }), undefined);
  const current = await db.createAuthSession({ id: 'session-pg-current', tokenHash: 'hash-pg-current', unitId: 'unit-auth', memberId: member.id, deviceId: 'device-pg', realName: member.real_name, role: member.role, expiresAt: Date.now() + 60_000 });
  assert.equal((await db.getAuthSession('hash-pg-current')).role, 'manager');
  const refreshed = await db.refreshAuthSession('hash-pg-current', { expiresAt: current.expires_at + 60_000 });
  assert.equal(refreshed.expires_at, current.expires_at + 60_000);
  assert.equal(await db.touchAuthSession('hash-pg-current'), 1);
  assert.equal(await db.revokeAuthSession('hash-pg-current'), 1);
  assert.equal(await db.getAuthSession('hash-pg-current'), undefined);
});

test('PostgreSQL 操作账本按单位和操作号保留请求摘要与结果', async () => {
  await seedUnit('unit-ledger-pg');
  const first = await db.beginOperation({ unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', operationType: 'entry', requestHash: 'hash-pg-a', actorName: '甲' });
  assert.equal(first.status, 'pending');
  assert.equal(first.created, true);
  const duplicate = await db.beginOperation({ unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', operationType: 'entry', requestHash: 'hash-pg-b', actorName: '乙' });
  assert.equal(duplicate.request_hash, 'hash-pg-a');
  assert.equal(await db.completeOperation({ unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', requestHash: 'hash-pg-b', result: { id: 'wrong' } }), 0);
  assert.equal(await db.completeOperation({ unitId: 'unit-ledger-pg', clientOpId: 'ledger-pg-1', requestHash: 'hash-pg-a', result: { id: 'entry-pg-1' }, responseStatus: 201, eventId: 'event-pg-1' }), 1);
  const completed = await db.getOperation('unit-ledger-pg', 'ledger-pg-1');
  assert.equal(completed.status, 'succeeded');
  assert.equal((typeof completed.result_json === 'string' ? JSON.parse(completed.result_json) : completed.result_json).id, 'entry-pg-1');
  assert.equal(completed.response_status, 201);
});

test('PostgreSQL 仓储的出场状态转换只成功一次', async () => {
  await seedUnit('unit-exit');
  const incident = await db.createIncident({ id: 'incident-pg-exit', unitId: 'unit-exit', createdAt: 1000 });
  await db.createEntry({ id: 'entry-exit-once', scene: incident.id, name: '张三', pressureMpa: 20, durationMin: 1, entryAtMs: 1000, exitAtMs: 2000 });
  const first = await db.markExitedIfActive('entry-exit-once', 1000);
  const second = await db.markExitedIfActive('entry-exit-once', 2000);
  assert.equal(first.changed, true);
  assert.equal(second.changed, false);
  assert.equal(Number(second.entry.exited_at), 1000);
});

test('PostgreSQL 力量按ID改名，名称冲突与跨警情编辑不误写', async () => {
  const incident = await db.createIncident({ unitId: 'unit-test', createdAt: 6000 });
  const a = await db.upsertIncidentForce({ incidentId: incident.id, stationName: '灵山队', vehicleCount: 2, personnelCount: 10 });
  const b = await db.upsertIncidentForce({ incidentId: incident.id, stationName: '林山专职队', vehicleCountKnown: false, personnelCountKnown: false });
  const renamed = await db.upsertIncidentForce({ id: a.id, updateOnly: true, incidentId: incident.id, stationName: '灵山专职队', expectedVersion: a.version });
  assert.equal(renamed.id, a.id);
  assert.equal(renamed.station_name, '灵山专职队');
  assert.equal(renamed.personnel_count, 10);
  await assert.rejects(db.upsertIncidentForce({ id: a.id, updateOnly: true, incidentId: incident.id, stationName: b.station_name }), { code: 'FORCE_NAME_CONFLICT' });
  await assert.rejects(db.upsertIncidentForce({ id: a.id, incidentId: 'other-incident', stationName: '越权' }), { code: 'FORCE_NOT_FOUND' });
  await assert.rejects(db.upsertIncidentForce({ id: a.id, incidentId: incident.id, stationName: '过期修改', expectedVersion: a.version }), { code: 'VERSION_CONFLICT' });
  assert.equal((await db.getIncidentForce(b.id)).personnel_count_known, false);
  assert.equal((await db.listIncidentForces(incident.id)).length, 2);
});

test('PostgreSQL 未知数量经旧版无关编辑保留，显式补全可确认真实零', async () => {
  const incident = await db.createIncident({ unitId: 'unit-test', createdAt: 7000 });
  const force = await db.upsertIncidentForce({ incidentId: incident.id, stationName: '未知专职队', vehicleCountKnown: false, personnelCountKnown: false });
  const legacy = await db.upsertIncidentForce({ id: force.id, incidentId: incident.id, stationName: '未知队改名', vehicleCount: 0, personnelCount: 0 });
  assert.equal(legacy.vehicle_count_known, false);
  assert.equal(legacy.personnel_count_known, false);
  const completed = await db.upsertIncidentForce({ id: force.id, incidentId: incident.id, stationName: legacy.station_name, vehicleCount: 0, vehicleCountKnown: true, personnelCount: 7 });
  assert.equal(completed.vehicle_count_known, true);
  assert.equal(completed.personnel_count_known, true);
  assert.equal(completed.personnel_count, 7);
});

const { randomUUID } = require('node:crypto');

test('单位常用队伍隔离、别名冲突、停用及历史快照保护', async () => {
  await seedUnit('unit-directory-a');
  await seedUnit('unit-directory-b');
  const a = await imports.addStation('unit-directory-a', '灵山专职队', 'actor-a');
  const b = await imports.addStation('unit-directory-b', '灵山专职队', 'actor-b');
  assert.notEqual(a.id, b.id);
  const updated = await imports.updateStation('unit-directory-a', a.id, { expected_version: 1, aliases: ['灵山队'] }, 'manager');
  assert.equal(updated.version, 2);
  const second = await imports.addStation('unit-directory-a', '林山专职队', 'actor-a');
  await assert.rejects(imports.updateStation('unit-directory-a', second.id, { expected_version: 1, aliases: ['灵山队'] }, 'manager'), { code: 'STATION_NAME_CONFLICT' });
  await assert.rejects(imports.updateStation('unit-directory-b', a.id, { expected_version: 2, name: '越权' }, 'other'), { code: 'STATION_NOT_FOUND' });
  await imports.updateStation('unit-directory-a', a.id, { expected_version: 2, active: false }, 'manager');
  assert.equal((await imports.listStations('unit-directory-a')).length, 1);
  assert.equal((await imports.listStations('unit-directory-a', true)).length, 2);
});

async function readyImport(incident, actorId = 'actor-import', draft = {}) {
  const id = randomUUID(), now = Date.now();
  await store.query(`INSERT INTO incident_imports(id, unit_id, incident_id, actor_id, actor_name, source, status, input_hash, pages, draft, created_at, updated_at, expires_at)
    VALUES ($1,$2,$3,$4,'测试员','text','ready','sample',$5,$6,$7,$7,$8)`,
    [id, incident.unit_id, incident.id, actorId, JSON.stringify([{ index: 1, status: 'succeeded', text: '脱敏通报' }]), JSON.stringify(draft), now, now + 86400000]);
  return id;
}

test('导入事务原子更新、响应丢失重放、操作号内容冲突与跨单位保护', async () => {
  const incident = await db.createIncident({ unitId: 'unit-test', createdAt: 9000 });
  const id = await readyImport(incident);
  const body = { expected_incident_version: incident.version, expected_details_version: 0, replace_title: true, title: '大源村电表箱火灾', details: { original_category: '火灾扑救', trapped: '无人员被困' }, forces: [{ station_name: '未预设专职队', vehicle_count: 0, personnel_count: 0, vehicle_count_known: false, personnel_count_known: false, save_common: true }] };
  const args = { unitId: 'unit-test', incidentId: incident.id, actorId: 'actor-import', actorName: '测试员', importId: id, opId: `import-${id}`, body };
  const first = await imports.applyImport(args);
  const replay = await imports.applyImport(args);
  assert.deepEqual(replay, first);
  assert.equal((await db.listIncidentForces(incident.id)).length, 1);
  assert.equal((await imports.details('unit-test', incident.id)).data.trapped, '无人员被困');
  assert.equal((await db.listEntries({ scene: incident.id })).length, 0);
  await assert.rejects(imports.applyImport({ ...args, body: { ...body, title: '不同内容' } }), { code: 'CLIENT_OP_ID_CONFLICT' });
  await assert.rejects(imports.readImport('unit-directory-b', incident.id, 'actor-import', id), { code: 'IMPORT_NOT_FOUND' });
});

test('导入中途名称冲突整批回滚，资料、名录和Outbox不留半成品', async () => {
  const incident = await db.createIncident({ unitId: 'unit-test', createdAt: 10000 });
  const force = await db.upsertIncidentForce({ incidentId: incident.id, stationName: '已有力量' });
  const id = await readyImport(incident);
  const before = await db.getSyncCheckpoint('unit-test', incident.id);
  await assert.rejects(imports.applyImport({ unitId: 'unit-test', incidentId: incident.id, actorId: 'actor-import', actorName: '测试员', importId: id, opId: `rollback-${id}`,
    body: { expected_incident_version: incident.version, expected_details_version: 0, details: { location: '不应保存' }, forces: [{ station_name: '事务内新队伍', save_common: true, vehicle_count: 1, personnel_count: 7 }, { station_name: force.station_name }] } }), { code: 'FORCE_NAME_CONFLICT' });
  assert.equal((await imports.details('unit-test', incident.id)).version, 0);
  assert.equal((await imports.listStations('unit-test')).some((s) => s.name === '事务内新队伍'), false);
  assert.equal((await db.listIncidentForces(incident.id)).length, 1);
  assert.deepEqual(await db.getSyncCheckpoint('unit-test', incident.id), before);
  assert.equal(await db.getOperation('unit-test', `rollback-${id}`), undefined);
});

const {validateExtraction}=require('../src/incident-extraction');

test('多页任务保留成功页、失败页可重试，取消任务阻止迟到应用', async()=>{
  const incident=await db.createIncident({unitId:'unit-test',createdAt:11000});
  // Header validation happens before any filesystem storage or provider call.
  const png=Buffer.alloc(24);Buffer.from([137,80,78,71,13,10,26,10]).copy(png);png.writeUInt32BE(100,16);png.writeUInt32BE(100,20);
  const task=await importTasks.createTask({unitId:'unit-test',incidentId:incident.id,actorId:'task-actor',actorName:'测试员',files:[{buffer:png},{buffer:png}]});
  const duplicate=await importTasks.createTask({unitId:'unit-test',incidentId:incident.id,actorId:'task-actor',actorName:'测试员',files:[{buffer:png},{buffer:png}]});
  assert.equal(task.id,duplicate.id);
  const claimed=await importTasks.claimTask();
  let calls=0;
  await importTasks.runTask(claimed,{},async()=>{
    if(++calls===2) throw Object.assign(new Error('failed'),{code:'IMPORT_PAGE_FAILED'});
    return validateExtraction({raw_text:'甲站出动1车7人',location:'测试村',forces:[{station_name:'甲站',vehicle_count:1,personnel_count:7}]});
  });
  const row=await imports.readImport('unit-test',incident.id,'task-actor',task.id);
  assert.equal(row.status,'partial');
  assert.equal(row.pages[0].status,'succeeded');
  assert.equal(row.pages[1].status,'failed');
  assert.equal(JSON.stringify(imports.publicImport(row)).includes('file_path'),false);
  const scope={unitId:'unit-test',incidentId:incident.id,actorId:'task-actor',id:task.id};
  await importTasks.retryTask(scope,[2]);
  const retry=await importTasks.claimTask();
  await importTasks.runTask(retry,{},async()=>validateExtraction({raw_text:'第二页',forces:[]}));
  assert.equal((await imports.readImport('unit-test',incident.id,'task-actor',task.id)).status,'ready');
  await importTasks.cancelTask(scope);
  assert.equal((await imports.readImport('unit-test',incident.id,'task-actor',task.id)).status,'cancelled');
  assert.equal((await db.listIncidentForces(incident.id)).length,0);
});

test('导入任务使用专用模型，避免把隐式思考算进等待时间',async()=>{
  // 每个用例用独立单位：导入有「单单位 60 秒内最多 3 次」的频率限制
  const run=async(unit,config,text)=>{
    await seedUnit(unit);
    const incident=await db.createIncident({unitId:unit,createdAt:11500});
    const task=await importTasks.createTask({unitId:unit,incidentId:incident.id,actorId:'model-actor',actorName:'测试员',text});
    const claimed=await importTasks.claimTask();
    const seen=[];
    await importTasks.runTask(claimed,config,async(options)=>{
      seen.push(options.model);
      return validateExtraction({raw_text:text});
    });
    assert.ok(task.id);
    return seen;
  };
  // 配了专用模型就用专用模型：导入只需照抄原文，不该为隐式思考等二三十秒
  assert.deepEqual(await run('unit-model-a',{apiKey:'k',baseUrl:'u',chatModel:'通用模型',importModel:'导入模型'},'甲站出动1车7人'),['导入模型']);
  // 没配专用模型时回落到通用问答模型，不能因此不跑
  assert.deepEqual(await run('unit-model-b',{apiKey:'k',baseUrl:'u',chatModel:'通用模型'},'乙站出动2车9人'),['通用模型']);
});

test('力量显式合并采用确认数量且可幂等重放，不相加',async()=>{
  const incident=await db.createIncident({unitId:'unit-test',createdAt:12000});
  const a=await db.upsertIncidentForce({incidentId:incident.id,stationName:'甲队简称',vehicleCount:1,personnelCount:7});
  const b=await db.upsertIncidentForce({incidentId:incident.id,stationName:'甲队正式名',vehicleCount:2,personnelCount:10});
  const args={unitId:'unit-test',incidentId:incident.id,actorId:'merge-actor',actorName:'测试员',opId:randomUUID(),body:{source_id:a.id,target_id:b.id,source_version:a.version,target_version:b.version,vehicle_count:2,personnel_count:10,vehicle_count_known:true,personnel_count_known:true}};
  await imports.mergeForces(args);await imports.mergeForces(args);
  const rows=await db.listIncidentForces(incident.id);
  assert.equal(rows.length,1);assert.equal(rows[0].personnel_count,10);
});

test('真实HTTP路由隔离草稿、限制共享名录管理并原子应用',async()=>{
  process.env.WATCHDOG_UNIT_AUTH_REQUIRED='1';
  process.env.WATCHDOG_SESSION_AUTH_REQUIRED='1';
  const {createHash}=require('node:crypto');
  const token=`http-${randomUUID()}`;
  const member=await db.addUnitMember({unitId:'unit-test',realName:'接口测试员',role:'member'});
  await db.createAuthSession({id:randomUUID(),tokenHash:createHash('sha256').update(token).digest('hex'),unitId:'unit-test',memberId:member.id,deviceId:'http-device',realName:member.real_name,role:'member',expiresAt:Date.now()+60000});
  const incident=await db.createIncident({unitId:'unit-test',createdAt:13000});
  const task=await readyImport(incident,member.id);
  const foreignTask=await readyImport(incident,'other-member');
  const app=require('../src/server');
  const server=app.listen(0,'127.0.0.1');
  await new Promise((resolve)=>server.once('listening',resolve));
  const base=`http://127.0.0.1:${server.address().port}`;
  const headers={'Authorization':`Bearer ${token}`,'Content-Type':'application/json','X-Incident-Id':incident.id};
  try{
    assert.equal((await fetch(`${base}/api/incidents/${incident.id}/imports/${foreignTask}`,{headers})).status,404);
    const read=await fetch(`${base}/api/incidents/${incident.id}/imports/${task}`,{headers});
    assert.equal(read.status,200);
    const station=await imports.addStation('unit-test',`HTTP常用-${randomUUID()}`,member.id);
    const denied=await fetch(`${base}/api/unit-stations/${station.id}`,{method:'PATCH',headers,body:JSON.stringify({name:'无权改名',expected_version:station.version})});
    assert.equal(denied.status,403);
    const access=await (await fetch(`${base}/api/unit-stations/access`,{headers})).json();
    assert.equal(access.can_manage,false);
    const body={expected_incident_version:incident.version,expected_details_version:0,details:{location:'HTTP测试地点'},forces:[]};
    const apply=await fetch(`${base}/api/incidents/${incident.id}/imports/${task}/apply`,{method:'POST',headers:{...headers,'X-Op-Id':`http-apply-${task}`},body:JSON.stringify(body)});
    assert.equal(apply.status,200);
    const detail=await (await fetch(`${base}/api/incidents/${incident.id}/details`,{headers})).json();
    assert.equal(detail.data.location,'HTTP测试地点');
    assert.equal(detail.imports.length,1);
  }finally{await new Promise((resolve)=>server.close(resolve));}
});

test('常用队伍别名匹配稳定身份，相似名称只建议且跨单位关联拒绝',async()=>{
  const unit=await imports.addStation('unit-directory-a','测试专职队','actor');
  await imports.updateStation('unit-directory-a',unit.id,{expected_version:unit.version,aliases:['测试队']},'manager');
  const incident=await db.createIncident({unitId:'unit-directory-a'});
  const force=await db.upsertIncidentForce({incidentId:incident.id,stationName:'测试专职队',unitStationId:unit.id});
  const [matched]=await imports.matchForces('unit-directory-a',incident.id,[{station_name:'测试队'}]);
  assert.equal(matched.target_force_id,force.id);
  const [similar]=await imports.matchForces('unit-directory-a',incident.id,[{station_name:'测式专职队'}]);
  assert.equal(similar.match,'unmatched');assert.equal(similar.target_force_id,null);
  assert.ok(similar.candidates.some(c=>c.name==='测试专职队'));
  const other=await db.createIncident({unitId:'unit-directory-b'});
  await assert.rejects(db.upsertIncidentForce({incidentId:other.id,stationName:'测试队',unitStationId:unit.id}),{code:'FORCE_NOT_FOUND'});
});
