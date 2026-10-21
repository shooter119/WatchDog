const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const WebSocket = require('ws');
process.env.DATABASE_URL ||= 'postgresql:///watchdog_test';
process.env.WATCHDOG_DB_DRIVER = 'postgres';
process.env.WATCHDOG_SKIP_SEED = '1';
const { Pool } = require('pg');
const adminPool = new Pool({ connectionString: process.env.DATABASE_URL });
const schema = `member_review_${process.pid}_${Date.now()}`;
let store, db;
const unit = `review-${randomUUID()}`, other = `other-${randomUUID()}`;
let child, base, platform, manager, ordinary, outsider;
const sockets = [];
const headers = token => ({ Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' });
async function call(path, token, body) {
  const response = await fetch(`${base}${path}`, { headers: headers(token), ...(body === undefined ? {} : { method: 'POST', body: JSON.stringify(body) }) });
  return { status: response.status, body: await response.json() };
}
async function login(name, uid = unit, device = name) {
  const result = await call('/api/auth/verify', '', { unit_name: uid, unit_code: uid, real_name: name, device_id: device });
  assert.equal(result.status, 200, JSON.stringify(result.body));
  return result.body.session_token;
}
async function apply(name) {
  const result = await call('/api/auth/apply', '', { unit_name: unit, unit_code: unit, real_name: name, apply_reason: '测试入队' });
  assert.equal(result.status, 202, JSON.stringify(result.body));
  return result.body.member;
}
async function inbox(token) { return call('/api/unit-members/pending', token); }
async function open(token) {
  const socket = new WebSocket(base.replace('http', 'ws') + '/api/realtime', { headers: headers(token) });
  sockets.push(socket);
  const messages = [];
  socket.on('message', data => messages.push(JSON.parse(data)));
  await new Promise((resolve,reject) => { socket.once('open',resolve); socket.once('error',reject); });
  socket.send(JSON.stringify({ type:'subscribe', unit_cursor:'0', incident_cursor:'0' }));
  return messages;
}
async function until(fn) {
  for (let i=0;i<100;i++) { if (fn()) return; await new Promise(r=>setTimeout(r,30)); }
  assert.fail('同步消息超时');
}
before(async () => {
  await adminPool.query(`CREATE SCHEMA "${schema}"`);
  const url = new URL(process.env.DATABASE_URL);
  url.searchParams.set('options', `-c search_path=${schema}`);
  process.env.DATABASE_URL = url.toString();
  store = require('../src/postgres-store');
  db = require('../src/db-postgres');
  await store.ready;
  for (const id of [unit,other]) await store.query('INSERT INTO units(id,name,verification_code,created_at,updated_at) VALUES($1,$1,$1,$2,$2)', [id,Date.now()]);
  platform = await db.addUnitMember({unitId:unit,realName:'平台甲'});
  manager = await db.addUnitMember({unitId:unit,realName:'管理员乙',role:'manager'});
  ordinary = await db.addUnitMember({unitId:unit,realName:'普通丙'});
  outsider = await db.addUnitMember({unitId:other,realName:'外单位丁',role:'admin'});
  await store.query("INSERT INTO admin_grants(member_id,role,updated_at) VALUES($1,'platform_admin',$2)",[platform.id,Date.now()]);
  const port = 15000 + Math.floor(Math.random()*1000);
  child = spawn(process.execPath,['src/server.js'],{cwd:require('node:path').join(__dirname,'..'),env:{...process.env,NODE_ENV:'test',PORT:String(port),WATCHDOG_SESSION_AUTH_REQUIRED:'1',WATCHDOG_UNIT_AUTH_REQUIRED:'1',WATCHDOG_MEMBER_AUTH_REQUIRED:'1'},stdio:['ignore','pipe','pipe']});
  let errors=''; child.stderr.on('data',data=>errors+=data);
  base=`http://127.0.0.1:${port}`;
  for(let i=0;i<100;i++) { try { if ((await fetch(`${base}/api/health`)).ok) return; } catch {} await new Promise(r=>setTimeout(r,100)); }
  throw new Error(errors);
});
after(async () => {
  for(const socket of sockets) socket.terminate();
  if(child && child.exitCode===null) { child.kill(); await new Promise(r=>child.once('close',r)); }
  await store?.close();
  await adminPool.query(`DROP SCHEMA IF EXISTS "${schema}" CASCADE`);
  await adminPool.end();
});

test('同单位平台管理员和单位管理员共享待办，实时通知无个人信息；并发审批只成功一次', async () => {
  const a=await login('平台甲'), b=await login('管理员乙'), c=await login('普通丙'), d=await login('外单位丁',other);
  assert.equal((await call('/api/unit-members/capability',a)).body.can_review_members,true);
  assert.equal((await call('/api/unit-members/capability',b)).body.can_review_members,true);
  assert.equal((await call('/api/unit-members/capability',c)).body.can_review_members,false);
  assert.equal((await inbox(c)).status,403);
  assert.equal((await call('/api/unit-members/review-history',c)).status,403);
  // Approval-only capability does not expand the general management API.
  assert.equal((await call('/api/unit-members',a)).status,403);
  const [messagesA,messagesB] = await Promise.all([open(a),open(b)]);
  await until(()=>messagesA.some(m=>m.type==='ready') && messagesB.some(m=>m.type==='ready'));
  const beforeA=messagesA.length,beforeB=messagesB.length;
  const member = await apply('测试戊');
  const duplicate = await apply('测试戊');
  assert.equal(member.id,duplicate.id);
  await until(()=>[messagesA.slice(beforeA),messagesB.slice(beforeB)].every(ms=>ms.some(m=>m.event_type==='members.applications_changed')));
  for (const messages of [messagesA,messagesB]) {
    for(const event of messages.filter(m=>m.event_type==='members.applications_changed')) assert.deepEqual(event.payload,{});
  }
  assert.equal((await inbox(a)).body[0].id,member.id);
  assert.equal((await inbox(b)).body[0].id,member.id);
  assert.equal((await inbox(d)).body.length,0);
  assert.equal((await call(`/api/unit-members/${member.id}/approve`,d,{})).status,404);
  const eventCounts=[messagesA,messagesB].map(ms=>ms.filter(m=>m.event_type==='members.applications_changed').length);
  const results=await Promise.all([call(`/api/unit-members/${member.id}/approve`,a,{}),call(`/api/unit-members/${member.id}/reject`,b,{})]);
  assert.deepEqual(results.map(r=>r.status).sort(),[200,409]);
  assert.equal(results.find(r=>r.status===409).body.code,'MEMBER_APPLICATION_ALREADY_REVIEWED');
  assert.ok(results.find(r=>r.status===409).body.review.reviewer_name);
  await until(()=>[messagesA,messagesB].every((ms,i)=>ms.filter(m=>m.event_type==='members.applications_changed').length>eventCounts[i]));
  assert.equal((await inbox(a)).body.length,0);
  assert.equal((await inbox(b)).body.length,0);
  const history=(await call('/api/unit-members/review-history',b)).body;
  assert.equal(history.length,1);
  assert.equal(history[0].real_name,'测试戊');
  assert.equal(typeof history[0].reviewed_at,'number');
  assert.equal((await store.query('SELECT COUNT(*)::int n FROM firefighters WHERE unit_id=$1 AND name=$2',[unit,'测试戊'])).rows[0].n,history[0].review_status==='approved'?1:0);
  // Role/grant changes are checked from current database state, even with an old session.
  await store.query('DELETE FROM admin_grants WHERE member_id=$1',[platform.id]);
  assert.equal((await call('/api/unit-members/capability',a)).body.can_review_members,false);
  assert.equal((await inbox(a)).status,403);
  await store.query("UPDATE unit_members SET role='member' WHERE id=$1",[manager.id]);
  assert.equal((await inbox(b)).status,403);
});

test('驳回后重新申请保留历史，批准后可登录，重复批准不重写历史', async () => {
  await store.query("UPDATE unit_members SET role='manager' WHERE id=$1",[manager.id]);
  const token=await login('管理员乙');
  const member=await apply('测试己');
  assert.equal((await call(`/api/unit-members/${member.id}/reject`,token,{})).status,200);
  const denied=await call('/api/auth/verify','',{unit_name:unit,unit_code:unit,real_name:'测试己'});
  assert.equal(denied.body.code,'MEMBER_APPLICATION_REJECTED');
  assert.equal((await apply('测试己')).id,member.id);
  assert.equal((await call(`/api/unit-members/${member.id}/approve`,token,{})).status,200);
  assert.ok(await login('测试己'));
  assert.equal((await call(`/api/unit-members/${member.id}/approve`,token,{})).status,409);
  const rows=(await call('/api/unit-members/review-history',token)).body.filter(r=>r.member_id===member.id);
  assert.equal(rows.length,2);
  assert.deepEqual(rows.map(r=>r.review_status).sort(),['approved','rejected']);
});

 test('审批事务回滚不残留成员激活、名单、审计或同步事件', async () => {
  const member = await apply('测试庚');
  const before = await store.query('SELECT COUNT(*)::int n FROM sync_events WHERE unit_id=$1', [unit]);
  await assert.rejects(() => store.transaction(async () => {
    await db.approveUnitMember(member.id, unit, manager.id, { reviewerName: '管理员乙' });
    throw new Error('模拟事务失败');
  }), /模拟事务失败/);
  assert.equal((await db.listPendingUnitMembers(unit)).some(m=>m.id===member.id),true);
  assert.equal((await store.query('SELECT COUNT(*)::int n FROM firefighters WHERE unit_id=$1 AND name=$2',[unit,'测试庚'])).rows[0].n,0);
  assert.equal((await db.listMemberReviewHistory(unit)).filter(r=>r.member_id===member.id).length,0);
  assert.equal((await store.query('SELECT COUNT(*)::int n FROM sync_events WHERE unit_id=$1',[unit])).rows[0].n,before.rows[0].n);
});
