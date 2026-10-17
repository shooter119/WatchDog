const { test } = require('node:test');
const assert = require('node:assert/strict');
const { forceQuantity, forceQuantityLabel } = require('../src/force-fields');

test('未知数量与真实零分别保存，旧客户端占位零写回保留未知', () => {
  assert.deepEqual(forceQuantity(0, undefined, 0, false), { value: 0, known: false });
  assert.deepEqual(forceQuantity(0, true, 0, false), { value: 0, known: true });
  assert.deepEqual(forceQuantity(7, undefined, 0, false), { value: 7, known: true });
  assert.deepEqual(forceQuantity(undefined, undefined, 0, false), { value: 0, known: false });
  assert.deepEqual(forceQuantity(undefined, undefined, 0, true), { value: 0, known: true });
  assert.deepEqual(forceQuantity(undefined, false), { value: 0, known: false });
});

test('非法数量和非布尔已知标志拒绝而非强制转换', () => {
  for (const value of [null, '', true, -1, 1000, 1.5, 'abc']) assert.throws(() => forceQuantity(value), { code: 'INVALID_FORCE' });
  assert.throws(() => forceQuantity(0, 'false'), { code: 'INVALID_FORCE' });
  assert.throws(() => forceQuantity(undefined, true, 0, false), { code: 'INVALID_FORCE' });
});

test('审计数量文字区分待补充与实际零', () => {
  assert.equal(forceQuantityLabel({ vehicle_count: 0, vehicle_count_known: false, personnel_count: 7 }), '车辆待补充 7人');
  assert.equal(forceQuantityLabel({ vehicle_count: 0, personnel_count: 0 }), '0车 0人');
});
