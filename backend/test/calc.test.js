const { test } = require('node:test');
const assert = require('node:assert/strict');
const { durationMinutes, exitAtMs } = require('../src/calc');

test('标准换算：6.8L × 20MPa × 10 ÷ 40L/min = 34 分钟', () => {
  assert.equal(durationMinutes({ cylinderVolL: 6.8, pressureMpa: 20, consumptionLpm: 40 }), 34);
});

test('满压 30MPa 时 = 51 分钟', () => {
  assert.equal(durationMinutes({ cylinderVolL: 6.8, pressureMpa: 30, consumptionLpm: 40 }), 51);
});

test('默认参数可省略', () => {
  assert.equal(durationMinutes({ pressureMpa: 20 }), 34);
});

test('压力缺失/为 0/负数 → 0', () => {
  assert.equal(durationMinutes({ pressureMpa: undefined }), 0);
  assert.equal(durationMinutes({ pressureMpa: 0 }), 0);
  assert.equal(durationMinutes({ pressureMpa: -5 }), 0);
});

test('exitAtMs = entryAt + 可用分钟数', () => {
  const entryAtMs = Date.now();
  const exit = exitAtMs({ entryAtMs, cylinderVolL: 6.8, pressureMpa: 20, consumptionLpm: 40 });
  assert.equal(exit - entryAtMs, 34 * 60 * 1000);
});
