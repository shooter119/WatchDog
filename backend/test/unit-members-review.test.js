const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

let child;
let base;
let dataDir;

before(async () => {
  dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-member-review-'));
  const port = 4700 + Math.floor(Math.random() * 400);
  child = spawn(process.execPath, ['src/server.js'], {
    cwd: path.join(__dirname, '..'),
    env: {
      ...process.env,
      NODE_ENV: 'test',
      WATCHDOG_DB_DRIVER: 'sqlite',
      PORT: String(port),
      API_TOKEN: 'review-token',
      WATCHDOG_UNIT_AUTH_REQUIRED: '1',
      WATCHDOG_SESSION_AUTH_REQUIRED: '1',
      WATCHDOG_MEMBER_AUTH_REQUIRED: '1',
      WATCHDOG_SEED_UNIT_ID: 'review-unit',
      WATCHDOG_SEED_UNIT_NAME: '搜救中队',
      WATCHDOG_SEED_UNIT_CODE: '6688',
      WATCHDOG_SEED_UNIT_MEMBERS: '[{"real_name":"站长","role":"manager"}]',
      WATCHDOG_DATA_DIR: dataDir,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  for (let i = 0; i < 40; i++) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (response.status === 200) {
        base = `http://127.0.0.1:${port}`;
        return;
      }
    } catch (_) {}
    if (child.exitCode != null) break;
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error('测试服务器启动失败');
});

after(async () => {
  if (child && child.exitCode == null) {
    child.kill('SIGTERM');
    await new Promise((resolve) => child.on('close', resolve));
  }
  fs.rmSync(dataDir, { recursive: true, force: true });
});

test('新队员申请加入 -> 待审核拦截 -> 站长审批 -> 成功登录全链路', async () => {
  // 1. 新队员提交申请前尝试直接登录 -> 被拒绝
  const preLogin = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '李小龙' }),
  });
  assert.equal(preLogin.status, 403);
  const preLoginJson = await preLogin.json();
  assert.equal(preLoginJson.code, 'MEMBER_NOT_ALLOWED');

  // 2. 提交申请：姓名合法性检查
  const badApply = await fetch(`${base}/api/auth/apply`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: 'BruceLee123' }),
  });
  assert.equal(badApply.status, 400);
  assert.equal((await badApply.json()).code, 'REAL_NAME_INVALID');

  // 3. 正常提交入队申请 (202 Accepted)
  const applyRes = await fetch(`${base}/api/auth/apply`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      unit_name: '搜救中队',
      unit_code: '6688',
      real_name: '李小龙',
      station_name: '一班',
      phone: '13800138000',
      apply_reason: '新调入队员',
    }),
  });
  assert.equal(applyRes.status, 202);
  const applyJson = await applyRes.json();
  assert.equal(applyJson.applied, true);
  assert.equal(applyJson.member.real_name, '李小龙');
  assert.equal(applyJson.member.review_status, 'pending');

  // 4. 重复提交申请（幂等返回，不报错）
  const dupApplyRes = await fetch(`${base}/api/auth/apply`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      unit_name: '搜救中队',
      unit_code: '6688',
      real_name: '李小龙',
    }),
  });
  assert.equal(dupApplyRes.status, 202);

  // 5. 待审状态下再次尝试登录 -> 提示 MEMBER_APPLICATION_PENDING
  const pendingLogin = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '李小龙' }),
  });
  assert.equal(pendingLogin.status, 403);
  const pendingLoginJson = await pendingLogin.json();
  assert.equal(pendingLoginJson.code, 'MEMBER_APPLICATION_PENDING');

  // 6. 站长登录获取 session_token
  const managerLogin = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '站长' }),
  });
  assert.equal(managerLogin.status, 200);
  const { session_token: mgrToken } = await managerLogin.json();

  // 7. 站长查看待审列表
  const pendingListRes = await fetch(`${base}/api/unit-members/pending`, {
    headers: { 'Authorization': `Bearer ${mgrToken}` },
  });
  assert.equal(pendingListRes.status, 200);
  const pendingList = await pendingListRes.json();
  assert.equal(pendingList.length, 1);
  assert.equal(pendingList[0].real_name, '李小龙');
  const targetMemberId = pendingList[0].id;

  // 8. 站长审批通过
  const approveRes = await fetch(`${base}/api/unit-members/${targetMemberId}/approve`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${mgrToken}` },
  });
  assert.equal(approveRes.status, 200);
  const approveJson = await approveRes.json();
  assert.equal(approveJson.approved, true);
  assert.equal(approveJson.member.review_status, 'approved');
  assert.equal(approveJson.member.status, 'active');

  // 9. 待审列表清空
  const pendingEmptyRes = await fetch(`${base}/api/unit-members/pending`, {
    headers: { 'Authorization': `Bearer ${mgrToken}` },
  });
  assert.equal((await pendingEmptyRes.json()).length, 0);

  // 10. 队员此时登录 -> 成功登录！
  const approvedLogin = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '李小龙' }),
  });
  assert.equal(approvedLogin.status, 200);
  const approvedJson = await approvedLogin.json();
  assert.equal(approvedJson.authenticated, true);
  assert.equal(approvedJson.user.real_name, '李小龙');
});

test('入队申请被驳回后登录提示 MEMBER_APPLICATION_REJECTED 并允许重新申请', async () => {
  // 1. 提交新申请
  await fetch(`${base}/api/auth/apply`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '王小二' }),
  });

  // 2. 站长登录并拒绝
  const managerLogin = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '站长' }),
  });
  const { session_token: mgrToken } = await managerLogin.json();

  const pendingList = await (await fetch(`${base}/api/unit-members/pending`, {
    headers: { 'Authorization': `Bearer ${mgrToken}` },
  })).json();
  const wang = pendingList.find((m) => m.real_name === '王小二');
  assert.ok(wang);

  const rejectRes = await fetch(`${base}/api/unit-members/${wang.id}/reject`, {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${mgrToken}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ reason: '非本队人员' }),
  });
  assert.equal(rejectRes.status, 200);

  // 3. 王小二登录 -> MEMBER_APPLICATION_REJECTED
  const rejectLogin = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '王小二' }),
  });
  assert.equal(rejectLogin.status, 403);
  assert.equal((await rejectLogin.json()).code, 'MEMBER_APPLICATION_REJECTED');

  // 4. 允许重新提交申请
  const reApply = await fetch(`${base}/api/auth/apply`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '王小二', apply_reason: '核实后重申' }),
  });
  assert.equal(reApply.status, 202);
  assert.equal((await reApply.json()).member.review_status, 'pending');
});

test('语音名单精确命中返回 MEMBER_ROSTER_ONLY，差一字返回 suggestions，待审列表标记 in_roster', async () => {
  // 站长登录获取管理 token
  const managerLogin = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '站长' }),
  });
  assert.equal(managerLogin.status, 200);
  const { session_token: mgrToken } = await managerLogin.json();

  // 1. 先把一个名字写进语音名单（用 POST /api/firefighters，需管理角色 token）
  const addFfRes = await fetch(`${base}/api/firefighters`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${mgrToken}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ name: '韩梅梅' }),
  });
  assert.equal(addFfRes.status, 201);

  // 再用该姓名（精确）调 /api/auth/verify -> 403 MEMBER_ROSTER_ONLY
  const rosterOnlyRes = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '韩梅梅' }),
  });
  assert.equal(rosterOnlyRes.status, 403);
  const rosterOnlyJson = await rosterOnlyRes.json();
  assert.equal(rosterOnlyJson.code, 'MEMBER_ROSTER_ONLY');
  assert.equal(
    rosterOnlyJson.error,
    '该姓名在语音识别名单中，但还没有登录权限，请提交入队申请等待管理员批准',
  );

  // 2. 用“差一个字”的姓名调 verify -> 403 MEMBER_NOT_ALLOWED 且 suggestions 含正确写法
  const nearMissRes = await fetch(`${base}/api/auth/verify`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '韩梅美' }),
  });
  assert.equal(nearMissRes.status, 403);
  const nearMissJson = await nearMissRes.json();
  assert.equal(nearMissJson.code, 'MEMBER_NOT_ALLOWED');
  assert.ok(Array.isArray(nearMissJson.suggestions));
  assert.ok(nearMissJson.suggestions.includes('韩梅梅'));

  // 3. 提交申请后 /api/unit-members/pending 中该条 in_roster === true
  const applyInRoster = await fetch(`${base}/api/auth/apply`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '韩梅梅' }),
  });
  assert.equal(applyInRoster.status, 202);

  // 换成一个不在语音名单的姓名申请 -> in_roster === false
  const applyNotInRoster = await fetch(`${base}/api/auth/apply`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ unit_name: '搜救中队', unit_code: '6688', real_name: '孙悟空' }),
  });
  assert.equal(applyNotInRoster.status, 202);

  const pendingRes = await fetch(`${base}/api/unit-members/pending`, {
    headers: { 'Authorization': `Bearer ${mgrToken}` },
  });
  assert.equal(pendingRes.status, 200);
  const pendingList = await pendingRes.json();
  const han = pendingList.find((m) => m.real_name === '韩梅梅');
  const sun = pendingList.find((m) => m.real_name === '孙悟空');
  assert.ok(han);
  assert.equal(han.in_roster, true);
  assert.ok(sun);
  assert.equal(sun.in_roster, false);
});
