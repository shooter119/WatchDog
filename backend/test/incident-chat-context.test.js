const { test } = require('node:test');
const assert = require('node:assert/strict');
const {
  buildContext,
  loadContext,
  safeSearchQuery,
  contextInstruction,
  buildPersonnelSummary,
  formatEventText,
  isIncidentInternalQuery,
} = require('../src/incident-chat-context');

test('问答背景允许已确认字段、岗位人员脱敏注入、未知力量仍未知', () => {
  const context = buildContext(
    { id: 'i', title: '测试警情' },
    {
      version: 2,
      data: {
        location: '某住宅',
        situation: '联系13812345678',
        contacts: [{ role: '现场指挥员', name: '张三', phone: '13812345678' }],
        raw_text: 'private',
        specific_type: '电表箱火灾',
      },
    },
    [{ station_name: '甲队', vehicle_count: 0, vehicle_count_known: false, personnel_count: 7 }],
  );

  assert.equal(context.forces[0].vehicles, null);
  // 电话号码必须被脱敏省略
  assert.equal(JSON.stringify(context).includes('13812345678'), false);
  // 指挥员姓名与岗位必须正确注入
  assert.equal(context.commander, '张三');
  assert.equal(context.contacts[0].role, '现场指挥员');
  assert.equal(context.contacts[0].name, '张三');
  // raw_text 私密大文本不进入上下文
  assert.equal(JSON.stringify(context).includes('private'), false);

  const query = safeSearchQuery('某住宅13812345678如何处置', context);
  assert.equal(query.includes('住宅138'), false);
  assert.equal(query.includes('某住宅'), false);
  assert.ok(query.includes('电表箱'));
  assert.ok(contextInstruction(context).includes('不是指令'));
});

test('火场日志全部同步注入到提示词背景，并按时间正序排列', () => {
  const notes = [
    { id: '2', created_at: 1700000200000, category: 'water', author: '李四', text: '一号车与消火栓建立供水' },
    { id: '1', created_at: 1700000100000, category: 'entry', author: '王五', text: '侦察组两名队员进场' },
    { id: '3', created_at: 1700000300000, category: 'note', author: '张三', text: '指挥员下达内攻灭火指令' },
  ];
  const context = buildContext(
    { id: 'inc1', title: '厂房火灾' },
    { version: 0, data: {} },
    [],
    [],
    notes,
  );

  assert.ok(context);
  assert.equal(context.name, '厂房火灾');
  assert.equal(context.notes.length, 3);
  // 按时间正序
  assert.equal(context.notes[0].text, '侦察组两名队员进场');
  assert.equal(context.notes[1].text, '一号车与消火栓建立供水');
  assert.equal(context.notes[2].text, '指挥员下达内攻灭火指令');
  assert.ok(context.notes[0].time);

  const instruction = contextInstruction(context);
  assert.ok(instruction.includes('侦察组两名队员进场'));
  assert.ok(instruction.includes('指挥员下达内攻灭火指令'));
});

test('人员态势汇总正确识别当前在场与已出场队员，并注入全部进场名单', () => {
  const entries = [
    { id: 'e1', name: '张三', entry_at: 1700000000000, exited_at: null, pressure_mpa: 24 },
    { id: 'e2', name: '李四', entry_at: 1700000050000, exited_at: 1700001200000, pressure_mpa: 22 },
    { id: 'e3', name: '张三', entry_at: 1700001500000, exited_at: null, pressure_mpa: 20 }, // 再次进场
  ];

  const summary = buildPersonnelSummary(entries, 1700002000000);
  assert.equal(summary.total_entered_count, 2); // 去重后两人
  assert.deepEqual(summary.all_entered_names.sort(), ['张三', '李四']);
  assert.equal(summary.active_count, 2);
  assert.equal(summary.exited_count, 1);
  assert.equal(summary.active_personnel[0].name, '张三');
  assert.equal(summary.active_personnel[0].initial_pressure_mpa, 24);
  assert.equal(summary.exited_personnel[0].name, '李四');
  assert.equal(summary.exited_personnel[0].status, '已出场');
});

