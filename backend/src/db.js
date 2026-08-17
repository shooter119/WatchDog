const { DatabaseSync } = require('node:sqlite');
const { randomUUID } = require('node:crypto');
const path = require('path');
const fs = require('fs');

const DATA_DIR = process.env.WATCHDOG_DATA_DIR || path.join(__dirname, '..', 'data');
fs.mkdirSync(DATA_DIR, { recursive: true });

const db = new DatabaseSync(path.join(DATA_DIR, 'watchdog.db'));
// CloudBase CFS is a network filesystem. Keep the existing WAL default for the
// VPS, while allowing the CloudBase deployment to select a more conservative
// journal mode through configuration. The deployment uses one replica so that
// SQLite never has to coordinate writes across multiple application instances.
const journalMode = String(process.env.WATCHDOG_SQLITE_JOURNAL_MODE || 'WAL').toUpperCase();
const allowedJournalModes = new Set(['DELETE', 'TRUNCATE', 'PERSIST', 'MEMORY', 'WAL', 'OFF']);
if (!allowedJournalModes.has(journalMode)) {
  throw new Error(`不支持的 WATCHDOG_SQLITE_JOURNAL_MODE: ${journalMode}`);
}
const configuredBusyTimeout = Number(process.env.WATCHDOG_SQLITE_BUSY_TIMEOUT_MS || 5000);
const busyTimeoutMs = Number.isFinite(configuredBusyTimeout) && configuredBusyTimeout >= 0
  ? Math.min(Math.trunc(configuredBusyTimeout), 60000)
  : 5000;
db.exec(`PRAGMA journal_mode = ${journalMode};`);
db.exec(`PRAGMA busy_timeout = ${busyTimeoutMs};`);
db.exec('PRAGMA synchronous = NORMAL;');
if (journalMode === 'WAL') db.exec('PRAGMA wal_autocheckpoint = 1000;');

// BEGIN IMMEDIATE 将“检查 + 写入”变成一个原子操作，避免多台设备/多进程
// 同时写共享 SQLite 文件时出现重复记录或半完成记录。
function withImmediateTransaction(work) {
  db.exec('BEGIN IMMEDIATE;');
  try {
    const result = work();
    db.exec('COMMIT;');
    return result;
  } catch (error) {
    try { db.exec('ROLLBACK;'); } catch {}
    throw error;
  }
}

db.exec(`
CREATE TABLE IF NOT EXISTS entries (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  name TEXT NOT NULL,
  pressure_mpa REAL,
  duration_min INTEGER NOT NULL DEFAULT 0,
  entry_at INTEGER NOT NULL,
  exit_at INTEGER NOT NULL,
  exited_at INTEGER,
  source TEXT NOT NULL DEFAULT 'voice',
  raw_text TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_entries_entry_at ON entries(entry_at);
CREATE INDEX IF NOT EXISTS idx_entries_scene ON entries(scene, entry_at);
CREATE INDEX IF NOT EXISTS idx_entries_exited_at ON entries(exited_at);

CREATE TABLE IF NOT EXISTS firefighters (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS hotwords (
  id TEXT PRIMARY KEY,
  word TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS logs (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  device TEXT,
  op_id TEXT,
  level TEXT NOT NULL DEFAULT 'info',
  stage TEXT NOT NULL,
  msg TEXT NOT NULL DEFAULT '',
  data TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_logs_scene ON logs(scene, created_at);
CREATE INDEX IF NOT EXISTS idx_logs_op ON logs(op_id);
CREATE INDEX IF NOT EXISTS idx_logs_created_at ON logs(created_at);

CREATE TABLE IF NOT EXISTS user_settings (
  user_id TEXT NOT NULL,
  scene TEXT NOT NULL DEFAULT 'default',
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, scene, key)
);
CREATE INDEX IF NOT EXISTS idx_user_settings_scene ON user_settings(scene, user_id);

CREATE TABLE IF NOT EXISTS pressure_samples (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entry_id TEXT NOT NULL,
  scene TEXT NOT NULL DEFAULT 'default',
  name TEXT NOT NULL,
  pressure_mpa REAL NOT NULL,
  reported_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_samples_entry ON pressure_samples(entry_id, reported_at);

CREATE TABLE IF NOT EXISTS notes (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  text TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT '其他',
  author TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_notes_scene ON notes(scene, created_at);
CREATE INDEX IF NOT EXISTS idx_notes_created_at ON notes(created_at);

CREATE TABLE IF NOT EXISTS chat_messages (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_chat_scene ON chat_messages(scene, created_at);
CREATE INDEX IF NOT EXISTS idx_chat_created_at ON chat_messages(created_at);

`);

