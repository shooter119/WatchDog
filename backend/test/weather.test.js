const { test } = require('node:test');
const assert = require('node:assert/strict');

const {
  lookup,
  parseRegeo,
  parseWeather,
  weatherLine,
  validCoord,
  roundCoord,
  TtlCache,
} = require('../src/weather');

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
  const fetchImpl = fakeFetch({ '/v3/geocode/regeo': REGEO_OK, '/v3/weather/weatherInfo': WEATHER_OK });
  const addressStore = new TtlCache(60_000);
  const weatherStore = new TtlCache(60_000);

  const first = await lookup({
    lat: 29.03, lon: 119.18, key: 'k', fetchImpl, now: 1000, addressStore, weatherStore,
  });
  assert.equal(first.address, '浙江省衢州市龙游县东华街道鸡鸣路146号');
  assert.equal(first.weather.text, '阴');
  assert.equal(first.degraded, false);
  assert.equal(fetchImpl.calls.length, 2);

  const second = await lookup({
    lat: 29.0301, lon: 119.1801, key: 'k', fetchImpl, now: 2000, addressStore, weatherStore,
  });
  assert.equal(second.address, first.address);
  assert.equal(fetchImpl.calls.length, 2, '同一网格内应命中缓存');
});

test('lookup：天气失败时保留地址并标记降级', async () => {
  const fetchImpl = fakeFetch({ '/v3/geocode/regeo': REGEO_OK });
  const result = await lookup({
    lat: 29.03, lon: 119.18, key: 'k', fetchImpl,
    addressStore: new TtlCache(60_000), weatherStore: new TtlCache(60_000),
  });
  assert.equal(result.address, '浙江省衢州市龙游县东华街道鸡鸣路146号');
  assert.equal(result.weather, null);
  assert.equal(result.degraded, true);
});

test('lookup：地址失败时不请求天气并全程降级', async () => {
  const fetchImpl = fakeFetch({});
  const result = await lookup({
    lat: 29.03, lon: 119.18, key: 'k', fetchImpl,
    addressStore: new TtlCache(60_000), weatherStore: new TtlCache(60_000),
  });
  assert.equal(result.address, null);
  assert.equal(result.weather, null);
  assert.equal(result.degraded, true);
  assert.equal(fetchImpl.calls.length, 1, '无 adcode 时不应再查天气');
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
    addressStore: new TtlCache(60_000), weatherStore: new TtlCache(60_000),
  });
  assert.equal(result.address, null);
  assert.equal(result.degraded, true);
});
