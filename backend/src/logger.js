const LEVELS = { debug: 0, info: 1, warn: 2, error: 3 };

function fmt(level, args) {
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
  return `[${ts}] [${level.toUpperCase().padEnd(5)}] ${args
    .map((a) => (typeof a === 'object' ? JSON.stringify(a) : String(a)))
    .join(' ')}`;
}

const logger = {
  debug: (...a) => {
    if ((process.env.LOG_LEVEL || 'info') === 'debug') console.log(fmt('debug', a));
  },
  info: (...a) => console.log(fmt('info', a)),
  warn: (...a) => console.log(fmt('warn', a)),
  error: (...a) => console.error(fmt('error', a)),
};

module.exports = logger;
