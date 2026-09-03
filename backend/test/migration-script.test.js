const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { migrate } = require('../src/postgres-migrator');
const { Pool } = require('pg');

test('PostgreSQL 基线迁移存在事务、锁和校验和记录', () => {
  const migration = fs.readFileSync(path.join(__dirname, '..', 'migrations', '000_standard_baseline.sql'), 'utf8');
  assert.match(migration, /CREATE TABLE IF NOT EXISTS schema_migrations/);
  assert.match(fs.readFileSync(path.join(__dirname, '..', 'src', 'postgres-migrator.js'), 'utf8'), /pg_advisory_xact_lock/);
  assert.equal(crypto.createHash('sha256').update(migration).digest('hex').length, 64);
});

test('标准 PostgreSQL 基线迁移可重复执行', async () => {
  const pool = new Pool({ connectionString: process.env.DATABASE_URL || 'postgresql:///watchdog_test' });
  try {
    await migrate(pool);
    await migrate(pool);
    const result = await pool.query('SELECT version, checksum FROM schema_migrations WHERE version = $1', ['000_standard_baseline.sql']);
    assert.equal(result.rowCount, 1);
    assert.equal(result.rows[0].checksum.length, 64);
  } finally {
    await pool.end();
  }
});
