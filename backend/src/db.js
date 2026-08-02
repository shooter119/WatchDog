const { DatabaseSync } = require('node:sqlite');
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

module.exports = {
  listEntries,
  getEntry,
  createEntry,
  markExited,
  listFirefighters,
  addFirefighter,
  removeFirefighter,
  listHotwords,
  addHotword,
  removeHotword,
};
