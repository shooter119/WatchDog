const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
  lookup,
  parseRegeo,
  parseCoordinateConversion,
  parseWeather,
  weatherLine,
  lookupResponse,
  validCoord,
  roundCoord,
  TtlCache,
} = require('../src/weather');

const CONVERT_OK = {
  status: '1',
  info: 'OK',
  locations: '119.18042,29.03036',
};

const REGEO_OK = {
  status: '1',
  info: 'OK',
  regeocode: {
    formatted_address: '浙江省衢州市龙游县东华街道鸡鸣路146号',
    addressComponent: { adcode: '330825', city: '衢州市', province: '浙江省', district: '龙游县' },
  },
};

const WEATHER_OK = {
  status: '1',
  info: 'OK',
  lives: [{
    city: '龙游县',
    weather: '阴',
    temperature: '33',
    humidity: '43',
    winddirection: '西',
    windpower: '≤3',
    reporttime: '2026-10-18 13:00:00',
  }],
};

function fakeFetch(routes) {
  const calls = [];
  const impl = async (url) => {
    calls.push(url);
    for (const [marker, payload] of Object.entries(routes)) {
      if (url.includes(marker)) {
        return { ok: true, json: async () => payload };
      }
    }
    return { ok: false, json: async () => ({}) };
  };
  impl.calls = calls;
  return impl;
}

test('坐标校验：合法与非法边界', () => {
  assert.equal(validCoord(29.03, 119.18), true);
  assert.equal(validCoord(-90, 180), true);
  assert.equal(validCoord(NaN, 119), false);
  assert.equal(validCoord(91, 119), false);
  assert.equal(validCoord(29, 181), false);
  assert.equal(validCoord(0, 0), false, '0,0 视为无效坐标');
});

test('坐标按 3 位小数取整，供缓存键复用', () => {
  assert.equal(roundCoord(29.03049), 29.03);
  assert.equal(roundCoord(29.03051), 29.031);
});

test('解析逆地理响应：正常返回', () => {
  const parsed = parseRegeo(REGEO_OK);
  assert.equal(parsed.address, '浙江省衢州市龙游县东华街道鸡鸣路146号');
  assert.equal(parsed.adcode, '330825');
  assert.equal(parsed.city, '衢州市');
});

test('解析逆地理响应：上游状态失败或字段缺失时返回 null', () => {
  assert.equal(parseRegeo(null), null);
  assert.equal(parseRegeo({ status: '0', regeocode: {} }), null);
  assert.equal(parseRegeo({ status: '1', regeocode: { formatted_address: '' } }), null);
  assert.equal(parseRegeo({ status: '1' }), null);
});

test('解析坐标转换响应：返回 GCJ-02 经纬度', () => {
  assert.deepEqual(parseCoordinateConversion(CONVERT_OK), {
    lat: 29.03036,
    lon: 119.18042,
    coordinate: 'gcj02',
  });
  assert.deepEqual(
    parseCoordinateConversion({ status: '1', locations: ['119.18,29.03'] }),
    { lat: 29.03, lon: 119.18, coordinate: 'gcj02' },
  );
  assert.equal(parseCoordinateConversion({ status: '0', locations: '119.18,29.03' }), null);
  assert.equal(parseCoordinateConversion({ status: '1', locations: 'bad' }), null);
  assert.equal(parseCoordinateConversion({ status: '1', locations: '0,0' }), null);
});

test('解析天气响应：正常返回并保留字符串形态的温度', () => {
  const parsed = parseWeather(WEATHER_OK);
  assert.equal(parsed.text, '阴');
  assert.equal(parsed.temperature, '33');
  assert.equal(parsed.humidity, '43');
  assert.equal(parsed.windPower, '≤3');
  assert.equal(parsed.city, '龙游县');
});

test('解析天气响应：lives 为空或缺少天气时返回 null', () => {
  assert.equal(parseWeather({ status: '1', lives: [] }), null);
  assert.equal(parseWeather({ status: '1' }), null);
  assert.equal(parseWeather({ status: '0', lives: [{ weather: '阴' }] }), null);
});

test('天气展示行组装', () => {
  assert.equal(weatherLine(parseWeather(WEATHER_OK)), '阴 · 33℃ · 湿度43%');
  assert.equal(weatherLine({ text: '晴', temperature: '', humidity: '' }), '晴');
  assert.equal(weatherLine(null), '');
});

test('/api/weather 响应保留旧字段并追加高德坐标，旧版字段不变', () => {
  const response = lookupResponse({
    address: '测试地址',
    adcode: '330825',
    city: '衢州市',
    weather: parseWeather(WEATHER_OK),
    amapLocation: { lat: 29.03036, lon: 119.18042, coordinate: 'gcj02' },
    coordinateDegraded: false,
    degraded: false,
  });
  assert.equal(response.address, '测试地址');
  assert.equal(response.adcode, '330825');
  assert.equal(response.city, '衢州市');
  assert.equal(response.line, '阴 · 33℃ · 湿度43%');
  assert.equal(response.degraded, false);
  assert.deepEqual(response.amapLocation, {
    lat: 29.03036,
    lon: 119.18042,
    coordinate: 'gcj02',
  });
  assert.equal(response.coordinateDegraded, false);

  const fallback = lookupResponse({
    address: null,
    adcode: null,
    city: null,
    weather: null,
    amapLocation: null,
    coordinateDegraded: true,
    degraded: true,
  });
  assert.equal(fallback.address, null);
  assert.equal(fallback.line, '');
  assert.equal(fallback.amapLocation, null);
  assert.equal(fallback.coordinateDegraded, true);
});

