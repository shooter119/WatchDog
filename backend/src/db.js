// 本地开发和旧 VPS 默认使用 SQLite；CloudBase 云托管通过环境变量切换到 PostgreSQL。
// 保留 SQLite 实现是为了让离线开发、单元测试和现有 ByteVirt 服务继续稳定运行。
const driver = String(process.env.WATCHDOG_DB_DRIVER || 'sqlite').toLowerCase();

module.exports = driver === 'cloudbase'
  ? require('./db-cloudbase')
  : require('./db-sqlite');
