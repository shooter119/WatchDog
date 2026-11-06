const { test } = require('node:test');
const assert = require('node:assert/strict');
const { buildContext, safeSearchQuery, contextInstruction } = require('../src/incident-chat-context');

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

test('无已确认资料且无警情名称、日志时返回 null', () => {
  assert.equal(buildContext({ id: 'i' }, { version: 0, data: {} }, []), null);
});
