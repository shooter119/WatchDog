const { randomUUID } = require('node:crypto');

const ENV_ID = process.env.CLOUDBASE_ENV_ID || process.env.CLOUDBASE_ENV || '';
const API_KEY = process.env.CLOUDBASE_API_KEY || process.env.CLOUDBASE_APIKEY || '';
const PG_ENDPOINT = process.env.CLOUDBASE_PG_ENDPOINT ||
  (ENV_ID ? `https://${ENV_ID}.api.tcloudbasegateway.com/v1/rdb/exec-pgsql` : '');

class CloudBaseStatement {
  constructor(database, sql) {
    this.database = database;
    this.sql = sql;
  }

  all(...params) {
    return this.database.query(this.sql, params).then((result) => result.rows);
  }

  get(...params) {
    return this.database.query(this.sql, params).then((result) => result.rows[0]);
  }

  run(...params) {
    return this.database.query(this.sql, params).then((result) => ({
      changes: result.rowCount,
      lastInsertRowid: result.rows[0]?.id,
    }));
  }
}

class CloudBaseDatabase {
  prepare(sql) {
    return new CloudBaseStatement(this, sql);
  }

  async exec(sql) {
    // exec-pgsql 的 session mode 不支持一次请求提交多条 SQL；必须逐条
    // 执行，query() 内部会在连接池暂满时等待后重试。
    const statements = String(sql)
      .split(/;\s*(?=(?:CREATE|ALTER|DROP|INSERT|UPDATE|DELETE|COMMENT|GRANT|REVOKE)\b)/i)
      .map((statement) => statement.trim())
      .filter(Boolean);
    for (const statement of statements) await this.query(statement, []);
  }

