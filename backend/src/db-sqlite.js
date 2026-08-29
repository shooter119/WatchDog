const { DatabaseSync } = require('node:sqlite');
const { randomUUID } = require('node:crypto');
const path = require('path');
const fs = require('fs');

const DATA_DIR = process.env.WATCHDOG_DATA_DIR || path.join(__dirname, '..', 'data');
fs.mkdirSync(DATA_DIR, { recursive: true });

const db = new DatabaseSync(path.join(DATA_DIR, 'watchdog.db'));
// SQLite 仅用于本地开发和测试；CloudBase 生产环境使用 PostgREST 数据库驱动。
// 通过环境变量保留 journal mode 配置，便于本地测试不同的锁策略。
const journalMode = String(process.env.WATCHDOG_SQLITE_JOURNAL_MODE || 'WAL').toUpperCase();
const allowedJournalModes = new Set(['DELETE', 'TRUNCATE', 'PERSIST', 'MEMORY', 'WAL', 'OFF']);
if (!allowedJournalModes.has(journalMode)) {
  throw new Error(`不支持的 WATCHDOG_SQLITE_JOURNAL_MODE: ${journalMode}`);
}
db.exec(`PRAGMA journal_mode = ${journalMode};`);
db.exec(`PRAGMA busy_timeout = ${Number(process.env.WATCHDOG_SQLITE_BUSY_TIMEOUT_MS || 5000)};`);

let transactionDepth = 0;

function transaction(callback) {
  if (transactionDepth > 0) return callback();
  db.exec('BEGIN IMMEDIATE');
  transactionDepth++;
  try {
    const result = callback();
    db.exec('COMMIT');
    return result;
  } catch (error) {
    db.exec('ROLLBACK');
    throw error;
  } finally {
    transactionDepth--;
  }
}

function limitOf(value, fallback, maximum) {
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.min(Math.floor(parsed), maximum);
}

db.exec(`
CREATE TABLE IF NOT EXISTS units (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  verification_code TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS unit_members (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL,
  real_name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' CHECK(role IN ('member', 'manager', 'admin')),
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'disabled')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(unit_id, real_name)
);
CREATE INDEX IF NOT EXISTS idx_unit_members_lookup ON unit_members(unit_id, real_name, status);

CREATE TABLE IF NOT EXISTS auth_sessions (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  unit_id TEXT NOT NULL,
  member_id TEXT,
  device_id TEXT,
  real_name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' CHECK(role IN ('member', 'manager', 'admin')),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  last_seen_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_token ON auth_sessions(token_hash);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_device ON auth_sessions(unit_id, device_id, revoked_at);

CREATE TABLE IF NOT EXISTS operation_ledger (
  unit_id TEXT NOT NULL DEFAULT '',
  client_op_id TEXT NOT NULL,
  incident_id TEXT,
  operation_type TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending', 'succeeded')),
  result_json TEXT,
  response_status INTEGER,
  event_id TEXT,
  actor_device_id TEXT,
  actor_name TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  lease_until INTEGER,
  completed_at INTEGER,
  PRIMARY KEY(unit_id, client_op_id)
);
CREATE INDEX IF NOT EXISTS idx_operation_ledger_incident ON operation_ledger(unit_id, incident_id, updated_at);

CREATE TABLE IF NOT EXISTS entries (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  name TEXT NOT NULL,
  pressure_mpa REAL CHECK(pressure_mpa IS NULL OR (pressure_mpa > 0 AND pressure_mpa <= 40)),
  duration_min INTEGER NOT NULL DEFAULT 0 CHECK(duration_min >= 0),
  entry_at INTEGER NOT NULL,
  exit_at INTEGER NOT NULL,
  exited_at INTEGER,
  source TEXT NOT NULL DEFAULT 'voice',
  raw_text TEXT,
  cylinder_vol_l REAL CHECK(cylinder_vol_l IS NULL OR (cylinder_vol_l > 0 AND cylinder_vol_l <= 20)),
  consumption_lpm REAL CHECK(consumption_lpm IS NULL OR (consumption_lpm > 0 AND consumption_lpm <= 300)),
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_entries_entry_at ON entries(entry_at);

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
CREATE INDEX IF NOT EXISTS idx_logs_op ON logs(op_id);

CREATE TABLE IF NOT EXISTS user_settings (
  user_id TEXT NOT NULL,
  scene TEXT NOT NULL DEFAULT 'default',
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, scene, key)
);

CREATE TABLE IF NOT EXISTS pressure_samples (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  entry_id TEXT NOT NULL,
  scene TEXT NOT NULL DEFAULT 'default',
  name TEXT NOT NULL,
  pressure_mpa REAL NOT NULL CHECK(pressure_mpa > 0 AND pressure_mpa <= 40),
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

CREATE TABLE IF NOT EXISTS chat_messages (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

`);

