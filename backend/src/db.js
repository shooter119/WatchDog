// 运行时统一使用标准 PostgreSQL。SQLite 仅保留给现有同步单测，不能作为
// 本地业务运行或生产回退，避免把单机文件数据库误当成实时多实例存储。
const driver = String(
  process.env.WATCHDOG_DB_DRIVER || (process.env.NODE_ENV === 'test' ? 'sqlite' : 'postgres'),
).toLowerCase();
const postgresDrivers = ['postgres', 'postgresql'];
if (process.env.NODE_ENV === 'test' && driver === 'sqlite') {
  module.exports = require('./db-sqlite');
} else {
  if (!postgresDrivers.includes(driver)) {
    throw new Error('业务运行时必须使用 WATCHDOG_DB_DRIVER=postgres');
  }
  module.exports = require('./db-postgres');
}
