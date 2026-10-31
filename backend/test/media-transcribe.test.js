const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
process.env.WATCHDOG_DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-media-asr-'));
process.env.VOLC_APP_ID = 'test-app';
const app = require('../src/server');
let server;
let base;
before(async () => {
  server = app.listen(0);
  await new Promise(resolve => server.once('listening', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => new Promise(resolve => server.close(resolve)));
test('视频转写允许无警情，普通转写仍要求警情', async () => {
  const options = { method: 'POST', headers: { 'content-type': 'audio/wav' }, body: Buffer.alloc(10) };
  let response = await fetch(`${base}/api/media/transcribe`, options);
  assert.equal(response.status, 400);
  assert.match((await response.json()).error, /音频数据过短/);
  response = await fetch(`${base}/api/transcribe`, options);
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, 'INCIDENT_REQUIRED');
  response = await fetch(`${base}/api/media/transcribe`, { ...options, headers: { ...options.headers, 'x-incident-id': 'missing' } });
  assert.equal(response.status, 404);
});