// 警情档案模型：业务主键使用 UUID，旧投影表中的字符串列仅作为一次迁移兼容层。
db.exec(
  'CREATE TABLE IF NOT EXISTS incidents (' +
  'id TEXT PRIMARY KEY, number TEXT NOT NULL UNIQUE, title TEXT, suggested_title TEXT, ' +
  'status TEXT NOT NULL DEFAULT \'active\' CHECK(status IN (\'active\', \'archived\')), ' +
  'created_at INTEGER NOT NULL, last_activity_at INTEGER NOT NULL, archived_at INTEGER, ' +
  'archived_by TEXT, auto_archived INTEGER NOT NULL DEFAULT 0, ' +
  'unresolved_active_count INTEGER NOT NULL DEFAULT 0, created_by TEXT, version INTEGER NOT NULL DEFAULT 1);' +
  'CREATE INDEX IF NOT EXISTS idx_incidents_status_activity ON incidents(status, last_activity_at DESC);' +
  'CREATE INDEX IF NOT EXISTS idx_incidents_archived_at ON incidents(archived_at DESC);' +
  'CREATE TABLE IF NOT EXISTS incident_events (' +
  'id TEXT PRIMARY KEY, incident_id TEXT NOT NULL, type TEXT NOT NULL, occurred_at INTEGER NOT NULL, ' +
  'recorded_at INTEGER NOT NULL, actor_device_id TEXT, actor_name TEXT, source TEXT NOT NULL DEFAULT \'online\', ' +
  'client_op_id TEXT, payload TEXT, revision_of TEXT, voided_at INTEGER);' +
  'CREATE INDEX IF NOT EXISTS idx_incident_events_time ON incident_events(incident_id, occurred_at DESC, recorded_at DESC);' +
  'CREATE UNIQUE INDEX IF NOT EXISTS idx_incident_events_op ON incident_events(client_op_id) WHERE client_op_id IS NOT NULL;' +
  'CREATE TABLE IF NOT EXISTS stations (' +
  'id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, normalized_name TEXT NOT NULL UNIQUE, ' +
  'created_at INTEGER NOT NULL, created_by TEXT);' +
  'CREATE TABLE IF NOT EXISTS incident_forces (' +
  'id TEXT PRIMARY KEY, incident_id TEXT NOT NULL, station_id TEXT, station_name TEXT NOT NULL, ' +
  'vehicle_count INTEGER NOT NULL DEFAULT 0, personnel_count INTEGER NOT NULL DEFAULT 0, ' +
  'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, version INTEGER NOT NULL DEFAULT 1, ' +
  'UNIQUE(incident_id, station_name));' +
  'CREATE INDEX IF NOT EXISTS idx_incident_forces_incident ON incident_forces(incident_id, station_name);' +
  'CREATE TABLE IF NOT EXISTS device_profiles (' +
  'device_id TEXT PRIMARY KEY, real_name TEXT NOT NULL DEFAULT \'\', updated_at INTEGER NOT NULL);'
);

function incidentNumberFor(timestamp) {
  const date = new Date(timestamp);
  return date.getFullYear() + '年' + (date.getMonth() + 1) + '月' + date.getDate() + '日' +
    String(date.getHours()).padStart(2, '0') + '时' + String(date.getMinutes()).padStart(2, '0') + '分';
}

function uniqueIncidentNumber(timestamp) {
  const base = incidentNumberFor(timestamp);
  let sequence = 1;
  let candidate = base + sequence + '#警情';
  while (db.prepare('SELECT 1 FROM incidents WHERE number = ?').get(candidate)) {
    sequence++;
    candidate = base + sequence + '#警情';
  }
  return candidate;
}

function parseEventPayload(value) {
  if (value == null || value === '') return null;
  try { return JSON.parse(value); } catch { return value; }
}

// 维护窗口兼容迁移：把旧投影中的历史字符串标识映射为 UUID，并保留历史内容。
function migrateLegacyIncidentRows() {
  const hasLegacyScene = (table) => {
    try {
      return db.prepare('PRAGMA table_info(' + table + ')').all().some((column) => column.name === 'scene');
    } catch {
      return false;
    }
  };
  const legacyScenes = new Set();
  for (const table of ['entries', 'logs', 'pressure_samples', 'notes', 'chat_messages']) {
    if (!hasLegacyScene(table)) continue;
    for (const row of db.prepare('SELECT DISTINCT scene FROM ' + table).all()) {
      if (row.scene) legacyScenes.add(String(row.scene));
    }
  }
  const oldStates = db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'scene_state'").get()
    ? db.prepare('SELECT * FROM scene_state').all() : [];
  oldStates.forEach((row) => { if (row.scene) legacyScenes.add(String(row.scene)); });
  if (legacyScenes.size === 0) {
    if (oldStates.length) db.exec('DROP TABLE scene_state');
    return;
  }

  const sceneMap = new Map();
  for (const legacy of legacyScenes) {
    // 已完成迁移的场景会在日志/旧投影中继续出现；多进程同时启动时必须
    // 将其视为已处理，否则第二个进程会再次创建同一分钟的警情编号。
    if (db.prepare('SELECT 1 FROM incidents WHERE id = ?').get(legacy)) continue;
    const state = oldStates.find((item) => item.scene === legacy);
    const times = [];
    for (const table of ['entries', 'notes', 'logs', 'chat_messages']) {
      if (!hasLegacyScene(table)) continue;
      const column = table === 'entries' ? 'entry_at' : 'created_at';
      const row = db.prepare('SELECT MIN(' + column + ') AS at FROM ' + table + ' WHERE scene = ?').get(legacy);
      if (row && row.at) times.push(Number(row.at));
    }
    const createdAt = Math.min.apply(Math, times.concat([Number(state && state.created_at || Date.now())]));
    const id = randomUUID();
    db.prepare(
      'INSERT INTO incidents (id, number, status, created_at, last_activity_at, archived_at, archived_by, auto_archived, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?)'
    ).run(id, uniqueIncidentNumber(createdAt), state && state.ended_at ? 'archived' : 'active', createdAt,
      state && state.ended_at || createdAt, state && state.ended_at || null, state && state.ended_by || null, 'legacy');
    sceneMap.set(legacy, id);
  }

  for (const table of ['entries', 'logs', 'pressure_samples', 'notes', 'chat_messages']) {
    if (!hasLegacyScene(table)) continue;
    const update = db.prepare('UPDATE ' + table + ' SET scene = ? WHERE scene = ?');
    for (const pair of sceneMap) update.run(pair[1], pair[0]);
  }
  if (oldStates.length) db.exec('DROP TABLE scene_state');
}

