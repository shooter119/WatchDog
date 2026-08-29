const { test } = require('node:test');
const assert = require('node:assert/strict');

const { MinuteRateLimiter } = require('../src/rate-limiter');

test('高基数来源不能让分钟限流 Map 超过硬上限', () => {
  const limiter = new MinuteRateLimiter({ maxEntries: 3 });
  for (let i = 0; i < 20; i++) {
    assert.equal(limiter.isLimited(`source-${i}`, 10, 60_000), false);
  }
  assert.equal(limiter.size, 3);
});

test('限流器按分钟重置计数并清理过期桶', () => {
  const limiter = new MinuteRateLimiter({ maxEntries: 10, staleMinutes: 1 });
  assert.equal(limiter.isLimited('source', 1, 60_000), false);
  assert.equal(limiter.isLimited('source', 1, 60_001), true);
  assert.equal(limiter.isLimited('source', 1, 120_000), false);
  assert.equal(limiter.isLimited('new-source', 1, 240_000), false);
  assert.equal(limiter.size, 1);
});

test('限流器只在超过当前分钟配额后拒绝', () => {
  const limiter = new MinuteRateLimiter({ maxEntries: 2 });
  assert.equal(limiter.isLimited('source', 2, 60_000), false);
  assert.equal(limiter.isLimited('source', 2, 60_001), false);
  assert.equal(limiter.isLimited('source', 2, 60_002), true);
});
