const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { resolveOrgSeed, EXAMPLE_SEED_PATH } = require('../src/org-seed');

const secret = (...parts) => parts.join('');
const FORBIDDEN = [
  secret('龙游县', '消防救援大队'),
  secret('longyou-', 'county-fire-rescue'),
  secret('龙翔', '路站'),
  secret('永安', '路站'),
  secret('兴园', '站'),
  secret('龙游', '大队'),
  secret('李', '翔'),
  secret('陆河', '圣'),
  secret('盛承', '华'),
  secret('游方', '远'),
  secret('鸡鸣路', '146号'),
  secret('05', '70'),
];

function walk(dir, found = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['node_modules', '.git', 'build', '.dart_tool', 'data'].includes(entry.name)) continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, found);
    else if (/\.(js|dart|sql|json|md|html|example|yml)$/.test(entry.name)) found.push(full);
  }
  return found;
}

test('示例种子是假名，且测试环境默认加载它', () => {
  const seed = resolveOrgSeed({ NODE_ENV: 'test' });
  assert.equal(seed.id, 'example-county-fire-rescue');
  assert.equal(seed.name, '示例县消防救援大队');
  assert.equal(seed.verificationCode, '1001');
  assert.deepEqual(seed.firefighters.map((item) => item.name), ['张伟', '李娜', '赵磊', '陈建华']);
  assert.deepEqual(seed.stations, ['示例路站', '示范路站', '实训站']);
  assert.ok(seed.hotwords.includes('示例大队'));
  assert.ok(seed.hotwords.includes('内攻'));
  assert.equal(fs.existsSync(EXAMPLE_SEED_PATH), true);
});

test('显式单位环境变量不会混入示例名单', () => {
  const seed = resolveOrgSeed({
    NODE_ENV: 'test',
    WATCHDOG_SEED_UNIT_ID: 'custom-unit',
    WATCHDOG_SEED_UNIT_NAME: '自定义单位',
    WATCHDOG_SEED_UNIT_CODE: '4242',
  });
  assert.equal(seed.id, 'custom-unit');
  assert.equal(seed.name, '自定义单位');
  assert.deepEqual(seed.firefighters, []);
  assert.ok(seed.hotwords.includes('内攻'));
  assert.ok(!seed.hotwords.includes('示例大队'));
});

test('未配置的生产环境不创建示例组织', () => {
  assert.equal(resolveOrgSeed({ NODE_ENV: 'production' }), null);
  assert.equal(resolveOrgSeed({ NODE_ENV: 'test', WATCHDOG_SKIP_SEED: '1' }), null);
});

test('公开源码不再包含真实单位名单和验证码', () => {
  const root = path.join(__dirname, '..', '..');
  const hits = [];
  for (const file of walk(root)) {
    const text = fs.readFileSync(file, 'utf8');
    for (const word of FORBIDDEN) {
      if (text.includes(word)) hits.push(`${path.relative(root, file)}: ${word}`);
    }
  }
  assert.deepEqual(hits, []);
});