withImmediateTransaction(() => migrateLegacyIncidentRows());
if (db.prepare("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'scene_state'").get()) {
  db.exec('DROP TABLE scene_state');
}

for (const stationName of ['龙翔路站', '永安路站', '兴园站']) {
  const normalized = String(stationName).replace(/\s+/g, '');
  db.prepare(
    'INSERT OR IGNORE INTO stations (id, name, normalized_name, created_at, created_by) VALUES (?, ?, ?, ?, ?)'
  ).run(randomUUID(), stationName, normalized, Date.now(), 'system');
}

// 动态耗气率迁移：entries 增加实测耗气率列（可空，无采样时为 null）
if (!hasColumn('entries', 'consumption_actual_lpm')) {
  db.exec('ALTER TABLE entries ADD COLUMN consumption_actual_lpm REAL');
}

// 实名认证迁移：notes 增加发布者姓名列（可空串 = 匿名）
if (!hasColumn('notes', 'author')) {
  db.exec("ALTER TABLE notes ADD COLUMN author TEXT NOT NULL DEFAULT ''");
}

// 旧库迁移：无 scene 列时重建表（新表场景内唯一，跨场景允许同名）
function hasColumn(table, column) {
  return db.prepare(`PRAGMA table_info(${table})`).all().some((c) => c.name === column);
}
for (const t of ['entries']) {
  if (hasColumn(t, 'scene')) continue;
  db.exec(`ALTER TABLE ${t} RENAME TO ${t}_old;`);
  if (t === 'entries') {
    db.exec(`
      CREATE TABLE entries (
        id TEXT PRIMARY KEY,
        scene TEXT NOT NULL DEFAULT 'default',
        name TEXT NOT NULL,
        pressure_mpa REAL,
        duration_min INTEGER NOT NULL DEFAULT 0,
        entry_at INTEGER NOT NULL,
        exit_at INTEGER NOT NULL,
        exited_at INTEGER,
        source TEXT NOT NULL DEFAULT 'voice',
        raw_text TEXT,
        created_at INTEGER NOT NULL
      );
      INSERT INTO entries (id, scene, name, pressure_mpa, duration_min, entry_at, exit_at, exited_at, source, raw_text, created_at)
        SELECT id, 'default', name, pressure_mpa, duration_min, entry_at, exit_at, exited_at, source, raw_text, created_at FROM entries_old;
    `);
  } else {
    const nameCol = t === 'firefighters' ? 'name' : 'word';
    db.exec(`
      CREATE TABLE ${t} (
        id TEXT PRIMARY KEY,
        scene TEXT NOT NULL DEFAULT 'default',
        ${nameCol} TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        UNIQUE(scene, ${nameCol})
      );
      INSERT INTO ${t} (id, scene, ${nameCol}, created_at)
        SELECT id, 'default', ${nameCol}, created_at FROM ${t}_old;
    `);
  }
  db.exec(`DROP TABLE ${t}_old;`);
}
// 消防员全局化迁移：旧版按场景隔离，重建为全局唯一（按名去重，保留最早一条）
if (hasColumn('firefighters', 'scene')) {
  db.exec(`
    CREATE TABLE firefighters_new (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL
    );
    INSERT INTO firefighters_new (id, name, created_at)
      SELECT MIN(id), name, MIN(created_at) FROM firefighters GROUP BY name;
    DROP TABLE firefighters;
    ALTER TABLE firefighters_new RENAME TO firefighters;
  `);
}
// 热词全局化迁移：旧版热词按场景隔离，重建为全局唯一（按词去重，保留最早一条）
if (hasColumn('hotwords', 'scene')) {
  db.exec(`
    CREATE TABLE hotwords_new (
      id TEXT PRIMARY KEY,
      word TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL
    );
    INSERT INTO hotwords_new (id, word, created_at)
      SELECT MIN(id), word, MIN(created_at) FROM hotwords GROUP BY word;
    DROP TABLE hotwords;
    ALTER TABLE hotwords_new RENAME TO hotwords;
  `);
}
// 迁移后确保唯一约束与索引
db.exec(`
CREATE INDEX IF NOT EXISTS idx_entries_scene ON entries(scene, entry_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_firefighters_name ON firefighters(name);
CREATE UNIQUE INDEX IF NOT EXISTS idx_hotwords_word ON hotwords(word);
`);

