/**
 * 按分钟计数的进程内限流器。
 *
 * 它只负责单实例止损；跨实例共享限流仍由网关或外部存储承担。
 * 任何来源标识都可能被轮换，因此 Map 必须有硬上限，不能只依赖过期清理。
 */
class MinuteRateLimiter {
  constructor({ maxEntries = 10000, staleMinutes = 1 } = {}) {
    this.maxEntries = Math.max(1, Math.floor(Number(maxEntries) || 10000));
    this.staleMinutes = Math.max(1, Math.floor(Number(staleMinutes) || 1));
    this.buckets = new Map();
  }

  get size() {
    return this.buckets.size;
  }

  clear() {
    this.buckets.clear();
  }

  _prune(minute) {
    for (const [key, bucket] of this.buckets) {
      if (bucket.minute < minute - this.staleMinutes) this.buckets.delete(key);
    }
    if (this.buckets.size < this.maxEntries) return;

    // 新 key 到来且容量已满时，淘汰最久未使用的条目，保证高基数来源不能无限占内存。
    const overflow = this.buckets.size - this.maxEntries + 1;
    const oldest = [...this.buckets.entries()]
      .sort(([, a], [, b]) => (a.lastSeenAt - b.lastSeenAt) || (a.minute - b.minute))
      .slice(0, overflow);
    for (const [key] of oldest) this.buckets.delete(key);
  }

  isLimited(key, limit, now = Date.now()) {
    const minute = Math.floor(now / 60000);
    const normalizedKey = String(key);
    const normalizedLimit = Math.max(0, Math.floor(Number(limit) || 0));
    let bucket = this.buckets.get(normalizedKey);
    if (!bucket) {
      this._prune(minute);
      bucket = { minute, count: 1, lastSeenAt: now };
      this.buckets.set(normalizedKey, bucket);
      return false;
    }
    if (bucket.minute !== minute) {
      bucket.minute = minute;
      bucket.count = 1;
      bucket.lastSeenAt = now;
      return false;
    }
    bucket.count++;
    bucket.lastSeenAt = now;
    return bucket.count > normalizedLimit;
  }
}

module.exports = { MinuteRateLimiter };
