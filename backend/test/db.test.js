const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

// 每个测试文件独立临时数据目录（node:sqlite 在 db.js 加载时初始化）
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-db-'));
process.env.WATCHDOG_DATA_DIR = tmpDir;

const db = require('../src/db');

test('createEntry 保存完整字段并可读回', () => {
  const now = Date.now();
  const e = db.createEntry({
    id: 'e1',
    scene: 'sceneA',
    name: '张伟',
    pressureMpa: 20,
    durationMin: 34,
    entryAtMs: now,
    exitAtMs: now + 34 * 60000,
    source: 'voice',
    rawText: '张伟，20兆帕',
  });
  assert.equal(e.name, '张伟');
  assert.equal(e.pressure_mpa, 20);
  assert.equal(e.duration_min, 34);
  assert.equal(e.source, 'voice');
  assert.equal(e.exited_at, null);
});

test('场景隔离：不同场景互不可见', () => {
  db.createEntry({ id: 'a1', scene: 'A', name: '甲', pressureMpa: 20, entryAtMs: 1, exitAtMs: 2, durationMin: 1 });
  db.createEntry({ id: 'b1', scene: 'B', name: '乙', pressureMpa: 20, entryAtMs: 1, exitAtMs: 2, durationMin: 1 });
  assert.equal(db.listEntries({ scene: 'A' }).length, 1);
  assert.equal(db.listEntries({ scene: 'B' })[0].name, '乙');
});

test('markExited 后 activeOnly 不再返回', () => {
  db.createEntry({ id: 'm1', scene: 's', name: '丙', pressureMpa: 20, entryAtMs: 1, exitAtMs: 2, durationMin: 1 });
  assert.equal(db.listEntries({ activeOnly: true, scene: 's' }).length, 1);
  db.markExited('m1', Date.now());
  assert.equal(db.listEntries({ activeOnly: true, scene: 's' }).length, 0);
  assert.ok(db.listEntries({ scene: 's' })[0].exited_at);
});

test('消防员：装机自带名单/新增/查重/删除（全局不区分场景）', () => {
  const names = db.listFirefighters().map((f) => f.name);
  assert.ok(names.includes('李翔'));
  assert.ok(names.includes('游方远'));
  assert.ok(!names.includes('徐琴琴'));
  const before = names.length;
  db.addFirefighter('f1', '测试员甲');
  assert.throws(() => db.addFirefighter('f2', '测试员甲'), /UNIQUE/);
  assert.equal(db.listFirefighters().length, before + 1);
  db.removeFirefighter('f1');
  assert.equal(db.listFirefighters().length, before);
});

test('热词：装机自带种子/新增/查重/删除（全局不区分场景）', () => {
  const words = db.listHotwords().map((h) => h.word);
  assert.ok(words.includes('龙游大队'));
  assert.ok(words.includes('内攻'));
  assert.ok(!words.includes('到场'));
  const before = words.length;
  db.addHotword('h1', '进入火场');
  assert.throws(() => db.addHotword('h2', '进入火场'), /UNIQUE/);
  // 全局共享：任意场景读到同一列表
  assert.equal(db.listHotwords().length, before + 1);
  db.removeHotword('h1');
  assert.equal(db.listHotwords().length, before);
});

test('purgeOldExited 只清理超过期限的出场记录', () => {
  const old = Date.now() - 10 * 24 * 3600 * 1000;
  db.createEntry({ id: 'p1', scene: 's', name: '旧', pressureMpa: 20, entryAtMs: old, exitAtMs: old + 1000, durationMin: 1 });
  db.createEntry({ id: 'p2', scene: 's', name: '新', pressureMpa: 20, entryAtMs: 1, exitAtMs: 2, durationMin: 1 });
  db.markExited('p1', old);
  db.markExited('p2', Date.now());
  const n = db.purgeOldExited(7);
  assert.equal(n, 1);
  assert.equal(db.getEntry('p1'), undefined);
  assert.ok(db.getEntry('p2'));
  // 未出场记录不受影响
  db.createEntry({ id: 'p3', scene: 's', name: '在场', pressureMpa: 20, entryAtMs: old, exitAtMs: old + 1000, durationMin: 1 });
  db.purgeOldExited(7);
  assert.ok(db.getEntry('p3'));
});

test('压力报数采样：进场自动写首条采样，可追加/取最近/取历史', () => {
  const now = Date.now();
  const e = db.createEntry({ id: 'samp1', scene: 's', name: '采样员', pressureMpa: 20, entryAtMs: now, exitAtMs: now + 60000, durationMin: 1 });
  let samples = db.listPressureSamples('samp1');
  assert.equal(samples.length, 1);
  assert.equal(samples[0].pressure_mpa, 20);
  db.addPressureSample({ entryId: 'samp1', scene: 's', name: '采样员', pressureMpa: 15, reportedAtMs: now + 5 * 60000 });
  db.addPressureSample({ entryId: 'samp1', scene: 's', name: '采样员', pressureMpa: 10, reportedAtMs: now + 10 * 60000 });
  samples = db.listPressureSamples('samp1');
  assert.equal(samples.length, 3);
  assert.equal(samples[0].pressure_mpa, 10);
  const last = db.lastPressureSample('samp1');
  assert.equal(last.pressure_mpa, 10);
  assert.equal(db.lastPressureSample('nope'), undefined);
});