// 装机自带专业热词（全局生效）：仅当表为空时写入，避免覆盖用户已删除的词条
const DEFAULT_HOTWORDS = ['龙游大队', '龙游', '龙翔路站', '永安路站', '兴园站', '头车', '两车', '三车', '四车', '内攻', '搜救'];
const existingHotwords = db.prepare('SELECT COUNT(*) AS n FROM hotwords').get().n;
if (existingHotwords === 0) {
  const seedStmt = db.prepare('INSERT INTO hotwords (id, word, created_at) VALUES (?, ?, ?)');
  const seedAt = Date.now();
  DEFAULT_HOTWORDS.forEach((word, i) => seedStmt.run(randomUUID(), word, seedAt + i));
}

// 装机自带消防员名单（全局生效，龙游大队花名册 95 人：大队部+龙翔路+永安路+兴园）
// 仅当表为空时写入，避免覆盖用户已删除的姓名
const DEFAULT_FIREFIGHTERS = [
  // 大队部
  '李翔', '盛承华', '楼松超', '徐向相', '柯峰', '祝彪',
  // 龙翔路消防救援站
  '陆河圣', '洪辰', '沈松鹏', '金志明', '陈俊鹏', '叶华杰', '杨熙豪', '施豪杰', '袁超', '马李臣',
  '邢中本', '何家琦', '余贤耀', '徐莘焕', '杨小杰', '祝徐迁', '方文斌', '徐昊扬', '郑丽文', '郑怡',
  '郑涛', '占鑫涛', '叶健智', '胡海龙', '伊余健', '曹建罡', '马鑫', '徐康', '张烜烨', '李微',
  '储嘉俊', '毛伟', '陈俊安', '赵建平', '吴拥军', '路康清', '毕灵珂', '刘羽杰', '陈鑫', '廖淑明', '毛泽旭',
  // 永安路消防救援站
  '林成成', '程晓波', '郭逸', '蓝程雄', '成帅', '姚肖江', '毕文龙', '周志峰', '吕文建', '刘林辉',
  '齐征臣', '严仕华', '袁友顺', '劳凯董', '方罗进', '马俊', '刘振坤', '贺智成', '丁以强', '易子云',
  '李瑞', '宋宇', '宁成鑫', '甲巴有拉', '吉布小夫', '方梦龙',
  // 兴园消防救援站
  '游方远', '巫垚东', '万自良', '戴晓明', '李志鹏', '徐小龙', '吴鹏晖', '叶程刚', '陈嘉豪', '姚顺',
  '贺官', '孙国彬', '吴志云', '陈子俊', '何金伟', '周子俊', '何哲锴', '徐刚', '姜俊翰', '文闻',
  '张文浩', '宋博韬',
];
const existingFirefighters = db.prepare('SELECT COUNT(*) AS n FROM firefighters').get().n;
if (existingFirefighters === 0) {
  const seedStmt = db.prepare('INSERT INTO firefighters (id, name, created_at) VALUES (?, ?, ?)');
  const seedAt = Date.now();
  DEFAULT_FIREFIGHTERS.forEach((name, i) => seedStmt.run(randomUUID(), name, seedAt + i));
}

function listEntries({ activeOnly = false, limit = 500, scene = 'default' } = {}) {
  let sql = 'SELECT * FROM entries WHERE scene = ?';
  if (activeOnly) sql += ' AND exited_at IS NULL';
  sql += ' ORDER BY entry_at DESC LIMIT ?';
  return db.prepare(sql).all(scene, limit);
}

function getEntry(id) {
  return db.prepare('SELECT * FROM entries WHERE id = ?').get(id);
}

function insertEntry({ id, scene = 'default', name, pressureMpa, durationMin, entryAtMs, exitAtMs, source = 'voice', rawText = null }) {
  db.prepare(
    'INSERT INTO entries (id, scene, name, pressure_mpa, duration_min, entry_at, exit_at, source, raw_text, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
  ).run(id, scene, name, pressureMpa, durationMin, entryAtMs, exitAtMs, source, rawText, Date.now());
  if (pressureMpa != null) {
    addPressureSample({ entryId: id, scene, name, pressureMpa, reportedAtMs: entryAtMs });
  }
  return getEntry(id);
}

function createEntry(options) {
  return withImmediateTransaction(() => insertEntry(options));
}

/**
 * 原子完成进场查重、主记录、压力采样、警情活动时间和事件写入。
 * 返回 existing 时表示同名人员已在场，调用方应返回 409；不会产生半条记录。
 */
function createEntryWithEvent({ entry, event, force = false } = {}) {
  return withImmediateTransaction(() => {
    const existing = !force ? findActiveByName(entry.scene, entry.name) : null;
    if (existing) return { entry: null, existing };
    const created = insertEntry(entry);
    touchIncidentActivity(event.incidentId, entry.entryAtMs);
    const recordedEvent = appendIncidentEvent({
      ...event,
      payload: { ...(event.payload || {}), entry_id: created.id, pressure_mpa: created.pressure_mpa },
    });
    return { entry: created, event: recordedEvent, existing: null };
  });
}

function markExited(id, exitedAtMs) {
  db.prepare('UPDATE entries SET exited_at = ? WHERE id = ?').run(exitedAtMs, id);
  return getEntry(id);
}

/** 同场景同名且未出场的在场记录（用于防重复进场） */
function findActiveByName(scene, name) {
  return db
    .prepare('SELECT * FROM entries WHERE scene = ? AND name = ? AND exited_at IS NULL ORDER BY entry_at ASC LIMIT 1')
    .get(scene, name);
}

