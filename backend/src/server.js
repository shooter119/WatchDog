const express = require('express');
const crypto = require('crypto');
const { transcribe } = require('./asr');
const { parseTextWithDeepSeek, reviseTextWithDeepSeek, chatWithDeepSeek } = require('./parse');
const { durationMinutes, exitAtMs, measuredConsumptionLpm } = require('./calc');
const db = require('./db');
const logger = require('./logger');

const app = express();
const PORT = process.env.PORT || 3000;
const API_TOKEN = process.env.API_TOKEN || '';

const CFG = {
  asr: {
    appId: process.env.VOLC_APP_KEY || process.env.VOLC_APP_ID || '',
    accessToken: process.env.VOLC_ACCESS_TOKEN || '',
    resourceId: process.env.VOLC_RESOURCE_ID || 'volc.bigasr.sauc.duration',
  },
  llm: {
    apiKey: process.env.DEEPSEEK_API_KEY || '',
    baseUrl: process.env.DEEPSEEK_BASE_URL || 'https://api.deepseek.com',
    model: process.env.DEEPSEEK_MODEL || 'deepseek-chat',
  },
  calc: {
    cylinderVolL: Number(process.env.CYLINDER_VOL_L || 6.8),
    fullPressureMpa: Number(process.env.FULL_PRESSURE_MPA || 30),
    consumptionLpm: Number(process.env.CONSUMPTION_LPM || 40),
    warnMin: Number(process.env.WARN_MIN || 10),
    alarmMin: Number(process.env.ALARM_MIN || 5),
  },
};

app.use(express.json({ limit: '5mb' }));
app.use((req, res, next) => {
  res.set('Access-Control-Allow-Origin', '*');
  res.set('Access-Control-Allow-Methods', 'GET,POST,PUT,PATCH,DELETE,OPTIONS');
  res.set('Access-Control-Allow-Headers', 'Content-Type, X-Scene-Code, X-Api-Token, X-Device-Id, X-Op-Id');
  if (req.method === 'OPTIONS') return res.sendStatus(204);
  next();
});

// 请求日志（health 探活不刷屏）
app.use((req, res, next) => {
  if (req.path === '/api/health') return next();
  const start = Date.now();
  res.on('finish', () => {
    logger.info(`${req.method} ${req.path} ${res.statusCode} ${Date.now() - start}ms`);
  });
  next();
});

// 简单共享 Token 认证（/api/health 除外），未配置 API_TOKEN 时不做校验
app.use((req, res, next) => {
  if (req.path === '/api/health' || !API_TOKEN) return next();
  if (req.headers['x-api-token'] !== API_TOKEN) {
    return res.status(401).json({ error: '未授权，请检查设置的访问令牌' });
  }
  next();
});

function sceneKey(req) {
  return (req.headers['x-scene-code'] || 'default').toString().slice(0, 64);
}

function deviceKey(req) {
  return (req.headers['x-device-id'] || '').toString().slice(0, 128) || null;
}

function opKey(req) {
  return (req.headers['x-op-id'] || '').toString().slice(0, 64) || null;
}

// 允许同步到服务器的用户设置键（与 App 端 Settings 同步白名单一致）
const USER_SETTING_KEYS = [
  'cylinder_vol_l',
  'full_pressure_mpa',
  'consumption_lpm',
  'warn_min',
  'alarm_min',
  'tts_enabled',
  'alarm_sound_enabled',
  'keep_screen_on',
  'asr_cloud_enabled',
  'parse_cloud_enabled',
];

/** 服务端操作日志：与 App 端同 op_id，便于拼接完整链路 */
function logOp(req, level, stage, msg, data = null) {
  try {
    db.addLog({
      scene: sceneKey(req),
      device: deviceKey(req),
      opId: opKey(req),
      level,
      stage,
      msg,
      data,
    });
  } catch (e) {
    logger.warn('写入操作日志失败', e.message || e);
  }
}

function hotwordList(scene) {
  const firefighters = db.listFirefighters().map((f) => f.name);
  const terms = db.listHotwords().map((h) => h.word);
  const defaults = ['兆帕', '个压', '气瓶', '空气呼吸器', '余量', '进入火场', '出来了', '已出火场', '收到'];
  return [...new Set([...firefighters, ...terms, ...defaults])].filter(Boolean);
}

