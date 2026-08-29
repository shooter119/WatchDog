/*
 * 将版本化 PostgreSQL 迁移应用到 CloudBase PG 模式环境。
 *
 * 需要：
 *   CLOUDBASE_ENV_ID
 *   CLOUDBASE_SECRET_ID
 *   CLOUDBASE_SECRET_KEY
 *
 * 运行时业务请求使用 CLOUDBASE_API_KEY；该脚本使用腾讯云密钥调用
 * CloudBase Manager Node SDK 的 executePGSql，仅用于 DDL/初始化。
 */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const migrationsDir = path.join(__dirname, '..', 'migrations');

function splitStatements(sql) {
  const source = String(sql).replace(/^\s*--.*$/gm, '');
  const statements = [];
  let start = 0;
  let dollarTag = null;
  let quote = null;
  let lineComment = false;
  let blockComment = false;
  for (let index = 0; index < source.length; index++) {
    const char = source[index];
    const next = source[index + 1];
    if (lineComment) {
      if (char === '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (char === '*' && next === '/') { blockComment = false; index++; }
      continue;
    }
    if (!quote && !dollarTag && char === '-' && next === '-') { lineComment = true; index++; continue; }
    if (!quote && !dollarTag && char === '/' && next === '*') { blockComment = true; index++; continue; }
    if (dollarTag) {
      if (source.startsWith(dollarTag, index)) { index += dollarTag.length - 1; dollarTag = null; }
      continue;
    }
    if (quote) {
      if (char === quote) {
        if (source[index + 1] === quote) { index++; continue; }
        quote = null;
      }
      continue;
    }
    if (char === '\'' || char === '"') { quote = char; continue; }
    if (char === '$') {
      const match = source.slice(index).match(/^\$[A-Za-z_][A-Za-z0-9_]*\$|^\$\$/);
      if (match) { dollarTag = match[0]; index += dollarTag.length - 1; continue; }
    }
    if (char === ';') {
      const statement = source.slice(start, index).trim();
      if (statement) statements.push(statement);
      start = index + 1;
    }
  }
  const tail = source.slice(start).trim();
  if (tail) statements.push(tail);
  return statements;
}

function migrationChecksum(sql) {
  return crypto.createHash('sha256').update(String(sql)).digest('hex');
}

function resultRows(result) {
  const columns = Array.isArray(result?.Columns) ? result.Columns : [];
  const rows = Array.isArray(result?.Rows) ? result.Rows : [];
  return rows.map((raw) => {
    let values = raw;
    if (typeof raw === 'string') {
      try { values = JSON.parse(raw); } catch (_) { values = [raw]; }
    }
    if (!Array.isArray(values)) return values;
    return Object.fromEntries(columns.map((column, index) => [column, values[index]]));
  });
}

async function main() {
  const envId = process.env.CLOUDBASE_ENV_ID || process.env.CLOUDBASE_ENV || '';
  const secretId = process.env.CLOUDBASE_SECRET_ID || process.env.TENCENTCLOUD_SECRET_ID || '';
  const secretKey = process.env.CLOUDBASE_SECRET_KEY || process.env.TENCENTCLOUD_SECRET_KEY || '';
  if (!envId || !secretId || !secretKey) {
    throw new Error('请设置 CLOUDBASE_ENV_ID、CLOUDBASE_SECRET_ID、CLOUDBASE_SECRET_KEY');
  }

  const CloudBaseModule = require('@cloudbase/manager-node');
  const CloudBase = CloudBaseModule.default || CloudBaseModule;
  const app = CloudBase.init({ secretId, secretKey, envId });
  const database = app.database;
  const execute = (sql) => database.executePGSql({ Sql: sql });
  const quote = (value) => `'${String(value).replaceAll("'", "''")}'`;

  // CloudBase Manager 的 ExecutePGSql 按调用提交，不能假设跨调用 BEGIN/COMMIT 有效；
  // 因此每条迁移必须可重复执行，成功记录只在该文件全部语句完成后写入。
  await execute(`CREATE TABLE IF NOT EXISTS public.schema_migrations (version TEXT PRIMARY KEY, checksum TEXT NOT NULL, applied_at BIGINT NOT NULL)`);
  const files = fs.readdirSync(migrationsDir)
    .filter((file) => /^\d+_.+\.sql$/.test(file))
    .sort();
  if (files.length === 0) throw new Error('migrations 目录为空');

  for (const file of files) {
    const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    const version = file.replace(/\.sql$/, '');
    const checksum = migrationChecksum(sql);
    const applied = resultRows(await execute(`SELECT version, checksum FROM public.schema_migrations WHERE version = ${quote(version)}`))[0];
    if (applied) {
      if (applied.checksum !== checksum) throw new Error(`迁移文件校验和变化，拒绝跳过: ${file}`);
      console.log(`[migration] ${file}: 已应用，跳过`);
      continue;
    }
    const statements = splitStatements(sql);
    console.log(`[migration] ${file}: ${statements.length} statements`);
    for (const statement of statements) {
      await execute(statement);
    }
    await execute(`INSERT INTO public.schema_migrations (version, checksum, applied_at) VALUES (${quote(version)}, ${quote(checksum)}, ${Date.now()}) ON CONFLICT (version) DO UPDATE SET checksum = EXCLUDED.checksum, applied_at = EXCLUDED.applied_at`);
  }
  console.log('CloudBase PostgreSQL 结构迁移完成。');
}

if (require.main === module) {
  main().catch((error) => {
    console.error('CloudBase PostgreSQL 迁移失败:', error.stack || error);
    process.exitCode = 1;
  });
}

module.exports = { splitStatements, migrationChecksum, resultRows, main };
