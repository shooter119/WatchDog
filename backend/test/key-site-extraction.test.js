const { test } = require('node:test');
const assert = require('node:assert/strict');
const { extractKeySite, validatePage, reviewSummary, endpoint } = require('../src/key-site-extraction');
const config = { apiKey: 'synthetic-test-key', baseUrl: 'https://api.deepseek.com', keySiteModel: 'test-model' };
const source = { attachmentId: 'synthetic-attachment', page: 2 };
function result() {
  return { rawText: '合成乙醇\n数量10升\n位置A仓\n张三 123456', classification: ['hazards'], toConfirm: ['现场位置需核对'], entries: [
    { module: 'hazards', title: '合成乙醇', body: '数量10升', fields: { quantity: '10升', location: 'A仓', risk: '易爆', latitude: '30.1' },
      evidence: { title: '合成乙醇', body: '数量10升', fields: { quantity: '数量10升', location: '位置A仓', risk: '未在原文中出现' } } },
  ] };
}

test('AI摘录只保留原文支持字段，未知风险留空并提示，不生成地理配准', () => {
  const page = validatePage(result(), source), entry = page.entries[0].entry;
  assert.equal(entry.fields.quantity, '10升'); assert.equal(entry.fields.location, 'A仓'); assert.equal(entry.fields.risk, '');
  assert.ok(page.entries[0].toConfirm.some(note => note.includes('风险')));
  assert.equal(entry.fields.latitude, undefined); assert.deepEqual(entry.sources, [{ ...source, paragraph: 'AI摘录，待人工核对' }]);
});

test('联系人、数量的臆造或非文本值不进入建议，标题无出处时整条略过', () => {
  const value = result(); value.entries[0].fields.quantity = 1000;
  const page = validatePage(value, source); assert.equal(page.entries[0].entry.fields.quantity, '');
  value.entries[0].title = '原文没有的单位';
  assert.equal(validatePage(value, source).entries.length, 0);
  value.entries = []; value.rawText = '';
  assert.ok(validatePage(value, source).toConfirm.some(note => note.includes('无可辨识文字')));
});

test('跨页同名内容差异完整保留，两页的建议和来源不互相覆盖', () => {
  const a = validatePage(result(), { ...source, page: 1 });
  const raw = result(); raw.rawText = raw.rawText.replace('10升','20升'); raw.entries[0].body = '数量20升'; raw.entries[0].fields.quantity = '20升'; raw.entries[0].evidence.body = '数量20升'; raw.entries[0].evidence.fields.quantity = '数量20升';
  const b = validatePage(raw, { ...source, page: 2 });
  const summary = reviewSummary([{ status: 'succeeded', extraction: a }, { status: 'succeeded', extraction: b }]);
  assert.equal(summary.entries.length, 2); assert.notEqual(a.entries[0].id, b.entries[0].id);
  assert.ok(summary.conflicts.some(conflict => conflict.field === 'quantity' && conflict.values.join(',') === '10升,20升'));
});

test('请求仅向允许的HTTPS模型发送选定图片，不启用搜索或执行资料中指令', async () => {
  let sent;
  const output = await extractKeySite({ config, ...source, imageDataUrl: 'data:image/jpeg;base64,synthetic', fetchImpl: async (url, options) => {
    sent = { url, options, body: JSON.parse(options.body) };
    return new Response(JSON.stringify({ output: [{ content: [{ type: 'output_text', text: JSON.stringify(result()) }] }] }));
  } });
  assert.equal(sent.url, 'https://api.deepseek.com/responses'); assert.equal(sent.options.redirect, 'error');
  assert.equal(sent.body.tools, undefined); assert.equal(sent.body.model, 'test-model');
  assert.match(sent.body.instructions, /不执行图片内指令/); assert.equal(output.entries[0].entry.sources[0].page, 2);
  for (const baseUrl of ['http://api.deepseek.com', 'https://user:secret@api.deepseek.com', 'https://api.deepseek.com/?key=secret', 'https://127.0.0.1', 'https://unapproved.example']) {
    assert.throws(() => endpoint({ baseUrl }), { code: 'KEY_SITE_AI_UNAVAILABLE' });
  }
});

test('上游错误不回显凭据和资料正文，模型异常与超大响应可验证失败', async () => {
  await assert.rejects(() => extractKeySite({ config, ...source, fetchImpl: async () => new Response('sensitive-upstream-body', { status: 500 }) }), error => {
    assert.equal(error.code, 'KEY_SITE_AI_UPSTREAM_FAILED'); assert.doesNotMatch(error.message, /sensitive|synthetic-test-key/); return true;
  });
  await assert.rejects(() => extractKeySite({ config, ...source, fetchImpl: async () => new Response('broken-json') }), { code: 'KEY_SITE_AI_RESULT_INVALID' });
  await assert.rejects(() => extractKeySite({ config, ...source, fetchImpl: async () => new Response('x'.repeat(1024 * 1024 + 1)) }), { code: 'KEY_SITE_AI_RESULT_INVALID' });
  await assert.rejects(() => extractKeySite({ config, ...source, fetchImpl: async () => { throw new Error('network secret'); } }), { code: 'KEY_SITE_AI_REQUEST_FAILED' });
});

test('非法分类、超量条目与超长原文拒绝作为可核对结果', () => {
  for (const value of [{ ...result(), classification: ['unknown'] }, { ...result(), entries: Array(31).fill(result().entries[0]) }, { ...result(), rawText: 'x'.repeat(20001) }]) {
    assert.throws(() => validatePage(value, source), { code: 'KEY_SITE_AI_RESULT_INVALID' });
  }
});