app.get('/api/health', (req, res) => {
  res.json({ ok: true, time: Date.now(), asrConfigured: !!CFG.asr.appId, llmConfigured: !!CFG.llm.apiKey });
});

app.get('/api/config', (req, res) => {
  res.json({ calc: CFG.calc, asrConfigured: !!CFG.asr.appId, llmConfigured: !!CFG.llm.apiKey });
});

// 场景列表（供多设备确认场景码、查看活跃场景）
app.get('/api/scenes', (req, res) => {
  res.json(db.listScenes());
});

app.post('/api/transcribe', (req, res, next) => {
  if (!CFG.asr.appId) return res.status(503).json({ error: 'ASR 未配置 VOLC_APP_KEY' });
  const scene = sceneKey(req);
  const chunks = [];
  let total = 0;
  req.on('data', (c) => {
    total += c.length;
    if (total > 15 * 1024 * 1024) {
      res.status(413).json({ error: '音频过大' });
      req.destroy();
      return;
    }
    chunks.push(c);
  });
  req.on('end', async () => {
    try {
      const audio = Buffer.concat(chunks);
      if (audio.length < 44) return res.status(400).json({ error: '音频数据过短' });
      const hotwords = hotwordList(scene);
      // 解析 Content-Type（去掉 charset 等参数），支持 wav/pcm/mp3/ogg，未知一律按 wav 处理
      const ct = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
      const fmt = ct.replace(/^audio\//, '');
      const format = ['wav', 'pcm', 'mp3', 'ogg'].includes(fmt) ? fmt : 'wav';
      const t0 = Date.now();
      logOp(req, 'info', 'transcribe_received', '收到语音转写请求', { bytes: audio.length, format, hotwords: hotwords.length });
      const text = await transcribe({
        appId: CFG.asr.appId,
        accessToken: CFG.asr.accessToken,
        resourceId: CFG.asr.resourceId,
        audioBuffer: audio,
        format,
        hotwords,
      });
      logOp(req, 'info', 'asr_done', 'ASR 识别完成', { text, ms: Date.now() - t0 });
      // ASR 文本修正：结合名单与热词纠正同音字/专有名词（如"理想"→"李翔"）。
      // 仅当 LLM 已配置且 ASR 有结果时执行；修正失败回退原文，不阻塞语音录入。
      let revised = false;
      let finalText = text;
      if (text && CFG.llm.apiKey) {
        try {
          const corrected = await reviseTextWithDeepSeek({
            apiKey: CFG.llm.apiKey,
            baseUrl: CFG.llm.baseUrl,
            model: CFG.llm.model,
            text,
            firefighters: db.listFirefighters().map((f) => f.name),
            hotwords: db.listHotwords().map((h) => h.word),
          });
          if (corrected && corrected !== text) {
            finalText = corrected;
            revised = true;
          }
          logOp(req, 'info', 'revise_done', '文本修正完成', { before: text, after: finalText, revised });
        } catch (e) {
          logger.warn('文本修正失败，回退原始转写', e.message || e);
          logOp(req, 'warn', 'revise_failed', `文本修正失败，回退原始转写: ${e.message || e}`);
        }
      }
      res.json({ text: finalText, revised, hotwordCount: hotwords.length });
      logOp(req, 'info', 'transcribe_resp', '转写响应', { text: finalText, revised, ms: Date.now() - t0 });
    } catch (e) {
      logOp(req, 'error', 'transcribe_err', `转写失败: ${e.message || e}`);
      next(e);
    }
  });
  req.on('error', next);
});

app.post('/api/parse', async (req, res, next) => {
  try {
    const { text } = req.body || {};
    if (!text || !String(text).trim()) return res.status(400).json({ error: '缺少 text' });
    if (!CFG.llm.apiKey) return res.status(503).json({ error: 'LLM 未配置 DEEPSEEK_API_KEY' });
    const firefighters = db.listFirefighters().map((f) => f.name);
    const hotwords = db.listHotwords().map((h) => h.word);
    const t0 = Date.now();
    logOp(req, 'info', 'parse_req', '收到语义解析请求', { text: String(text).trim(), firefighters, hotwords });
    const parsed = await parseTextWithDeepSeek({
      apiKey: CFG.llm.apiKey,
      baseUrl: CFG.llm.baseUrl,
      model: CFG.llm.model,
      text: String(text).trim(),
      firefighters,
      hotwords,
    });
    logOp(req, 'info', 'parse_done', '语义解析完成', { parsed, ms: Date.now() - t0 });
    res.json(parsed);
  } catch (e) {
    logOp(req, 'error', 'parse_err', `解析失败: ${e.message || e}`);
    next(e);
  }
});

const CHAT_SYSTEM_PROMPT = `你是"辅助"，消防救援现场安全管控系统里的 AI 智囊，常驻安全员的手持终端。
安全员和消防员在火场里遇到困难时会向你提问，你要给出专业、务实、安全的解答。

回答要求：
1. 简洁直接，分条给出可立即执行的措施，不要长篇大论、不要空话套话
2. 涉及火场风险判断时，安全永远第一：先提示评估风险、做好个人防护、必要时请求支援或撤离
3. 不确定或超出知识范围时如实说明，严禁编造数据或器材参数
4. 涉及医疗急救、危险化学品处置等专业操作，强调必须由持证专业人员执行
5. 可从火场战术、器材使用、气瓶余量管理、破拆搜救、通讯协同等角度回答
6. 回答结构固定为三段，每段以「结论」「立即行动」「注意事项」标题开头（标题独占一行）：
   - 结论：一句话概括判断或建议
   - 立即行动：分条列出 2~4 条马上能做的措施
   - 注意事项：指出风险点与禁忌，必要时追问一句关键信息帮助判断现场情况
7. 问题简单明确时可不分段，直接简洁作答，但需保留安全提示要点`;

// 智能体问答限流：按场景内存计数（单实例部署），每分钟最多 10 次提问
const chatRateBuckets = new Map();
function chatRateLimited(scene) {
  const minute = Math.floor(Date.now() / 60000);
  const bucket = chatRateBuckets.get(scene);
  if (!bucket || bucket.minute !== minute) {
    chatRateBuckets.set(scene, { minute, count: 1 });
    return false;
  }
  bucket.count++;
  return bucket.count > 10;
}

// 智能体问答：带场景隔离的历史上下文，回复同时落库（user + assistant 成对写入）
app.post('/api/chat', async (req, res, next) => {
  try {
    const { message } = req.body || {};
    const clean = String(message || '').trim();
    if (!clean) return res.status(400).json({ error: '缺少 message' });
    if (clean.length > 2000) return res.status(400).json({ error: '问题过长（最多 2000 字）' });
    if (!CFG.llm.apiKey) return res.status(503).json({ error: 'LLM 未配置 DEEPSEEK_API_KEY' });
    const scene = sceneKey(req);
    if (chatRateLimited(scene)) return res.status(429).json({ error: '提问过于频繁，请稍后再试' });
    const history = db.listChatMessages({ scene, limit: 40 });
    const messages = [
      { role: 'system', content: CHAT_SYSTEM_PROMPT },
      ...history.map((m) => ({ role: m.role, content: m.content })),
      { role: 'user', content: clean },
    ];
    const t0 = Date.now();
    logOp(req, 'info', 'chat_req', '收到问答请求', { text: clean.slice(0, 100), history: history.length });
    const reply = await chatWithDeepSeek({
      apiKey: CFG.llm.apiKey,
      baseUrl: CFG.llm.baseUrl,
      model: CFG.llm.model,
      messages,
    });
    db.createChatMessage({ id: crypto.randomUUID(), scene, role: 'user', content: clean });
    db.createChatMessage({ id: crypto.randomUUID(), scene, role: 'assistant', content: reply });
    logOp(req, 'info', 'chat_done', '问答完成', { ms: Date.now() - t0, replyLen: reply.length });
    res.json({ reply, created_at: Date.now() });
  } catch (e) {
    logOp(req, 'error', 'chat_err', `问答失败: ${e.message || e}`);
    next(e);
  }
});

app.get('/api/chat', (req, res) => {
  const limit = Number(req.query.limit) || 100;
  res.json(db.listChatMessages({ scene: sceneKey(req), limit }));
});

app.delete('/api/chat', (req, res, next) => {
  try {
    const n = db.clearChatMessages(sceneKey(req));
    logOp(req, 'info', 'chat_cleared', '已清空问答记录', { deleted: n });
    res.json({ ok: true, deleted: n });
  } catch (e) {
    next(e);
  }
});

app.get('/api/entries', (req, res) => {
  const activeOnly = req.query.active === '1';
  res.json(db.listEntries({ activeOnly, scene: sceneKey(req) }));
});

app.post('/api/entries', (req, res, next) => {
  try {
    const { name, pressure_mpa, source = 'voice', raw_text = null, force = false, volume_l, consumption_lpm } = req.body || {};
    const scene = sceneKey(req);
    const cleanName = String(name || '').trim();
    if (!cleanName) return res.status(400).json({ error: '缺少姓名' });
    if (pressure_mpa == null) return res.status(400).json({ error: '缺少气瓶压力，请确认压力后再登记' });
    const p = Number(pressure_mpa);
    if (!(p > 0) || p > 40) return res.status(400).json({ error: '压力数值异常' });

    // 气瓶容量：可空（用全局默认），提供时须在合理范围（防止误填导致倒计时异常）
    let vol = null;
    if (volume_l != null && volume_l !== '') {
      vol = Number(volume_l);
      if (!(vol > 0) || vol > 20) return res.status(400).json({ error: '气瓶容量数值异常' });
    }

    // 消耗率：App 端可携带本地设置值（不传则用服务端默认）
    let consumption = CFG.calc.consumptionLpm;
    if (consumption_lpm != null && consumption_lpm !== '') {
      consumption = Number(consumption_lpm);
      if (!(consumption > 0) || consumption > 300) return res.status(400).json({ error: '消耗率数值异常' });
    }
    const calcParam = { ...CFG.calc, consumptionLpm: consumption };

    // 同名在场记录：防止同一人重复登记（改名合并走 PATCH，重复进场须 force）
    const existing = db.findActiveByName(scene, cleanName);
    if (existing && !force) {
      const at = new Date(existing.entry_at);
      const hh = String(at.getHours()).padStart(2, '0');
      const mm = String(at.getMinutes()).padStart(2, '0');
      logOp(req, 'warn', 'entry_conflict', `「${cleanName}」已在火场内，拒绝重复进场`, { entryId: existing.id });
      return res.status(409).json({
        error: `「${existing.name}」已在火场内（${hh}:${mm} 进入，尚未出场）。请选择改名合并或确认重复进场`,
        entry: existing,
      });
    }

    const now = Date.now();
    const durationMin = Math.round(durationMinutes({ ...calcParam, pressureMpa: p, cylinderVolL: vol || calcParam.cylinderVolL }));
    const entry = db.createEntry({
      id: crypto.randomUUID(),
      scene,
      name: cleanName,
      pressureMpa: p,
      durationMin,
      entryAtMs: now,
      exitAtMs: exitAtMs({ ...calcParam, pressureMpa: p, entryAtMs: now, cylinderVolL: vol || calcParam.cylinderVolL }),
      source,
      rawText: raw_text,
    });
    logOp(req, 'info', 'entry_created', '登记进场成功', {
      entryId: entry.id,
      name: cleanName,
      pressureMpa: p,
      volumeL: vol || calcParam.cylinderVolL,
      consumptionLpm: consumption,
      durationMin,
      force,
      rawText: raw_text,
    });
    res.status(201).json(entry);
  } catch (e) {
    logOp(req, 'error', 'entry_err', `登记进场失败: ${e.message || e}`);
    next(e);
  }
});

// 在场记录改名/复核压力（合并场景：保留原记录，不产生重复计数）
app.patch('/api/entries/:id', (req, res, next) => {
  try {
    const entry = db.getEntry(req.params.id);
    if (!entry) return res.status(404).json({ error: '记录不存在' });
    const { name, pressure_mpa, consumption_lpm } = req.body || {};
    const newName = name != null ? String(name).trim() : null;
    if (name != null && !newName) return res.status(400).json({ error: '姓名不能为空' });
    let p = null;
    if (pressure_mpa != null) {
      p = Number(pressure_mpa);
      if (!(p > 0) || p > 40) return res.status(400).json({ error: '压力数值异常' });
    }
    let consumption = CFG.calc.consumptionLpm;
    if (consumption_lpm != null && consumption_lpm !== '') {
      consumption = Number(consumption_lpm);
      if (!(consumption > 0) || consumption > 300) return res.status(400).json({ error: '消耗率数值异常' });
    }
    const now = Date.now();
    // 动态耗气率：每次压力报数存采样，与上次报数差分实测消耗率
    let actualLpm = null;
    if (p != null) {
      const prev = db.lastPressureSample(entry.id);
      if (prev && prev.reported_at < now) {
        actualLpm = measuredConsumptionLpm({
          cylinderVolL: CFG.calc.cylinderVolL,
          prevPressureMpa: prev.pressure_mpa,
          newPressureMpa: p,
          intervalMs: now - prev.reported_at,
        });
      }
      db.addPressureSample({ entryId: entry.id, scene: entry.scene, name: newName || entry.name, pressureMpa: p, reportedAtMs: now });
    }
    const effConsumption = actualLpm ?? consumption;
    const calcParam = { ...CFG.calc, consumptionLpm: effConsumption };
    const updated = db.updateEntry(entry.id, {
      name: newName,
      pressureMpa: p,
      // 压力视为现场复核读数，从此刻起按实测（无实测用默认）消耗率重新倒计时
      durationMin: p != null ? Math.round(durationMinutes({ ...calcParam, pressureMpa: p })) : null,
      exitAtMs: p != null ? exitAtMs({ ...calcParam, pressureMpa: p, entryAtMs: now }) : null,
      consumptionActualLpm: actualLpm,
    });
    logOp(req, 'info', 'entry_pressure_recheck', '压力报数复核', {
      entryId: entry.id,
      name: updated.name,
      pressureMpa: p,
      actualConsumptionLpm: actualLpm,
      durationMin: updated.duration_min,
    });
    res.json(updated);
  } catch (e) {
    next(e);
  }
});

app.post('/api/entries/:id/exit', (req, res, next) => {
  try {
    const entry = db.getEntry(req.params.id);
    if (!entry) {
      logOp(req, 'warn', 'exit_missing', `登记出火场失败：记录不存在`, { id: req.params.id });
      return res.status(404).json({ error: '记录不存在' });
    }
    logOp(req, 'info', 'entry_exited', `登记出火场`, { entryId: entry.id, name: entry.name });
    res.json(db.markExited(entry.id, Date.now()));
  } catch (e) {
    logOp(req, 'error', 'exit_err', `登记出火场失败: ${e.message || e}`);
    next(e);
  }
});

app.get('/api/firefighters', (req, res) => res.json(db.listFirefighters()));
app.post('/api/firefighters', (req, res, next) => {
  try {
    const { name } = req.body || {};
    if (!name || !String(name).trim()) return res.status(400).json({ error: '缺少姓名' });
    const id = crypto.randomUUID();
    try {
      res.status(201).json(db.addFirefighter(id, String(name).trim()));
    } catch (e) {
      if (String(e.message).includes('UNIQUE')) return res.status(409).json({ error: '该姓名已存在' });
      throw e;
    }
  } catch (e) {
    next(e);
  }
});
app.delete('/api/firefighters/:id', (req, res) => {
  db.removeFirefighter(req.params.id);
  res.json({ ok: true });
});

app.get('/api/hotwords', (req, res) => res.json(db.listHotwords()));
app.post('/api/hotwords', (req, res, next) => {
  try {
    const { word } = req.body || {};
    if (!word || !String(word).trim()) return res.status(400).json({ error: '缺少词条' });
    const id = crypto.randomUUID();
    try {
      res.status(201).json(db.addHotword(id, String(word).trim()));
    } catch (e) {
      if (String(e.message).includes('UNIQUE')) return res.status(409).json({ error: '该词条已存在' });
      throw e;
    }
  } catch (e) {
    next(e);
  }
});
app.delete('/api/hotwords/:id', (req, res) => {
  db.removeHotword(req.params.id);
  res.json({ ok: true });
});

// 火场随手记：按场景隔离，App 语音/手动记录时间节点，供复盘（新→旧）
const NOTE_CATEGORIES = ['部署', '搜救', '出水', '撤离', '异常', '其他'];
function cleanCategory(c) {
  const v = String(c || '').trim();
  return NOTE_CATEGORIES.includes(v) ? v : '其他';
}

app.get('/api/notes', (req, res) => {
  res.json(
    db.listNotes({
      scene: sceneKey(req),
      limit: Number(req.query.limit) || 500,
    })
  );
});

app.post('/api/notes', (req, res, next) => {
  try {
    const { text, category } = req.body || {};
    const clean = String(text || '').trim();
    if (!clean) return res.status(400).json({ error: '缺少日志内容' });
    if (clean.length > 2000) return res.status(400).json({ error: '日志内容过长（最多 2000 字）' });
    const note = db.createNote({
      id: crypto.randomUUID(),
      scene: sceneKey(req),
      text: clean,
      category: cleanCategory(category),
    });
    logOp(req, 'info', 'note_created', '已记录随手记', { noteId: note.id, category: note.category, text: clean.slice(0, 100) });
    res.status(201).json(note);
  } catch (e) {
    logOp(req, 'error', 'note_err', `记录随手记失败: ${e.message || e}`);
    next(e);
  }
});

app.patch('/api/notes/:id', (req, res, next) => {
  try {
    const note = db.getNote(req.params.id);
    if (!note) return res.status(404).json({ error: '日志不存在' });
    const { text, category } = req.body || {};
    const clean = text != null ? String(text).trim() : null;
    if (text != null && !clean) return res.status(400).json({ error: '日志内容不能为空' });
    if (clean != null && clean.length > 2000) return res.status(400).json({ error: '日志内容过长（最多 2000 字）' });
    const updated = db.updateNote(note.id, {
      text: clean,
      category: category != null ? cleanCategory(category) : null,
    });
    logOp(req, 'info', 'note_updated', '已编辑随手记', { noteId: note.id, category: updated.category });
    res.json(updated);
  } catch (e) {
    logOp(req, 'error', 'note_err', `编辑随手记失败: ${e.message || e}`);
    next(e);
  }
});

app.delete('/api/notes/:id', (req, res, next) => {
  try {
    const n = db.deleteNote(req.params.id);
    if (n === 0) return res.status(404).json({ error: '日志不存在' });
    logOp(req, 'info', 'note_deleted', '已删除随手记', { noteId: req.params.id });
    res.json({ ok: true });
  } catch (e) {
    logOp(req, 'error', 'note_err', `删除随手记失败: ${e.message || e}`);
    next(e);
  }
});

// 用户设置云同步：以 X-Device-Id（Android ID 加盐哈希）识别用户，按场景隔离
// GET 拉取；PUT 全量覆盖。仅接受白名单键，值限 number/boolean
app.get('/api/user-settings', (req, res) => {
  const user = deviceKey(req);
  if (!user) return res.status(400).json({ error: '缺少 X-Device-Id 请求头' });
  const { settings, updatedAt } = db.getUserSettings(user, sceneKey(req));
  res.json({ settings, updated_at: updatedAt });
});

app.put('/api/user-settings', (req, res, next) => {
  try {
    const user = deviceKey(req);
    if (!user) return res.status(400).json({ error: '缺少 X-Device-Id 请求头' });
    const { settings } = req.body || {};
    if (!settings || typeof settings !== 'object' || Array.isArray(settings)) {
      return res.status(400).json({ error: '缺少 settings 对象' });
    }
    const clean = {};
    for (const key of USER_SETTING_KEYS) {
      const v = settings[key];
      if (v === undefined) continue;
      if (typeof v === 'number' && Number.isFinite(v)) {
        clean[key] = v;
      } else if (typeof v === 'boolean') {
        clean[key] = v;
      }
    }
    if (Object.keys(clean).length === 0) return res.status(400).json({ error: '没有可同步的合法设置项' });
    const { settings: saved, updatedAt } = db.saveUserSettings(user, sceneKey(req), clean);
    logOp(req, 'info', 'user_settings_saved', '用户设置已同步', { keys: Object.keys(clean) });
    res.json({ settings: saved, updated_at: updatedAt });
  } catch (e) {
    next(e);
  }
});

// 操作日志：App 批量上报（与场景码/令牌同规则鉴权）
app.post('/api/logs', (req, res, next) => {
  try {
    const { logs } = req.body || {};
    if (!Array.isArray(logs)) return res.status(400).json({ error: '缺少 logs 数组' });
    if (logs.length === 0) return res.json({ ok: true, count: 0 });
    if (logs.length > 100) return res.status(400).json({ error: '单次最多上报 100 条日志' });
    const scene = sceneKey(req);
    const device = deviceKey(req);
    const levels = ['info', 'warn', 'error'];
    let inserted = 0;
    for (const item of logs) {
      if (!item || typeof item !== 'object') continue;
      const stage = String(item.stage || '').slice(0, 64);
      if (!stage) continue;
      const level = levels.includes(item.level) ? item.level : 'info';
      const data = item.data;
      db.addLog({
        scene,
        device: device || String(item.device || '').slice(0, 64) || null,
        opId: String(item.op_id || '').slice(0, 64) || null,
        level,
        stage,
        msg: item.msg == null ? '' : String(item.msg),
        data: data === undefined || data === null ? null : JSON.stringify(data).length > 8192 ? { truncated: true, data: JSON.stringify(data).slice(0, 8192) } : data,
      });
      inserted++;
    }
    res.json({ ok: true, count: inserted });
  } catch (e) {
    next(e);
  }
});

// 操作日志查询/清空（调试用：可按 op_id/device 过滤，新→旧）
app.get('/api/logs', (req, res) => {
  res.json(
    db.listLogs({
      scene: sceneKey(req),
      limit: Number(req.query.limit) || 200,
      opId: String(req.query.op_id || ''),
      device: String(req.query.device || ''),
    })
  );
});

app.delete('/api/logs', (req, res) => {
  const n = db.clearLogs({
    scene: sceneKey(req),
    opId: String(req.query.op_id || '') || null,
  });
  res.json({ ok: true, deleted: n });
});

app.use((err, req, res, next) => {
  logger.error(req.method, req.path, err.stack || err);
  if (req.headers['x-op-id']) {
    logOp(req, 'error', 'http_err', `${req.method} ${req.path} 失败: ${err.message || err}`);
  }
  const status = err.status || 500;
  res.status(status).json({ error: status === 500 ? '服务器内部错误' : err.message });
});

// 仅作为入口运行时监听端口；被测试 require 时导出 app
if (require.main === module) {
  const purgeDays = Number(process.env.PURGE_EXITED_DAYS || 7);
  const logPurgeDays = Number(process.env.LOG_PURGE_DAYS || 30);
  const doPurge = () => {
    try {
      const n = db.purgeOldExited(purgeDays);
      if (n > 0) logger.info(`已清理 ${n} 条超过 ${purgeDays} 天的出场记录`);
    } catch (e) {
      logger.error('清理旧记录失败', e.message);
    }
    try {
      const n = db.purgeOldLogs(logPurgeDays);
      if (n > 0) logger.info(`已清理 ${n} 条超过 ${logPurgeDays} 天的操作日志`);
    } catch (e) {
      logger.error('清理旧日志失败', e.message);
    }
    try {
      const n = db.purgeOldNotes(logPurgeDays);
      if (n > 0) logger.info(`已清理 ${n} 条超过 ${logPurgeDays} 天的随手记`);
    } catch (e) {
      logger.error('清理旧随手记失败', e.message);
    }
  };
  doPurge();
  setInterval(doPurge, 24 * 3600 * 1000);

  app.listen(PORT, () => {
    logger.info(`WatchDog 后端已启动: http://0.0.0.0:${PORT}`);
    logger.info(`ASR 配置: ${CFG.asr.appId ? '已配置' : '未配置 (VOLC_APP_KEY)'}`);
    logger.info(`LLM 配置: ${CFG.llm.apiKey ? '已配置' : '未配置 (DEEPSEEK_API_KEY)'}`);
  });
}

module.exports = app;
