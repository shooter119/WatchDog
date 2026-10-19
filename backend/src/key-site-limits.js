const DEFAULT_LIMITS = { fileBytes: 20 * 1024 * 1024, pages: 200, pixels: 40000000, dimension: 30000,
  quotaBytes: 2 * 1024 ** 3, unitPending: 10, timeoutMs: 120000, taskTimeoutMs: 600000, concurrency: 2,
  aiPages: 20, aiConcurrency: 1, aiRequestTimeoutMs: 90000, aiTaskTimeoutMs: 1200000, aiResultBytes: 2 * 1024 * 1024 };
function keySiteLimits(overrides = {}) {
  const configured = {};
  for (const key of Object.keys(DEFAULT_LIMITS)) {
    const env = process.env[`WATCHDOG_KEY_SITE_${key.replace(/[A-Z]/g, letter => `_${letter}`).toUpperCase()}`];
    if (env !== undefined) {
      const value = Number(env);
      if (!Number.isSafeInteger(value) || value < 1 || value > DEFAULT_LIMITS[key]) throw new Error(`重点单位处理限制无效：${key}`);
      configured[key] = value;
    }
  }
  return { ...DEFAULT_LIMITS, ...configured, ...overrides };
}
module.exports = { DEFAULT_LIMITS, keySiteLimits };