test('purgeOldExited 连带清理已删记录的压力采样', () => {
  const old = Date.now() - 10 * 24 * 3600 * 1000;
  db.createEntry({ id: 'samp2', scene: 's', name: '旧采样', pressureMpa: 20, entryAtMs: old, exitAtMs: old + 1000, durationMin: 1 });
  db.addPressureSample({ entryId: 'samp2', scene: 's', name: '旧采样', pressureMpa: 15, reportedAtMs: old + 1000 });
  db.markExited('samp2', old);
  db.purgeOldExited(7);
  assert.equal(db.getEntry('samp2'), undefined);
  assert.equal(db.lastPressureSample('samp2'), undefined);
  assert.equal(db.listPressureSamples('samp2').length, 0);
});

test('updateEntry 支持写入实测耗气率', () => {
  const now = Date.now();
  db.createEntry({ id: 'samp3', scene: 's', name: '耗气', pressureMpa: 20, entryAtMs: now, exitAtMs: now + 60000, durationMin: 34 });
  const u = db.updateEntry('samp3', { consumptionActualLpm: 68 });
  assert.equal(u.consumption_actual_lpm, 68);
});

test('listScenes 仅由 entries 产生（名单/热词全局共享不产生场景）', () => {
  db.createEntry({ id: 's1', scene: 'x', name: 'n', pressureMpa: 20, entryAtMs: 1, exitAtMs: 2, durationMin: 1 });
  db.addFirefighter('sf1', '全局姓名');
  db.addHotword('sh1', '全局词');
  const scenes = db.listScenes();
  assert.ok(scenes.includes('x'));
  assert.ok(!scenes.includes('y'));
});

test('markSceneEnded：分配可读新码、幂等、不与既有场景冲突', () => {
  const s1 = db.markSceneEnded('sceneEnd', 'dev-abc');
  assert.match(s1.new_scene, /^[一-鿿]{2}$/);
  assert.ok(s1.ended_at > 0);
  assert.equal(s1.ended_by, 'dev-abc');
  // 幂等：已结束场景返回既有记录（新码不变）
  const s2 = db.markSceneEnded('sceneEnd', 'dev-other');
  assert.equal(s2.new_scene, s1.new_scene);
  assert.equal(s2.ended_by, 'dev-abc');
  // 新码不与既有场景码冲突
  const scenes = db.listScenes();
  assert.ok(!scenes.includes(s1.new_scene));
  // getSceneStates 返回含该场景
  const states = db.getSceneStates();
  assert.ok(states.some((s) => s.scene === 'sceneEnd'));
  assert.ok(states.some((s) => s.new_scene === s1.new_scene));
});

test('purgeOldSceneStates 清理结束标记', () => {
  db.markSceneEnded('scenePurge', 'dev-x');
  assert.ok(db.getSceneStates().some((s) => s.scene === 'scenePurge'));
  db.purgeOldSceneStates(-1);
  assert.ok(!db.getSceneStates().some((s) => s.scene === 'scenePurge'));
});

test('中文任务码：近 7 天内新码计入占用，词表耗尽抛错，清理后恢复', () => {
  // 连续分配若干场景：新码均为两字中文且互不重复
  const codes = new Set();
  for (let i = 0; i < 10; i++) {
    const s = db.markSceneEnded(`fruit-${i}`, 'dev-x');
    assert.match(s.new_scene, /^[\u4e00-\u9fff]{2}$/);
    codes.add(s.new_scene);
  }
  assert.equal(codes.size, 10, '10 个场景应分配到互不重复的中文任务码');
  // 新码不与既有场景码冲突
  const scenes = db.listScenes();
  for (const c of codes) {
    assert.ok(!scenes.includes(c));
  }
  // 词表耗尽：持续分配直到抛错（防死循环，词表规模应在合理区间）
  let n = 0;
  try {
    for (n = 0; n < 100; n++) db.markSceneEnded(`fruit-full-${n}`, 'dev-x');
  } catch (e) {
    assert.match(String(e.message), /词表已全部占用/);
  }
  assert.ok(n >= 10 && n < 100, `词表应 10~99 个（实际耗尽于 ${n} 个）`);
  // 清理结束标记（模拟 7 天复用窗口过后）→ 恢复可分配
  db.purgeOldSceneStates(-1);
  const s = db.markSceneEnded('fruit-reuse', 'dev-x');
  assert.match(s.new_scene, /^[\u4e00-\u9fff]{2}$/);
});
