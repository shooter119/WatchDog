const SYSTEM_PROMPT = `你是消防救援现场安全管控系统的语音指令解析器。
安全员会在消防员进入火场时喊一句话，例如"张伟，20兆帕"、"王强气瓶还有十五个压"，或多人同时进场时喊"张伟20兆帕，刘洋22兆帕，王强十五个压"，消防员出来时喊"张伟和刘洋出来了"。

请从这句话中提取结构化信息，只输出 JSON，不要输出其他内容：
{
  "intent": "entry" | "exit" | "note" | "ask" | "ignore",
  "action": "enter" | "exit" | "unknown",
  "people": [
    { "name": "姓名", "pressure_mpa": "气瓶压力数值，单位兆帕，未提及填 null" }
  ],
  "note": "简短说明，可空"
}

intent 判断规则（最重要，决定 App 跳转）：
1. intent=entry：消防员进火场报数（进场+气瓶压力，如"张伟20兆帕"）
2. intent=exit：消防员出火场（如"张伟出来了"）
3. intent=note：火场日志/随手记内容（如"二楼西侧发现明火"、"三号房有被困人员"、"水带破了一个口"），即与灭火救援相关但不涉及人员进出场的信息
4. intent=ask：向 AI 助手提问求助（如"气瓶压力低怎么办"、"浓烟太大看不清怎么办"、"这个情况怎么处理"），通常是疑问句或求助口吻
5. intent=ignore：误输入的环境音/无关内容，如：旁边人闲聊、电视声音、咳嗽声、测试测试、喂喂喂、报数测试、或者内容与灭火救援毫无交集的话。只有确认与灭火救援没有任何关系才选 ignore

其他规则：
1. 必须输出 people 数组：即使只有一个人也必须放在 people 数组中。严禁输出顶层 name 或 pressure_mpa 字段，严禁用 note 代替 people
2. action 判断：进入火场/开始作业/进去了/气瓶余量等 → enter；出来/已出/撤离/收工等 → exit。注意："搜救出/取出/救出/搬出/抱出一只宠物狗/煤气罐/物品"等"从火场拿出物品"的表达不是消防员出场，一律 unknown；未提及任何消防员姓名进出场时也一律 unknown
3. 一句话可能包含多人：如"张伟20兆帕，刘洋22兆帕，王强十五个压"，people 数组需包含全部明确提到的进场人员，按说话顺序排列，不要遗漏、不要合并、不要只取第一个
4. 数字可能以中文表示（二十、15），请统一转为数字
5. 压力单位换算：1兆帕=10个大气压，"20个压"=20MPa，"2个压"=2MPa
6. 姓名优先匹配消防员名单（见下文）
7. exit 时 people 只填姓名，pressure_mpa 为 null
8. 无法确定姓名的人员不要放入 people，放入 note 说明
9. 人数上限 10 人，超出部分在 note 中说明
10. intent 与 action 一致性：intent=entry 时 action=enter；intent=exit 时 action=exit；intent 为 note/ask/ignore 时 action=unknown`;

const REVISE_SYSTEM_PROMPT = `你是消防救援现场语音识别文本修正器。安全员的喊话被语音识别成文本后，可能存在同音字、错别字或专有名词错误。

修正规则：
1. 只修正识别错误（同音字、错别字、专有名词），不得改写内容、不得增删信息、不得调整语序、不得润色
2. 名单中的姓名被识别成同音字时必须修正为名单中的准确姓名（例如名单有"李翔"，识别成"理想"应修正为"李翔"）
3. 数字、压力数值、单位（兆帕/个压）必须原样保留
4. 文本过短或无法判断错误时，原样返回
5. 只输出 JSON：{"corrected": "修正后的文本"}`;

function callDeepSeek({ apiKey, baseUrl, model, systemPrompt, userPrompt, timeoutMs = 30000 }) {
  const url = (baseUrl || 'https://api.deepseek.com') + '/chat/completions';
  return fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: model || 'deepseek-chat',
      messages: [
        { role: 'system', content: systemPrompt },
        { role: 'user', content: userPrompt },
      ],
      temperature: 0,
      response_format: { type: 'json_object' },
      max_tokens: 1024,
    }),
    signal: AbortSignal.timeout(timeoutMs),
  })
    .then(async (res) => {
      if (!res.ok) {
        const body = await res.text().catch(() => '');
        throw new Error(`DeepSeek API ${res.status}: ${body.slice(0, 200)}`);
      }
      return res.json();
    })
    .then((data) => {
      const content = data?.choices?.[0]?.message?.content || '';
      const match = content.match(/\{[\s\S]*\}/);
      if (!match) throw new Error('LLM 返回无法解析: ' + content.slice(0, 200));
      return JSON.parse(match[0]);
    });
}

