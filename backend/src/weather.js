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
const COORDINATE_TTL_MS = 10 * 60 * 1000;
const WEATHER_TTL_MS = 20 * 60 * 1000;
const GEOCODE_TTL_MS = 10 * 60 * 1000;
const FORECAST_TTL_MS = 20 * 60 * 1000;
const ROUTE_TTL_MS = 2 * 60 * 1000;
// 3 位小数约 110 米，足够区分同一现场的不同拍摄点，又能让相邻设备命中同一缓存。
const COORD_DIGITS = 3;

function strOrEmpty(value) {
  if (value === null || value === undefined || typeof value === 'object') return '';
  return String(value).trim();
}

function strOrNull(value) {
  const clean = strOrEmpty(value);
  return clean || null;
}

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

/** 解析高德坐标转换响应；返回可直接用于逆地理与地图链接的 GCJ-02 坐标。 */
function parseCoordinateConversion(payload) {
  if (!payload || String(payload.status) !== '1') return null;
  const raw = Array.isArray(payload.locations)
    ? payload.locations[0]
    : payload.locations;
  const parts = String(raw || '').split(',').map((part) => Number(part.trim()));
  if (parts.length !== 2) return null;
  const [lon, lat] = parts;
  if (!validCoord(lat, lon)) return null;
  return { lat, lon, coordinate: 'gcj02' };
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

/** 解析高德地理编码响应（地址 -> GCJ-02 坐标 + 行政区划）。 */
function parseGeocode(payload) {
  if (!payload || String(payload.status) !== '1') return null;
  const item = Array.isArray(payload.geocodes) ? payload.geocodes[0] : null;
  if (!item) return null;
  const parts = strOrEmpty(item.location).split(',').map((part) => Number(part.trim()));
  if (parts.length !== 2) return null;
  const [lon, lat] = parts;
  if (!validCoord(lat, lon)) return null;
  const province = strOrEmpty(item.province);
  const city = strOrEmpty(item.city) || province;
  const district = strOrEmpty(item.district);
  const adcode = strOrEmpty(item.adcode);
  const formattedAddress = strOrEmpty(item.formatted_address) ||
    [province, city !== province ? city : '', district].filter(Boolean).join('');
  return {
    formattedAddress,
    province,
    city,
    district,
    adcode,
    location: { lat, lon, coordinate: 'gcj02' },
  };
}

/** 解析高德天气预报响应（extensions=all），提取当日白天/夜间预报。 */
function parseForecast(payload) {
  if (!payload || String(payload.status) !== '1') return null;
  const forecast = Array.isArray(payload.forecasts) ? payload.forecasts[0] : null;
  const cast = Array.isArray(forecast?.casts) ? forecast.casts[0] : null;
  if (!cast) return null;
  return {
    date: strOrNull(cast.date),
    dayWeather: strOrNull(cast.dayweather),
    nightWeather: strOrNull(cast.nightweather),
    dayTemp: strOrNull(cast.daytemp),
    nightTemp: strOrNull(cast.nighttemp),
    dayWind: strOrNull(cast.daywind),
    nightWind: strOrNull(cast.nightwind),
    dayPower: strOrNull(cast.daypower),
    nightPower: strOrNull(cast.nightpower),
  };
}

const TMC_SEVERITY = {
  严重拥堵: 3,
  拥堵: 2,
  缓行: 1,
};

/** 解析高德驾车路径规划响应（/v3/direction/driving?extensions=all）。 */
function parseDrivingRoute(payload) {
  if (!payload || String(payload.status) !== '1') return [];
  const rawPaths = payload.route?.paths;
  if (!Array.isArray(rawPaths) || rawPaths.length === 0) return [];

  return rawPaths.slice(0, 3).map((path) => {
    const strategy = strOrEmpty(path?.strategy) || '推荐路线';
    const distanceMeters = Math.max(0, Math.round(Number(path?.distance) || 0));
    const durationSeconds = Math.max(0, Math.round(Number(path?.duration) || 0));
    const trafficLights = Math.max(0, Math.round(Number(path?.traffic_lights) || 0));
    const tolls = Math.max(0, Math.round(Number(path?.tolls) || 0));
    const tollDistanceMeters = Math.max(0, Math.round(Number(path?.toll_distance) || 0));

    const roads = [];
    const seenRoads = new Set();
    let smoothMeters = 0;
    let slowMeters = 0;
    let jamMeters = 0;
    let severeJamMeters = 0;
    let unknownMeters = 0;

    const congestedMap = new Map();
    let segmentOrder = 0;

    const rawSteps = Array.isArray(path?.steps) ? path.steps : [];
    const steps = rawSteps.map((step) => {
      const road = strOrEmpty(step?.road);
      if (road && !seenRoads.has(road)) {
        seenRoads.add(road);
        roads.push(road);
      }
      const stepDistance = Math.max(0, Math.round(Number(step?.distance) || 0));
      const stepDuration = Math.max(0, Math.round(Number(step?.duration) || 0));
      const tmcs = Array.isArray(step?.tmcs) ? step.tmcs : [];

      let hasSevereJam = false;
      let hasJam = false;
      let hasSlow = false;
      let hasSmooth = false;

      if (tmcs.length === 0) {
        unknownMeters += stepDistance;
      } else {
        for (const tmc of tmcs) {
          const status = strOrEmpty(tmc?.status);
          const dist = Math.max(0, Math.round(Number(tmc?.distance) || 0));
          if (status === '严重拥堵') {
            hasSevereJam = true;
            severeJamMeters += dist;
          } else if (status === '拥堵') {
            hasJam = true;
            jamMeters += dist;
          } else if (status === '缓行') {
            hasSlow = true;
            slowMeters += dist;
          } else if (status === '畅通') {
            hasSmooth = true;
            smoothMeters += dist;
          } else {
            unknownMeters += dist;
          }

          if (TMC_SEVERITY[status] && dist > 0) {
            const roadLabel = road || '无名道路';
            const segKey = `${roadLabel}__${status}`;
            const existing = congestedMap.get(segKey);
            if (existing) {
              existing.distanceMeters += dist;
            } else {
              congestedMap.set(segKey, {
                road: roadLabel,
                status,
                distanceMeters: dist,
                order: segmentOrder++,
              });
            }
          }
        }
      }

      let stepStatus = '未知';
      if (hasSevereJam) stepStatus = '严重拥堵';
      else if (hasJam) stepStatus = '拥堵';
      else if (hasSlow) stepStatus = '缓行';
      else if (hasSmooth) stepStatus = '畅通';

      return {
        instruction: strOrEmpty(step?.instruction),
        road,
        distanceMeters: stepDistance,
        durationSeconds: stepDuration,
        action: strOrEmpty(step?.action),
        status: stepStatus,
      };
    });

    const congestedSegments = [...congestedMap.values()]
      .sort((a, b) => (TMC_SEVERITY[b.status] - TMC_SEVERITY[a.status]) || (a.order - b.order))
      .slice(0, 8)
      .map(({ road, status, distanceMeters: dist }) => ({
        road,
        status,
        distanceMeters: dist,
      }));

    let overallStatus = '路况未知';
    if (severeJamMeters >= 500) {
      overallStatus = '严重拥堵';
    } else if (severeJamMeters >= 200 || jamMeters >= 1000) {
      overallStatus = '拥堵';
    } else if (jamMeters > 0 || severeJamMeters > 0) {
      overallStatus = '局部拥堵';
    } else if (slowMeters >= 300) {
      overallStatus = '局部缓行';
    } else if (smoothMeters > 0) {
      overallStatus = '畅通';
    }

    return {
      strategy,
      overallStatus,
      distanceMeters,
      durationSeconds,
      trafficLights,
      tolls,
      tollDistanceMeters,
      roads,
      trafficSummary: {
        smoothMeters,
        slowMeters,
        jamMeters,
        severeJamMeters,
        unknownMeters,
      },
      congestedSegments,
      steps,
    };
  });
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
const coordinateCache = new TtlCache(COORDINATE_TTL_MS);
const weatherCache = new TtlCache(WEATHER_TTL_MS);
const geocodeCache = new TtlCache(GEOCODE_TTL_MS);
const forecastCache = new TtlCache(FORECAST_TTL_MS);
const routeCache = new TtlCache(ROUTE_TTL_MS);

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
 *   weather:object|null,amapLocation:object|null,coordinateDegraded:boolean,
 *   degraded:boolean}>}
 */
