const { test } = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const shape = require('../src/key-site-content');
const { validatePage, reviewSummary } = require('../src/key-site-extraction');
const entry = (kind, fields) => ({ kind, title: '合成验收记录', body: '', fields, sources: [] });

test('标准记录覆盖基本情况表各节，兼容五类通用资料且无隐式实值', () => {
  const data = shape.emptyContent();
  for (const [kind, spec] of Object.entries(shape.SCHEMA.kinds)) {
    data[spec.module].push(entry(kind, Object.fromEntries(spec.fields.map(key => [key, '/']))));
    for (const key of spec.fields) assert.ok(shape.SCHEMA.fieldLabels[key]);
  }
  const normalized = shape.content(data);
  assert.equal(Object.values(normalized).flat().length, 9);
  assert.equal(normalized.hazards[1].fields.designVolume, '/');
  assert.equal(normalized.hazards[1].fields.quantity, '/');
  const legacy = shape.emptyContent(); legacy.cards.push({ title: '历史卡片', fields: { water: '原水源说明' } });
  const old = shape.content(legacy).cards[0]; assert.equal(old.kind, undefined); assert.equal(old.fields.water, '原水源说明');
});

test('储罐、库存不互串字段，非法类型及跨模块类型被拒绝', () => {
  for (const [module, kind, fields] of [['cards','storageTank',{}], ['hazards','unknown',{}], ['hazards','__proto__',{}], ['hazards','storageTank',{packageCapacity:'2L'}], ['cards','siteOverview',[]]]) {
    const data = shape.emptyContent(); data[module] = [entry(kind, fields)];
    assert.throws(() => shape.content(data), { code: 'KEY_SITE_INVALID' });
  }
});

test('原文约数、混合长度单位、负设计压力及容积均按字符串保留，不推断实际储量', () => {
  const data = shape.emptyContent();
  data.hazards.push(entry('storageTank', { diameterAndHeight:'直径2m 高度3500mm', designPressure:'-0.0005/0.008', designVolume:'42', quantity:'' }));
  data.cards.push(entry('siteOverview', { dayStaff:'约30人', nightStaff:'/', buildingArea:'1200㎡' }));
  const value = shape.content(data);
  assert.equal(value.hazards[0].fields.designVolume, '42'); assert.equal(value.hazards[0].fields.quantity, '');
  assert.equal(value.hazards[0].fields.diameterAndHeight, '直径2m 高度3500mm');
  assert.equal(value.cards[0].fields.dayStaff, '约30人'); assert.equal(value.cards[0].fields.nightStaff, '/');
});

function extracted(page, volume = '42') {
  return validatePage({ rawText:`合成介质 V-TEST 立式固定顶 ${volume} -0.0005/0.008`, classification:['hazards'], entries:[{
    module:'hazards', kind:'storageTank', title:'合成介质', fields:{tankNumber:'V-TEST',tankForm:'立式固定顶',designVolume:volume,designPressure:'-0.0005/0.008',quantity:'999吨'},
    evidence:{title:'合成介质', fields:{tankNumber:'V-TEST',tankForm:'立式固定顶',designVolume:volume,designPressure:'-0.0005/0.008',quantity:'999吨'}},
  }] }, {attachmentId:'synthetic-source',page});
}
test('AI标准记录字段仍逐项核实来源，原文未载实际储量留空', () => {
  const page = extracted(1), item = page.entries[0];
  assert.equal(item.entry.kind, 'storageTank'); assert.equal(item.entry.fields.designVolume, '42'); assert.equal(item.entry.fields.quantity, '');
  assert.equal(item.entry.sources[0].page, 1); assert.ok(item.toConfirm.some(text => text.includes('实际储量')));
  assert.throws(() => validatePage({ rawText:'合成',classification:['cards'],entries:[{module:'cards',kind:'storageTank',title:'合成',evidence:{title:'合成'}}] }, {attachmentId:'s',page:1}), {code:'KEY_SITE_AI_RESULT_INVALID'});
});
test('AI跨页储罐容积差异可核对且不与通用记录混为一条', () => {
  const summary=reviewSummary([{status:'succeeded',extraction:extracted(1)}, {status:'succeeded',extraction:extracted(2,'43')}]);
  assert.ok(summary.conflicts.some(c => c.field==='designVolume' && c.values.join(',')==='42,43'));
});
test('App标准字段标签由同一份定义生成，防止中英文字段漂移', () => {
  execFileSync(process.execPath, [path.join(__dirname,'../../scripts/generate-key-site-schema.mjs'),'--check']);
});
test('同名不同编号储罐分别核对，不产生伪容积冲突', () => {
  const one = extracted(1), two = extracted(2,'43');
  two.entries[0].entry.fields.tankNumber='OTHER-TEST';
  const result=reviewSummary([{status:'succeeded',extraction:one},{status:'succeeded',extraction:two}]);
  assert.equal(result.entries.length,2); assert.equal(result.conflicts.length,0);
});
