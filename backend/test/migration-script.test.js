const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { splitStatements, migrationChecksum, resultRows } = require('../scripts/migrate-cloudbase');

test('PostgreSQL 迁移脚本不会拆开字符串和 dollar-quoted 函数体', () => {
  const statements = splitStatements(`
    CREATE TABLE demo (value TEXT);
    CREATE FUNCTION demo_fn() RETURNS TEXT AS $$
    BEGIN
      RETURN 'a;b';
    END;
    $$ LANGUAGE plpgsql;
    INSERT INTO demo VALUES ('tail;value');
  `);
  assert.equal(statements.length, 3);
  assert.match(statements[1], /RETURN 'a;b'/);
  assert.match(statements[2], /tail;value/);
  assert.equal(migrationChecksum('a').length, 64);
});

test('迁移脚本可把 CloudBase ExecutePGSql 行结果映射为对象', () => {
  const rows = resultRows({ Columns: ['version', 'checksum'], Rows: ['["005","abc"]'] });
  assert.deepEqual(rows, [{ version: '005', checksum: 'abc' }]);
});

test('原子 RPC 的 client_op_id 冲突目标具备可匹配的完整唯一索引', () => {
  const rpc = fs.readFileSync(path.join(__dirname, '..', 'migrations', '007_atomic_write_functions.sql'), 'utf8');
  const conflictTargets = rpc.match(/ON CONFLICT \(client_op_id\) DO NOTHING/g) || [];
  assert.equal(conflictTargets.length, 11);

  const indexMigration = fs.readFileSync(path.join(__dirname, '..', 'migrations', '008_atomic_rpc_conflict_index.sql'), 'utf8');
  assert.match(indexMigration, /CREATE UNIQUE INDEX IF NOT EXISTS[\s\S]+ON public\.incident_events\(client_op_id\)/);
  assert.doesNotMatch(indexMigration, /WHERE\s+client_op_id\s+IS\s+NOT\s+NULL/i);

  const otaMigration = fs.readFileSync(path.join(__dirname, '..', 'migrations', '009_ota_public_bucket.sql'), 'utf8');
  assert.match(otaMigration, /watchdog-ota/);
  assert.match(otaMigration, /CREATE POLICY watchdog_ota_public_read/);
  assert.match(otaMigration, /TO anon, authenticated/);
});
