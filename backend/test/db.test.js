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

test('分页参数对负数和小数设置安全下限与上限', () => {
  db.createEntry({ id: 'limit-entry-1', scene: 'limit', name: '甲', pressureMpa: 20, entryAtMs: 1, exitAtMs: 2, durationMin: 1 });
  db.createEntry({ id: 'limit-entry-2', scene: 'limit', name: '乙', pressureMpa: 20, entryAtMs: 2, exitAtMs: 3, durationMin: 1 });
  assert.equal(db.listEntries({ scene: 'limit', limit: -1 }).length, 2);
  assert.equal(db.listEntries({ scene: 'limit', limit: 1.9 }).length, 1);
});

test('markExited 后 activeOnly 不再返回', () => {
  db.createEntry({ id: 'm1', scene: 's', name: '丙', pressureMpa: 20, entryAtMs: 1, exitAtMs: 2, durationMin: 1 });
  assert.equal(db.listEntries({ activeOnly: true, scene: 's' }).length, 1);
  db.markExited('m1', Date.now());
  assert.equal(db.listEntries({ activeOnly: true, scene: 's' }).length, 0);
  assert.ok(db.listEntries({ scene: 's' })[0].exited_at);
});

test('并发出场只允许第一次改变状态', () => {
  const now = Date.now();
  db.createEntry({ id: 'exit-once', scene: 'exit-scene', name: '只出场一次', pressureMpa: 20, entryAtMs: now, exitAtMs: now + 60000, durationMin: 1 });
  const first = db.markExitedIfActive('exit-once', now + 1000);
  const second = db.markExitedIfActive('exit-once', now + 2000);
  assert.equal(first.changed, true);
  assert.equal(second.changed, false);
  assert.equal(second.entry.exited_at, now + 1000);
});

test('进场与事件写入失败时整体回滚', () => {
  const now = Date.now();
  const incident = db.createIncident({ id: 'atomic-entry-incident', createdAt: now });
  db.appendIncidentEvent({ id: 'atomic-event-conflict', incidentId: incident.id, type: 'note' });
  assert.throws(() => db.createEntryWithEvent({
    entry: { id: 'atomic-entry', scene: incident.id, name: '回滚测试', pressureMpa: 20, durationMin: 10, entryAtMs: now, exitAtMs: now + 600000 },
    event: { id: 'atomic-event-conflict', incidentId: incident.id, type: 'entry', payload: { entry_id: 'atomic-entry' } },
    activityAt: now,
  }));
  assert.equal(db.getEntry('atomic-entry'), undefined);
  assert.equal(db.listPressureSamples('atomic-entry').length, 0);
});

