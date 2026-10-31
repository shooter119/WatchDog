const { test } = require('node:test');
const assert = require('node:assert/strict');
const { nameSuggestions } = require('../src/name-match');

test('陈建平 vs 陈建华 距离 1 命中', () => {
  const result = nameSuggestions('陈建平', ['张伟', '陈建华', '李娜']);
  assert.deepEqual(result, ['陈建华']);
});

test('长度差 >1 不命中', () => {
  const result = nameSuggestions('陈建华', ['陈', '陈建华甲乙', '张伟']);
  assert.deepEqual(result, []);
});

test('完全相同被排除（含首尾或中间空格差异）', () => {
  const result = nameSuggestions(' 陈建华 ', ['陈建华', '陈 建华', '  陈建华  ', '陈建平']);
  assert.deepEqual(result, ['陈建平']);
});

test('去重与上限 3 且保持原顺序', () => {
  const candidates = ['张玮', '张卫', '张玮', '张威', '张维', '张伟'];
  const result = nameSuggestions('张伟', candidates);
  assert.deepEqual(result, ['张玮', '张卫', '张威']);
});

test('英文大小写归一', () => {
  assert.deepEqual(
    nameSuggestions('alice', ['Alice', 'ALICE', 'Alica', 'Alic']),
    ['Alica', 'Alic'],
  );
  assert.deepEqual(
    nameSuggestions('ALICE', ['alice', 'alica']),
    ['alica'],
  );
});