test('TtlCache 过期后不再命中，且限制条目上限', () => {
  const cache = new TtlCache(1000, 2);
  cache.set('a', 1, 0);
  assert.equal(cache.get('a', 500), 1);
  assert.equal(cache.get('a', 1001), null, '超过 TTL 应失效');

  cache.set('x', 1, 0);
  cache.set('y', 2, 0);
  cache.set('z', 3, 0);
  assert.equal(cache.get('x', 10), null, '超出上限应淘汰最早条目');
  assert.equal(cache.get('z', 10), 3);
});

test('lookup：地址与天气都成功，且第二次命中缓存不再请求上游', async () => {
  const fetchImpl = fakeFetch({
    '/v3/assistant/coordinate/convert': CONVERT_OK,
    '/v3/geocode/regeo': REGEO_OK,
    '/v3/weather/weatherInfo': WEATHER_OK,
  });
  const addressStore = new TtlCache(60_000);
  const coordinateStore = new TtlCache(60_000);
  const weatherStore = new TtlCache(60_000);

  const first = await lookup({
    lat: 29.03, lon: 119.18, key: 'k', fetchImpl, now: 1000,
    addressStore, coordinateStore, weatherStore,
  });
  assert.equal(first.address, '浙江省衢州市龙游县东华街道鸡鸣路146号');
  assert.equal(first.weather.text, '阴');
  assert.deepEqual(first.amapLocation, {
    lat: 29.03036,
    lon: 119.18042,
    coordinate: 'gcj02',
  });
  assert.equal(first.coordinateDegraded, false);
  assert.equal(first.degraded, false);
  assert.equal(fetchImpl.calls.length, 3);
  assert.match(fetchImpl.calls[0], /assistant\/coordinate\/convert/);
  assert.match(fetchImpl.calls[1], /location=119\.18042,29\.03036/);

  const second = await lookup({
    lat: 29.0301, lon: 119.1801, key: 'k', fetchImpl, now: 2000,
    addressStore, coordinateStore, weatherStore,
  });
  assert.equal(second.address, first.address);
  assert.deepEqual(second.amapLocation, first.amapLocation);
  assert.equal(fetchImpl.calls.length, 3, '同一网格内应命中坐标、地址和天气缓存');
});

test('lookup：天气失败时保留地址并标记降级', async () => {
  const fetchImpl = fakeFetch({
    '/v3/assistant/coordinate/convert': CONVERT_OK,
    '/v3/geocode/regeo': REGEO_OK,
  });
  const result = await lookup({
    lat: 29.03, lon: 119.18, key: 'k', fetchImpl,
    addressStore: new TtlCache(60_000),
    coordinateStore: new TtlCache(60_000),
    weatherStore: new TtlCache(60_000),
  });
  assert.equal(result.address, '浙江省衢州市龙游县东华街道鸡鸣路146号');
  assert.equal(result.weather, null);
  assert.equal(result.coordinateDegraded, false);
  assert.equal(result.degraded, true);
});

test('lookup：坐标转换失败时回退 WGS84 逆地理，并隐藏高德坐标', async () => {
  const fetchImpl = fakeFetch({ '/v3/geocode/regeo': REGEO_OK });
  const result = await lookup({
    lat: 29.03, lon: 119.18, key: 'k', fetchImpl,
    addressStore: new TtlCache(60_000),
    coordinateStore: new TtlCache(60_000),
    weatherStore: new TtlCache(60_000),
  });
  assert.equal(result.address, '浙江省衢州市龙游县东华街道鸡鸣路146号');
  assert.equal(result.amapLocation, null);
  assert.equal(result.coordinateDegraded, true);
  assert.equal(fetchImpl.calls.length, 3);
  assert.match(fetchImpl.calls[1], /location=119\.18,29\.03/);
});

test('lookup：坐标转换成功后逆地理失败，仍返回高德坐标并全程降级', async () => {
  const fetchImpl = fakeFetch({ '/v3/assistant/coordinate/convert': CONVERT_OK });
  const result = await lookup({
    lat: 29.03, lon: 119.18, key: 'k', fetchImpl,
    addressStore: new TtlCache(60_000),
    coordinateStore: new TtlCache(60_000),
    weatherStore: new TtlCache(60_000),
  });
  assert.equal(result.address, null);
  assert.equal(result.weather, null);
  assert.equal(result.amapLocation.coordinate, 'gcj02');
  assert.equal(result.coordinateDegraded, false);
  assert.equal(result.degraded, true);
  assert.equal(fetchImpl.calls.length, 2, '无 adcode 时不应再查天气');
});

test('lookup：未配置 Key 抛出 AMAP_NOT_CONFIGURED', async () => {
  await assert.rejects(
    () => lookup({ lat: 29.03, lon: 119.18, key: '' }),
    (error) => error.code === 'AMAP_NOT_CONFIGURED',
  );
});

test('lookup：坐标非法抛出 COORD_INVALID', async () => {
  await assert.rejects(
    () => lookup({ lat: 999, lon: 119, key: 'k' }),
    (error) => error.code === 'COORD_INVALID',
  );
});

test('lookup：上游超时或网络异常按降级处理，不抛出', async () => {
  const fetchImpl = async () => { throw new Error('aborted'); };
  const result = await lookup({
    lat: 29.03, lon: 119.18, key: 'k', fetchImpl,
    addressStore: new TtlCache(60_000),
    coordinateStore: new TtlCache(60_000),
    weatherStore: new TtlCache(60_000),
  });
  assert.equal(result.address, null);
  assert.equal(result.amapLocation, null);
  assert.equal(result.coordinateDegraded, true);
  assert.equal(result.degraded, true);
});
