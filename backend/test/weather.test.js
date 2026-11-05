const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
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
    formatted_address: '示例省示例市示例县示范路1号',
    addressComponent: { adcode: '000000', city: '示例市', province: '示例省', district: '示例县' },
  },
};

const WEATHER_OK = {
  status: '1',
  info: 'OK',
  lives: [{
    city: '示例县',
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
  assert.equal(parsed.address, '示例省示例市示例县示范路1号');
  assert.equal(parsed.adcode, '000000');
  assert.equal(parsed.city, '示例市');
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
  assert.equal(parsed.city, '示例县');
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
  assert.equal(first.address, '示例省示例市示例县示范路1号');
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
  assert.equal(result.address, '示例省示例市示例县示范路1号');
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
  assert.equal(result.address, '示例省示例市示例县示范路1号');
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

const GEOCODE_OK = {
  status: '1',
  info: 'OK',
  geocodes: [{
    formatted_address: '浙江省杭州市建德市新安江街道新安东路555号',
    province: '浙江省',
    city: '杭州市',
    district: '建德市',
    adcode: '330182',
    location: '119.28123,29.47512',
  }],
};

const FORECAST_OK = {
  status: '1',
  info: 'OK',
  forecasts: [{
    city: '建德市',
    adcode: '330182',
    casts: [{
      date: '2026-11-05',
      dayweather: '多云',
      nightweather: '小雨',
      daytemp: '24',
      nighttemp: '15',
      daywind: '东北',
      nightwind: '北',
      daypower: '≤3',
      nightpower: '4',
    }],
  }],
};

const DRIVING_OK = {
  status: '1',
  info: 'OK',
  route: {
    origin: '119.18042,29.03036',
    destination: '119.28123,29.47512',
    paths: [
      {
        strategy: '速度最快',
        distance: '5200',
        duration: '680',
        traffic_lights: '6',
        tolls: '0',
        toll_distance: '0',
        steps: [
          {
            instruction: '沿洋安大道向东行驶1.8公里右转',
            road: '洋安大道',
            distance: '1800',
            duration: '180',
            action: '右转',
            tmcs: [
              { status: '畅通', distance: '1500' },
              { status: '缓行', distance: '300' },
            ],
          },
          {
            instruction: '沿新安江大桥向南行驶1.2公里直行',
            road: '新安江大桥',
            distance: '1200',
            duration: '260',
            action: '直行',
            tmcs: [
              { status: '拥堵', distance: '800' },
              { status: '严重拥堵', distance: '400' },
            ],
          },
          {
            instruction: '沿新安东路向东行驶2.2公里到达目的地',
            road: '新安东路',
            distance: '2200',
            duration: '240',
            action: '到达目的地',
            tmcs: [
              { status: '畅通', distance: '2200' },
            ],
          },
        ],
      },
    ],
  },
};

test('parseGeocode：正常解析与直辖市空数组兜底', () => {
  const parsed = parseGeocode(GEOCODE_OK);
  assert.deepEqual(parsed, {
    formattedAddress: '浙江省杭州市建德市新安江街道新安东路555号',
    province: '浙江省',
    city: '杭州市',
    district: '建德市',
    adcode: '330182',
    location: { lat: 29.47512, lon: 119.28123, coordinate: 'gcj02' },
  });

  const municipality = parseGeocode({
    status: '1',
    geocodes: [{
      formatted_address: '北京市朝阳区建国路1号',
      province: '北京市',
      city: [],
      district: '朝阳区',
      adcode: '110105',
      location: '116.46,39.91',
    }],
  });
  assert.equal(municipality.city, '北京市');
  assert.equal(municipality.district, '朝阳区');

  assert.equal(parseGeocode(null), null);
  assert.equal(parseGeocode({ status: '0', geocodes: [{}] }), null);
  assert.equal(parseGeocode({ status: '1', geocodes: [] }), null);
  assert.equal(parseGeocode({ status: '1', geocodes: [{ location: '0,0' }] }), null);
});

test('parseForecast：正常解析当日预报并处理空数组字段', () => {
  const parsed = parseForecast(FORECAST_OK);
  assert.deepEqual(parsed, {
    date: '2026-11-05',
    dayWeather: '多云',
    nightWeather: '小雨',
    dayTemp: '24',
    nightTemp: '15',
    dayWind: '东北',
    nightWind: '北',
    dayPower: '≤3',
    nightPower: '4',
  });

  const withEmptyArrays = parseForecast({
    status: '1',
    forecasts: [{
      casts: [{
        date: '2026-11-05',
        dayweather: '晴',
        nightweather: [],
        daytemp: '28',
        nighttemp: [],
      }],
    }],
  });
  assert.equal(withEmptyArrays.dayWeather, '晴');
  assert.equal(withEmptyArrays.nightWeather, null);
  assert.equal(withEmptyArrays.nightTemp, null);

  assert.equal(parseForecast(null), null);
  assert.equal(parseForecast({ status: '1', forecasts: [] }), null);
});

test('parseDrivingRoute：汇总路况里程、拥堵分段、主要途经道路与整体状态', () => {
  const routes = parseDrivingRoute(DRIVING_OK);
  assert.equal(routes.length, 1);
  const route = routes[0];
  assert.equal(route.strategy, '速度最快');
  assert.equal(route.overallStatus, '拥堵');
  assert.equal(route.distanceMeters, 5200);
  assert.equal(route.durationSeconds, 680);
  assert.equal(route.trafficLights, 6);
  assert.deepEqual(route.roads, ['洋安大道', '新安江大桥', '新安东路']);
  assert.deepEqual(route.trafficSummary, {
    smoothMeters: 3700,
    slowMeters: 300,
    jamMeters: 800,
    severeJamMeters: 400,
    unknownMeters: 0,
  });
  assert.deepEqual(route.congestedSegments, [
    { road: '新安江大桥', status: '严重拥堵', distanceMeters: 400 },
    { road: '新安江大桥', status: '拥堵', distanceMeters: 800 },
    { road: '洋安大道', status: '缓行', distanceMeters: 300 },
  ]);
  assert.equal(route.steps[0].status, '缓行');
  assert.equal(route.steps[1].status, '严重拥堵');
  assert.equal(route.steps[2].status, '畅通');

  assert.deepEqual(parseDrivingRoute(null), []);
  assert.deepEqual(parseDrivingRoute({ status: '0', route: { paths: [{}] } }), []);
});

test('lookupRouteTraffic：完整含起点路线、天气预报及二次命中缓存', async () => {
  clearCaches();
  const fetchImpl = (url) => {
    fetchImpl.calls.push(url);
    if (url.includes('/v3/geocode/geo')) {
      return Promise.resolve({ ok: true, json: async () => GEOCODE_OK });
    }
    if (url.includes('/v3/weather/weatherInfo') && url.includes('extensions=base')) {
      return Promise.resolve({ ok: true, json: async () => WEATHER_OK });
    }
    if (url.includes('/v3/weather/weatherInfo') && url.includes('extensions=all')) {
      return Promise.resolve({ ok: true, json: async () => FORECAST_OK });
    }
    if (url.includes('/v3/assistant/coordinate/convert')) {
      return Promise.resolve({ ok: true, json: async () => CONVERT_OK });
    }
    if (url.includes('/v3/geocode/regeo')) {
      return Promise.resolve({ ok: true, json: async () => REGEO_OK });
    }
    if (url.includes('/v3/direction/driving')) {
      return Promise.resolve({ ok: true, json: async () => DRIVING_OK });
    }
    return Promise.resolve({ ok: false, json: async () => ({}) });
  };
  fetchImpl.calls = [];

  const first = await lookupRouteTraffic({
    address: '新安江街道新安东路555号',
    city: '建德市',
    originLat: 29.03,
    originLon: 119.18,
    key: 'test-key',
    fetchImpl,
    now: 1000,
  });

  assert.equal(first.destination.formattedAddress, '浙江省杭州市建德市新安江街道新安东路555号');
  assert.equal(first.destination.adcode, '330182');
  assert.equal(first.origin.address, '示例省示例市示例县示范路1号');
  assert.equal(first.origin.coordinateDegraded, false);
  assert.equal(first.weather.text, '阴');
  assert.equal(first.weatherLine, '阴 · 33℃ · 湿度43%');
  assert.equal(first.forecast.dayWeather, '多云');
  assert.equal(first.routeAvailable, true);
  assert.equal(first.routes.length, 1);
  assert.equal(first.routes[0].overallStatus, '拥堵');
  assert.equal(first.degraded, false);
  assert.equal(fetchImpl.calls.length, 6);

  const second = await lookupRouteTraffic({
    address: '新安江街道新安东路555号',
    city: '建德市',
    originLat: 29.0301,
    originLon: 119.1801,
    key: 'test-key',
    fetchImpl,
    now: 2000,
  });
  assert.equal(second.routeAvailable, true);
  assert.equal(fetchImpl.calls.length, 6, '缓存有效期内不应重复请求上游');
});

test('lookupRouteTraffic：无起点坐标时仅查询终点坐标与天气，不调用驾车规划', async () => {
  clearCaches();
  const fetchImpl = (url) => {
    fetchImpl.calls.push(url);
    if (url.includes('/v3/geocode/geo')) {
      return Promise.resolve({ ok: true, json: async () => GEOCODE_OK });
    }
    if (url.includes('/v3/weather/weatherInfo') && url.includes('extensions=base')) {
      return Promise.resolve({ ok: true, json: async () => WEATHER_OK });
    }
    if (url.includes('/v3/weather/weatherInfo') && url.includes('extensions=all')) {
      return Promise.resolve({ ok: true, json: async () => FORECAST_OK });
    }
    return Promise.resolve({ ok: false, json: async () => ({}) });
  };
  fetchImpl.calls = [];

  const result = await lookupRouteTraffic({
    address: '新安江街道新安东路555号',
    key: 'test-key',
    fetchImpl,
  });
  assert.equal(result.origin, null);
  assert.equal(result.routeAvailable, false);
  assert.deepEqual(result.routes, []);
  assert.equal(result.weather.text, '阴');
  assert.equal(result.degraded, false);
  assert.equal(fetchImpl.calls.length, 3);
});

test('lookupRouteTraffic：参数校验与地址无法解析错误码', async () => {
  clearCaches();
  await assert.rejects(
    () => lookupRouteTraffic({ address: '   ', key: 'k' }),
    (error) => error.code === 'ADDRESS_INVALID',
  );
  await assert.rejects(
    () => lookupRouteTraffic({ address: '测试地址', key: '' }),
    (error) => error.code === 'AMAP_NOT_CONFIGURED',
  );
  await assert.rejects(
    () => lookupRouteTraffic({ address: '测试地址', originLat: 999, originLon: 119, key: 'k' }),
    (error) => error.code === 'COORD_INVALID',
  );

  const emptyGeoFetch = fakeFetch({
    '/v3/geocode/geo': { status: '1', geocodes: [] },
  });
  await assert.rejects(
    () => lookupRouteTraffic({ address: '完全不存在的虚构地址XYZ', key: 'k', fetchImpl: emptyGeoFetch }),
    (error) => error.code === 'ADDRESS_NOT_RESOLVED',
  );
});
