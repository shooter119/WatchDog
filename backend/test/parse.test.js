const { test, afterEach } = require('node:test');
const assert = require('node:assert/strict');

const { parseTextWithDeepSeek, reviseTextWithDeepSeek, guardrailAction } = require('../src/parse');

afterEach(() => {
  delete globalThis.fetch;
});

const ok = (content) => ({
  async json() {
    return { choices: [{ message: { content: JSON.stringify(content) } }] };
  },
  ok: true,
});

test('reviseTextWithDeepSeek 把同音姓名修正为名单姓名', async () => {
  globalThis.fetch = () => Promise.resolve(ok({ corrected: '李翔，20兆帕' }));
  const corrected = await reviseTextWithDeepSeek({
    apiKey: 'k',
    text: '理想，20兆帕',
    firefighters: ['李翔'],
  });
  assert.equal(corrected, '李翔，20兆帕');
});

test('reviseTextWithDeepSeek 原文准确时原样返回', async () => {
  globalThis.fetch = () => Promise.resolve(ok({ corrected: '王强气瓶还有十五个压' }));
  const corrected = await reviseTextWithDeepSeek({
    apiKey: 'k',
    text: '王强气瓶还有十五个压',
    hotwords: ['气瓶'],
  });
  assert.equal(corrected, '王强气瓶还有十五个压');
});

test('reviseTextWithDeepSeek 服务异常时向上抛错（由调用方回退原文）', async () => {
  globalThis.fetch = () => Promise.reject(new Error('network down'));
  await assert.rejects(
    reviseTextWithDeepSeek({ apiKey: 'k', text: '李娜，22兆帕', firefighters: ['李娜'] }),
    /network down/,
  );
});

test('reviseTextWithDeepSeek 请求体包含名单与热词', async () => {
  let body = null;
  let init = null;
  globalThis.fetch = (url, opts) => {
    assert.match(String(url), /chat\/completions$/);
    body = JSON.parse(opts.body);
    init = opts;
    return Promise.resolve(ok({ corrected: '张伟，20兆帕' }));
  };
  await reviseTextWithDeepSeek({
    apiKey: 'k',
    model: 'deepseek-chat',
    text: '张伟，20兆帕',
    firefighters: ['张伟'],
    hotwords: ['空气呼吸器'],
  });
  assert.equal(body.model, 'deepseek-chat');
  assert.match(body.messages[0].content, /修正/);
  assert.match(body.messages[1].content, /名单：张伟/);
  assert.match(body.messages[1].content, /专业术语：空气呼吸器/);
  assert.ok(init.signal instanceof AbortSignal);
});

test('parseTextWithDeepSeek 修正后文本仍可正常解析', async () => {
  globalThis.fetch = () => Promise.resolve(ok({ action: 'enter', people: [{ name: '李翔', pressure_mpa: 20 }], note: '' }));
  const parsed = await parseTextWithDeepSeek({
    apiKey: 'k',
    text: '李翔，20兆帕',
    firefighters: ['李翔'],
  });
  assert.equal(parsed.action, 'enter');
  assert.deepEqual(parsed.people, [{ name: '李翔', pressure_mpa: 20 }]);
});

// guardrail：LLM 误判"搜救出宠物狗"为 exit 时强制降级
test('guardrailAction 搜救出宠物狗误判 exit 时降级 unknown', () => {
  assert.equal(
    guardrailAction('龙翔路站从燃烧建筑中搜救出一只宠物狗', { action: 'exit', people: [] }),
    'unknown',
  );
});

test('guardrailAction 取出煤气罐等物品动作误判 exit 时降级 unknown', () => {
  assert.equal(guardrailAction('龙翔路站从火场中取出一个煤气罐', { action: 'exit', people: [] }), 'unknown');
});

test('guardrailAction exit 无人名且无出场证据（LLM 幻觉）降级 unknown', () => {
  assert.equal(guardrailAction('龙翔路站攻坚组进入火场内部', { action: 'exit', people: [] }), 'unknown');
});

test('guardrailAction 明确的出场指令保留 exit', () => {
  assert.equal(guardrailAction('张伟和李娜出来了', { action: 'exit', people: [{ name: '张伟' }, { name: '李娜' }] }), 'exit');
  assert.equal(guardrailAction('全部人员撤出火场', { action: 'exit', people: [] }), 'exit');
  assert.equal(guardrailAction('收工', { action: 'exit', people: [] }), 'exit');
});

test('guardrailAction 正常进场不受影响', () => {
  assert.equal(guardrailAction('张伟，20兆帕', { action: 'enter', people: [{ name: '张伟', pressure_mpa: 20 }] }), 'enter');
});