/** 部分更新在场记录：传 null 的字段保持不变 */
function updateEntry(id, { name, pressureMpa, durationMin, exitAtMs, consumptionActualLpm }) {
  db.prepare(
    'UPDATE entries SET name = COALESCE(?, name), pressure_mpa = COALESCE(?, pressure_mpa), duration_min = COALESCE(?, duration_min), exit_at = COALESCE(?, exit_at), consumption_actual_lpm = COALESCE(?, consumption_actual_lpm) WHERE id = ?'
  ).run(name ?? null, pressureMpa ?? null, durationMin ?? null, exitAtMs ?? null, consumptionActualLpm ?? null, id);
  return getEntry(id);
}

/** 记录一次压力报数（进场/复核均写采样，用于动态耗气率差分） */
function addPressureSample({ entryId, scene = 'default', name, pressureMpa, reportedAtMs }) {
  db.prepare(
    'INSERT INTO pressure_samples (entry_id, scene, name, pressure_mpa, reported_at) VALUES (?, ?, ?, ?, ?)'
  ).run(entryId, scene, name, pressureMpa, reportedAtMs);
}

/** 最近一次压力报数（无则 null） */
function lastPressureSample(entryId) {
  return db
    .prepare('SELECT * FROM pressure_samples WHERE entry_id = ? ORDER BY reported_at DESC LIMIT 1')
    .get(entryId);
}

/** 某条记录的完整报数历史（新→旧） */
function listPressureSamples(entryId, { limit = 20 } = {}) {
  return db
    .prepare('SELECT * FROM pressure_samples WHERE entry_id = ? ORDER BY reported_at DESC LIMIT ?')
    .all(entryId, limit);
}

/** 消防员名单全局共享，不区分场景 */
function listFirefighters() {
  return db.prepare('SELECT id, name FROM firefighters ORDER BY created_at ASC').all();
}

function addFirefighter(id, name) {
  db.prepare('INSERT INTO firefighters (id, name, created_at) VALUES (?, ?, ?)').run(id, name, Date.now());
  return db.prepare('SELECT id, name FROM firefighters WHERE id = ?').get(id);
}

function removeFirefighter(id) {
  db.prepare('DELETE FROM firefighters WHERE id = ?').run(id);
}

/** 热词全局共享，不区分场景 */
function listHotwords() {
  return db.prepare('SELECT id, word FROM hotwords ORDER BY created_at ASC').all();
}

function addHotword(id, word) {
  db.prepare('INSERT INTO hotwords (id, word, created_at) VALUES (?, ?, ?)').run(id, word, Date.now());
  return db.prepare('SELECT id, word FROM hotwords WHERE id = ?').get(id);
}

function removeHotword(id) {
  db.prepare('DELETE FROM hotwords WHERE id = ?').run(id);
}

/** 清理已出火场超过 days 天的记录（含全部场景），返回删除条数 */
function purgeOldExited(days = 7) {
  const cutoff = Date.now() - days * 24 * 3600 * 1000;
  const r = db
    .prepare('DELETE FROM entries WHERE exited_at IS NOT NULL AND exited_at < ?')
    .run(cutoff);
  if (r.changes > 0) {
    // 连带清理已删除记录的压力报数采样
    db.prepare(
      'DELETE FROM pressure_samples WHERE entry_id NOT IN (SELECT id FROM entries)'
    ).run();
  }
  return r.changes;
}

/** 追加一条操作日志（App 上报或服务端埋点共用） */
function addLog({ scene = 'default', device = null, opId = null, level = 'info', stage = '', msg = '', data = null }) {
  db.prepare(
    'INSERT INTO logs (id, scene, device, op_id, level, stage, msg, data, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
  ).run(randomUUID(), scene, device, opId, level, stage, String(msg).slice(0, 2000), data == null ? null : JSON.stringify(data), Date.now());
}