async function lookup({
  lat, lon, key, fetchImpl = fetch, now = Date.now(),
  addressStore = addressCache, coordinateStore = coordinateCache,
  weatherStore = weatherCache,
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

  const sourceKey = `${roundCoord(latitude)},${roundCoord(longitude)}`;
  let amapLocation = coordinateStore.get(sourceKey, now);
  if (!amapLocation) {
    const url = `${AMAP_BASE}/v3/assistant/coordinate/convert?locations=${longitude},${latitude}` +
      `&coordsys=gps&output=JSON&key=${encodeURIComponent(key)}`;
    amapLocation = parseCoordinateConversion(await fetchJson(url, fetchImpl));
    if (amapLocation) coordinateStore.set(sourceKey, amapLocation, now);
  }
  const coordinateDegraded = !amapLocation;
  const geoLat = amapLocation?.lat ?? latitude;
  const geoLon = amapLocation?.lon ?? longitude;
  const addressKey = `${roundCoord(geoLat)},${roundCoord(geoLon)}`;

  let geo = addressStore.get(addressKey, now);
  if (!geo) {
    const url = `${AMAP_BASE}/v3/geocode/regeo?location=${geoLon},${geoLat}` +
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
    amapLocation,
    coordinateDegraded,
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

/** 组装 `/api/weather` 响应；保留旧字段，同时追加可选的 GCJ-02 坐标。 */
function lookupResponse(result) {
  return {
    address: result?.address ?? null,
    adcode: result?.adcode ?? null,
    city: result?.city ?? null,
    weather: result?.weather ?? null,
    amapLocation: result?.amapLocation ?? null,
    coordinateDegraded: result?.coordinateDegraded !== false,
    line: weatherLine(result?.weather),
    degraded: result?.degraded !== false,
  };
}

function clearCaches() {
  addressCache.clear();
  coordinateCache.clear();
  weatherCache.clear();
  geocodeCache.clear();
  forecastCache.clear();
  routeCache.clear();
}

/**
 * 综合查询事发地坐标、目的地实况天气与当日预报、以及从当前位置到事发地的驾车路线与实时路况。
 */
async function lookupRouteTraffic({
  address,
  city = '',
  originLat = null,
  originLon = null,
  key,
  fetchImpl = fetch,
  now = Date.now(),
  addressStore = addressCache,
  coordinateStore = coordinateCache,
  weatherStore = weatherCache,
  geocodeStore,
  forecastStore,
  routeStore,
  geocodeCache: geocodeCacheArg,
  forecastCache: forecastCacheArg,
  routeCache: routeCacheArg,
} = {}) {
  const cleanAddress = strOrEmpty(address);
  if (!cleanAddress || cleanAddress.length > 200) {
    const error = new Error('请输入有效的事发地点（1~200 字）');
    error.code = 'ADDRESS_INVALID';
    throw error;
  }
  if (!key) {
    const error = new Error('路况与天气服务未配置');
    error.code = 'AMAP_NOT_CONFIGURED';
    throw error;
  }

  const hasOrigin =
    (originLat !== null && originLat !== undefined && String(originLat).trim() !== '') ||
    (originLon !== null && originLon !== undefined && String(originLon).trim() !== '');
  let originLatitude = null;
  let originLongitude = null;
  if (hasOrigin) {
    originLatitude = Number(originLat);
    originLongitude = Number(originLon);
    if (!validCoord(originLatitude, originLongitude)) {
      const error = new Error('起点坐标格式错误');
      error.code = 'COORD_INVALID';
      throw error;
    }
  }

  const geoStore = geocodeStore || geocodeCacheArg || geocodeCache;
  const fcStore = forecastStore || forecastCacheArg || forecastCache;
  const rtStore = routeStore || routeCacheArg || routeCache;

  const cleanCity = strOrEmpty(city).slice(0, 80);
  const geocodeKey = `${cleanCity}::${cleanAddress}`;
  let geocode = geoStore.get(geocodeKey, now);
  if (!geocode) {
    const cityParam = cleanCity ? `&city=${encodeURIComponent(cleanCity)}` : '';
    const url = `${AMAP_BASE}/v3/geocode/geo?address=${encodeURIComponent(cleanAddress)}` +
      `${cityParam}&output=JSON&key=${encodeURIComponent(key)}`;
    geocode = parseGeocode(await fetchJson(url, fetchImpl));
    if (geocode) geoStore.set(geocodeKey, geocode, now);
  }
  if (!geocode) {
    const error = new Error('未能解析该事发地点，请补充更详细的地址信息');
    error.code = 'ADDRESS_NOT_RESOLVED';
    throw error;
  }

  const weatherCityKey = geocode.adcode || geocode.city || geocode.province;
  let weather = null;
  let forecast = null;
  if (weatherCityKey) {
    weather = weatherStore.get(weatherCityKey, now);
    if (!weather) {
      const url = `${AMAP_BASE}/v3/weather/weatherInfo?city=${encodeURIComponent(weatherCityKey)}` +
        `&key=${encodeURIComponent(key)}&extensions=base`;
      weather = parseWeather(await fetchJson(url, fetchImpl));
      if (weather) weatherStore.set(weatherCityKey, weather, now);
    }

    forecast = fcStore.get(weatherCityKey, now);
    if (!forecast) {
      const url = `${AMAP_BASE}/v3/weather/weatherInfo?city=${encodeURIComponent(weatherCityKey)}` +
        `&key=${encodeURIComponent(key)}&extensions=all`;
      forecast = parseForecast(await fetchJson(url, fetchImpl));
      if (forecast) fcStore.set(weatherCityKey, forecast, now);
    }
  }

  let originAmapLocation = null;
  let originGeo = null;
  let routes = [];
  if (hasOrigin) {
    const sourceKey = `${roundCoord(originLatitude)},${roundCoord(originLongitude)}`;
    originAmapLocation = coordinateStore.get(sourceKey, now);
    if (!originAmapLocation) {
      const url = `${AMAP_BASE}/v3/assistant/coordinate/convert?locations=${originLongitude},${originLatitude}` +
        `&coordsys=gps&output=JSON&key=${encodeURIComponent(key)}`;
      originAmapLocation = parseCoordinateConversion(await fetchJson(url, fetchImpl));
      if (originAmapLocation) coordinateStore.set(sourceKey, originAmapLocation, now);
    }
    const originLatGcj = originAmapLocation?.lat ?? originLatitude;
    const originLonGcj = originAmapLocation?.lon ?? originLongitude;
    const addressKey = `${roundCoord(originLatGcj)},${roundCoord(originLonGcj)}`;
    originGeo = addressStore.get(addressKey, now);
    if (!originGeo) {
      const url = `${AMAP_BASE}/v3/geocode/regeo?location=${originLonGcj},${originLatGcj}` +
        `&key=${encodeURIComponent(key)}&extensions=base&radius=200`;
      originGeo = parseRegeo(await fetchJson(url, fetchImpl));
      if (originGeo) addressStore.set(addressKey, originGeo, now);
    }

    const destLat = geocode.location.lat;
    const destLon = geocode.location.lon;
    const routeKey = `${roundCoord(originLatGcj)},${roundCoord(originLonGcj)}->${roundCoord(destLat)},${roundCoord(destLon)}`;
    const cachedRoutes = rtStore.get(routeKey, now);
    if (cachedRoutes) {
      routes = cachedRoutes;
    } else {
      const url = `${AMAP_BASE}/v3/direction/driving?origin=${originLonGcj},${originLatGcj}` +
        `&destination=${destLon},${destLat}&extensions=all&strategy=10&output=JSON&key=${encodeURIComponent(key)}`;
      routes = parseDrivingRoute(await fetchJson(url, fetchImpl));
      if (routes.length > 0) rtStore.set(routeKey, routes, now);
    }
  }

  return {
    destination: {
      queryAddress: cleanAddress,
      formattedAddress: geocode.formattedAddress,
      province: geocode.province,
      city: geocode.city,
      district: geocode.district,
      adcode: geocode.adcode,
      location: geocode.location,
    },
    origin: hasOrigin ? {
      address: originGeo?.address || null,
      location: originAmapLocation || { lat: originLatitude, lon: originLongitude, coordinate: 'wgs84' },
      coordinateDegraded: !originAmapLocation,
    } : null,
    weather,
    weatherLine: weatherLine(weather),
    forecast,
    routes,
    routeAvailable: routes.length > 0,
    degraded: !weather || (hasOrigin && routes.length === 0),
  };
}

module.exports = {
  lookup,
  lookupRouteTraffic,
  parseRegeo,
  parseGeocode,
  parseCoordinateConversion,
  parseWeather,
  parseForecast,
  parseDrivingRoute,
  weatherLine,
  lookupResponse,
  validCoord,
  roundCoord,
  clearCaches,
  TtlCache,
};
