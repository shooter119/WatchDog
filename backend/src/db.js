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
  scene TEXT NOT NULL DEFAULT 'default',
  name TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(scene, name)
);

CREATE TABLE IF NOT EXISTS hotwords (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  word TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(scene, word)
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
`);

// 旧库迁移：无 scene 列时重建表（新表场景内唯一，跨场景允许同名）
function hasColumn(table, column) {
  return db.prepare(`PRAGMA table_info(${table})`).all().some((c) => c.name === column);
}
for (const t of ['entries', 'firefighters', 'hotwords']) {
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
// 迁移后确保唯一约束与索引
db.exec(`
CREATE INDEX IF NOT EXISTS idx_entries_scene ON entries(scene, entry_at);
CREATE UNIQUE INDEX IF NOT EXISTS idx_firefighters_scene_name ON firefighters(scene, name);
CREATE UNIQUE INDEX IF NOT EXISTS idx_hotwords_scene_word ON hotwords(scene, word);
`);

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

function listFirefighters(scene = 'default') {
  return db.prepare('SELECT id, name FROM firefighters WHERE scene = ? ORDER BY created_at ASC').all(scene);
}

function addFirefighter(id, name, scene = 'default') {
  db.prepare('INSERT INTO firefighters (id, scene, name, created_at) VALUES (?, ?, ?, ?)').run(id, scene, name, Date.now());
  return db.prepare('SELECT id, name FROM firefighters WHERE id = ?').get(id);
}

function removeFirefighter(id) {
  db.prepare('DELETE FROM firefighters WHERE id = ?').run(id);
}

function listHotwords(scene = 'default') {
  return db.prepare('SELECT id, word FROM hotwords WHERE scene = ? ORDER BY created_at ASC').all(scene);
}

function addHotword(id, word, scene = 'default') {
  db.prepare('INSERT INTO hotwords (id, scene, word, created_at) VALUES (?, ?, ?, ?)').run(id, scene, word, Date.now());
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

/** 全部场景码（跨 entries/firefighters/hotwords 去重） */
function listScenes() {
  const rows = db
    .prepare(
      'SELECT scene FROM entries UNION SELECT scene FROM firefighters UNION SELECT scene FROM hotwords ORDER BY scene'
    )
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
};
