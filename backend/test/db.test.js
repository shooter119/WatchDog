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

test('消防员：新增/查重（场景内唯一，跨场景允许同名）/删除', () => {
  db.addFirefighter('f1', '张伟', 's1');
  db.addFirefighter('f2', '张伟', 's2');
  assert.equal(db.listFirefighters('s1').length, 1);
  assert.equal(db.listFirefighters('s2').length, 1);
  assert.throws(() => db.addFirefighter('f3', '张伟', 's1'), /UNIQUE/);
  db.removeFirefighter('f1');
  assert.equal(db.listFirefighters('s1').length, 0);
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

test('listScenes 跨表去重', () => {
  db.createEntry({ id: 's1', scene: 'x', name: 'n', pressureMpa: 20, entryAtMs: 1, exitAtMs: 2, durationMin: 1 });
  db.addFirefighter('sf1', 'name', 'y');
  db.addHotword('sh1', '词');
  const scenes = db.listScenes();
  assert.ok(scenes.includes('x'));
  assert.ok(scenes.includes('y'));
  // 热词全局共享、不再产生场景：'x' 仅由 entries 贡献，出现一次
  assert.equal(scenes.filter((s) => s === 'x').length, 1);
});