// 警情档案模型：业务主键使用 UUID，旧投影表中的字符串列仅作为一次迁移兼容层。
db.exec(
  'CREATE TABLE IF NOT EXISTS incidents (' +
  'id TEXT PRIMARY KEY, unit_id TEXT, number TEXT NOT NULL UNIQUE, title TEXT, suggested_title TEXT, ' +
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
  'vehicle_count INTEGER NOT NULL DEFAULT 0 CHECK(vehicle_count BETWEEN 0 AND 999), personnel_count INTEGER NOT NULL DEFAULT 0 CHECK(personnel_count BETWEEN 0 AND 999), ' +
  'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, version INTEGER NOT NULL DEFAULT 1, ' +
  'UNIQUE(incident_id, station_name));' +
  'CREATE INDEX IF NOT EXISTS idx_incident_forces_incident ON incident_forces(incident_id, station_name);' +
  'CREATE TABLE IF NOT EXISTS device_profiles (' +
  'device_id TEXT PRIMARY KEY, unit_id TEXT, real_name TEXT NOT NULL DEFAULT \'\', updated_at INTEGER NOT NULL);'
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
  return transaction(() => {
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
      // 已经迁移过的 scene 会等于现有警情 UUID。跳过它，避免每次启动重复创建警情并再次改写历史记录。
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
  });
}

migrateLegacyIncidentRows();
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
if (!hasColumn('entries', 'cylinder_vol_l')) {
  db.exec('ALTER TABLE entries ADD COLUMN cylinder_vol_l REAL');
}
if (!hasColumn('entries', 'consumption_lpm')) {
  db.exec('ALTER TABLE entries ADD COLUMN consumption_lpm REAL');
}

// 实名认证迁移：notes 增加发布者姓名列（可空串 = 匿名）
if (!hasColumn('notes', 'author')) {
  db.exec("ALTER TABLE notes ADD COLUMN author TEXT NOT NULL DEFAULT ''");
}
if (!hasColumn('operation_ledger', 'lease_until')) {
  db.exec('ALTER TABLE operation_ledger ADD COLUMN lease_until INTEGER');
}

// 旧库迁移：无 scene 列时重建表（新表场景内唯一，跨场景允许同名）
function hasColumn(table, column) {
  return db.prepare(`PRAGMA table_info(${table})`).all().some((c) => c.name === column);
}
if (!hasColumn('incidents', 'unit_id')) {
  db.exec('ALTER TABLE incidents ADD COLUMN unit_id TEXT');
}
if (!hasColumn('device_profiles', 'unit_id')) {
  db.exec('ALTER TABLE device_profiles ADD COLUMN unit_id TEXT');
}
db.exec('CREATE INDEX IF NOT EXISTS idx_incidents_unit_status_activity ON incidents(unit_id, status, last_activity_at DESC)');
db.exec('CREATE INDEX IF NOT EXISTS idx_device_profiles_unit ON device_profiles(unit_id, device_id)');