/// 规范化 people：兼容旧格式（顶层 name/pressure_mpa），去空、限 10 人
function normalizePeople(parsed) {
  const rawPeople = Array.isArray(parsed.people)
    ? parsed.people
    : parsed.name
      ? [{ name: parsed.name, pressure_mpa: parsed.pressure_mpa }]
      : [];
  return rawPeople
    .map((p) => ({
      name: p && p.name ? String(p.name).trim() : null,
      pressure_mpa: p && p.pressure_mpa != null ? Number(p.pressure_mpa) : null,
    }))
    .filter((p) => p.name)
    .slice(0, 10);
}

/// 启发式判断文本是否提及多人：出现 >=2 处压力数值（如"20兆帕/二十二个压"）
function looksMultiPerson(text) {
  const re = /(?:\d+(?:\.\d+)?|[零一二三四五六七八九十百千]+)(?:\s*)(?:兆帕|MPa|mpa|个压|压)/g;
  let n = 0;
  for (const m of text.matchAll(re)) {
    n++;
    if (n >= 2) return true;
  }
  return false;
}

/// 确定性校验 LLM 解析结果（guardrail）：
/// LLM 是概率模型，可能把"搜救出宠物狗"误判为出场指令。这里用文本证据强制把关，
/// 无证据的 exit 一律降级 unknown——宁可为日志，不误登记离场。
const EXIT_ACTION_WORDS = ['出来', '撤离', '撤出', '收工', '退场', '离开', '撤退', '出去', '出火场', '退回'];
const TAKE_OUT_WORDS = ['搜救出', '取出', '救出', '搬出', '抱出', '抢出', '卸出', '拎出', '转移出'];
// 与灭火救援相关的痕迹词：命中任一即不允许判为 ignore（宁记不错过）
const FIRE_KEYWORDS = [
  ...EXIT_ACTION_WORDS, ...TAKE_OUT_WORDS,
  '进场', '进入', '进去', '进火场', '开始作业', '上气瓶', '兆帕', 'MPa', '个压', '压力', '气压',
  '火', '救援', '救', '水带', '气瓶', '浓烟', '烟', '被困', '明火', '燃烧', '消防', '搜救', '灭火', '破拆', '内攻', '被困人员',
  '指挥员', '带队', '指挥部', '到场', '到达现场', '赶赴', '出动', '处置',
];

function guardrailAction(text, parsed) {
  if (parsed.action !== 'exit') return parsed.action;
  // 从火场拿出物品（搜救出宠物狗/取出煤气罐）绝不是出场指令
  if (TAKE_OUT_WORDS.some((w) => text.includes(w))) return 'unknown';
  // exit 必须有明确出场证据：具体人名，或强出场动作词；两者皆无视为 LLM 幻觉
  const hasPeople = Array.isArray(parsed.people) && parsed.people.length > 0;
  if (hasPeople) return parsed.action;
  return EXIT_ACTION_WORDS.some((w) => text.includes(w)) ? parsed.action : 'unknown';
}

/// 意图级 guardrail：LLM 是概率模型，这里用文本证据强制把关意图分类
function guardrailIntent(text, parsed, firefighters = []) {
  const names = firefighters.map((n) => (typeof n === 'string' ? n : n?.name)).filter(Boolean);
  let intent = parsed.intent;
  if (!['entry', 'exit', 'note', 'ask', 'ignore'].includes(intent)) intent = 'note';
  const hasPeople = Array.isArray(parsed.people) && parsed.people.length > 0;
  // 出场意图：从火场拿物品、或无人名且无强出场动作词 → 按日志处理，不误登记离场
  if (intent === 'exit' && (TAKE_OUT_WORDS.some((w) => text.includes(w)) || (!hasPeople && !EXIT_ACTION_WORDS.some((w) => text.includes(w))))) {
    return 'note';
  }
  // 进场意图但无人可登记 → 按日志兜底
  if (intent === 'entry' && !hasPeople) return 'note';
  // 环境音意图：文本仍含名单姓名/火场痕迹/压力读数时禁止丢弃，宁记不错过
  if (intent === 'ignore') {
    const hasFireTrace =
      names.some((n) => n && text.includes(n)) ||
      FIRE_KEYWORDS.some((w) => text.includes(w)) ||
      looksMultiPerson(text);
    if (hasFireTrace) return 'note';
  }
  return intent;
}

async function parseTextWithDeepSeek({ apiKey, baseUrl, model, text, firefighters = [], hotwords = [] }) {
  const names = firefighters.length > 0 ? '名单：' + firefighters.join('、') : '名单：无';
  const terms = hotwords.length > 0 ? '专业术语：' + hotwords.join('、') : '';
  const userPrompt = `现场已知消防员${names}${terms ? '\n' + terms : ''}\n\n安全员语音识别文本："${text}"`;

  const parsed = await callDeepSeek({
    apiKey,
    baseUrl,
    model,
    systemPrompt: SYSTEM_PROMPT,
    userPrompt,
  });
  let people = normalizePeople(parsed);

  // LLM 漏解析兜底：文本明显含多人但只识别出 <=1 人时，重试一次并指出遗漏
  if (looksMultiPerson(text) && people.length < 2) {
    const retryPrompt = `${userPrompt}\n\n重要：上句语音包含多名进场人员与各自的压力读数，请重新解析，在 people 数组中完整列出全部人员（按说话顺序），严禁只返回第一个或遗漏任何一人。`;
    const retried = await callDeepSeek({
      apiKey,
      baseUrl,
      model,
      systemPrompt: SYSTEM_PROMPT,
      userPrompt: retryPrompt,
    });
    const retriedPeople = normalizePeople(retried);
    if (retriedPeople.length > people.length) {
      people = retriedPeople;
    }
  }

  const intent = guardrailIntent(text, parsed, firefighters);
  // 意图与动作一致性：非进出场意图时动作一律 unknown，App 以 intent 为准路由
  let action = guardrailAction(text, parsed);
  if (intent !== 'entry' && intent !== 'exit') action = 'unknown';

  return {
    intent,
    action,
    people,
    note: parsed.note || '',
  };
}

