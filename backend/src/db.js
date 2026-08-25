// 本地开发和测试默认使用 SQLite；CloudBase 云托管通过环境变量切换到 PostgreSQL。
// SQLite 仅作为本地开发/测试适配器，生产 CloudBase 使用 PostgREST + service_role。
const driver = String(process.env.WATCHDOG_DB_DRIVER || 'sqlite').toLowerCase();

module.exports = ['cloudbase', 'postgres', 'postgresql'].includes(driver)
  ? require('./db-postgres')
  : require('./db-sqlite');
