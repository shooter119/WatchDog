// 本地开发和测试默认使用 SQLite；CloudBase 云托管通过环境变量切换到 PostgreSQL。
// SQLite 仅作为本地开发/测试适配器，生产环境禁止静默落到容器本地盘。
const driver = String(process.env.WATCHDOG_DB_DRIVER || 'sqlite').toLowerCase();
const postgresDrivers = ['cloudbase', 'postgres', 'postgresql'];
if (process.env.NODE_ENV === 'production' && !postgresDrivers.includes(driver)) {
  throw new Error('生产环境必须显式配置 WATCHDOG_DB_DRIVER=postgres（禁止回退 SQLite）');
}

module.exports = postgresDrivers.includes(driver)
  ? require('./db-postgres')
  : require('./db-sqlite');
