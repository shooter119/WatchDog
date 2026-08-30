const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

// 用子进程验证单位级认证不依赖 API_TOKEN（环境变量对单测进程不可变）
test('单位级认证：不填写 API_TOKEN 也可完成认证', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-token-'));
  const port = 3900 + Math.floor(Math.random() * 500);
  const child = spawn(process.execPath, ['src/server.js'], {
    cwd: path.join(__dirname, '..'),
    env: {
      ...process.env,
      PORT: String(port),
      API_TOKEN: 'secret-token',
      WATCHDOG_UNIT_AUTH_REQUIRED: '1',
      WATCHDOG_DATA_DIR: tmpDir,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  try {
    // 等待就绪
    let up = false;
    for (let i = 0; i < 40; i++) {
      try {
        const r = await fetch(`http://127.0.0.1:${port}/api/health`);
        if (r.status === 200) { up = true; break; }
      } catch {}
      await new Promise((r) => setTimeout(r, 250));
    }
    assert.ok(up, '服务未在 10s 内启动');

    // health 免认证
    const health = await fetch(`http://127.0.0.1:${port}/api/health`);
    assert.equal(health.status, 200);

    // 未完成单位认证 → 401
    const noAuth = await fetch(`http://127.0.0.1:${port}/api/config`);
    assert.equal(noAuth.status, 401);

    // 错误令牌不会绕过单位认证 → 401
    const badAuth = await fetch(`http://127.0.0.1:${port}/api/config`, { headers: { 'X-Api-Token': 'wrong' } });
    assert.equal(badAuth.status, 401);

    // 单位认证只依靠单位名称和验证码，并继续受失败限流保护。
    const badBootstrap = await fetch(`http://127.0.0.1:${port}/api/auth/verify`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Device-Id': 'bootstrap-bad' },
      body: JSON.stringify({ unit_name: '龙游县消防救援大队', unit_code: '0570', real_name: '测试员' }),
    });
    assert.equal(badBootstrap.status, 200);

    // 无 API_TOKEN、未完成单位认证 → 401
    const okAuth = await fetch(`http://127.0.0.1:${port}/api/config`);
    assert.equal(okAuth.status, 401);

    // 只有单位 ID + 验证码 → 200
    const okUnitAuth = await fetch(`http://127.0.0.1:${port}/api/config`, {
      headers: {
        'X-Unit-Id': 'longyou-county-fire-rescue',
        'X-Unit-Code': '0570',
      },
    });
    assert.equal(okUnitAuth.status, 200);

    // 限流不能被轮换客户端自报设备 ID 绕过。
    const attempts = [];
    for (let i = 0; i < 6; i++) {
      const response = await fetch(`http://127.0.0.1:${port}/api/auth/verify`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Device-Id': `rotated-device-${i}`,
        },
        body: JSON.stringify({ unit_name: '龙游县消防救援大队', unit_code: 'wrong', real_name: '测试员' }),
      });
      attempts.push(response.status);
    }
    assert.deepEqual(attempts.slice(0, 5), [403, 403, 403, 403, 403]);
    assert.equal(attempts[5], 429);
  } finally {
    child.kill('SIGTERM');
    await new Promise((r) => child.once('exit', r));
  }
});
