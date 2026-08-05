const SYSTEM_PROMPT = `你是消防救援现场安全管控系统的语音指令解析器。
安全员会在消防员进入火场时喊一句话，例如"张伟，20兆帕"、"王强气瓶还有十五个压"，或多人同时进场时喊"张伟20兆帕，李娜22兆帕，王强十五个压"，消防员出来时喊"张伟和李娜出来了"。

请从这句话中提取结构化信息，只输出 JSON，不要输出其他内容：
{
  "action": "enter" | "exit" | "unknown",
  "people": [
    { "name": "姓名", "pressure_mpa": "气瓶压力数值，单位兆帕，未提及填 null" }
  ],
  "note": "简短说明，可空"
}

规则：
1. 必须输出 people 数组：即使只有一个人也必须放在 people 数组中。严禁输出顶层 name 或 pressure_mpa 字段，严禁用 note 代替 people
2. action 判断：进入火场/开始作业/进去了/气瓶余量等 → enter；出来/已出/撤离/收工等 → exit
3. 一句话可能包含多人：如"张伟20兆帕，李娜22兆帕，王强十五个压"，people 数组需包含全部明确提到的进场人员，按说话顺序排列，不要遗漏、不要合并、不要只取第一个
4. 数字可能以中文表示（二十、15），请统一转为数字
5. 压力单位换算：1兆帕=10个大气压，"20个压"=20MPa，"2个压"=2MPa
6. 姓名优先匹配消防员名单（见下文）
7. exit 时 people 只填姓名，pressure_mpa 为 null
8. 无法确定姓名的人员不要放入 people，放入 note 说明
9. 人数上限 10 人，超出部分在 note 中说明`;

function callDeepSeek({ apiKey, baseUrl, model, systemPrompt, userPrompt }) {
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

  return {
    action: parsed.action || 'unknown',
    people,
    note: parsed.note || '',
  };
}

module.exports = { parseTextWithDeepSeek, looksMultiPerson };
