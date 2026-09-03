const { Client, Pool } = require('pg');
const { AsyncLocalStorage } = require('node:async_hooks');
const { migrate } = require('./postgres-migrator');

const tables = new Set([
  'units', 'unit_members', 'auth_sessions', 'incidents', 'entries', 'pressure_samples',
  'notes', 'firefighters', 'hotwords', 'stations', 'incident_forces', 'incident_events',
  'operation_ledger', 'device_profiles', 'user_settings', 'logs', 'chat_messages',
  'sync_streams', 'sync_events',
]);

const databaseUrl = process.env.DATABASE_URL ||
  (process.env.NODE_ENV === 'test' ? 'postgresql:///watchdog_test' : 'postgresql:///watchdog_dev');
const sslEnabled = ['1', 'true', 'require'].includes(String(process.env.DATABASE_SSL || '').toLowerCase());
const pool = new Pool({
  connectionString: databaseUrl,
  max: Math.max(2, Number(process.env.DATABASE_POOL_MAX || 10)),
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,
  ...(sslEnabled ? { ssl: { rejectUnauthorized: false } } : {}),
});

const transactionStorage = new AsyncLocalStorage();
const ready = migrate(pool);

// pg 返回 BIGINT 为字符串，以避免 JavaScript 精度损失。WatchDog 的旧 REST
// 契约对时间戳/计数使用 JSON number，因此在仓储边界仅转换已知安全字段；
// 游标由同步层显式转为十进制字符串，绝不依赖这里的隐式转换。
const numericColumns = new Set([
  'created_at', 'updated_at', 'occurred_at', 'recorded_at', 'entry_at', 'exit_at',
  'exited_at', 'archived_at', 'last_activity_at', 'expires_at', 'last_seen_at',
  'revoked_at', 'reported_at', 'completed_at', 'lease_until', 'response_status',
  'duration_min', 'auto_archived', 'unresolved_active_count', 'version',
  'vehicle_count', 'personnel_count', 'roster_version',
]);

function normalizeRow(row) {
  if (!row || typeof row !== 'object' || Array.isArray(row)) return row;
  const copy = { ...row };
  for (const key of numericColumns) {
    if (typeof copy[key] === 'string' && /^-?\d+$/.test(copy[key])) copy[key] = Number(copy[key]);
  }
  return copy;
}

function identifier(value) {
  const clean = String(value || '').trim();
  if (!/^[a-z_][a-z0-9_]*$/i.test(clean)) throw new Error(`非法数据库标识符：${clean}`);
  return `"${clean}"`;
}

function tableName(table) {
  if (!tables.has(table)) throw new Error(`未知数据表：${table}`);
  return identifier(table);
}

function columns(value) {
  if (!value || value === '*') return '*';
  return String(value).split(',').map((item) => {
    const clean = item.trim();
    if (!/^[a-z_][a-z0-9_]*$/i.test(clean)) throw new Error(`非法字段：${clean}`);
    return identifier(clean);
  }).join(',');
}

function addFilter(parts, values, key, raw) {
  const field = identifier(key);
  if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
    const op = String(raw.op || '=').toLowerCase();
    if (op === 'is' && String(raw.value).toLowerCase() === 'null') {
      parts.push(`${field} IS NULL`);
      return;
    }
    if (op === 'in') {
      const list = Array.isArray(raw.value) ? raw.value : [];
      if (list.length === 0) {
        parts.push('FALSE');
        return;
      }
      const placeholders = list.map((item) => {
        values.push(item);
        return `$${values.length}`;
      });
      parts.push(`${field} IN (${placeholders.join(',')})`);
      return;
    }
    const operators = { eq: '=', gt: '>', gte: '>=', lt: '<', lte: '<=', neq: '<>' };
    if (!operators[op]) throw new Error(`非法查询操作符：${op}`);
    values.push(raw.value);
    parts.push(`${field} ${operators[op]} $${values.length}`);
    return;
  }
  values.push(raw);
  parts.push(`${field} = $${values.length}`);
}

function whereClause(filters, values) {
  const parts = [];
  for (const [key, value] of Object.entries(filters || {})) addFilter(parts, values, key, value);
  return parts.length ? ` WHERE ${parts.join(' AND ')}` : '';
}

function orderClause(order) {
  if (!order) return '';
  const items = String(order).split(',').map((item) => item.trim()).filter(Boolean).map((item) => {
    const match = item.match(/^([a-z_][a-z0-9_]*)(?:\.(asc|desc))?$/i);
    if (!match) throw new Error(`非法排序：${item}`);
    return `${identifier(match[1])} ${(match[2] || 'asc').toUpperCase()}`;
  });
  return items.length ? ` ORDER BY ${items.join(', ')}` : '';
}

function queryClient() {
  return transactionStorage.getStore()?.client || pool;
}

async function query(text, values = []) {
  return queryClient().query(text, values);
}

