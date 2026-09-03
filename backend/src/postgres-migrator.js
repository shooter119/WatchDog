const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');

const MIGRATION_DIR = path.join(__dirname, '..', 'migrations');
const BASELINE = '000_standard_baseline.sql';

async function checksum(file) {
  const content = await fs.readFile(file);
  return crypto.createHash('sha256').update(content).digest('hex');
}

async function migrate(pool) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(1942082026)');
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version TEXT PRIMARY KEY,
        checksum TEXT NOT NULL,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    `);
    const file = path.join(MIGRATION_DIR, BASELINE);
    const digest = await checksum(file);
    const existing = await client.query(
      'SELECT checksum FROM schema_migrations WHERE version = $1',
      [BASELINE],
    );
    if (existing.rowCount && existing.rows[0].checksum !== digest) {
      throw new Error(`迁移文件校验失败：${BASELINE}`);
    }
    if (!existing.rowCount) {
      await client.query(await fs.readFile(file, 'utf8'));
      await client.query(
        'INSERT INTO schema_migrations (version, checksum) VALUES ($1, $2)',
        [BASELINE, digest],
      );
    }
    await client.query('COMMIT');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

module.exports = { migrate };

if (require.main === module) {
  const { Pool } = require('pg');
  const url = process.env.DATABASE_URL || 'postgresql:///watchdog_dev';
  const pool = new Pool({ connectionString: url });
  migrate(pool)
    .then(() => console.log(`PostgreSQL 迁移完成：${url}`))
    .catch((error) => {
      console.error(`PostgreSQL 迁移失败：${error.message}`);
      process.exitCode = 1;
    })
    .finally(() => pool.end());
}
