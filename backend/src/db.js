const { DatabaseSync } = require('node:sqlite');
const { randomUUID } = require('node:crypto');
const path = require('path');
const fs = require('fs');

const DATA_DIR = process.env.WATCHDOG_DATA_DIR || path.join(__dirname, '..', 'data');
fs.mkdirSync(DATA_DIR, { recursive: true });

const db = new DatabaseSync(path.join(DATA_DIR, 'watchdog.db'));
db.exec('PRAGMA journal_mode = WAL;');

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

CREATE TABLE IF NOT EXISTS user_settings (
  user_id TEXT NOT NULL,
  scene TEXT NOT NULL DEFAULT 'default',
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, scene, key)
);
CREATE INDEX IF NOT EXISTS idx_user_settings_scene ON user_settings(scene, user_id);

`);


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

function createEntry({ id, scene = 'default', name, pressureMpa, durationMin, entryAtMs, exitAtMs, source = 'voice', rawText = null }) {
  db.prepare(
    'INSERT INTO entries (id, scene, name, pressure_mpa, duration_min, entry_at, exit_at, source, raw_text, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)'
  ).run(id, scene, name, pressureMpa, durationMin, entryAtMs, exitAtMs, source, rawText, Date.now());
  return getEntry(id);
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
function updateEntry(id, { name, pressureMpa, durationMin, exitAtMs }) {
  db.prepare(
    'UPDATE entries SET name = COALESCE(?, name), pressure_mpa = COALESCE(?, pressure_mpa), duration_min = COALESCE(?, duration_min), exit_at = COALESCE(?, exit_at) WHERE id = ?'
  ).run(name ?? null, pressureMpa ?? null, durationMin ?? null, exitAtMs ?? null, id);
  return getEntry(id);
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
  return r.changes;
}

/** 全部场景码（仅 entries 产生场景；消防员名单与热词全局共享） */
function listScenes() {
  const rows = db
    .prepare('SELECT scene FROM entries ORDER BY scene')
    .all();
  return rows.map((r) => r.scene);
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

module.exports = {
  listEntries,
  getEntry,
  createEntry,
  markExited,
  findActiveByName,
  updateEntry,
  listFirefighters,
  addFirefighter,
  removeFirefighter,
  listHotwords,
  addHotword,
  removeHotword,
  purgeOldExited,
  listScenes,
  addLog,
  listLogs,
  clearLogs,
  purgeOldLogs,
  getUserSettings,
  saveUserSettings,
};