/** 查询操作日志（按场景隔离，可按 op_id/device 过滤，新→旧） */
function listLogs({ scene = 'default', limit = 200, opId = null, device = null } = {}) {
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
  return db.prepare(sql).all(...args).map((r) => {
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
function clearLogs({ scene = 'default', opId = null } = {}) {
  if (opId) return db.prepare('DELETE FROM logs WHERE scene = ? AND op_id = ?').run(scene, opId).changes;
  return db.prepare('DELETE FROM logs WHERE scene = ?').run(scene).changes;
}

/** 清理超过 days 天的日志，返回删除条数 */
function purgeOldLogs(days = 30) {
  const cutoff = Date.now() - days * 24 * 3600 * 1000;
  return db.prepare('DELETE FROM logs WHERE created_at < ?').run(cutoff).changes;
}

/** 火场随手记列表（按场景隔离，新→旧） */
function listNotes({ scene = 'default', limit = 500 } = {}) {
  return db
    .prepare('SELECT * FROM notes WHERE scene = ? ORDER BY created_at DESC LIMIT ?')
    .all(scene, Math.min(Number(limit) || 500, 2000));
}

function getNote(id) {
  return db.prepare('SELECT * FROM notes WHERE id = ?').get(id);
}

function createNote({ id, scene = 'default', text, category = '其他', author = '' }) {
  const now = Date.now();
  db.prepare(
    'INSERT INTO notes (id, scene, text, category, author, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)'
  ).run(id, scene, text, category, author, now, now);
  return getNote(id);
}

/** 编辑日志条目：传 null 的字段保持不变 */
function updateNote(id, { text, category }) {
  db.prepare(
    'UPDATE notes SET text = COALESCE(?, text), category = COALESCE(?, category), updated_at = ? WHERE id = ?'
  ).run(text ?? null, category ?? null, Date.now(), id);
  return getNote(id);
}

function deleteNote(id) {
  return db.prepare('DELETE FROM notes WHERE id = ?').run(id).changes;
}

/** 清理超过 days 天的日志条目（含全部场景），返回删除条数 */
function purgeOldNotes(days = 30) {
  const cutoff = Date.now() - days * 24 * 3600 * 1000;
  return db.prepare('DELETE FROM notes WHERE created_at < ?').run(cutoff).changes;
}

/** 智能体问答消息列表（按场景隔离，旧→新，便于按序恢复上下文） */
function listChatMessages({ scene = 'default', limit = 100 } = {}) {
  return db
    .prepare('SELECT * FROM chat_messages WHERE scene = ? ORDER BY created_at ASC LIMIT ?')
    .all(scene, Math.min(Number(limit) || 100, 500));
}

function createChatMessage({ id, scene = 'default', role, content }) {
  const clean = String(content || '').slice(0, 4000);
  db.prepare(
    'INSERT INTO chat_messages (id, scene, role, content, created_at) VALUES (?, ?, ?, ?, ?)'
  ).run(id, scene, role, clean, Date.now());
  return db.prepare('SELECT * FROM chat_messages WHERE id = ?').get(id);
}

/** 清空某场景的全部问答记录，返回删除条数 */
function clearChatMessages(scene = 'default') {
  return db.prepare('DELETE FROM chat_messages WHERE scene = ?').run(scene).changes;
}

/** 清理超过 days 天的问答记录（含全部场景），返回删除条数 */
function purgeOldChatMessages(days = 30) {
  const cutoff = Date.now() - days * 24 * 3600 * 1000;
  return db.prepare('DELETE FROM chat_messages WHERE created_at < ?').run(cutoff).changes;
}

/**
 * 读取某用户在指定场景下的设置（按用户识别码 + 场景隔离）
 * 返回 { settings: {key: value}, updatedAt: 最近修改时间（无记录为 0） }
 */
function getUserSettings(userId, scene = 'default') {
  const rows = db
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
function saveUserSettings(userId, scene = 'default', settings = {}) {
  return withImmediateTransaction(() => {
    const upsert = db.prepare(`
      INSERT INTO user_settings (user_id, scene, key, value, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(user_id, scene, key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
    `);
    const now = Date.now();
    for (const [key, value] of Object.entries(settings)) {
      upsert.run(userId, scene, String(key).slice(0, 64), JSON.stringify(value), now);
    }
    return getUserSettings(userId, scene);
  });
}

const compatibilityIncidentAliases = new Map();

function getIncident(id) {
  return db.prepare('SELECT * FROM incidents WHERE id = ?').get(String(id || ''));
}

function createIncident({ id = randomUUID(), createdAt = Date.now(), createdBy = null } = {}) {
  const created = Number(createdAt) || Date.now();
  return withImmediateTransaction(() => {
    db.prepare(
      'INSERT INTO incidents (id, number, status, created_at, last_activity_at, created_by) VALUES (?, ?, \'active\', ?, ?, ?)'
    ).run(id, uniqueIncidentNumber(created), created, created, createdBy);
    return getIncident(id);
  });
}

function ensureIncidentId(value) {
  const raw = String(value || '').trim();
  if (!raw) throw new Error('缺少警情 ID');
  if (getIncident(raw)) return raw;
  const byNumber = db.prepare('SELECT id FROM incidents WHERE number = ?').get(raw);
  if (byNumber) return byNumber.id;
  if (compatibilityIncidentAliases.has(raw)) return compatibilityIncidentAliases.get(raw);
  const incident = createIncident({ createdBy: 'compatibility' });
  compatibilityIncidentAliases.set(raw, incident.id);
  return incident.id;
}

function listIncidents(status = null) {
  if (status === 'active') return db.prepare('SELECT * FROM incidents WHERE status = \'active\' ORDER BY last_activity_at DESC, created_at DESC').all();
  if (status === 'archived') return db.prepare('SELECT * FROM incidents WHERE status = \'archived\' ORDER BY archived_at DESC, created_at DESC').all();
  return db.prepare('SELECT * FROM incidents ORDER BY CASE WHEN status = \'active\' THEN 0 ELSE 1 END, COALESCE(archived_at, last_activity_at) DESC, created_at DESC').all();
}

// 只把通过新建接口产生过 incident_created 事件的记录作为建档冷却依据，
// 避免维护迁移或单元测试直接写入的兼容警情阻塞真实用户建档。
function findRecentActiveIncident(createdAfter) {
  return db.prepare(
    'SELECT i.* FROM incidents i WHERE i.status = \'active\' AND i.created_at >= ? ' +
      'AND EXISTS (SELECT 1 FROM incident_events e WHERE e.incident_id = i.id AND e.type = \'incident_created\') ' +
      'ORDER BY i.created_at DESC LIMIT 1'
  ).get(Number(createdAfter) || 0) || null;
}

function updateIncidentTitle(id, title, { expectedVersion = null } = {}) {
  const current = getIncident(id);
  if (!current) return null;
  if (expectedVersion != null && Number(expectedVersion) !== current.version) {
    const error = new Error('警情已被其他用户修改，请刷新后重试');
    error.code = 'VERSION_CONFLICT';
    throw error;
  }
  const clean = title == null ? null : String(title).trim().slice(0, 120) || null;
  db.prepare('UPDATE incidents SET title = ?, version = version + 1 WHERE id = ?').run(clean, id);
  return getIncident(id);
}

function setIncidentSuggestedTitle(id, title) {
  const clean = title == null ? null : String(title).trim().slice(0, 120) || null;
  db.prepare('UPDATE incidents SET suggested_title = ? WHERE id = ?').run(clean, id);
  return getIncident(id);
}

function touchIncidentActivity(id, at = Date.now()) {
  const current = getIncident(id);
  if (!current || current.status !== 'active') return current;
  db.prepare('UPDATE incidents SET last_activity_at = MAX(last_activity_at, ?) WHERE id = ?').run(Number(at) || Date.now(), id);
  return getIncident(id);
}

function unresolvedActiveCount(id) {
  return db.prepare('SELECT COUNT(*) AS count FROM entries WHERE scene = ? AND exited_at IS NULL').get(id).count;
}

function archiveIncident(id, { archivedBy = null, now = Date.now(), auto = false } = {}) {
  const current = getIncident(id);
  if (!current) return null;
  if (current.status === 'archived') return current;
  db.prepare(
    'UPDATE incidents SET status = \'archived\', archived_at = ?, archived_by = ?, auto_archived = ?, unresolved_active_count = ?, version = version + 1 WHERE id = ?'
  ).run(now, archivedBy, auto ? 1 : 0, unresolvedActiveCount(id), id);
  return getIncident(id);
}

function archiveStaleIncidents({ now = Date.now(), inactivityMs = 12 * 3600 * 1000 } = {}) {
  const cutoff = now - inactivityMs;
  const stale = db.prepare('SELECT id FROM incidents WHERE status = \'active\' AND last_activity_at <= ?').all(cutoff);
  for (const row of stale) {
    const archived = archiveIncident(row.id, { archivedBy: 'system', now, auto: true });
    appendIncidentEvent({
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

function getIncidentEvent(id) {
  return eventWithPayload(db.prepare('SELECT * FROM incident_events WHERE id = ?').get(id));
}

function getIncidentEventByClientOp(clientOpId) {
  if (!clientOpId) return undefined;
  return eventWithPayload(db.prepare('SELECT * FROM incident_events WHERE client_op_id = ?').get(clientOpId));
}

function appendIncidentEvent({
  id = randomUUID(), incidentId, type, occurredAt = Date.now(), recordedAt = Date.now(),
  actorDeviceId = null, actorName = null, source = 'online', clientOpId = null,
  payload = null, revisionOf = null, voidedAt = null,
} = {}) {
  const result = db.prepare(
    'INSERT OR IGNORE INTO incident_events (id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name, source, client_op_id, payload, revision_of, voided_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
  ).run(id, incidentId, type, Number(occurredAt) || Date.now(), Number(recordedAt) || Date.now(),
    actorDeviceId, actorName, source, clientOpId, payload == null ? null : JSON.stringify(payload), revisionOf, voidedAt);
  if (clientOpId && result.changes === 0) return getIncidentEventByClientOp(clientOpId);
  return getIncidentEvent(id);
}

function listIncidentEvents(incidentId, { limit = 2000 } = {}) {
  return db.prepare(
    'SELECT * FROM incident_events WHERE incident_id = ? ORDER BY occurred_at DESC, recorded_at DESC LIMIT ?'
  ).all(incidentId, Math.min(Number(limit) || 2000, 5000)).map(eventWithPayload);
}

function listStations() {
  return db.prepare('SELECT id, name, created_at, created_by FROM stations ORDER BY name ASC').all();
}

function addStation({ name, createdBy = null } = {}) {
  const clean = String(name || '').trim().slice(0, 80);
  const normalized = clean.replace(/消防救援站$/, '站').replace(/\s+/g, '');
  if (!normalized) throw new Error('消防站名称不能为空');
  const existing = db.prepare('SELECT * FROM stations WHERE normalized_name = ?').get(normalized);
  if (existing) return existing;
  const id = randomUUID();
  db.prepare('INSERT INTO stations (id, name, normalized_name, created_at, created_by) VALUES (?, ?, ?, ?, ?)')
    .run(id, clean, normalized, Date.now(), createdBy);
  return db.prepare('SELECT id, name, created_at, created_by FROM stations WHERE id = ?').get(id);
}

function listIncidentForces(incidentId) {
  return db.prepare('SELECT * FROM incident_forces WHERE incident_id = ? ORDER BY station_name ASC').all(incidentId);
}

function getIncidentForce(id) {
  return db.prepare('SELECT * FROM incident_forces WHERE id = ?').get(id);
}

function forceCount(value) {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 0 || number > 999) throw new Error('参战车辆或人员数量无效');
  return number;
}

function upsertIncidentForce({ id = randomUUID(), incidentId, stationId = null, stationName, vehicleCount = 0, personnelCount = 0, expectedVersion = null } = {}) {
  return withImmediateTransaction(() => {
    const cleanName = String(stationName || '').trim().slice(0, 80);
    if (!cleanName) throw new Error('消防站名称不能为空');
    const vehicles = forceCount(vehicleCount);
    const personnel = forceCount(personnelCount);
    const current = db.prepare('SELECT * FROM incident_forces WHERE incident_id = ? AND station_name = ?').get(incidentId, cleanName);
    if (current && expectedVersion != null && Number(expectedVersion) !== current.version) {
      const error = new Error('该消防站的参战力量已被其他用户修改，请刷新后重试');
      error.code = 'VERSION_CONFLICT';
      throw error;
    }
    if (current) {
      db.prepare('UPDATE incident_forces SET station_id = ?, vehicle_count = ?, personnel_count = ?, updated_at = ?, version = version + 1 WHERE id = ?')
        .run(stationId, vehicles, personnel, Date.now(), current.id);
      return getIncidentForce(current.id);
    }
    const now = Date.now();
    db.prepare('INSERT INTO incident_forces (id, incident_id, station_id, station_name, vehicle_count, personnel_count, created_at, updated_at, version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)')
      .run(id, incidentId, stationId, cleanName, vehicles, personnel, now, now);
    return getIncidentForce(id);
  });
}

function deleteIncidentForce(id) {
  return db.prepare('DELETE FROM incident_forces WHERE id = ?').run(id).changes;
}

function getDeviceProfile(deviceId) {
  const id = String(deviceId || '');
  const row = db.prepare('SELECT device_id, real_name, updated_at FROM device_profiles WHERE device_id = ?').get(id);
  return row || { device_id: id, real_name: '', updated_at: 0 };
}

function saveDeviceProfile(deviceId, realName) {
  const id = String(deviceId || '');
  const name = String(realName || '').trim().slice(0, 32);
  const now = Date.now();
  db.prepare('INSERT INTO device_profiles (device_id, real_name, updated_at) VALUES (?, ?, ?) ON CONFLICT(device_id) DO UPDATE SET real_name = excluded.real_name, updated_at = excluded.updated_at')
    .run(id, name, now);
  return getDeviceProfile(id);
}

function backfillIncidentEvents() {
  for (const incident of db.prepare('SELECT id FROM incidents').all()) {
    if (db.prepare('SELECT 1 FROM incident_events WHERE incident_id = ? LIMIT 1').get(incident.id)) continue;
    for (const note of db.prepare('SELECT * FROM notes WHERE scene = ?').all(incident.id)) {
      db.prepare('INSERT INTO incident_events (id, incident_id, type, occurred_at, recorded_at, actor_name, source, payload) VALUES (?, ?, \'note\', ?, ?, ?, \'legacy\', ?)')
        .run(randomUUID(), incident.id, note.created_at, note.updated_at || note.created_at, note.author || null,
          JSON.stringify({ note_id: note.id, text: note.text, category: note.category, author: note.author }));
    }
    for (const entry of db.prepare('SELECT * FROM entries WHERE scene = ?').all(incident.id)) {
      db.prepare('INSERT INTO incident_events (id, incident_id, type, occurred_at, recorded_at, source, payload) VALUES (?, ?, \'entry\', ?, ?, \'legacy\', ?)')
        .run(randomUUID(), incident.id, entry.entry_at, entry.created_at,
          JSON.stringify({ entry_id: entry.id, name: entry.name, pressure_mpa: entry.pressure_mpa }));
      if (entry.exited_at) {
        db.prepare('INSERT INTO incident_events (id, incident_id, type, occurred_at, recorded_at, source, payload) VALUES (?, ?, \'exit\', ?, ?, \'legacy\', ?)')
          .run(randomUUID(), incident.id, entry.exited_at, entry.exited_at,
            JSON.stringify({ entry_id: entry.id, name: entry.name }));
      }
    }
  }
}

// 旧版进退场会同时写入 entries 和一条同内容随手记。迁移到统一事件流后，
// 对“同一姓名 + 同一动作 + 30 秒内”的 legacy 随手记做确定性去重；
// 其他无法确定的历史记录继续保留，避免误删真实现场记录。
function dedupeLegacyIncidentEvents() {
  let removed = 0;
  for (const incident of db.prepare('SELECT id FROM incidents').all()) {
    const events = db.prepare(
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
      removed += db.prepare('DELETE FROM incident_events WHERE id = ?').run(event.id).changes;
    }
  }
  return removed;
}

backfillIncidentEvents();
dedupeLegacyIncidentEvents();

function pragmaValue(name) {
  const row = db.prepare(`PRAGMA ${name}`).get();
  return row ? Object.values(row)[0] : undefined;
}

function healthCheck() {
  db.prepare('SELECT 1 AS ok').get();
  return {
    journalMode: String(pragmaValue('journal_mode') || journalMode).toUpperCase(),
    busyTimeoutMs: Number(pragmaValue('busy_timeout') || busyTimeoutMs),
  };
}

let closed = false;
function close() {
  if (closed) return;
  closed = true;
  db.close();
}

module.exports = {
  getIncident,
  createIncident,
  createEntryWithEvent,
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
  healthCheck,
  close,
};
