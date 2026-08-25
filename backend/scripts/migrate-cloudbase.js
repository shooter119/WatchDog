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
const migrationsDir = path.join(__dirname, '..', 'migrations');

function splitStatements(sql) {
  return String(sql)
    .replace(/^\s*--.*$/gm, '')
    .split(/;\s*/)
    .map((statement) => statement.trim())
    .filter(Boolean);
}

async function main() {
  const files = fs.readdirSync(migrationsDir)
    .filter((file) => /^\d+_.+\.sql$/.test(file))
    .sort();
  if (files.length === 0) throw new Error('migrations 目录为空');

  for (const file of files) {
    const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
    const statements = splitStatements(sql);
    console.log(`[migration] ${file}: ${statements.length} statements`);
    for (const statement of statements) {
      await database.executePGSql({ Sql: statement });
    }
  }
  console.log('CloudBase PostgreSQL 结构迁移完成。');
}

main().catch((error) => {
  console.error('CloudBase PostgreSQL 迁移失败:', error.stack || error);
  process.exitCode = 1;
});
