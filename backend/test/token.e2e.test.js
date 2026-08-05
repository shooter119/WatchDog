const { test } = require('node:test');
const assert = require('node:assert/strict');
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

// 用子进程验证 API_TOKEN 鉴权（环境变量对单测进程不可变）
test('API_TOKEN 鉴权：未带令牌 401，正确令牌放行', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-token-'));
  const port = 3900 + Math.floor(Math.random() * 500);
  const child = spawn(process.execPath, ['src/server.js'], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, PORT: String(port), API_TOKEN: 'secret-token', WATCHDOG_DATA_DIR: tmpDir },
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

    // 未带令牌 → 401
    const noAuth = await fetch(`http://127.0.0.1:${port}/api/config`);
    assert.equal(noAuth.status, 401);

    // 错误令牌 → 401
    const badAuth = await fetch(`http://127.0.0.1:${port}/api/config`, { headers: { 'X-Api-Token': 'wrong' } });
    assert.equal(badAuth.status, 401);

    // 正确令牌 → 200
    const okAuth = await fetch(`http://127.0.0.1:${port}/api/config`, { headers: { 'X-Api-Token': 'secret-token' } });
    assert.equal(okAuth.status, 200);
  } finally {
    child.kill('SIGTERM');
    await new Promise((r) => child.once('exit', r));
  }
});