test('消防员：单位词库中的内置名单/新增/查重/删除', () => {
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

test('热词：单位词库中的内置词/新增/查重/删除', () => {
  const words = db.listHotwords().map((h) => h.word);
  assert.ok(words.includes('龙游大队'));
  assert.ok(words.includes('内攻'));
  assert.ok(!words.includes('到场'));
  const before = words.length;
  db.addHotword('h1', '进入火场');
  assert.throws(() => db.addHotword('h2', '进入火场'), /UNIQUE/);
  // 无参数调用保留本地仓储兼容行为；HTTP 接口始终传入单位。
  assert.equal(db.listHotwords().length, before + 1);
  db.removeHotword('h1');
  assert.equal(db.listHotwords().length, before);
});

test('单位词库隔离：相同词条可存在于不同单位，不能跨单位删除', () => {
  const unitA = 'roster-unit-a';
  const unitB = 'roster-unit-b';
  db.addFirefighter('roster-fa', '共同姓名', unitA, { createdByMemberId: 'member-a' });
  db.addFirefighter('roster-fb', '共同姓名', unitB, { createdByMemberId: 'member-b' });
  db.addHotword('roster-ha', '共同术语', unitA, { createdByMemberId: 'member-a' });
  db.addHotword('roster-hb', '共同术语', unitB, { createdByMemberId: 'member-b' });

  assert.deepEqual(db.listFirefighters(unitA).map((item) => item.name), ['共同姓名']);
  assert.deepEqual(db.listFirefighters(unitB).map((item) => item.name), ['共同姓名']);
  assert.deepEqual(db.listHotwords(unitA).map((item) => item.word), ['共同术语']);
  assert.deepEqual(db.listHotwords(unitB).map((item) => item.word), ['共同术语']);
  assert.equal(db.removeHotword('roster-hb', unitA, { memberId: 'member-a' }), 0);
  assert.equal(db.removeHotword('roster-hb', unitB, { memberId: 'member-b' }), 1);
  assert.equal(db.removeFirefighter('roster-fb', unitA, { memberId: 'member-a' }), 0);
  assert.equal(db.removeFirefighter('roster-fb', unitB, { memberId: 'member-b' }), 1);
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

test('警情列表分页保持单位过滤和稳定切片', () => {
  const unitId = 'incident-page-unit';
  for (let i = 0; i < 3; i++) {
    db.createIncident({
      id: `incident-page-${i}`,
      unitId,
      createdAt: 2000000 + i,
    });
  }
  db.createIncident({ id: 'incident-page-other-unit', unitId: 'other-unit', createdAt: 2000001 });
  const first = db.listIncidents('active', { unitId, limit: 2, offset: 0 });
  const second = db.listIncidents('active', { unitId, limit: 2, offset: 2 });
  assert.equal(first.length, 2);
  assert.equal(second.length, 1);
  assert.equal(new Set([...first, ...second].map((item) => item.id)).size, 3);
  assert.ok([...first, ...second].every((item) => item.unit_id === unitId));
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

  const repeated = db.archiveIncident(incident.id, { archivedBy: 'device-b', now: now + 2000, returnMeta: true });
  assert.equal(repeated.changed, false);
  assert.equal(repeated.incident.status, 'archived');
  assert.equal(repeated.incident.version, archived.version);
  assert.equal(repeated.incident.archived_at, archived.archived_at);
  assert.equal(repeated.incident.archived_by, archived.archived_by);
});

test('按单位清理陈旧警情时不会改变其他单位的状态', () => {
  const now = Date.now();
  const own = db.createIncident({ id: 'incident-stale-own', unitId: 'unit-own', createdAt: now - 13 * 3600 * 1000 });
  const other = db.createIncident({ id: 'incident-stale-other', unitId: 'unit-other', createdAt: now - 13 * 3600 * 1000 });
  assert.equal(db.archiveStaleIncidents({ now, unitId: 'unit-own' }), 1);
  assert.equal(db.getIncident(own.id).status, 'archived');
  assert.equal(db.getIncident(other.id).status, 'active');
  assert.equal(db.archiveStaleIncidents({ now, unitId: 'unit-own' }), 0);
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
  assert.equal(db.listIncidentForcesBatch([incident.id, 'missing']).length, 1);
});

test('管理写入与时间线事件在 SQLite 事务中成组提交', () => {
  const now = Date.now();
  const incident = db.createIncident({ id: 'atomic-management-incident', createdAt: now });
  const renamed = db.updateIncidentTitleWithEvent({
    id: incident.id,
    title: '事务警情',
    expectedVersion: incident.version,
    event: { incidentId: incident.id, type: 'incident_renamed', payload: { before: null, after: '事务警情' } },
  });
  assert.equal(renamed.incident.title, '事务警情');
  assert.equal(renamed.event.type, 'incident_renamed');

  const force = db.upsertIncidentForceWithEvent({
    force: { id: 'atomic-force', incidentId: incident.id, stationName: '事务站', vehicleCount: 1, personnelCount: 4 },
    event: { incidentId: incident.id, type: 'force_added', payload: { force_id: 'atomic-force' } },
    activityAt: now + 1,
  });
  assert.equal(force.force.id, 'atomic-force');
  assert.equal(force.event.type, 'force_added');

  const note = db.createNote({ id: 'atomic-note', scene: incident.id, text: '原始记录' });
  const revised = db.updateNoteWithEvent({
    id: note.id,
    text: '修订记录',
    category: '其他',
    incidentId: incident.id,
    event: { incidentId: incident.id, type: 'note_updated', payload: { note_id: note.id } },
    activityAt: now + 2,
  });
  assert.equal(revised.note.text, '修订记录');
  assert.equal(revised.event.type, 'note_updated');
  const removed = db.deleteNoteWithEvent({
    id: note.id,
    incidentId: incident.id,
    event: { incidentId: incident.id, type: 'note_voided', payload: { note_id: note.id } },
    activityAt: now + 3,
  });
  assert.equal(removed.changed, true);
  assert.equal(db.getNote(note.id), undefined);

  const deletedForce = db.deleteIncidentForceWithEvent({
    id: force.force.id,
    incidentId: incident.id,
    event: { incidentId: incident.id, type: 'force_removed', payload: { force_id: force.force.id } },
    activityAt: now + 4,
  });
  assert.equal(deletedForce.changed, true);
  const archived = db.archiveIncidentWithEvent({
    id: incident.id,
    archivedBy: '事务测试',
    now: now + 5,
    event: { incidentId: incident.id, type: 'incident_archived', payload: { auto: false } },
  });
  assert.equal(archived.changed, true);
  assert.equal(archived.event.payload.unresolved_active_count, 0);
});

test('操作日志批量写入在同一事务中完成', () => {
  const createdAt = Date.now();
  const count = db.addLogs([
    { scene: 'bulk-log', device: 'device-a', opId: 'bulk-1', stage: 'one', msg: '一', createdAt },
    { scene: 'bulk-log', device: 'device-a', opId: 'bulk-2', stage: 'two', msg: '二', createdAt: createdAt + 1 },
  ]);
  assert.equal(count, 2);
  assert.deepEqual(db.listLogs({ scene: 'bulk-log' }).map((log) => log.stage), ['two', 'one']);
});

test('操作账本按单位和操作号幂等，并拒绝摘要不一致的完成', () => {
  const first = db.beginOperation({
    unitId: 'unit-ledger-a', clientOpId: 'ledger-1', incidentId: 'incident-ledger',
    operationType: 'entry', requestHash: 'hash-a', actorName: '甲',
  });
  assert.equal(first.status, 'pending');
  assert.equal(first.created, true);
  const duplicate = db.beginOperation({
    unitId: 'unit-ledger-a', clientOpId: 'ledger-1', incidentId: 'incident-ledger',
    operationType: 'entry', requestHash: 'hash-b', actorName: '乙',
  });
  assert.equal(duplicate.request_hash, 'hash-a');
  assert.equal(db.completeOperation({ unitId: 'unit-ledger-a', clientOpId: 'ledger-1', requestHash: 'hash-b', result: { id: 'wrong' } }), 0);
  assert.equal(db.completeOperation({ unitId: 'unit-ledger-a', clientOpId: 'ledger-1', requestHash: 'hash-a', result: { id: 'entry-1' }, responseStatus: 201, eventId: 'event-1' }), 1);
  const completed = db.getOperation('unit-ledger-a', 'ledger-1');
  assert.equal(completed.status, 'succeeded');
  assert.equal(JSON.parse(completed.result_json).id, 'entry-1');
  assert.equal(completed.response_status, 201);

  // 不同单位可以使用各自的本地操作号，不能互相读取或覆盖账本。
  const otherUnit = db.beginOperation({
    unitId: 'unit-ledger-b', clientOpId: 'ledger-1', incidentId: 'incident-ledger-b',
    operationType: 'entry', requestHash: 'hash-b',
  });
  assert.equal(otherUnit.unit_id, 'unit-ledger-b');
  assert.equal(db.getOperation('unit-ledger-a', 'ledger-1').unit_id, 'unit-ledger-a');
  assert.equal(db.releaseOperation({ unitId: 'unit-ledger-b', clientOpId: 'ledger-1', requestHash: 'hash-b' }), 1);
});

test('操作账本租约到期后允许同摘要接管，未到期仍保持处理中', () => {
  const first = db.beginOperation({ unitId: 'unit-lease', clientOpId: 'lease-1', operationType: 'entry', requestHash: 'lease-hash', now: 1000 });
  assert.equal(first.created, true);
  const pending = db.beginOperation({ unitId: 'unit-lease', clientOpId: 'lease-1', operationType: 'entry', requestHash: 'lease-hash', now: 2000 });
  assert.equal(pending.created, false);
  const reclaimed = db.beginOperation({ unitId: 'unit-lease', clientOpId: 'lease-1', operationType: 'entry', requestHash: 'lease-hash', now: 31_001 });
  assert.equal(reclaimed.created, true);
  assert.equal(reclaimed.reclaimed, true);
});