for (const t of ['entries']) {
  if (hasColumn(t, 'scene')) continue;
  db.exec(`ALTER TABLE ${t} RENAME TO ${t}_old;`);
  if (t === 'entries') {
    db.exec(`
      CREATE TABLE entries (
        id TEXT PRIMARY KEY,
        scene TEXT NOT NULL DEFAULT 'default',
        name TEXT NOT NULL,
        pressure_mpa REAL CHECK(pressure_mpa IS NULL OR (pressure_mpa > 0 AND pressure_mpa <= 40)),
        duration_min INTEGER NOT NULL DEFAULT 0 CHECK(duration_min >= 0),
        entry_at INTEGER NOT NULL,
        exit_at INTEGER NOT NULL,
        exited_at INTEGER,
        source TEXT NOT NULL DEFAULT 'voice',
        raw_text TEXT,
        consumption_actual_lpm REAL,
        cylinder_vol_l REAL CHECK(cylinder_vol_l IS NULL OR (cylinder_vol_l > 0 AND cylinder_vol_l <= 20)),
        consumption_lpm REAL CHECK(consumption_lpm IS NULL OR (consumption_lpm > 0 AND consumption_lpm <= 300)),
        created_at INTEGER NOT NULL
      );
      INSERT INTO entries (id, scene, name, pressure_mpa, duration_min, entry_at, exit_at, exited_at, source, raw_text, consumption_actual_lpm, cylinder_vol_l, consumption_lpm, created_at)
        SELECT id, 'default', name, pressure_mpa, duration_min, entry_at, exit_at, exited_at, source, raw_text, consumption_actual_lpm, cylinder_vol_l, consumption_lpm, created_at FROM entries_old;
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
if (hasColumn('entries', 'scene')) db.exec('CREATE INDEX IF NOT EXISTS idx_entries_scene ON entries(scene, entry_at)');
if (hasColumn('logs', 'scene')) db.exec('CREATE INDEX IF NOT EXISTS idx_logs_scene ON logs(scene, created_at)');
if (hasColumn('user_settings', 'scene')) db.exec('CREATE INDEX IF NOT EXISTS idx_user_settings_scene ON user_settings(scene, user_id)');
if (hasColumn('notes', 'scene')) db.exec('CREATE INDEX IF NOT EXISTS idx_notes_scene ON notes(scene, created_at)');
if (hasColumn('chat_messages', 'scene')) db.exec('CREATE INDEX IF NOT EXISTS idx_chat_scene ON chat_messages(scene, created_at)');
db.exec('CREATE UNIQUE INDEX IF NOT EXISTS idx_firefighters_name ON firefighters(name)');
db.exec('CREATE UNIQUE INDEX IF NOT EXISTS idx_hotwords_word ON hotwords(word)');

// 单位种子仅允许测试环境或显式配置；生产环境绝不默认创建公开验证码。
const seedUnit = {
  id: process.env.WATCHDOG_SEED_UNIT_ID || (process.env.NODE_ENV === 'test' ? 'longyou-county-fire-rescue' : ''),
  name: process.env.WATCHDOG_SEED_UNIT_NAME || (process.env.NODE_ENV === 'test' ? '龙游县消防救援大队' : ''),
  code: process.env.WATCHDOG_SEED_UNIT_CODE || (process.env.NODE_ENV === 'test' ? '0570' : ''),
};
if (seedUnit.id && seedUnit.name && seedUnit.code) {
  db.prepare(
    'INSERT OR IGNORE INTO units (id, name, verification_code, created_at, updated_at) VALUES (?, ?, ?, ?, ?)'
  ).run(seedUnit.id, seedUnit.name, seedUnit.code, 1780000000000, 1780000000000);
}

// 成员白名单由部署环境显式提供，格式支持 JSON 数组或“姓名[:角色],姓名[:角色]”。
// 不把全局消防员名单自动当作认证成员，避免名单维护与访问准入意外耦合。
function parseSeedMembers(value) {
  const raw = String(value || '').trim();
  if (!raw) return [];
  let items;
  try {
    const parsed = JSON.parse(raw);
    items = Array.isArray(parsed) ? parsed : [];
  } catch (_) {
    items = raw.split(',').map((item) => {
      const [realName, role = 'member'] = item.split(/[:：]/, 2);
      return { real_name: realName, role };
    });
  }
  return items.map((item) => {
    if (typeof item === 'string') return { real_name: item, role: 'member' };
    return { real_name: item?.real_name ?? item?.name, role: item?.role ?? 'member' };
  }).map((item) => ({
    realName: String(item.real_name || '').trim().slice(0, 32),
    role: ['member', 'manager', 'admin'].includes(String(item.role)) ? String(item.role) : 'member',
  })).filter((item) => item.realName);
}

if (seedUnit.id && process.env.WATCHDOG_SEED_UNIT_MEMBERS) {
  const seedAt = Date.now();
  const stmt = db.prepare(
    'INSERT INTO unit_members (id, unit_id, real_name, role, status, created_at, updated_at) VALUES (?, ?, ?, ?, \'active\', ?, ?) ON CONFLICT(unit_id, real_name) DO UPDATE SET role = excluded.role, status = \'active\', updated_at = excluded.updated_at'
  );
  for (const member of parseSeedMembers(process.env.WATCHDOG_SEED_UNIT_MEMBERS)) {
    stmt.run(randomUUID(), seedUnit.id, member.realName, member.role, seedAt, seedAt);
  }
}

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
  return db.prepare(sql).all(scene, limitOf(limit, 500, 2000));
}

function getEntry(id) {
  return db.prepare('SELECT * FROM entries WHERE id = ?').get(id);
}

function getUnit(id) {
  return db.prepare('SELECT id, name, verification_code, created_at, updated_at FROM units WHERE id = ?').get(String(id || ''));
}

function findUnit(name, verificationCode) {
  return db.prepare(
    'SELECT id, name, verification_code, created_at, updated_at FROM units WHERE name = ? AND verification_code = ?'
  ).get(String(name || '').trim(), String(verificationCode || '').trim());
}

function findUnitMember(unitId, realName) {
  return db.prepare(
    'SELECT id, unit_id, real_name, role, status, created_at, updated_at FROM unit_members WHERE unit_id = ? AND real_name = ? AND status = \'active\''
  ).get(String(unitId || ''), String(realName || '').trim());
}

function listUnitMembers(unitId) {
  return db.prepare(
    'SELECT id, unit_id, real_name, role, status, created_at, updated_at FROM unit_members WHERE unit_id = ? ORDER BY real_name ASC'
  ).all(String(unitId || ''));
}

function addUnitMember({ id = randomUUID(), unitId, realName, role = 'member' }) {
  const name = String(realName || '').trim().slice(0, 32);
  if (!unitId || !name) throw new Error('单位成员姓名不能为空');
  const cleanRole = ['member', 'manager', 'admin'].includes(role) ? role : 'member';
  const now = Date.now();
  db.prepare(
    'INSERT INTO unit_members (id, unit_id, real_name, role, status, created_at, updated_at) VALUES (?, ?, ?, ?, \'active\', ?, ?)'
  ).run(String(id), String(unitId), name, cleanRole, now, now);
  return db.prepare('SELECT id, unit_id, real_name, role, status, created_at, updated_at FROM unit_members WHERE id = ?').get(String(id));
}

function updateUnitMember(id, unitId, { role, status } = {}) {
  const cleanRole = role == null ? null : (['member', 'manager', 'admin'].includes(role) ? role : null);
  const cleanStatus = status == null ? null : (['active', 'disabled'].includes(status) ? status : null);
  if (role != null && cleanRole == null) throw new Error('成员角色无效');
  if (status != null && cleanStatus == null) throw new Error('成员状态无效');
  const result = db.prepare(
    'UPDATE unit_members SET role = COALESCE(?, role), status = COALESCE(?, status), updated_at = ? WHERE id = ? AND unit_id = ?'
  ).run(cleanRole, cleanStatus, Date.now(), String(id || ''), String(unitId || ''));
  const updated = db.prepare('SELECT id, unit_id, real_name, role, status, created_at, updated_at FROM unit_members WHERE id = ? AND unit_id = ?')
    .get(String(id || ''), String(unitId || ''));
  if (result.changes > 0) revokeAuthSessionsForMember(String(id || ''));
  return updated;
}

function createAuthSession({ id, tokenHash, unitId, memberId = null, deviceId = null, realName, role = 'member', createdAt = Date.now(), expiresAt }) {
  const created = Number(createdAt) || Date.now();
  const expires = Number(expiresAt);
  if (!id || !tokenHash || !unitId || !realName || !Number.isFinite(expires)) {
    throw new Error('认证会话参数不完整');
  }
  db.prepare(
    'INSERT INTO auth_sessions (id, token_hash, unit_id, member_id, device_id, real_name, role, created_at, expires_at, last_seen_at, revoked_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)'
  ).run(String(id), String(tokenHash), String(unitId), memberId ? String(memberId) : null, deviceId ? String(deviceId) : null,
    String(realName).trim().slice(0, 32), ['member', 'manager', 'admin'].includes(role) ? role : 'member', created, expires, created);
  return getAuthSession(tokenHash);
}

function getAuthSession(tokenHash) {
  return db.prepare(
    'SELECT id, token_hash, unit_id, member_id, device_id, real_name, role, created_at, expires_at, last_seen_at, revoked_at FROM auth_sessions WHERE token_hash = ? AND revoked_at IS NULL AND expires_at > ?'
  ).get(String(tokenHash || ''), Date.now());
}

function revokeAuthSession(tokenHash, revokedAt = Date.now()) {
  return db.prepare('UPDATE auth_sessions SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL')
    .run(Number(revokedAt) || Date.now(), String(tokenHash || '')).changes;
}

function revokeAuthSessionsForMember(memberId, revokedAt = Date.now()) {
  return db.prepare('UPDATE auth_sessions SET revoked_at = ? WHERE member_id = ? AND revoked_at IS NULL')
    .run(Number(revokedAt) || Date.now(), String(memberId || '')).changes;
}

function getOperation(unitId, clientOpId) {
  if (!clientOpId) return undefined;
  return db.prepare(
    'SELECT unit_id, client_op_id, incident_id, operation_type, request_hash, status, result_json, response_status, event_id, actor_device_id, actor_name, created_at, updated_at, lease_until, completed_at FROM operation_ledger WHERE unit_id = ? AND client_op_id = ?'
  ).get(String(unitId || ''), String(clientOpId));
}

function beginOperation({ unitId = '', clientOpId, incidentId = null, operationType, requestHash, actorDeviceId = null, actorName = null, now = Date.now() } = {}) {
  if (!clientOpId || !operationType || !requestHash) throw new Error('操作账本参数不完整');
  const timestamp = Number(now) || Date.now();
  const leaseUntil = timestamp + 30 * 1000;
  const result = db.prepare(
    'INSERT INTO operation_ledger (unit_id, client_op_id, incident_id, operation_type, request_hash, status, result_json, response_status, event_id, actor_device_id, actor_name, created_at, updated_at, lease_until, completed_at) VALUES (?, ?, ?, ?, ?, \'pending\', NULL, NULL, NULL, ?, ?, ?, ?, ?, NULL) ON CONFLICT(unit_id, client_op_id) DO NOTHING'
  ).run(String(unitId || ''), String(clientOpId), incidentId ? String(incidentId) : null, String(operationType), String(requestHash),
    actorDeviceId ? String(actorDeviceId) : null, actorName ? String(actorName).slice(0, 32) : null, timestamp, timestamp, leaseUntil);
  if (result.changes === 0) {
    const reclaimed = db.prepare(
      'UPDATE operation_ledger SET updated_at = ?, lease_until = ?, actor_device_id = ?, actor_name = ? WHERE unit_id = ? AND client_op_id = ? AND request_hash = ? AND status = \'pending\' AND (lease_until IS NULL OR lease_until <= ?)'
    ).run(timestamp, leaseUntil, actorDeviceId ? String(actorDeviceId) : null, actorName ? String(actorName).slice(0, 32) : null,
      String(unitId || ''), String(clientOpId), String(requestHash), timestamp);
    if (reclaimed.changes > 0) {
      const operation = getOperation(unitId, clientOpId);
      return operation ? { ...operation, created: true, reclaimed: true } : operation;
    }
  }
  const operation = getOperation(unitId, clientOpId);
  return operation ? { ...operation, created: result.changes > 0 } : operation;
}

function completeOperation({ unitId = '', clientOpId, incidentId = null, requestHash, result, responseStatus = 200, eventId = null, now = Date.now() } = {}) {
  if (!clientOpId || !requestHash) return 0;
  const timestamp = Number(now) || Date.now();
  const serialized = result == null ? null : JSON.stringify(result);
  return db.prepare(
    'UPDATE operation_ledger SET incident_id = COALESCE(?, incident_id), status = \'succeeded\', result_json = ?, response_status = ?, event_id = ?, updated_at = ?, lease_until = NULL, completed_at = ? WHERE unit_id = ? AND client_op_id = ? AND request_hash = ? AND status = \'pending\''
  ).run(incidentId ? String(incidentId) : null, serialized, Number(responseStatus) || 200, eventId ? String(eventId) : null, timestamp, timestamp,
    String(unitId || ''), String(clientOpId), String(requestHash)).changes;
}

function releaseOperation({ unitId = '', clientOpId, requestHash } = {}) {
  if (!clientOpId || !requestHash) return 0;
  return db.prepare(
    'DELETE FROM operation_ledger WHERE unit_id = ? AND client_op_id = ? AND request_hash = ? AND status = \'pending\''
  ).run(String(unitId || ''), String(clientOpId), String(requestHash)).changes;
}

function createEntry({ id, scene = 'default', name, pressureMpa, durationMin, entryAtMs, exitAtMs, source = 'voice', rawText = null, cylinderVolL = null, consumptionLpm = null }) {
  const write = () => {
    db.prepare(
      'INSERT INTO entries (id, scene, name, pressure_mpa, duration_min, entry_at, exit_at, source, raw_text, cylinder_vol_l, consumption_lpm, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
    ).run(id, scene, name, pressureMpa, durationMin, entryAtMs, exitAtMs, source, rawText, cylinderVolL, consumptionLpm, Date.now());
    if (pressureMpa != null) {
      addPressureSample({ entryId: id, scene, name, pressureMpa, reportedAtMs: entryAtMs });
    }
  };
  transaction(write);
  return getEntry(id);
}

function createEntryWithEvent({ entry, event, activityAt = null } = {}) {
  return transaction(() => {
    const created = createEntry(entry);
    if (activityAt != null) touchIncidentActivity(event.incidentId, activityAt);
    const recorded = appendIncidentEvent(event);
    return { entry: created, event: recorded };
  });
}

function markExited(id, exitedAtMs) {
  db.prepare('UPDATE entries SET exited_at = ? WHERE id = ? AND exited_at IS NULL').run(exitedAtMs, id);
  return getEntry(id);
}

function markExitedIfActive(id, exitedAtMs) {
  const result = db.prepare('UPDATE entries SET exited_at = ? WHERE id = ? AND exited_at IS NULL').run(exitedAtMs, id);
  return { entry: getEntry(id), changed: result.changes > 0 };
}

function exitEntryWithEvent({ entryId, exitedAtMs, incidentId, activityAt = null, event } = {}) {
  return transaction(() => {
    const transition = markExitedIfActive(entryId, exitedAtMs);
    if (!transition.changed) return { entry: transition.entry, event: null, changed: false };
    if (activityAt != null) touchIncidentActivity(incidentId, activityAt);
    const recorded = appendIncidentEvent(event);
    return { entry: transition.entry, event: recorded, changed: true };
  });
}

function updatePressureWithEvent({ entryId, scene, name, pressureMpa, reportedAtMs, durationMin, exitAtMs, consumptionActualLpm = null, incidentId, activityAt = null, event } = {}) {
  return transaction(() => {
    addPressureSample({ entryId, scene, name, pressureMpa, reportedAtMs });
    const updated = updateEntry(entryId, { pressureMpa, durationMin, exitAtMs, consumptionActualLpm });
    if (activityAt != null) touchIncidentActivity(incidentId, activityAt);
    const recorded = appendIncidentEvent(event);
    return { entry: updated, event: recorded };
  });
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
    .all(entryId, limitOf(limit, 20, 500));
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

/** 批量追加操作日志：一次事务提交，避免云端/本地逐条写入放大延迟。 */
function addLogs(logs = []) {
  if (!Array.isArray(logs) || logs.length === 0) return 0;
  const insert = db.prepare(
    'INSERT INTO logs (id, scene, device, op_id, level, stage, msg, data, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)'
  );
  return transaction(() => {
    let count = 0;
    for (const item of logs) {
      insert.run(
        randomUUID(), item.scene || 'default', item.device || null, item.opId || null,
        item.level || 'info', item.stage || '', String(item.msg || '').slice(0, 2000),
        item.data == null ? null : JSON.stringify(item.data), Number(item.createdAt) || Date.now(),
      );
      count++;
    }
    return count;
  });
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
  args.push(limitOf(limit, 200, 1000));
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
    .all(scene, limitOf(limit, 500, 2000));
}

function getNote(id) {
  return db.prepare('SELECT * FROM notes WHERE id = ?').get(id);
}

function createNote({ id, scene = 'default', text, category = '其他', author = '', createdAt = Date.now() }) {
  const now = Number(createdAt) || Date.now();
  db.prepare(
    'INSERT INTO notes (id, scene, text, category, author, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)'
  ).run(id, scene, text, category, author, now, now);
  return getNote(id);
}

function createNoteWithEvent({ note, event, activityAt = null } = {}) {
  return transaction(() => {
    const created = createNote(note);
    if (activityAt != null) touchIncidentActivity(event.incidentId, activityAt);
    const recorded = appendIncidentEvent(event);
    return { note: created, event: recorded };
  });
}

/** 编辑日志条目：传 null 的字段保持不变 */
function updateNote(id, { text, category }) {
  db.prepare(
    'UPDATE notes SET text = COALESCE(?, text), category = COALESCE(?, category), updated_at = ? WHERE id = ?'
  ).run(text ?? null, category ?? null, Date.now(), id);
  return getNote(id);
}

function updateNoteWithEvent({ id, text, category, incidentId, event, activityAt = null } = {}) {
  return transaction(() => {
    const updated = updateNote(id, { text, category });
    if (!updated) return { note: null, event: null, changed: false };
    if (activityAt != null) touchIncidentActivity(incidentId, activityAt);
    return { note: updated, event: event ? appendIncidentEvent(event) : null, changed: true };
  });
}

function deleteNote(id) {
  return db.prepare('DELETE FROM notes WHERE id = ?').run(id).changes;
}

function deleteNoteWithEvent({ id, incidentId, event, activityAt = null } = {}) {
  return transaction(() => {
    const changed = deleteNote(id);
    if (changed > 0 && activityAt != null) touchIncidentActivity(incidentId, activityAt);
    const recorded = changed > 0 && event ? appendIncidentEvent(event) : null;
    return { changed: changed > 0, event: recorded };
  });
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
    .all(scene, limitOf(limit, 100, 500));
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
}

const compatibilityIncidentAliases = new Map();

function getIncident(id, { unitId = null } = {}) {
  if (unitId) {
    return db.prepare('SELECT * FROM incidents WHERE id = ? AND unit_id = ?').get(String(id || ''), unitId);
  }
  return db.prepare('SELECT * FROM incidents WHERE id = ?').get(String(id || ''));
}

function createIncident({ id = randomUUID(), unitId = null, createdAt = Date.now(), createdBy = null } = {}) {
  const created = Number(createdAt) || Date.now();
  db.prepare(
    'INSERT INTO incidents (id, unit_id, number, status, created_at, last_activity_at, created_by) VALUES (?, ?, ?, \'active\', ?, ?, ?)'
  ).run(id, unitId, uniqueIncidentNumber(created), created, created, createdBy);
  return getIncident(id);
}

function createIncidentWithEvent({ id = randomUUID(), unitId = null, createdAt = Date.now(), createdBy = null, event = {} } = {}) {
  const createdAtValue = Number(createdAt) || Date.now();
  return transaction(() => {
    const recent = findRecentActiveIncident(createdAtValue - 60 * 1000, { unitId });
    if (recent) return { cooldown: true, recent };
    const incident = createIncident({ id, unitId, createdAt: createdAtValue, createdBy });
    const recorded = appendIncidentEvent({
      ...event,
      incidentId: incident.id,
      payload: { ...(event.payload || {}), number: incident.number },
    });
    return { incident, event: recorded, cooldown: false };
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

function listIncidents(status = null, { unitId = null, limit = null, offset = 0 } = {}) {
  const filters = [];
  const args = [];
  if (status) {
    filters.push('status = ?');
    args.push(status);
  }
  if (unitId) {
    // 未归属历史记录属于隔离的 legacy 命名空间，普通单位不可见。
    filters.push('unit_id = ?');
    args.push(unitId);
  }
  const where = filters.length ? `WHERE ${filters.join(' AND ')}` : '';
  const normalizedLimit = Number.isFinite(Number(limit)) && Number(limit) > 0
    ? Math.min(Math.floor(Number(limit)), 500)
    : null;
  const normalizedOffset = Number.isFinite(Number(offset)) && Number(offset) >= 0
    ? Math.min(Math.floor(Number(offset)), 10000)
    : 0;
  let pageSql = '';
  if (normalizedLimit == null) {
    if (normalizedOffset > 0) {
      pageSql = ' LIMIT -1 OFFSET ?';
      args.push(normalizedOffset);
    }
  } else {
    pageSql = ' LIMIT ? OFFSET ?';
    args.push(normalizedLimit, normalizedOffset);
  }
  return db.prepare(
    'SELECT * FROM incidents ' + where +
      ' ORDER BY CASE WHEN status = \'active\' THEN 0 ELSE 1 END, COALESCE(archived_at, last_activity_at) DESC, created_at DESC' + pageSql
  ).all(...args);
}

// 只把通过新建接口产生过 incident_created 事件的记录作为建档冷却依据，
// 避免维护迁移或单元测试直接写入的兼容警情阻塞真实用户建档。
function findRecentActiveIncident(createdAfter, { unitId = null } = {}) {
  const unitFilter = unitId ? ' AND i.unit_id = ? ' : '';
  const args = unitId ? [Number(createdAfter) || 0, unitId] : [Number(createdAfter) || 0];
  return db.prepare(
    'SELECT i.* FROM incidents i WHERE i.status = \'active\' AND i.created_at >= ? ' + unitFilter +
      'AND EXISTS (SELECT 1 FROM incident_events e WHERE e.incident_id = i.id AND e.type = \'incident_created\') ' +
      'ORDER BY i.created_at DESC LIMIT 1'
  ).get(...args) || null;
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
  const result = expectedVersion == null
    ? db.prepare('UPDATE incidents SET title = ?, version = version + 1 WHERE id = ?').run(clean, id)
    : db.prepare('UPDATE incidents SET title = ?, version = version + 1 WHERE id = ? AND version = ?').run(clean, id, current.version);
  if (expectedVersion != null && result.changes === 0) {
    const error = new Error('警情已被其他用户修改，请刷新后重试');
    error.code = 'VERSION_CONFLICT';
    throw error;
  }
  return getIncident(id);
}

function updateIncidentTitleWithEvent({ id, title, expectedVersion = null, event } = {}) {
  return transaction(() => {
    const incident = updateIncidentTitle(id, title, { expectedVersion });
    if (!incident || !event) return { incident, event: null, changed: Boolean(incident) };
    return { incident, event: appendIncidentEvent(event), changed: true };
  });
}

function setIncidentSuggestedTitle(id, title) {
  const clean = title == null ? null : String(title).trim().slice(0, 120) || null;
  db.prepare('UPDATE incidents SET suggested_title = ? WHERE id = ?').run(clean, id);
  return getIncident(id);
}

function touchIncidentActivity(id, at = Date.now()) {
  const current = getIncident(id);
  if (!current || current.status !== 'active') return current;
  db.prepare('UPDATE incidents SET last_activity_at = MAX(last_activity_at, ?) WHERE id = ? AND status = \'active\'').run(Number(at) || Date.now(), id);
  return getIncident(id);
}

function unresolvedActiveCount(id) {
  return db.prepare('SELECT COUNT(*) AS count FROM entries WHERE scene = ? AND exited_at IS NULL').get(id).count;
}

function archiveIncident(id, { archivedBy = null, now = Date.now(), auto = false, returnMeta = false } = {}) {
  const current = getIncident(id);
  if (!current) return returnMeta ? { incident: null, changed: false } : null;
  if (current.status === 'archived') return returnMeta ? { incident: current, changed: false } : current;
  const result = db.prepare(
    'UPDATE incidents SET status = \'archived\', archived_at = ?, archived_by = ?, auto_archived = ?, unresolved_active_count = ?, version = version + 1 WHERE id = ? AND status = \'active\''
  ).run(now, archivedBy, auto ? 1 : 0, unresolvedActiveCount(id), id);
  const archived = getIncident(id);
  return returnMeta ? { incident: archived, changed: result.changes > 0 } : archived;
}

function archiveIncidentWithEvent({ id, archivedBy = null, now = Date.now(), auto = false, event } = {}) {
  return transaction(() => {
    const result = archiveIncident(id, { archivedBy, now, auto, returnMeta: true });
    if (!result.incident || !result.changed || !event) return { ...result, event: null };
    return {
      ...result,
      event: appendIncidentEvent({
        ...event,
        payload: { ...(event.payload || {}), unresolved_active_count: result.incident.unresolved_active_count },
      }),
    };
  });
}

function archiveStaleIncidents({ now = Date.now(), inactivityMs = 12 * 3600 * 1000, unitId = null } = {}) {
  const cutoff = now - inactivityMs;
  const stale = unitId
    ? db.prepare('SELECT id FROM incidents WHERE status = \'active\' AND last_activity_at <= ? AND unit_id = ?').all(cutoff, unitId)
    : db.prepare('SELECT id FROM incidents WHERE status = \'active\' AND last_activity_at <= ?').all(cutoff);
  let archivedCount = 0;
  for (const row of stale) {
    const result = archiveIncident(row.id, { archivedBy: 'system', now, auto: true, returnMeta: true });
    const archived = result.incident;
    // 多个轮询请求可能同时发现同一条陈旧警情；只有真正完成 active→archived
    // 的调用可以写归档事件，避免时间线出现重复自动归档记录。
    if (result.changed && archived?.status === 'archived' && archived.archived_at === now) {
      archivedCount += 1;
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
  }
  return archivedCount;
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
  if (clientOpId) {
    const duplicate = getIncidentEventByClientOp(clientOpId);
    if (duplicate) return duplicate;
  }
  try {
    db.prepare(
      'INSERT INTO incident_events (id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name, source, client_op_id, payload, revision_of, voided_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
    ).run(id, incidentId, type, Number(occurredAt) || Date.now(), Number(recordedAt) || Date.now(),
      actorDeviceId, actorName, source, clientOpId, payload == null ? null : JSON.stringify(payload), revisionOf, voidedAt);
  } catch (error) {
    // 并发请求可能在“查询重复”与 INSERT 之间竞争；唯一索引获胜后返回
    // 已存在事件，保持和 PostgreSQL 驱动相同的幂等语义。
    if (clientOpId && String(error.message || '').includes('UNIQUE')) {
      return getIncidentEventByClientOp(clientOpId);
    }
    throw error;
  }
  return getIncidentEvent(id);
}

function listIncidentEvents(incidentId, { limit = 2000 } = {}) {
  return db.prepare(
    'SELECT * FROM incident_events WHERE incident_id = ? ORDER BY occurred_at DESC, recorded_at DESC LIMIT ?'
  ).all(incidentId, limitOf(limit, 2000, 5000)).map(eventWithPayload);
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

function listIncidentForcesBatch(incidentIds = []) {
  const ids = [...new Set(incidentIds.map((id) => String(id || '')).filter(Boolean))];
  if (ids.length === 0) return [];
  const placeholders = ids.map(() => '?').join(',');
  return db.prepare(
    'SELECT * FROM incident_forces WHERE incident_id IN (' + placeholders + ') ORDER BY incident_id ASC, station_name ASC'
  ).all(...ids);
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
    const result = expectedVersion == null
      ? db.prepare('UPDATE incident_forces SET station_id = ?, vehicle_count = ?, personnel_count = ?, updated_at = ?, version = version + 1 WHERE id = ?')
        .run(stationId, vehicles, personnel, Date.now(), current.id)
      : db.prepare('UPDATE incident_forces SET station_id = ?, vehicle_count = ?, personnel_count = ?, updated_at = ?, version = version + 1 WHERE id = ? AND version = ?')
        .run(stationId, vehicles, personnel, Date.now(), current.id, current.version);
    if (expectedVersion != null && result.changes === 0) {
      const error = new Error('该消防站的参战力量已被其他用户修改，请刷新后重试');
      error.code = 'VERSION_CONFLICT';
      throw error;
    }
    return getIncidentForce(current.id);
  }
  const now = Date.now();
  db.prepare('INSERT INTO incident_forces (id, incident_id, station_id, station_name, vehicle_count, personnel_count, created_at, updated_at, version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)')
    .run(id, incidentId, stationId, cleanName, vehicles, personnel, now, now);
  return getIncidentForce(id);
}

function upsertIncidentForceWithEvent({ force, event, activityAt = null } = {}) {
  return transaction(() => {
    const updated = upsertIncidentForce(force);
    if (activityAt != null) touchIncidentActivity(event.incidentId, activityAt);
    return { force: updated, event: appendIncidentEvent(event) };
  });
}

function deleteIncidentForce(id) {
  return db.prepare('DELETE FROM incident_forces WHERE id = ?').run(id).changes;
}

function deleteIncidentForceWithEvent({ id, incidentId, event, activityAt = null } = {}) {
  return transaction(() => {
    const changed = deleteIncidentForce(id);
    if (changed > 0 && activityAt != null) touchIncidentActivity(incidentId, activityAt);
    const recorded = changed > 0 && event ? appendIncidentEvent(event) : null;
    return { changed: changed > 0, event: recorded };
  });
}

function getDeviceProfile(deviceId) {
  const id = String(deviceId || '');
  const row = db.prepare('SELECT device_id, unit_id, real_name, updated_at FROM device_profiles WHERE device_id = ?').get(id);
  return row || { device_id: id, unit_id: null, real_name: '', updated_at: 0 };
}

function saveDeviceProfile(deviceId, realName, unitId = null) {
  const id = String(deviceId || '');
  const name = String(realName || '').trim().slice(0, 32);
  const now = Date.now();
  db.prepare('INSERT INTO device_profiles (device_id, unit_id, real_name, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(device_id) DO UPDATE SET unit_id = excluded.unit_id, real_name = excluded.real_name, updated_at = excluded.updated_at')
    .run(id, unitId, name, now);
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

module.exports = {
  getUnit,
  findUnit,
  findUnitMember,
  listUnitMembers,
  addUnitMember,
  updateUnitMember,
  createAuthSession,
  getAuthSession,
  revokeAuthSession,
  revokeAuthSessionsForMember,
  getOperation,
  beginOperation,
  completeOperation,
  releaseOperation,
  getIncident,
  createIncident,
  createIncidentWithEvent,
  listIncidents,
  findRecentActiveIncident,
  updateIncidentTitle,
  updateIncidentTitleWithEvent,
  setIncidentSuggestedTitle,
  touchIncidentActivity,
  archiveIncident,
  archiveIncidentWithEvent,
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
  upsertIncidentForceWithEvent,
  deleteIncidentForce,
  deleteIncidentForceWithEvent,
  listIncidentForcesBatch,
  getDeviceProfile,
  saveDeviceProfile,
  listEntries,
  getEntry,
  createEntry,
  createEntryWithEvent,
  markExited,
  markExitedIfActive,
  exitEntryWithEvent,
  updatePressureWithEvent,
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
  addLogs,
  listLogs,
  clearLogs,
  purgeOldLogs,
  listNotes,
  getNote,
  createNote,
  createNoteWithEvent,
  updateNote,
  updateNoteWithEvent,
  deleteNote,
  deleteNoteWithEvent,
  purgeOldNotes,
  listChatMessages,
  createChatMessage,
  clearChatMessages,
  purgeOldChatMessages,
  getUserSettings,
  saveUserSettings,
};