/// 自由文本对话（用于智能体问答）：返回完整回复文本
async function chatWithDeepSeek({ apiKey, baseUrl, model, messages, timeoutMs = 60000, temperature = 0.3, maxTokens = 800 }) {
  const url = (baseUrl || 'https://api.deepseek.com') + '/chat/completions';
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: model || 'deepseek-chat',
      messages,
      temperature,
      max_tokens: maxTokens,
    }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`DeepSeek API ${res.status}: ${body.slice(0, 200)}`);
  }
  const data = await res.json();
  const content = data?.choices?.[0]?.message?.content || '';
  if (!content) throw new Error('DeepSeek 返回空内容');
  return content;
}

/// 智能体问答（流式 SSE）：yield 每次增量文本，供 /api/chat stream 模式逐段转发。
/// DeepSeek 原生 stream 输出 `data: {...delta...}` 行，[DONE] 结束。
async function* chatWithDeepSeekStream({ apiKey, baseUrl, model, messages, timeoutMs = 60000, temperature = 0.3, maxTokens = 800 }) {
  const url = (baseUrl || 'https://api.deepseek.com') + '/chat/completions';
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: model || 'deepseek-chat',
      messages,
      temperature,
      max_tokens: maxTokens,
      stream: true,
    }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`DeepSeek API ${res.status}: ${body.slice(0, 200)}`);
  }
  if (!res.body) throw new Error('DeepSeek 无响应流');
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = '';
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let idx;
    while ((idx = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, idx).trim();
      buf = buf.slice(idx + 1);
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (data === '[DONE]') return;
      try {
        const delta = JSON.parse(data)?.choices?.[0]?.delta?.content;
        if (delta) yield delta;
      } catch (_) {
        // 忽略无法解析的片段（如 keep-alive 行）
      }
    }
  }
}

/// 智能体问答（Responses API + 服务端联网搜索）：返回完整回复文本。
/// 目前仅 deepseek-v4-flash 支持 Responses API，失败抛错由调用方决定是否回退。
async function chatWithWebSearch({ apiKey, baseUrl, model, messages, timeoutMs = 90000, temperature = 0.3, maxOutputTokens = 800 }) {
  const url = (baseUrl || 'https://api.deepseek.com') + '/responses';
  const system = messages.find((m) => m.role === 'system')?.content || '';
  const input = messages
    .filter((m) => m.role !== 'system')
    .map((m) => ({ role: m.role === 'assistant' ? 'assistant' : 'user', content: m.content }));
  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: model || 'deepseek-v4-flash',
      instructions: system,
      input,
      tools: [{ type: 'web_search' }],
      tool_choice: 'auto',
      temperature,
      max_output_tokens: maxOutputTokens,
      stream: false,
    }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`DeepSeek Responses API ${res.status}: ${body.slice(0, 200)}`);
  }
  const data = await res.json();
  const content = data?.output_text || '';
  if (!content) throw new Error('DeepSeek Responses 返回空内容');
  return content;
}

/// 修正 ASR 原始文本：结合消防员名单与热词纠正同音字/错别字/专有名词。
/// 返回修正后的文本；调用方应捕获异常并回退原始文本。
async function reviseTextWithDeepSeek({ apiKey, baseUrl, model, text, firefighters = [], hotwords = [] }) {
  const names = firefighters.length > 0 ? '名单：' + firefighters.join('、') : '名单：无';
  const terms = hotwords.length > 0 ? '专业术语：' + hotwords.join('、') : '';
  const userPrompt = `现场已知消防员${names}${terms ? '\n' + terms : ''}\n\n语音识别原始文本："${text}"`;

  const parsed = await callDeepSeek({
    apiKey,
    baseUrl,
    model,
    systemPrompt: REVISE_SYSTEM_PROMPT,
    userPrompt,
    timeoutMs: 15000,
  });
  const corrected = parsed && typeof parsed.corrected === 'string' ? parsed.corrected.trim() : '';
  return corrected || text;
}

module.exports = { parseTextWithDeepSeek, reviseTextWithDeepSeek, chatWithDeepSeek, chatWithDeepSeekStream, chatWithWebSearch, looksMultiPerson, guardrailAction, guardrailIntent };
