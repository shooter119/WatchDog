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

test('警情列表按状态和档案时间排序', () => {
  const first = db.createIncident({ id: 'incident-list-1', createdAt: 946684800000 });
  const second = db.createIncident({ id: 'incident-list-2', createdAt: 946684860000 });
  assert.ok(db.listIncidents('active').some((item) => item.id === first.id));
  assert.ok(db.listIncidents('active').some((item) => item.id === second.id));
  assert.ok(db.getIncident(first.id));
});

test('警情归档记录方式和未确认离场人数', () => {
  const now = Date.now();
  const incident = db.createIncident({ id: 'incident-archive', createdAt: now });
  db.createEntry({ id: 'archive-entry', scene: incident.id, name: '未离场', pressureMpa: 20, entryAtMs: now, exitAtMs: now + 60000, durationMin: 1 });
  const archived = db.archiveIncident(incident.id, { archivedBy: 'device-a', now: now + 1000 });
  assert.equal(archived.status, 'archived');
  assert.equal(archived.archived_by, 'device-a');
  assert.equal(archived.unresolved_active_count, 1);
  assert.equal(archived.auto_archived, 0);
});

test('警情事件按 client_op_id 幂等并按晚到早读取', () => {
  const incident = db.createIncident({ id: 'incident-events' });
  const first = db.appendIncidentEvent({ incidentId: incident.id, type: 'note', clientOpId: 'event-once', occurredAt: 2, payload: { text: '晚' } });
  const duplicate = db.appendIncidentEvent({ incidentId: incident.id, type: 'note', clientOpId: 'event-once', occurredAt: 1, payload: { text: '不应重复' } });
  assert.equal(duplicate.id, first.id);
  db.appendIncidentEvent({ incidentId: incident.id, type: 'entry', occurredAt: 3, payload: { name: '甲' } });
  const events = db.listIncidentEvents(incident.id);
  assert.equal(events.length, 2);
  assert.equal(events[0].payload.name, '甲');
});

test('旧版进退场随手记迁移时确定性去重', () => {
  const incident = db.createIncident({ id: 'incident-legacy-dedupe' });
  db.appendIncidentEvent({ incidentId: incident.id, type: 'entry', source: 'legacy', occurredAt: 1000, payload: { name: '甲' } });
  db.appendIncidentEvent({ incidentId: incident.id, type: 'note', source: 'legacy', occurredAt: 1005, payload: { text: '甲进场' } });
  db.appendIncidentEvent({ incidentId: incident.id, type: 'note', source: 'legacy', occurredAt: 50000, payload: { text: '甲进场' } });
  assert.equal(db.dedupeLegacyIncidentEvents(), 1);
  const events = db.listIncidentEvents(incident.id);
  assert.deepEqual(events.map((event) => event.payload.text || event.payload.name), ['甲进场', '甲']);
});

test('参战力量同站点只保留一条汇总记录', () => {
  const incident = db.createIncident({ id: 'incident-forces' });
  const first = db.upsertIncidentForce({ incidentId: incident.id, stationName: '龙翔路站', vehicleCount: 5, personnelCount: 25 });
  const second = db.upsertIncidentForce({ incidentId: incident.id, stationName: '龙翔路站', vehicleCount: 6, personnelCount: 30, expectedVersion: first.version });
  assert.equal(second.id, first.id);
  assert.equal(second.version, 2);
  assert.equal(db.listIncidentForces(incident.id).length, 1);
});
