const { test, afterEach } = require('node:test');
const assert = require('node:assert/strict');

const { parseTextWithDeepSeek, reviseTextWithDeepSeek, guardrailAction, guardrailIntent } = require('../src/parse');

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
  globalThis.fetch = () => Promise.resolve(ok({ intent: 'entry', action: 'enter', people: [{ name: '李翔', pressure_mpa: 20 }], note: '' }));
  const parsed = await parseTextWithDeepSeek({
    apiKey: 'k',
    text: '李翔，20兆帕',
    firefighters: ['李翔'],
  });
  assert.equal(parsed.intent, 'entry');
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

// guardrailIntent：环境音/无关内容与灭火救援无关时才允许丢弃
test('guardrailIntent 纯环境音（语气词/测试）保留 ignore', () => {
  assert.equal(guardrailIntent('咳咳，测试测试', { intent: 'ignore', people: [] }, []), 'ignore');
  assert.equal(guardrailIntent('嗯', { intent: 'ignore', people: [] }, []), 'ignore');
  assert.equal(guardrailIntent('喂喂', { intent: 'ignore', people: [] }, []), 'ignore');
});

test('guardrailIntent 短句无痕迹且无噪音词时宁记不错过', () => {
  assert.equal(guardrailIntent('哦哦哦', { intent: 'ignore', people: [] }, []), 'ignore');
  assert.equal(guardrailIntent('收到', { intent: 'ignore', people: [] }, []), 'note');
});

test('guardrailIntent 完整陈述句默认保留（路况/情况通报等）', () => {
  // 出警途中路况通报：不含火场关键词也应按日志保留
  assert.equal(guardrailIntent('路上遇到小学放学，车队堵车。', { intent: 'ignore', people: [] }, []), 'note');
  // 完整句闲聊：宁记不错过，宁可多记一条也不漏任务信息
  assert.equal(guardrailIntent('今晚油价又涨了', { intent: 'ignore', people: [] }, []), 'note');
});

test('guardrailIntent 文本含名单姓名时禁止丢弃（宁记不错过）', () => {
  assert.equal(guardrailIntent('张伟，20兆帕', { intent: 'ignore', people: [] }, ['张伟']), 'note');
});

test('guardrailIntent 文本含火场痕迹时禁止丢弃', () => {
  assert.equal(guardrailIntent('这个火烧得挺大的', { intent: 'ignore', people: [] }, []), 'note');
  assert.equal(guardrailIntent('气瓶压力还有二十个压', { intent: 'ignore', people: [] }, []), 'note');
  // 火场指挥/到场语境（含与名单同音的姓名时更需兜底）
  assert.equal(guardrailIntent('带队指挥员陆和胜', { intent: 'ignore', people: [] }, ['陆河圣']), 'note');
  assert.equal(guardrailIntent('总队全勤指挥部到达现场', { intent: 'ignore', people: [] }, []), 'note');
  // 行进/路况痕迹
  assert.equal(guardrailIntent('途中堵车，预计晚十分钟到场', { intent: 'ignore', people: [] }, []), 'note');
  // 通信确认
  assert.equal(guardrailIntent('明白，马上增援', { intent: 'ignore', people: [] }, []), 'note');
});

test('guardrailIntent 搜救出物品误判 exit 降级 note', () => {
  assert.equal(guardrailIntent('搜救出一只宠物狗', { intent: 'exit', people: [] }, []), 'note');
});

test('guardrailIntent 进场无人可登记降级 note', () => {
  assert.equal(guardrailIntent('开始进场', { intent: 'entry', people: [] }, []), 'note');
});

test('guardrailIntent 正常进出场意图保留', () => {
  assert.equal(
    guardrailIntent('张伟，20兆帕', { intent: 'entry', people: [{ name: '张伟', pressure_mpa: 20 }] }, ['张伟']),
    'entry',
  );
  assert.equal(
    guardrailIntent('张伟和李娜出来了', { intent: 'exit', people: [{ name: '张伟' }, { name: '李娜' }] }, ['张伟', '李娜']),
    'exit',
  );
});

test('parseTextWithDeepSeek 返回意图字段，ask 时动作降级 unknown', async () => {
  globalThis.fetch = () => Promise.resolve(ok({ intent: 'ask', action: 'unknown', people: [], note: '' }));
  const parsed = await parseTextWithDeepSeek({ apiKey: 'k', text: '气瓶压力低怎么办', firefighters: [] });
  assert.equal(parsed.intent, 'ask');
  assert.equal(parsed.action, 'unknown');
  assert.deepEqual(parsed.people, []);
});

test('parseTextWithDeepSeek 环境音意图经 guardrail 丢弃', async () => {
  globalThis.fetch = () => Promise.resolve(ok({ intent: 'ignore', action: 'unknown', people: [], note: '' }));
  const parsed = await parseTextWithDeepSeek({ apiKey: 'k', text: '咳咳', firefighters: [] });
  assert.equal(parsed.intent, 'ignore');
});

test('parseTextWithDeepSeek 环境音意图但文本含名单时兜底为 note', async () => {
  globalThis.fetch = () => Promise.resolve(ok({ intent: 'ignore', action: 'unknown', people: [], note: '' }));
  const parsed = await parseTextWithDeepSeek({ apiKey: 'k', text: '李娜在不在火场里', firefighters: ['李娜'] });
  assert.equal(parsed.intent, 'note');
});
