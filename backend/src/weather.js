'use strict';

// 高德 Web 服务：逆地理编码 + 实时天气。
//
// 设计要点：
// 1. Key 只存在服务端（AMAP_KEY），App 永远拿不到，也无法被反编译提取。
// 2. 逆地理结果按约 110 米网格缓存，天气按城市 adcode 缓存，
//    一节现场多台设备同时拍摄时不会把配额打满。
// 3. 上游失败时降级返回「只有地址」或「都没有」，不阻断拍摄流程。
// 4. 本模块不记录经纬度，坐标只作为缓存键参与内部运算。

const AMAP_BASE = process.env.AMAP_BASE_URL || 'https://restapi.amap.com';
const REQUEST_TIMEOUT_MS = 4000;
const ADDRESS_TTL_MS = 10 * 60 * 1000;
const WEATHER_TTL_MS = 20 * 60 * 1000;
// 3 位小数约 110 米，足够区分同一现场的不同拍摄点，又能让相邻设备命中同一缓存。
const COORD_DIGITS = 3;

function roundCoord(value) {
  const factor = 10 ** COORD_DIGITS;
  return Math.round(Number(value) * factor) / factor;
}

function validCoord(lat, lon) {
  return Number.isFinite(lat) && Number.isFinite(lon) &&
    lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 &&
    !(lat === 0 && lon === 0);
}

/** 解析逆地理响应。上游任何异常字段都按缺失处理，不抛错。 */
function parseRegeo(payload) {
  if (!payload || String(payload.status) !== '1') return null;
  const regeo = payload.regeocode;
  if (!regeo) return null;
  const component = regeo.addressComponent || {};
  const address = String(regeo.formatted_address || '').trim();
  if (!address) return null;
  return {
    address,
    adcode: String(component.adcode || '').trim(),
    city: String(component.city || component.province || '').trim(),
    district: String(component.district || '').trim(),
  };
}

/** 解析天气实况响应；高德返回 lives 数组，空数组表示查无此城市。 */
function parseWeather(payload) {
  if (!payload || String(payload.status) !== '1') return null;
  const live = Array.isArray(payload.lives) ? payload.lives[0] : null;
  if (!live) return null;
  const text = String(live.weather || '').trim();
  if (!text) return null;
  return {
    text,
    temperature: live.temperature === undefined ? null : String(live.temperature),
    humidity: live.humidity === undefined ? null : String(live.humidity),
    windDirection: String(live.winddirection || '').trim() || null,
    windPower: String(live.windpower || '').trim() || null,
    observedAt: String(live.reporttime || '').trim() || null,
    city: String(live.city || '').trim() || null,
  };
}

class TtlCache {
  constructor(ttlMs, maxEntries = 500) {
    this.ttlMs = ttlMs;
    this.maxEntries = maxEntries;
    this.entries = new Map();
  }

  get(key, now = Date.now()) {
    const hit = this.entries.get(key);
    if (!hit) return null;
    if (now - hit.at > this.ttlMs) {
      this.entries.delete(key);
      return null;
    }
    return hit.value;
  }

  set(key, value, now = Date.now()) {
    if (this.entries.size >= this.maxEntries) {
      // 简单淘汰：删除最早写入的一条，避免内存无界增长。
      const oldest = this.entries.keys().next();
      if (!oldest.done) this.entries.delete(oldest.value);
    }
    this.entries.set(key, { value, at: now });
  }

  clear() {
    this.entries.clear();
  }
}

const addressCache = new TtlCache(ADDRESS_TTL_MS);
const weatherCache = new TtlCache(WEATHER_TTL_MS);

async function fetchJson(url, fetchImpl) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  try {
    const response = await fetchImpl(url, { signal: controller.signal });
    if (!response.ok) return null;
    return await response.json();
  } catch (_) {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 查询地址与天气。
 * @returns {Promise<{address:string|null,adcode:string|null,city:string|null,
 *   weather:object|null,degraded:boolean}>}
 */
async function lookup({
  lat, lon, key, fetchImpl = fetch, now = Date.now(),
  addressStore = addressCache, weatherStore = weatherCache,
} = {}) {
  const latitude = Number(lat);
  const longitude = Number(lon);
  if (!validCoord(latitude, longitude)) {
    const error = new Error('坐标格式错误');
    error.code = 'COORD_INVALID';
    throw error;
  }
  if (!key) {
    const error = new Error('天气与地址服务未配置');
    error.code = 'AMAP_NOT_CONFIGURED';
    throw error;
  }

  const addressKey = `${roundCoord(latitude)},${roundCoord(longitude)}`;

  let geo = addressStore.get(addressKey, now);
  if (!geo) {
    const url = `${AMAP_BASE}/v3/geocode/regeo?location=${longitude},${latitude}` +
      `&key=${encodeURIComponent(key)}&extensions=base&radius=200`;
    geo = parseRegeo(await fetchJson(url, fetchImpl));
    if (geo) addressStore.set(addressKey, geo, now);
  }

  let weather = null;
  if (geo?.adcode) {
    weather = weatherStore.get(geo.adcode, now);
    if (!weather) {
      const url = `${AMAP_BASE}/v3/weather/weatherInfo?city=${encodeURIComponent(geo.adcode)}` +
        `&key=${encodeURIComponent(key)}&extensions=base`;
      weather = parseWeather(await fetchJson(url, fetchImpl));
      if (weather) weatherStore.set(geo.adcode, weather, now);
    }
  }

  return {
    address: geo?.address || null,
    adcode: geo?.adcode || null,
    city: weather?.city || geo?.city || null,
    weather,
    // 地址或天气任一缺失即为降级：客户端照常拍摄，只显示已有部分。
    degraded: !geo || !weather,
  };
}

/** 组装水印展示用的单行天气文本，如「阴 33℃ · 湿度43%」。 */
function weatherLine(weather) {
  if (!weather?.text) return '';
  const parts = [weather.text];
  if (weather.temperature !== null && weather.temperature !== undefined &&
      String(weather.temperature) !== '') {
    parts.push(`${weather.temperature}℃`);
  }
  if (weather.humidity) parts.push(`湿度${weather.humidity}%`);
  return parts.join(' · ');
}

function clearCaches() {
  addressCache.clear();
  weatherCache.clear();
}

module.exports = {
  lookup,
  parseRegeo,
  parseWeather,
  weatherLine,
  validCoord,
  roundCoord,
  clearCaches,
  TtlCache,
};
