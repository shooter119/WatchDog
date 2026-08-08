const { test } = require('node:test');
const assert = require('node:assert/strict');
const { durationMinutes, exitAtMs, measuredConsumptionLpm } = require('../src/calc');

test('标准换算：6.8L × 20MPa × 10 ÷ 40L/min = 34 分钟', () => {
  assert.equal(durationMinutes({ cylinderVolL: 6.8, pressureMpa: 20, consumptionLpm: 40 }), 34);
});

test('满压 30MPa 时 = 51 分钟', () => {
  assert.equal(durationMinutes({ cylinderVolL: 6.8, pressureMpa: 30, consumptionLpm: 40 }), 51);
});

test('默认参数可省略：默认消耗率 80L/min → 6.8 × 20 × 10 ÷ 80 = 17 分钟', () => {
  assert.equal(durationMinutes({ pressureMpa: 20 }), 17);
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

test('实测耗气率：5 分钟掉 5MPa → 68 L/min', () => {
  const t = Date.now();
  assert.equal(
    measuredConsumptionLpm({ cylinderVolL: 6.8, prevPressureMpa: 20, newPressureMpa: 15, intervalMs: 5 * 60000 }),
    68
  );
});

test('实测耗气率：10 分钟掉 2MPa（低强度）→ 13.6 L/min', () => {
  assert.equal(
    measuredConsumptionLpm({ cylinderVolL: 6.8, prevPressureMpa: 18, newPressureMpa: 16, intervalMs: 10 * 60000 }),
    13.6
  );
});

test('实测耗气率：压力未下降（换瓶/读数回升）→ null', () => {
  assert.equal(
    measuredConsumptionLpm({ cylinderVolL: 6.8, prevPressureMpa: 15, newPressureMpa: 20, intervalMs: 5 * 60000 }),
    null
  );
  assert.equal(
    measuredConsumptionLpm({ cylinderVolL: 6.8, prevPressureMpa: 15, newPressureMpa: 15, intervalMs: 5 * 60000 }),
    null
  );
});

test('实测耗气率：时间无效或压力缺失 → null', () => {
  assert.equal(measuredConsumptionLpm({ prevPressureMpa: 20, newPressureMpa: 15, intervalMs: 0 }), null);
  assert.equal(measuredConsumptionLpm({ newPressureMpa: 15, intervalMs: 5 * 60000 }), null);
});

test('实测耗气率：超出合理范围（间隔过短/过长）→ null', () => {
  // 1 分钟掉 25MPa → 1700 L/min，物理不可能，拒绝
  assert.equal(
    measuredConsumptionLpm({ cylinderVolL: 6.8, prevPressureMpa: 30, newPressureMpa: 5, intervalMs: 60000 }),
    null
  );
});
