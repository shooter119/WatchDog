const { test } = require('node:test');
const assert = require('node:assert/strict');
const { nameSuggestions } = require('../src/name-match');

test('祝徐谦 vs 祝徐迁 距离 1 命中', () => {
  const result = nameSuggestions('祝徐谦', ['李翔', '祝徐迁', '方文斌']);
  assert.deepEqual(result, ['祝徐迁']);
});

test('长度差 >1 不命中', () => {
  const result = nameSuggestions('祝徐迁', ['祝', '祝徐迁甲乙', '李翔']);
  assert.deepEqual(result, []);
});

test('完全相同被排除（含首尾或中间空格差异）', () => {
  const result = nameSuggestions(' 祝徐迁 ', ['祝徐迁', '祝 徐迁', '  祝徐迁  ', '祝徐谦']);
  assert.deepEqual(result, ['祝徐谦']);
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
