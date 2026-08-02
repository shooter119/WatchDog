const SYSTEM_PROMPT = `你是消防救援现场安全管控系统的语音指令解析器。
安全员会在消防员进入火场时喊一句话，例如"张伟，20兆帕"、"王强气瓶还有十五个压"，或消防员出来时喊"张伟出来了"、"李娜已出火场"。

请从这句话中提取结构化信息，只输出 JSON，不要输出其他内容：
{
  "action": "enter" | "exit" | "unknown",
  "name": "姓名（如无法确定填 null）",
  "pressure_mpa": "气瓶压力数值，单位兆帕。可接受说法：20兆帕/20MPa/20个压/两个压*10/二百/100公斤等；如未提及填 null。注意"个压"需要换算：X个压即X兆帕",
  "note": "简短说明，可空"
}

规则：
1. action 判断：进入火场/开始作业/进去了/气瓶余量等 → enter；出来/已出/撤离/收工等 → exit
2. 数字可能以中文表示（二十、15），请统一转为数字
3. 压力单位换算：1兆帕=10个大气压，"20个压"=20MPa，"2个压"=2MPa
4. 姓名优先匹配消防员名单（见下文）
5. 一句话可能同时包含多人的进入，只解析第一个提到的明确人员`;

function parseTextWithDeepSeek({ apiKey, baseUrl, model, text, firefighters = [], hotwords = [] }) {
  const url = (baseUrl || 'https://api.deepseek.com') + '/chat/completions';
  const names = firefighters.length > 0 ? '名单：' + firefighters.join('、') : '名单：无';
  const terms = hotwords.length > 0 ? '专业术语：' + hotwords.join('、') : '';

  const userPrompt = `现场已知消防员${names}${terms ? '\n' + terms : ''}\n\n安全员语音识别文本："${text}"`;

  return fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: model || 'deepseek-chat',
      messages: [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: userPrompt },
      ],
      temperature: 0,
      response_format: { type: 'json_object' },
      max_tokens: 256,
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
      const parsed = JSON.parse(match[0]);
      return {
        action: parsed.action || 'unknown',
        name: parsed.name || null,
        pressure_mpa: parsed.pressure_mpa != null ? Number(parsed.pressure_mpa) : null,
        note: parsed.note || '',
      };
    });
}

module.exports = { parseTextWithDeepSeek };