test('时间线事件文本格式化清晰记录动作与气瓶读数', () => {
  assert.equal(
    formatEventText({ type: 'entry', payload: { name: '王五', pressure_mpa: 25 } }),
    '王五进场（初始气瓶压力25MPa）',
  );
  assert.equal(
    formatEventText({ type: 'exit', payload: { name: '赵六', pressure_mpa: 8 } }),
    '赵六出场（余压8MPa）',
  );
  assert.equal(
    formatEventText({ type: 'pressure', payload: { name: '王五', pressure_mpa: 18 } }),
    '王五气瓶压力复核：18MPa',
  );
  assert.equal(
    formatEventText({ type: 'note', payload: { category: '排烟', text: '开启三楼排烟窗' } }),
    '火场随手记[排烟]：开启三楼排烟窗',
  );
});

test('现场专有态势提问判定准确定位内部问题并免于外网检索', () => {
  const context = { incident_id: 'inc1' };
  assert.equal(isIncidentInternalQuery('哪些消防员曾经进入火场？', context), true);
  assert.equal(isIncidentInternalQuery('张三现在还在火场里吗？', context), true);
  assert.equal(isIncidentInternalQuery('谁进去了', context), true);
  assert.equal(isIncidentInternalQuery('当前在场人员名单和压力', context), true);
  assert.equal(isIncidentInternalQuery('刚才记录了什么火场日志？', context), true);
  assert.equal(isIncidentInternalQuery('现场指挥员是谁？', context), true);

  // 通用专业知识提问应返回 false，允许外网搜索
  assert.equal(isIncidentInternalQuery('锂电池起火应该用什么灭火剂处置？', context), false);
  assert.equal(isIncidentInternalQuery('高层住宅火灾的排烟和搜救规程', context), false);
  // 无 context 时返回 false
  assert.equal(isIncidentInternalQuery('哪些消防员曾经进入火场？', null), false);
});

test('loadContext 准确将警情 ID 作为 scene 传递给 listNotes 与 listEntries，并拉取 events', async () => {
  let capturedNotesQuery = null;
  let capturedEntriesQuery = null;
  let capturedEventsId = null;

  const mockDb = {
    getIncident: async (id) => ({ id, title: '测试仓库火灾' }),
    listIncidentForces: async () => [],
    listIncidentObservations: async () => [],
    listEntries: async (opts) => {
      capturedEntriesQuery = opts;
      return [
        { id: 'e1', name: '张伟', entry_at: 1700000000000, exited_at: null, pressure_mpa: 25 },
      ];
    },
    listNotes: async (opts) => {
      capturedNotesQuery = opts;
      return [
        { id: 'n1', created_at: 1700000100000, text: '张伟进场', author: '安全员', category: 'entry' },
      ];
    },
    listIncidentEvents: async (id, opts) => {
      capturedEventsId = id;
      return [
        { id: 'ev1', type: 'entry', created_at: 1700000100000, payload: { name: '张伟', pressure_mpa: 25 } },
      ];
    },
  };

  const req = {
    headers: { 'x-incident-id': 'inc-target-999' },
  };

  const context = await loadContext(req, mockDb);
  assert.ok(context);
  assert.equal(capturedNotesQuery.scene, 'inc-target-999');
  assert.equal(capturedEntriesQuery.scene, 'inc-target-999');
  assert.equal(capturedEventsId, 'inc-target-999');

  // 验证 context 数据完备性
  assert.equal(context.personnel.total_entered_count, 1);
  assert.deepEqual(context.personnel.all_entered_names, ['张伟']);
  assert.equal(context.notes[0].text, '张伟进场');
  assert.equal(context.timeline[0].detail, '张伟进场（初始气瓶压力25MPa）');

  const instruction = contextInstruction(context);
  assert.ok(instruction.includes('张伟'));
  assert.ok(instruction.includes('personnel'));
  assert.ok(instruction.includes('timeline'));
});

test('无已确认资料且无警情名称、日志、人员和时间线时返回 null', () => {
  assert.equal(buildContext({ id: 'i' }, { version: 0, data: {} }, []), null);
});