async function select(table, { select = '*', filters = {}, order = '', limit, offset, single = false } = {}) {
  const values = [];
  let sql = `SELECT ${columns(select)} FROM ${tableName(table)}${whereClause(filters, values)}${orderClause(order)}`;
  if (limit != null) {
    values.push(Math.max(0, Math.floor(Number(limit) || 0)));
    sql += ` LIMIT $${values.length}`;
  }
  if (offset != null) {
    values.push(Math.max(0, Math.floor(Number(offset) || 0)));
    sql += ` OFFSET $${values.length}`;
  }
  const rows = (await query(sql, values)).rows.map(normalizeRow);
  return single ? rows[0] : rows;
}

function normalizeRows(rows) {
  return Array.isArray(rows) ? rows : [rows];
}

function insertColumns(rows) {
  const names = new Set();
  for (const row of rows) for (const key of Object.keys(row)) names.add(key);
  return [...names].sort();
}

async function insert(table, inputRows, { onConflict = '', ignoreDuplicates = false } = {}) {
  const rows = normalizeRows(inputRows).filter(Boolean);
  if (rows.length === 0) return [];
  const names = insertColumns(rows);
  if (names.length === 0) return [];
  const values = [];
  const tuples = rows.map((row) => {
    const placeholders = names.map((name) => {
      values.push(row[name] === undefined ? null : row[name]);
      return `$${values.length}`;
    });
    return `(${placeholders.join(',')})`;
  });
  let conflict = '';
  if (onConflict) {
    const conflictNames = String(onConflict).split(',').map((item) => item.trim());
    const updateNames = names.filter((name) => !conflictNames.includes(name));
    const action = ignoreDuplicates || updateNames.length === 0
      ? 'DO NOTHING'
      : `DO UPDATE SET ${updateNames.map((name) => `${identifier(name)} = EXCLUDED.${identifier(name)}`).join(', ')}`;
    conflict = ` ON CONFLICT (${conflictNames.map(identifier).join(',')}) ${action}`;
  }
  let result;
  try {
    result = await query(
      `INSERT INTO ${tableName(table)} (${names.map(identifier).join(',')}) VALUES ${tuples.join(',')}${conflict} RETURNING *`,
      values,
    );
  } catch (error) {
    if (error?.code === '23505') error.status = 409;
    throw error;
  }
  return result.rows.map(normalizeRow);
}

async function update(table, filters, valuesObject) {
  const entries = Object.entries(valuesObject || {}).filter(([, value]) => value !== undefined);
  if (entries.length === 0) return { rows: [], changes: 0 };
  const values = [];
  const sets = entries.map(([key, value]) => {
    values.push(value);
    return `${identifier(key)} = $${values.length}`;
  });
  const where = whereClause(filters, values);
  const result = await query(`UPDATE ${tableName(table)} SET ${sets.join(', ')}${where} RETURNING *`, values);
  return { rows: result.rows.map(normalizeRow), changes: result.rowCount };
}

async function remove(table, filters) {
  const values = [];
  const result = await query(`DELETE FROM ${tableName(table)}${whereClause(filters, values)} RETURNING *`, values);
  return { rows: result.rows.map(normalizeRow), changes: result.rowCount };
}

async function upsert(table, rows, { onConflict } = {}) {
  const normalized = normalizeRows(rows).filter(Boolean);
  if (normalized.length === 0) return [];
  if (!onConflict) throw new Error('upsert 缺少冲突字段');
  const names = insertColumns(normalized);
  const conflictNames = String(onConflict).split(',').map((item) => item.trim());
  const updateNames = names.filter((name) => !conflictNames.includes(name));
  const values = [];
  const tuples = normalized.map((row) => `(${names.map((name) => {
    values.push(row[name] === undefined ? null : row[name]);
    return `$${values.length}`;
  }).join(',')})`);
  const updates = updateNames.length
    ? ` DO UPDATE SET ${updateNames.map((name) => `${identifier(name)} = EXCLUDED.${identifier(name)}`).join(', ')}`
    : ' DO NOTHING';
  const result = await query(
    `INSERT INTO ${tableName(table)} (${names.map(identifier).join(',')}) VALUES ${tuples.join(',')} ON CONFLICT (${conflictNames.map(identifier).join(',')})${updates} RETURNING *`,
    values,
  );
  return result.rows.map(normalizeRow);
}

async function transaction(fn) {
  const current = transactionStorage.getStore()?.client;
  if (current) return fn(current);
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await transactionStorage.run({ client }, () => fn(client));
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

async function listenSync(onNotification) {
  const client = new Client({ connectionString: databaseUrl, ...(sslEnabled ? { ssl: { rejectUnauthorized: false } } : {}) });
  await client.connect();
  await client.query('LISTEN watchdog_sync');
  const handler = (message) => {
    if (message.channel !== 'watchdog_sync') return;
    try { onNotification(JSON.parse(message.payload || '{}')); } catch (_) {}
  };
  client.on('notification', handler);
  return async () => {
    client.removeListener('notification', handler);
    await client.query('UNLISTEN watchdog_sync').catch(() => {});
    await client.end().catch(() => {});
  };
}

async function close() {
  await pool.end();
}

module.exports = {
  databaseUrl,
  pool,
  ready,
  query,
  select,
  insert,
  update,
  remove,
  upsert,
  transaction,
  listenSync,
  close,
};
