const fs = require('fs');
const path = require('path');

// 读取 /opt/watchdog/.env 注入 pm2 环境（避免在配置中硬编码密钥）
// PORT 由此处强制指定，不读 .env（避免与 proexam 的 3000 冲突）
const envFile = path.join(__dirname, '.env');
const env = {};
if (fs.existsSync(envFile)) {
  for (const line of fs.readFileSync(envFile, 'utf8').split('\n')) {
    const m = line.match(/^([A-Z][A-Z0-9_]*)=(.*)$/);
    if (m && m[1] !== 'PORT') env[m[1]] = m[2].trim();
  }
}
env.PORT = '3100';
// SQLite 只支持单进程写入；显式固定运行参数，避免服务器 .env 缺项时退回
// 到不适合共享/网络文件系统的隐式配置。
env.WATCHDOG_SQLITE_JOURNAL_MODE ||= 'WAL';
env.WATCHDOG_SQLITE_BUSY_TIMEOUT_MS ||= '5000';

module.exports = {
  apps: [
    {
      name: 'watchdog-api',
      script: 'src/server.js',
      cwd: __dirname,
      env,
      max_restarts: 10,
      restart_delay: 2000,
      kill_timeout: 10000,
      listen_timeout: 15000,
      max_memory_restart: '512M',
      out_file: '/var/log/watchdog/out.log',
      error_file: '/var/log/watchdog/err.log',
      time: true,
    },
  ],
};