  async query(sql, params = [], { role = 'cloudbase_postgres' } = {}) {
    if (!PG_ENDPOINT || !API_KEY) {
      throw new Error('CloudBase PostgreSQL 未配置 CLOUDBASE_ENV_ID/CLOUDBASE_API_KEY');
    }
    // PostgreSQL 使用 $1、$2……参数占位符；当前业务 SQL 的 ? 均为参数占位符。
    let index = 0;
    const statement = String(sql).replace(/\?/g, () => `$${++index}`);
    const executableSql = inlinePgParams(statement, params);
    const maxSessionRetries = Math.max(0, Number(process.env.CLOUDBASE_PG_MAX_SESSION_RETRIES || 5));
    for (let attempt = 0; ; attempt++) {
      const response = await fetch(PG_ENDPOINT, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${API_KEY}`,
          'Content-Type': 'application/json',
        },
        // CloudBase exec-pgsql 当前只接受可直接执行的 SQL，不处理 params 字段。
        body: JSON.stringify({ sql: executableSql, role }),
        signal: AbortSignal.timeout(Number(process.env.CLOUDBASE_PG_TIMEOUT_MS || 15000)),
      });
      const bodyText = await response.text();
      let body;
      try { body = bodyText ? JSON.parse(bodyText) : null; } catch { body = bodyText; }
      if (response.ok) return normalizeQueryResult(body);

      const detail = typeof body === 'string' ? body : JSON.stringify(body);
      if (detail.includes('EMAXCONNSESSION') && attempt < maxSessionRetries) {
        const baseDelay = Math.max(1000, Number(process.env.CLOUDBASE_PG_RETRY_DELAY_MS || 5000));
        const delay = Math.min(baseDelay * 2 ** attempt, 30000);
        await new Promise((resolve) => setTimeout(resolve, delay));
        continue;
      }
      const error = new Error(`CloudBase PostgreSQL ${response.status}: ${detail.slice(0, 500)}`);
      error.status = response.status;
      throw error;
    }
  }
}

function inlinePgParams(statement, params) {
  return String(statement).replace(/\$(\d+)/g, (placeholder, indexText) => {
    const index = Number(indexText) - 1;
    return index >= 0 && index < params.length ? toPgLiteral(params[index]) : placeholder;
  });
}

function toPgLiteral(value) {
  if (value === null || value === undefined) return 'NULL';
  if (typeof value === 'boolean') return value ? 'TRUE' : 'FALSE';
  if (typeof value === 'number' && Number.isFinite(value)) return String(value);
  const escaped = String(value).replace(/'/g, "''");
  return `'${escaped}'`;
}

function normalizeQueryResult(body) {
  // 兼容 CloudBase HTTP API 当前返回的 rows/columns 形式及直接 JSON 数组形式。
  if (Array.isArray(body)) {
    return { rows: body, rowCount: body.length };
  }
  if (body && Array.isArray(body.rows)) {
    const columns = Array.isArray(body.columns) ? body.columns : [];
    const rows = body.rows.map((row) => {
      if (!Array.isArray(row)) return row;
      return Object.fromEntries(columns.map((column, index) => [column, row[index] ?? null]));
    });
    return { rows, rowCount: Number(body.rowCount ?? body.affectedRows ?? rows.length) };
  }
  if (body && Array.isArray(body.data)) {
    return { rows: body.data, rowCount: body.data.length };
  }
  return {
    rows: [],
    rowCount: Number(body?.rowCount ?? body?.affectedRows ?? body?.AffectedRows ?? 0),
  };
}

const db = new CloudBaseDatabase();

function incidentNumberFor(timestamp) {
  const date = new Date(timestamp);
  return date.getFullYear() + '年' + (date.getMonth() + 1) + '月' + date.getDate() + '日' +
    String(date.getHours()).padStart(2, '0') + '时' + String(date.getMinutes()).padStart(2, '0') + '分';
}

async function uniqueIncidentNumber(timestamp) {
  const base = incidentNumberFor(timestamp);
  let sequence = 1;
  let candidate = base + sequence + '#警情';
  while (await db.prepare('SELECT 1 FROM incidents WHERE number = ?').get(candidate)) {
    sequence++;
    candidate = base + sequence + '#警情';
  }
  return candidate;
}

function parseEventPayload(value) {
  if (value == null || value === '') return null;
  try { return typeof value === 'string' ? JSON.parse(value) : value; } catch { return value; }
}

const DEFAULT_HOTWORDS = ['龙游大队', '龙游', '龙翔路站', '永安路站', '兴园站', '头车', '两车', '三车', '四车', '内攻', '搜救'];
const DEFAULT_FIREFIGHTERS = [
  '李翔', '盛承华', '楼松超', '徐向相', '柯峰', '祝彪',
  '陆河圣', '洪辰', '沈松鹏', '金志明', '陈俊鹏', '叶华杰', '杨熙豪', '施豪杰', '袁超', '马李臣',
  '邢中本', '何家琦', '余贤耀', '徐莘焕', '杨小杰', '祝徐迁', '方文斌', '徐昊扬', '郑丽文', '郑怡',
  '郑涛', '占鑫涛', '叶健智', '胡海龙', '伊余健', '曹建罡', '马鑫', '徐康', '张烜烨', '李微',
  '储嘉俊', '毛伟', '陈俊安', '赵建平', '吴拥军', '路康清', '毕灵珂', '刘羽杰', '陈鑫', '廖淑明', '毛泽旭',
  '林成成', '程晓波', '郭逸', '蓝程雄', '成帅', '姚肖江', '毕文龙', '周志峰', '吕文建', '刘林辉',
  '齐征臣', '严仕华', '袁友顺', '劳凯董', '方罗进', '马俊', '刘振坤', '贺智成', '丁以强', '易子云',
  '李瑞', '宋宇', '宁成鑫', '甲巴有拉', '吉布小夫', '方梦龙',
  '游方远', '巫垚东', '万自良', '戴晓明', '李志鹏', '徐小龙', '吴鹏晖', '叶程刚', '陈嘉豪', '姚顺',
  '贺官', '孙国彬', '吴志云', '陈子俊', '何金伟', '周子俊', '何哲锴', '徐刚', '姜俊翰', '文闻',
  '张文浩', '宋博韬',
];

const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS entries (
  id TEXT PRIMARY KEY, scene TEXT NOT NULL DEFAULT 'default', name TEXT NOT NULL,
  pressure_mpa DOUBLE PRECISION, duration_min INTEGER NOT NULL DEFAULT 0,
  entry_at BIGINT NOT NULL, exit_at BIGINT NOT NULL, exited_at BIGINT,
  source TEXT NOT NULL DEFAULT 'voice', raw_text TEXT, created_at BIGINT NOT NULL,
  consumption_actual_lpm DOUBLE PRECISION
);
CREATE TABLE IF NOT EXISTS firefighters (id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, created_at BIGINT NOT NULL);
CREATE TABLE IF NOT EXISTS hotwords (id TEXT PRIMARY KEY, word TEXT NOT NULL UNIQUE, created_at BIGINT NOT NULL);
CREATE TABLE IF NOT EXISTS logs (
  id TEXT PRIMARY KEY, scene TEXT NOT NULL DEFAULT 'default', device TEXT, op_id TEXT,
  level TEXT NOT NULL DEFAULT 'info', stage TEXT NOT NULL, msg TEXT NOT NULL DEFAULT '',
  data TEXT, created_at BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS user_settings (
  user_id TEXT NOT NULL, scene TEXT NOT NULL DEFAULT 'default', key TEXT NOT NULL,
  value TEXT NOT NULL, updated_at BIGINT NOT NULL, PRIMARY KEY (user_id, scene, key)
);
CREATE TABLE IF NOT EXISTS pressure_samples (
  id BIGSERIAL PRIMARY KEY, entry_id TEXT NOT NULL, scene TEXT NOT NULL DEFAULT 'default',
  name TEXT NOT NULL, pressure_mpa DOUBLE PRECISION NOT NULL, reported_at BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS notes (
  id TEXT PRIMARY KEY, scene TEXT NOT NULL DEFAULT 'default', text TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT '其他', author TEXT NOT NULL DEFAULT '',
  created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS chat_messages (
  id TEXT PRIMARY KEY, scene TEXT NOT NULL DEFAULT 'default', role TEXT NOT NULL,
  content TEXT NOT NULL, created_at BIGINT NOT NULL
);
CREATE TABLE IF NOT EXISTS incidents (
  id TEXT PRIMARY KEY, number TEXT NOT NULL UNIQUE, title TEXT, suggested_title TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'archived')),
  created_at BIGINT NOT NULL, last_activity_at BIGINT NOT NULL, archived_at BIGINT,
  archived_by TEXT, auto_archived INTEGER NOT NULL DEFAULT 0,
  unresolved_active_count INTEGER NOT NULL DEFAULT 0, created_by TEXT, version INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS incident_events (
  id TEXT PRIMARY KEY, incident_id TEXT NOT NULL, type TEXT NOT NULL, occurred_at BIGINT NOT NULL,
  recorded_at BIGINT NOT NULL, actor_device_id TEXT, actor_name TEXT,
  source TEXT NOT NULL DEFAULT 'online', client_op_id TEXT, payload TEXT, revision_of TEXT, voided_at BIGINT
);
CREATE TABLE IF NOT EXISTS stations (
  id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, normalized_name TEXT NOT NULL UNIQUE,
  created_at BIGINT NOT NULL, created_by TEXT
);
CREATE TABLE IF NOT EXISTS incident_forces (
  id TEXT PRIMARY KEY, incident_id TEXT NOT NULL, station_id TEXT, station_name TEXT NOT NULL,
  vehicle_count INTEGER NOT NULL DEFAULT 0, personnel_count INTEGER NOT NULL DEFAULT 0,
  created_at BIGINT NOT NULL, updated_at BIGINT NOT NULL, version INTEGER NOT NULL DEFAULT 1,
  UNIQUE (incident_id, station_name)
);
CREATE TABLE IF NOT EXISTS device_profiles (device_id TEXT PRIMARY KEY, real_name TEXT NOT NULL DEFAULT '', updated_at BIGINT NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS idx_incident_events_op ON incident_events(client_op_id) WHERE client_op_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_entries_entry_at ON entries(entry_at);
CREATE INDEX IF NOT EXISTS idx_entries_scene ON entries(scene, entry_at);
CREATE INDEX IF NOT EXISTS idx_logs_scene ON logs(scene, created_at);
CREATE INDEX IF NOT EXISTS idx_logs_op ON logs(op_id);
CREATE INDEX IF NOT EXISTS idx_samples_entry ON pressure_samples(entry_id, reported_at);
CREATE INDEX IF NOT EXISTS idx_notes_scene ON notes(scene, created_at);
CREATE INDEX IF NOT EXISTS idx_chat_scene ON chat_messages(scene, created_at);
CREATE INDEX IF NOT EXISTS idx_incidents_status_activity ON incidents(status, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_incidents_archived_at ON incidents(archived_at DESC);
CREATE INDEX IF NOT EXISTS idx_incident_events_time ON incident_events(incident_id, occurred_at DESC, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_incident_forces_incident ON incident_forces(incident_id, station_name);
`;

async function initialize() {
  if (process.env.CLOUDBASE_SKIP_SCHEMA !== '1') {
    await db.exec(SCHEMA_SQL);
  }
  const hotwordCount = await db.prepare('SELECT COUNT(*) AS n FROM hotwords').get();
  if (Number(hotwordCount?.n || 0) === 0) {
    const params = [];
    const values = DEFAULT_HOTWORDS.map((word, index) => {
      params.push(randomUUID(), word, Date.now() + index);
      const offset = params.length - 2;
      return `($${offset}, $${offset + 1}, $${offset + 2})`;
    }).join(', ');
    await db.query(
      `INSERT INTO hotwords (id, word, created_at) VALUES ${values} ON CONFLICT DO NOTHING`,
      params,
    );
  }
  const firefighterCount = await db.prepare('SELECT COUNT(*) AS n FROM firefighters').get();
  if (Number(firefighterCount?.n || 0) === 0) {
    const params = [];
    const values = DEFAULT_FIREFIGHTERS.map((name, index) => {
      params.push(randomUUID(), name, Date.now() + index);
      const offset = params.length - 2;
      return `($${offset}, $${offset + 1}, $${offset + 2})`;
    }).join(', ');
    await db.query(
      `INSERT INTO firefighters (id, name, created_at) VALUES ${values} ON CONFLICT DO NOTHING`,
      params,
    );
  }
}

const ready = initialize().then(async () => {
  await backfillIncidentEvents();
  await dedupeLegacyIncidentEvents();
});

async function listEntries({ activeOnly = false, limit = 500, scene = 'default' } = {}) {
  let sql = 'SELECT * FROM entries WHERE scene = ?';
  if (activeOnly) sql += ' AND exited_at IS NULL';
  sql += ' ORDER BY entry_at DESC LIMIT ?';
  return await db.prepare(sql).all(scene, limit);
}

async function getEntry(id) {
  return await db.prepare('SELECT * FROM entries WHERE id = ?').get(id);
}

async function createEntry({ id, scene = 'default', name, pressureMpa, durationMin, entryAtMs, exitAtMs, source = 'voice', rawText = null }) {
  await db.prepare(
    'INSERT INTO entries (id, scene, name, pressure_mpa, duration_min, entry_at, exit_at, source, raw_text, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
  ).run(id, scene, name, pressureMpa, durationMin, entryAtMs, exitAtMs, source, rawText, Date.now());
  if (pressureMpa != null) {
    await addPressureSample({ entryId: id, scene, name, pressureMpa, reportedAtMs: entryAtMs });
  }
  return getEntry(id);
}

async function markExited(id, exitedAtMs) {
  await db.prepare('UPDATE entries SET exited_at = ? WHERE id = ?').run(exitedAtMs, id);
  return getEntry(id);
}

/** 同场景同名且未出场的在场记录（用于防重复进场） */
async function findActiveByName(scene, name) {
  return db
    .prepare('SELECT * FROM entries WHERE scene = ? AND name = ? AND exited_at IS NULL ORDER BY entry_at ASC LIMIT 1')
    .get(scene, name);
}

/** 部分更新在场记录：传 null 的字段保持不变 */
async function updateEntry(id, { name, pressureMpa, durationMin, exitAtMs, consumptionActualLpm }) {
  await db.prepare(
    'UPDATE entries SET name = COALESCE(?, name), pressure_mpa = COALESCE(?, pressure_mpa), duration_min = COALESCE(?, duration_min), exit_at = COALESCE(?, exit_at), consumption_actual_lpm = COALESCE(?, consumption_actual_lpm) WHERE id = ?'
  ).run(name ?? null, pressureMpa ?? null, durationMin ?? null, exitAtMs ?? null, consumptionActualLpm ?? null, id);
  return getEntry(id);
}

/** 记录一次压力报数（进场/复核均写采样，用于动态耗气率差分） */
async function addPressureSample({ entryId, scene = 'default', name, pressureMpa, reportedAtMs }) {
  await db.prepare(
    'INSERT INTO pressure_samples (entry_id, scene, name, pressure_mpa, reported_at) VALUES (?, ?, ?, ?, ?)'
  ).run(entryId, scene, name, pressureMpa, reportedAtMs);
}

/** 最近一次压力报数（无则 null） */
async function lastPressureSample(entryId) {
  return db
    .prepare('SELECT * FROM pressure_samples WHERE entry_id = ? ORDER BY reported_at DESC LIMIT 1')
    .get(entryId);
}

/** 某条记录的完整报数历史（新→旧） */
async function listPressureSamples(entryId, { limit = 20 } = {}) {
  return db
    .prepare('SELECT * FROM pressure_samples WHERE entry_id = ? ORDER BY reported_at DESC LIMIT ?')
    .all(entryId, limit);
}

/** 消防员名单全局共享，不区分场景 */
async function listFirefighters() {
  return await db.prepare('SELECT id, name FROM firefighters ORDER BY created_at ASC').all();
}

async function addFirefighter(id, name) {
  await db.prepare('INSERT INTO firefighters (id, name, created_at) VALUES (?, ?, ?)').run(id, name, Date.now());
  return await db.prepare('SELECT id, name FROM firefighters WHERE id = ?').get(id);
}

async function removeFirefighter(id) {
  await db.prepare('DELETE FROM firefighters WHERE id = ?').run(id);
}

/** 热词全局共享，不区分场景 */
async function listHotwords() {
  return await db.prepare('SELECT id, word FROM hotwords ORDER BY created_at ASC').all();
}

async function addHotword(id, word) {
  await db.prepare('INSERT INTO hotwords (id, word, created_at) VALUES (?, ?, ?)').run(id, word, Date.now());
  return await db.prepare('SELECT id, word FROM hotwords WHERE id = ?').get(id);
}

async function removeHotword(id) {
  await db.prepare('DELETE FROM hotwords WHERE id = ?').run(id);
}

/** 清理已出火场超过 days 天的记录（含全部场景），返回删除条数 */
async function purgeOldExited(days = 7) {
  const cutoff = Date.now() - days * 24 * 3600 * 1000;
  const r = await db
    .prepare('DELETE FROM entries WHERE exited_at IS NOT NULL AND exited_at < ?')
    .run(cutoff);
  if (r.changes > 0) {
    // 连带清理已删除记录的压力报数采样
    await db.prepare(
      'DELETE FROM pressure_samples WHERE entry_id NOT IN (SELECT id FROM entries)'
    ).run();
  }
  return r.changes;
}

/** 追加一条操作日志（App 上报或服务端埋点共用） */
async function addLog({ scene = 'default', device = null, opId = null, level = 'info', stage = '', msg = '', data = null }) {
  await db.prepare(
    'INSERT INTO logs (id, scene, device, op_id, level, stage, msg, data, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
  ).run(randomUUID(), scene, device, opId, level, stage, String(msg).slice(0, 2000), data == null ? null : JSON.stringify(data), Date.now());
}

/** 查询操作日志（按场景隔离，可按 op_id/device 过滤，新→旧） */
async function listLogs({ scene = 'default', limit = 200, opId = null, device = null } = {}) {
  let sql = 'SELECT * FROM logs WHERE scene = ?';
  const args = [scene];
  if (opId) {
    sql += ' AND op_id = ?';
    args.push(opId);
  }
  if (device) {
    sql += ' AND device = ?';
    args.push(device);
  }
  sql += ' ORDER BY created_at DESC LIMIT ?';
  args.push(Math.min(Number(limit) || 200, 1000));
  return (await db.prepare(sql).all(...args)).map((r) => {
    let data = null;
    if (r.data) {
      try {
        data = JSON.parse(r.data);
      } catch {
        data = r.data;
      }
    }
    return { ...r, data };
  });
}

/** 清空某场景的日志（可限定 op_id），返回删除条数 */
async function clearLogs({ scene = 'default', opId = null } = {}) {
  if (opId) return (await db.prepare('DELETE FROM logs WHERE scene = ? AND op_id = ?').run(scene, opId)).changes;
  return (await db.prepare('DELETE FROM logs WHERE scene = ?').run(scene)).changes;
}

/** 清理超过 days 天的日志，返回删除条数 */
async function purgeOldLogs(days = 30) {
  const cutoff = Date.now() - days * 24 * 3600 * 1000;
  return (await db.prepare('DELETE FROM logs WHERE created_at < ?').run(cutoff)).changes;
}

/** 火场随手记列表（按场景隔离，新→旧） */
async function listNotes({ scene = 'default', limit = 500 } = {}) {
  return db
    .prepare('SELECT * FROM notes WHERE scene = ? ORDER BY created_at DESC LIMIT ?')
    .all(scene, Math.min(Number(limit) || 500, 2000));
}

async function getNote(id) {
  return await db.prepare('SELECT * FROM notes WHERE id = ?').get(id);
}

async function createNote({ id, scene = 'default', text, category = '其他', author = '' }) {
  const now = Date.now();
  await db.prepare(
    'INSERT INTO notes (id, scene, text, category, author, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)'
  ).run(id, scene, text, category, author, now, now);
  return getNote(id);
}

/** 编辑日志条目：传 null 的字段保持不变 */
async function updateNote(id, { text, category }) {
  await db.prepare(
    'UPDATE notes SET text = COALESCE(?, text), category = COALESCE(?, category), updated_at = ? WHERE id = ?'
  ).run(text ?? null, category ?? null, Date.now(), id);
  return getNote(id);
}

async function deleteNote(id) {
  return (await db.prepare('DELETE FROM notes WHERE id = ?').run(id)).changes;
}

/** 清理超过 days 天的日志条目（含全部场景），返回删除条数 */
async function purgeOldNotes(days = 30) {
  const cutoff = Date.now() - days * 24 * 3600 * 1000;
  return (await db.prepare('DELETE FROM notes WHERE created_at < ?').run(cutoff)).changes;
}

/** 智能体问答消息列表（按场景隔离，旧→新，便于按序恢复上下文） */
async function listChatMessages({ scene = 'default', limit = 100 } = {}) {
  return db
    .prepare('SELECT * FROM chat_messages WHERE scene = ? ORDER BY created_at ASC LIMIT ?')
    .all(scene, Math.min(Number(limit) || 100, 500));
}

async function createChatMessage({ id, scene = 'default', role, content }) {
  const clean = String(content || '').slice(0, 4000);
  await db.prepare(
    'INSERT INTO chat_messages (id, scene, role, content, created_at) VALUES (?, ?, ?, ?, ?)'
  ).run(id, scene, role, clean, Date.now());
  return await db.prepare('SELECT * FROM chat_messages WHERE id = ?').get(id);
}

/** 清空某场景的全部问答记录，返回删除条数 */
async function clearChatMessages(scene = 'default') {
  return (await db.prepare('DELETE FROM chat_messages WHERE scene = ?').run(scene)).changes;
}

/** 清理超过 days 天的问答记录（含全部场景），返回删除条数 */
async function purgeOldChatMessages(days = 30) {
  const cutoff = Date.now() - days * 24 * 3600 * 1000;
  return (await db.prepare('DELETE FROM chat_messages WHERE created_at < ?').run(cutoff)).changes;
}

/**
 * 读取某用户在指定场景下的设置（按用户识别码 + 场景隔离）
 * 返回 { settings: {key: value}, updatedAt: 最近修改时间（无记录为 0） }
 */
async function getUserSettings(userId, scene = 'default') {
  const rows = await db
    .prepare('SELECT key, value, updated_at FROM user_settings WHERE user_id = ? AND scene = ?')
    .all(userId, scene);
  const settings = {};
  let updatedAt = 0;
  for (const r of rows) {
    try {
      settings[r.key] = JSON.parse(r.value);
    } catch {
      settings[r.key] = r.value;
    }
    if (r.updated_at > updatedAt) updatedAt = r.updated_at;
  }
  return { settings, updatedAt };
}

/**
 * 保存某用户在指定场景下的设置（按 key upsert），返回与 getUserSettings 同结构
 */
async function saveUserSettings(userId, scene = 'default', settings = {}) {
  const upsert = await db.prepare(`
    INSERT INTO user_settings (user_id, scene, key, value, updated_at)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(user_id, scene, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
  `);
  const now = Date.now();
  for (const [key, value] of Object.entries(settings)) {
    await upsert.run(userId, scene, String(key).slice(0, 64), JSON.stringify(value), now);
  }
  return getUserSettings(userId, scene);
}

const compatibilityIncidentAliases = new Map();

async function getIncident(id) {
  return await db.prepare('SELECT * FROM incidents WHERE id = ?').get(String(id || ''));
}

async function createIncident({ id = randomUUID(), createdAt = Date.now(), createdBy = null } = {}) {
  const created = Number(createdAt) || Date.now();
  await db.prepare(
    'INSERT INTO incidents (id, number, status, created_at, last_activity_at, created_by) VALUES (?, ?, \'active\', ?, ?, ?)'
  ).run(id, await uniqueIncidentNumber(created), created, created, createdBy);
  return getIncident(id);
}

async function ensureIncidentId(value) {
  const raw = String(value || '').trim();
  if (!raw) throw new Error('缺少警情 ID');
  if (await getIncident(raw)) return raw;
  const byNumber = await db.prepare('SELECT id FROM incidents WHERE number = ?').get(raw);
  if (byNumber) return byNumber.id;
  if (compatibilityIncidentAliases.has(raw)) return compatibilityIncidentAliases.get(raw);
  const incident = await createIncident({ createdBy: 'compatibility' });
  compatibilityIncidentAliases.set(raw, incident.id);
  return incident.id;
}

async function listIncidents(status = null) {
  if (status === 'active') return await db.prepare('SELECT * FROM incidents WHERE status = \'active\' ORDER BY last_activity_at DESC, created_at DESC').all();
  if (status === 'archived') return await db.prepare('SELECT * FROM incidents WHERE status = \'archived\' ORDER BY archived_at DESC, created_at DESC').all();
  return await db.prepare('SELECT * FROM incidents ORDER BY CASE WHEN status = \'active\' THEN 0 ELSE 1 END, COALESCE(archived_at, last_activity_at) DESC, created_at DESC').all();
}

// 只把通过新建接口产生过 incident_created 事件的记录作为建档冷却依据，
// 避免维护迁移或单元测试直接写入的兼容警情阻塞真实用户建档。
async function findRecentActiveIncident(createdAfter) {
  return await db.prepare(
    'SELECT i.* FROM incidents i WHERE i.status = \'active\' AND i.created_at >= ? ' +
      'AND EXISTS (SELECT 1 FROM incident_events e WHERE e.incident_id = i.id AND e.type = \'incident_created\') ' +
      'ORDER BY i.created_at DESC LIMIT 1'
  ).get(Number(createdAfter) || 0) || null;
}

async function updateIncidentTitle(id, title, { expectedVersion = null } = {}) {
  const current = await getIncident(id);
  if (!current) return null;
  if (expectedVersion != null && Number(expectedVersion) !== current.version) {
    const error = new Error('警情已被其他用户修改，请刷新后重试');
    error.code = 'VERSION_CONFLICT';
    throw error;
  }
  const clean = title == null ? null : String(title).trim().slice(0, 120) || null;
  await db.prepare('UPDATE incidents SET title = ?, version = version + 1 WHERE id = ?').run(clean, id);
  return getIncident(id);
}

async function setIncidentSuggestedTitle(id, title) {
  const clean = title == null ? null : String(title).trim().slice(0, 120) || null;
  await db.prepare('UPDATE incidents SET suggested_title = ? WHERE id = ?').run(clean, id);
  return getIncident(id);
}

async function touchIncidentActivity(id, at = Date.now()) {
  const current = await getIncident(id);
  if (!current || current.status !== 'active') return current;
  await db.prepare('UPDATE incidents SET last_activity_at = GREATEST(last_activity_at, ?) WHERE id = ?').run(Number(at) || Date.now(), id);
  return getIncident(id);
}

async function unresolvedActiveCount(id) {
  return Number((await db.prepare('SELECT COUNT(*) AS count FROM entries WHERE scene = ? AND exited_at IS NULL').get(id))?.count || 0);
}

async function archiveIncident(id, { archivedBy = null, now = Date.now(), auto = false } = {}) {
  const current = await getIncident(id);
  if (!current) return null;
  if (current.status === 'archived') return current;
  await db.prepare(
    'UPDATE incidents SET status = \'archived\', archived_at = ?, archived_by = ?, auto_archived = ?, unresolved_active_count = ?, version = version + 1 WHERE id = ?'
  ).run(now, archivedBy, auto ? 1 : 0, await unresolvedActiveCount(id), id);
  return getIncident(id);
}

async function archiveStaleIncidents({ now = Date.now(), inactivityMs = 12 * 3600 * 1000 } = {}) {
  const cutoff = now - inactivityMs;
  const stale = await db.prepare('SELECT id FROM incidents WHERE status = \'active\' AND last_activity_at <= ?').all(cutoff);
  for (const row of stale) {
    const archived = await archiveIncident(row.id, { archivedBy: 'system', now, auto: true });
    await appendIncidentEvent({
      incidentId: row.id,
      type: 'incident_archived',
      occurredAt: now,
      recordedAt: now,
      actorName: '系统',
      source: 'online',
      payload: { auto: true, unresolved_active_count: archived.unresolved_active_count },
    });
  }
  return stale.length;
}

function eventWithPayload(row) {
  return row ? { ...row, payload: parseEventPayload(row.payload) } : undefined;
}

async function getIncidentEvent(id) {
  return eventWithPayload(await db.prepare('SELECT * FROM incident_events WHERE id = ?').get(id));
}

async function getIncidentEventByClientOp(clientOpId) {
  if (!clientOpId) return undefined;
  return eventWithPayload(await db.prepare('SELECT * FROM incident_events WHERE client_op_id = ?').get(clientOpId));
}

async function appendIncidentEvent({
  id = randomUUID(), incidentId, type, occurredAt = Date.now(), recordedAt = Date.now(),
  actorDeviceId = null, actorName = null, source = 'online', clientOpId = null,
  payload = null, revisionOf = null, voidedAt = null,
} = {}) {
  if (clientOpId) {
    const duplicate = await getIncidentEventByClientOp(clientOpId);
    if (duplicate) return duplicate;
  }
  await db.prepare(
    'INSERT INTO incident_events (id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name, source, client_op_id, payload, revision_of, voided_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
  ).run(id, incidentId, type, Number(occurredAt) || Date.now(), Number(recordedAt) || Date.now(),
    actorDeviceId, actorName, source, clientOpId, payload == null ? null : JSON.stringify(payload), revisionOf, voidedAt);
  return getIncidentEvent(id);
}

async function listIncidentEvents(incidentId, { limit = 2000 } = {}) {
  return (await db.prepare(
    'SELECT * FROM incident_events WHERE incident_id = ? ORDER BY occurred_at DESC, recorded_at DESC LIMIT ?'
  ).all(incidentId, Math.min(Number(limit) || 2000, 5000))).map(eventWithPayload);
}

async function listStations() {
  return await db.prepare('SELECT id, name, created_at, created_by FROM stations ORDER BY name ASC').all();
}

async function addStation({ name, createdBy = null } = {}) {
  const clean = String(name || '').trim().slice(0, 80);
  const normalized = clean.replace(/消防救援站$/, '站').replace(/\s+/g, '');
  if (!normalized) throw new Error('消防站名称不能为空');
  const existing = await db.prepare('SELECT * FROM stations WHERE normalized_name = ?').get(normalized);
  if (existing) return existing;
  const id = randomUUID();
  await db.prepare('INSERT INTO stations (id, name, normalized_name, created_at, created_by) VALUES (?, ?, ?, ?, ?)')
    .run(id, clean, normalized, Date.now(), createdBy);
  return await db.prepare('SELECT id, name, created_at, created_by FROM stations WHERE id = ?').get(id);
}

async function listIncidentForces(incidentId) {
  return await db.prepare('SELECT * FROM incident_forces WHERE incident_id = ? ORDER BY station_name ASC').all(incidentId);
}

async function getIncidentForce(id) {
  return await db.prepare('SELECT * FROM incident_forces WHERE id = ?').get(id);
}

function forceCount(value) {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 0 || number > 999) throw new Error('参战车辆或人员数量无效');
  return number;
}

async function upsertIncidentForce({ id = randomUUID(), incidentId, stationId = null, stationName, vehicleCount = 0, personnelCount = 0, expectedVersion = null } = {}) {
  const cleanName = String(stationName || '').trim().slice(0, 80);
  if (!cleanName) throw new Error('消防站名称不能为空');
  const vehicles = forceCount(vehicleCount);
  const personnel = forceCount(personnelCount);
  const current = await db.prepare('SELECT * FROM incident_forces WHERE incident_id = ? AND station_name = ?').get(incidentId, cleanName);
  if (current && expectedVersion != null && Number(expectedVersion) !== current.version) {
    const error = new Error('该消防站的参战力量已被其他用户修改，请刷新后重试');
    error.code = 'VERSION_CONFLICT';
    throw error;
  }
  if (current) {
    await db.prepare('UPDATE incident_forces SET station_id = ?, vehicle_count = ?, personnel_count = ?, updated_at = ?, version = version + 1 WHERE id = ?')
      .run(stationId, vehicles, personnel, Date.now(), current.id);
    return getIncidentForce(current.id);
  }
  const now = Date.now();
  await db.prepare('INSERT INTO incident_forces (id, incident_id, station_id, station_name, vehicle_count, personnel_count, created_at, updated_at, version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)')
    .run(id, incidentId, stationId, cleanName, vehicles, personnel, now, now);
  return getIncidentForce(id);
}

async function deleteIncidentForce(id) {
  return (await db.prepare('DELETE FROM incident_forces WHERE id = ?').run(id)).changes;
}

async function getDeviceProfile(deviceId) {
  const id = String(deviceId || '');
  const row = await db.prepare('SELECT device_id, real_name, updated_at FROM device_profiles WHERE device_id = ?').get(id);
  return row || { device_id: id, real_name: '', updated_at: 0 };
}

async function saveDeviceProfile(deviceId, realName) {
  const id = String(deviceId || '');
  const name = String(realName || '').trim().slice(0, 32);
  const now = Date.now();
  await db.prepare('INSERT INTO device_profiles (device_id, real_name, updated_at) VALUES (?, ?, ?) ON CONFLICT(device_id) DO UPDATE SET real_name = excluded.real_name, updated_at = excluded.updated_at')
    .run(id, name, now);
  return getDeviceProfile(id);
}

async function backfillIncidentEvents() {
  for (const incident of await db.prepare('SELECT id FROM incidents').all()) {
    if (await db.prepare('SELECT 1 FROM incident_events WHERE incident_id = ? LIMIT 1').get(incident.id)) continue;
    for (const note of await db.prepare('SELECT * FROM notes WHERE scene = ?').all(incident.id)) {
      await db.prepare('INSERT INTO incident_events (id, incident_id, type, occurred_at, recorded_at, actor_name, source, payload) VALUES (?, ?, \'note\', ?, ?, ?, \'legacy\', ?)')
        .run(randomUUID(), incident.id, note.created_at, note.updated_at || note.created_at, note.author || null,
          JSON.stringify({ note_id: note.id, text: note.text, category: note.category, author: note.author }));
    }
    for (const entry of await db.prepare('SELECT * FROM entries WHERE scene = ?').all(incident.id)) {
      await db.prepare('INSERT INTO incident_events (id, incident_id, type, occurred_at, recorded_at, source, payload) VALUES (?, ?, \'entry\', ?, ?, \'legacy\', ?)')
        .run(randomUUID(), incident.id, entry.entry_at, entry.created_at,
          JSON.stringify({ entry_id: entry.id, name: entry.name, pressure_mpa: entry.pressure_mpa }));
      if (entry.exited_at) {
        await db.prepare('INSERT INTO incident_events (id, incident_id, type, occurred_at, recorded_at, source, payload) VALUES (?, ?, \'exit\', ?, ?, \'legacy\', ?)')
          .run(randomUUID(), incident.id, entry.exited_at, entry.exited_at,
            JSON.stringify({ entry_id: entry.id, name: entry.name }));
      }
    }
  }
}

// 旧版进退场会同时写入 entries 和一条同内容随手记。迁移到统一事件流后，
// 对“同一姓名 + 同一动作 + 30 秒内”的 legacy 随手记做确定性去重；
// 其他无法确定的历史记录继续保留，避免误删真实现场记录。
async function dedupeLegacyIncidentEvents() {
  let removed = 0;
  for (const incident of await db.prepare('SELECT id FROM incidents').all()) {
    const events = await db.prepare(
      'SELECT id, type, occurred_at, payload FROM incident_events WHERE incident_id = ? AND source = \'legacy\' ORDER BY occurred_at ASC, recorded_at ASC'
    ).all(incident.id);
    const actions = events.filter((event) => event.type === 'entry' || event.type === 'exit').map((event) => ({
      ...event,
      payload: parseEventPayload(event.payload) || {},
    }));
    for (const event of events.filter((item) => item.type === 'note')) {
      const payload = parseEventPayload(event.payload) || {};
      const text = String(payload.text || '').trim();
      const duplicate = actions.find((action) => {
        const name = String(action.payload.name || '').trim();
        if (!name || Math.abs(Number(action.occurred_at) - Number(event.occurred_at)) > 30 * 1000) return false;
        return text === `${name}${action.type === 'entry' ? '进场' : '出场'}`;
      });
      if (!duplicate) continue;
      removed += (await db.prepare('DELETE FROM incident_events WHERE id = ?').run(event.id)).changes;
    }
  }
  return removed;
}

module.exports = {
  getIncident,
  createIncident,
  listIncidents,
  findRecentActiveIncident,
  updateIncidentTitle,
  setIncidentSuggestedTitle,
  touchIncidentActivity,
  archiveIncident,
  archiveStaleIncidents,
  appendIncidentEvent,
  getIncidentEvent,
  getIncidentEventByClientOp,
  listIncidentEvents,
  dedupeLegacyIncidentEvents,
  listStations,
  addStation,
  listIncidentForces,
  getIncidentForce,
  upsertIncidentForce,
  deleteIncidentForce,
  getDeviceProfile,
  saveDeviceProfile,
  listEntries,
  getEntry,
  createEntry,
  markExited,
  findActiveByName,
  updateEntry,
  addPressureSample,
  lastPressureSample,
  listPressureSamples,
  listFirefighters,
  addFirefighter,
  removeFirefighter,
  listHotwords,
  addHotword,
  removeHotword,
  purgeOldExited,
  addLog,
  listLogs,
  clearLogs,
  purgeOldLogs,
  listNotes,
  getNote,
  createNote,
  updateNote,
  deleteNote,
  purgeOldNotes,
  listChatMessages,
  createChatMessage,
  clearChatMessages,
  purgeOldChatMessages,
  getUserSettings,
  saveUserSettings,
  ready,
  executeSQL: (sql, params = [], options = {}) => db.query(sql, params, options),
};
