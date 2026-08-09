/*
 * 将现有 SQLite 数据复制到 CloudBase PostgreSQL。
 *
 * 运行前设置：
 *   WATCHDOG_DB_DRIVER=cloudbase
 *   CLOUDBASE_ENV_ID=...
 *   CLOUDBASE_API_KEY=...
 *   WATCHDOG_SOURCE_DB=/path/to/watchdog.db
 *
 * 该脚本只追加缺失记录，不删除 CloudBase 数据，适合上线前重复执行。
 */
const { DatabaseSync } = require('node:sqlite');
const path = require('node:path');

const sourcePath = process.env.WATCHDOG_SOURCE_DB || path.join(__dirname, '..', 'data', 'watchdog.db');
const source = new DatabaseSync(sourcePath, { readOnly: true });
const target = require('../src/db');

const TABLE_COLUMNS = {
  incidents: ['id', 'number', 'title', 'suggested_title', 'status', 'created_at', 'last_activity_at', 'archived_at', 'archived_by', 'auto_archived', 'unresolved_active_count', 'created_by', 'version'],
  stations: ['id', 'name', 'normalized_name', 'created_at', 'created_by'],
  firefighters: ['id', 'name', 'created_at'],
  hotwords: ['id', 'word', 'created_at'],
  entries: ['id', 'scene', 'name', 'pressure_mpa', 'duration_min', 'entry_at', 'exit_at', 'exited_at', 'source', 'raw_text', 'created_at', 'consumption_actual_lpm'],
  pressure_samples: ['id', 'entry_id', 'scene', 'name', 'pressure_mpa', 'reported_at'],
  notes: ['id', 'scene', 'text', 'category', 'author', 'created_at', 'updated_at'],
  chat_messages: ['id', 'scene', 'role', 'content', 'created_at'],
  user_settings: ['user_id', 'scene', 'key', 'value', 'updated_at'],
  logs: ['id', 'scene', 'device', 'op_id', 'level', 'stage', 'msg', 'data', 'created_at'],
  incident_events: ['id', 'incident_id', 'type', 'occurred_at', 'recorded_at', 'actor_device_id', 'actor_name', 'source', 'client_op_id', 'payload', 'revision_of', 'voided_at'],
  incident_forces: ['id', 'incident_id', 'station_id', 'station_name', 'vehicle_count', 'personnel_count', 'created_at', 'updated_at', 'version'],
  device_profiles: ['device_id', 'real_name', 'updated_at'],
};

function sourceTables() {
  return new Set(source.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").all().map((row) => row.name));
}

function sourceColumns(table) {
  return new Set(source.prepare(`PRAGMA table_info(${table})`).all().map((row) => row.name));
}

function defaultValue(table, column) {
  if (column === 'scene') return 'default';
  if (column === 'status') return 'active';
  if (column === 'source') return 'voice';
  if (column === 'category') return '其他';
  if (column === 'role') return 'user';
  if (column === 'level') return 'info';
  if (column === 'auto_archived') return 0;
  if (column === 'unresolved_active_count') return 0;
  if (column === 'version') return 1;
  if (column === 'created_at' || column === 'updated_at' || column === 'last_activity_at') return Date.now();
  if (column === 'title' || column === 'suggested_title' || column === 'archived_at' || column === 'archived_by' || column === 'created_by' || column === 'station_id' || column === 'device' || column === 'op_id' || column === 'actor_device_id' || column === 'actor_name' || column === 'client_op_id' || column === 'payload' || column === 'revision_of' || column === 'voided_at' || column === 'consumption_actual_lpm' || column === 'raw_text' || column === 'author') return null;
  return null;
}

async function copyTable(table, tables) {
  if (!tables.has(table)) {
    console.log(`[skip] ${table}: SQLite 中不存在`);
    return 0;
  }
  const targetColumns = TABLE_COLUMNS[table];
  const columns = sourceColumns(table);
  const rows = source.prepare(`SELECT * FROM ${table}`).all();
  let copied = 0;
  const placeholders = targetColumns.map(() => '?').join(', ');
  const sql = `INSERT INTO ${table} (${targetColumns.join(', ')}) VALUES (${placeholders}) ON CONFLICT DO NOTHING`;
  for (const row of rows) {
    const values = targetColumns.map((column) => columns.has(column) ? row[column] : defaultValue(table, column));
    await target.executeSQL(sql, values);
    copied++;
  }
  console.log(`[ok] ${table}: ${copied} 条已提交`);
  return copied;
}

async function main() {
  await target.ready;
  const tables = sourceTables();
  let total = 0;
  // 先主表，再依赖主键的现场记录和事件，避免外键策略开启时出现顺序问题。
  for (const table of Object.keys(TABLE_COLUMNS)) total += await copyTable(table, tables);
  console.log(`迁移完成，共处理 ${total} 条记录。`);
}

main().catch((error) => {
  console.error('迁移失败:', error.stack || error);
  process.exitCode = 1;
});
