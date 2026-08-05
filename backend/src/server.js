const express = require('express');
const crypto = require('crypto');
const { transcribe } = require('./asr');
const { parseTextWithDeepSeek } = require('./parse');
const { durationMinutes, exitAtMs } = require('./calc');
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
  res.set('Access-Control-Allow-Headers', 'Content-Type, X-Scene-Code, X-Api-Token');
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

function hotwordList(scene) {
  const firefighters = db.listFirefighters(scene).map((f) => f.name);
  const terms = db.listHotwords(scene).map((h) => h.word);
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
      const text = await transcribe({
        appId: CFG.asr.appId,
        accessToken: CFG.asr.accessToken,
        resourceId: CFG.asr.resourceId,
        audioBuffer: audio,
        format,
        hotwords,
      });
      res.json({ text, hotwordCount: hotwords.length });
    } catch (e) {
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
    const scene = sceneKey(req);
    const firefighters = db.listFirefighters(scene).map((f) => f.name);
    const hotwords = db.listHotwords(scene).map((h) => h.word);
    const parsed = await parseTextWithDeepSeek({
      apiKey: CFG.llm.apiKey,
      baseUrl: CFG.llm.baseUrl,
      model: CFG.llm.model,
      text: String(text).trim(),
      firefighters,
      hotwords,
    });
    res.json(parsed);
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
    const { name, pressure_mpa, source = 'voice', raw_text = null, force = false } = req.body || {};
    const scene = sceneKey(req);
    const cleanName = String(name || '').trim();
    if (!cleanName) return res.status(400).json({ error: '缺少姓名' });
    if (pressure_mpa == null) return res.status(400).json({ error: '缺少气瓶压力，请确认压力后再登记' });
    const p = Number(pressure_mpa);
    if (!(p > 0) || p > 40) return res.status(400).json({ error: '压力数值异常' });

    // 同名在场记录：防止同一人重复登记（改名合并走 PATCH，重复进场须 force）
    const existing = db.findActiveByName(scene, cleanName);
    if (existing && !force) {
      const at = new Date(existing.entry_at);
      const hh = String(at.getHours()).padStart(2, '0');
      const mm = String(at.getMinutes()).padStart(2, '0');
      return res.status(409).json({
        error: `「${existing.name}」已在火场内（${hh}:${mm} 进入，尚未出场）。请选择改名合并或确认重复进场`,
        entry: existing,
      });
    }

    const now = Date.now();
    const durationMin = Math.round(durationMinutes({ ...CFG.calc, pressureMpa: p }));
    const entry = db.createEntry({
      id: crypto.randomUUID(),
      scene,
      name: cleanName,
      pressureMpa: p,
      durationMin,
      entryAtMs: now,
      exitAtMs: exitAtMs({ ...CFG.calc, pressureMpa: p, entryAtMs: now }),
      source,
      rawText: raw_text,
    });
    res.status(201).json(entry);
  } catch (e) {
    next(e);
  }
});

// 在场记录改名/复核压力（合并场景：保留原记录，不产生重复计数）
app.patch('/api/entries/:id', (req, res, next) => {
  try {
    const entry = db.getEntry(req.params.id);
    if (!entry) return res.status(404).json({ error: '记录不存在' });
    const { name, pressure_mpa } = req.body || {};
    const newName = name != null ? String(name).trim() : null;
    if (name != null && !newName) return res.status(400).json({ error: '姓名不能为空' });
    let p = null;
    if (pressure_mpa != null) {
      p = Number(pressure_mpa);
      if (!(p > 0) || p > 40) return res.status(400).json({ error: '压力数值异常' });
    }
    const now = Date.now();
    const updated = db.updateEntry(entry.id, {
      name: newName,
      pressureMpa: p,
      // 压力视为现场复核读数，从此刻起重新倒计时
      durationMin: p != null ? Math.round(durationMinutes({ ...CFG.calc, pressureMpa: p })) : null,
      exitAtMs: p != null ? exitAtMs({ ...CFG.calc, pressureMpa: p, entryAtMs: now }) : null,
    });
    res.json(updated);
  } catch (e) {
    next(e);
  }
});

app.post('/api/entries/:id/exit', (req, res, next) => {
  try {
    const entry = db.getEntry(req.params.id);
    if (!entry) return res.status(404).json({ error: '记录不存在' });
    res.json(db.markExited(entry.id, Date.now()));
  } catch (e) {
    next(e);
  }
});

app.get('/api/firefighters', (req, res) => res.json(db.listFirefighters(sceneKey(req))));
app.post('/api/firefighters', (req, res, next) => {
  try {
    const { name } = req.body || {};
    if (!name || !String(name).trim()) return res.status(400).json({ error: '缺少姓名' });
    const id = crypto.randomUUID();
    try {
      res.status(201).json(db.addFirefighter(id, String(name).trim(), sceneKey(req)));
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

app.get('/api/hotwords', (req, res) => res.json(db.listHotwords(sceneKey(req))));
app.post('/api/hotwords', (req, res, next) => {
  try {
    const { word } = req.body || {};
    if (!word || !String(word).trim()) return res.status(400).json({ error: '缺少词条' });
    const id = crypto.randomUUID();
    try {
      res.status(201).json(db.addHotword(id, String(word).trim(), sceneKey(req)));
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

app.use((err, req, res, next) => {
  logger.error(req.method, req.path, err.stack || err);
  const status = err.status || 500;
  res.status(status).json({ error: status === 500 ? '服务器内部错误' : err.message });
});

// 仅作为入口运行时监听端口；被测试 require 时导出 app
if (require.main === module) {
  const purgeDays = Number(process.env.PURGE_EXITED_DAYS || 7);
  const doPurge = () => {
    try {
      const n = db.purgeOldExited(purgeDays);
      if (n > 0) logger.info(`已清理 ${n} 条超过 ${purgeDays} 天的出场记录`);
    } catch (e) {
      logger.error('清理旧记录失败', e.message);
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
