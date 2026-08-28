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
*6. 姓名必须与消防员名单做同音/近似字纠正：语音识别文本中的姓名若与名单中某人读音相同或近似（同音字、平翘舌/前后鼻音相近的错别字，如 名单"洪辰"被识别成"层层"、名单"陆河圣"识别成"路和胜"），必须纠正为名单中的准确姓名；名单外姓名按原文输出
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
// 灭火救援任务全生命周期痕迹词（依据 GB/T 5907.3《消防词汇·灭火救援》及一线实战用语分类）：
// 出动/行进/侦察/指挥/战斗/搜救/收尾/通信/装备——命中任一即不允许判为 ignore（宁记不错过）
const FIRE_KEYWORDS = [
  ...EXIT_ACTION_WORDS, ...TAKE_OUT_WORDS,
  // 压力/气瓶（安全员核心报告内容）
  '兆帕', 'MPa', '个压', '压力', '气压', '余气', '气量', '空呼', '气瓶',
  // 进场作业
  '进场', '进入', '进去', '进火场', '入场', '入火场', '开始作业', '上气瓶',
  // 灭火战斗
  '火', '救援', '救', '水带', '浓烟', '烟', '被困', '明火', '燃烧', '消防', '搜救', '灭火', '破拆', '内攻', '外攻',
  '水枪', '水炮', '供水', '出水', '断水', '泡沫', '阵地', '排烟', '照明', '干线', '支线', '灭火剂', '被困人员',
  // 指挥/组织
  '指挥员', '带队', '指挥部', '全勤', '到场', '到达现场', '赶赴', '出动', '出警', '接警', '警情', '增援',
  '战况', '部署', '警戒', '封控', '疏散', '处置', '作战', '协同', '请示', '报告',
  // 行进/路况（出警途中通报）
  '途中', '路况', '堵车', '让行', '鸣笛', '警笛', '抵达', '沿路', '通行', '路口', '车辆', '车队', '红绿灯',
  // 侦察/灾情
  '侦察', '侦查', '火势', '蔓延', '楼层', '燃烧物', '伤亡', '位置',
  // 搜救/救助
  '担架', '营救', '转移',
  // 破拆/处置
  '切割', '扩张', '顶撑', '断电', '断气', '登高', '云梯',
  // 安全/通信
  '安全员', '呼救', '避险', '收到', '明白', '完毕', '复述', '通报', '上报', '确认',
  // 收尾/保障
  '收水带', '清点', '洗消', '器材', '装备', '战备', '演练',
];
// 明确噪音特征：命中任一即可安全丢弃（语气词/测试/试音，不构成任务信息）
const NOISE_WORDS = ['测试', '试试', '试音', '喂', '嗯', '哦', '啊', '哈哈', '咳咳', '听得到吗', '能听到吗', '在吗', '嘀嗒'];

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
  // 入场报数兜底：意图被降级/人名存疑时，文本含强入场动作词 + 压力 → 强制按进场处理。
  // 进场登记是安全关键（宁多勿漏），姓名可在 App 确认页补全或重录
  if (intent === 'note' && !hasPeople) {
    const hasEnter = /(进入|进场|进火场|入火场|入场|开始作业|气瓶余量|进去了)/.test(text);
    const hasPressure = /(兆帕|个压|大气压|气瓶|钢瓶|压力|余量)/.test(text);
    if (hasEnter && hasPressure) return 'entry';
  }
  // 出场意图：从火场拿物品、或无人名且无强出场动作词 → 按日志处理，不误登记离场
  if (intent === 'exit' && (TAKE_OUT_WORDS.some((w) => text.includes(w)) || (!hasPeople && !EXIT_ACTION_WORDS.some((w) => text.includes(w))))) {
    return 'note';
  }
  // 进场意图但无人可登记：有"入场动作词+压力"强证据的保留 entry（交确认页补名），
  // 无证据（DeepSeek 幻觉）降级为日志
  if (intent === 'entry' && !hasPeople) {
    const hasEnter = /(进入|进场|进火场|入火场|入场|开始作业|气瓶余量|进去了)/.test(text);
    const hasPressure = /(兆帕|个压|大气压|气瓶|钢瓶|压力|余量)/.test(text);
    if (!(hasEnter && hasPressure)) return 'note';
  }
  // 环境音意图：默认保留（安全员主动按键报话即记录信号），仅明确噪音才允许丢弃——
  // 1) 命中名单/火场痕迹/多人 必救回；2) 长完整陈述句（路况、情况通报等）同样救回；3) 仅短句+噪音词才放行 ignore
  if (intent === 'ignore') {
    const hasFireTrace =
      names.some((n) => n && text.includes(n)) ||
      FIRE_KEYWORDS.some((w) => text.includes(w)) ||
      looksMultiPerson(text);
    if (hasFireTrace) return 'note';
    const isNoise = text.length < 6 || NOISE_WORDS.some((w) => text.includes(w));
    if (!isNoise) return 'note';
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
  let finalParsed = { ...parsed, people };

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
      finalParsed = { ...retried, people };
    }
  }

  const intent = guardrailIntent(text, finalParsed, firefighters);
  // 意图与动作一致性：非进出场意图时动作一律 unknown，App 以 intent 为准路由
  let action = guardrailAction(text, finalParsed);
  if (intent !== 'entry' && intent !== 'exit') action = 'unknown';

  return {
    intent,
    action,
    people,
    note: finalParsed.note || '',
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

function responsesText(data) {
  if (typeof data?.output_text === 'string' && data.output_text.trim()) {
    return data.output_text.trim();
  }
  if (!Array.isArray(data?.output)) return '';
  return data.output
    .filter((item) => item?.type === 'message' && Array.isArray(item.content))
    .flatMap((item) => item.content)
    .filter((part) => part?.type === 'output_text' && typeof part.text === 'string')
    .map((part) => part.text)
    .join('')
    .trim();
}

/// 智能体问答（Responses API + 服务端联网搜索）：返回完整回复文本。
/// 目前仅 deepseek-v4-flash 支持 Responses API，失败抛错由调用方决定是否回退。
async function chatWithWebSearch({ apiKey, baseUrl, model, messages, timeoutMs = 90000, temperature = 0.3, maxOutputTokens = 2000 }) {
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
  const content = responsesText(data);
  if (!content) {
    const status = data?.status ? `（status=${data.status}）` : '';
    throw new Error(`DeepSeek Responses 返回空内容${status}`);
  }
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
