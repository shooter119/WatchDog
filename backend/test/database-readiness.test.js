const { test } = require('node:test');
const assert = require('node:assert/strict');
const { createDatabaseReadiness } = require('../src/database-readiness');

test('数据库初始化期间业务请求等待完成后再继续', async () => {
  let resolveReady;
  const pending = new Promise((resolve) => { resolveReady = resolve; });
  const readiness = createDatabaseReadiness(pending, { waitMs: 100 });
  assert.equal(readiness.ready, false);

  const waiting = readiness.wait();
  resolveReady();
  assert.equal(await waiting, true);
  assert.equal(readiness.ready, true);
});

test('数据库初始化超时仍未完成时保持未就绪', async () => {
  const readiness = createDatabaseReadiness(new Promise(() => {}), { waitMs: 1 });
  assert.equal(await readiness.wait(), false);
  assert.equal(readiness.error, null);
});
