'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const { createAmapJsService, TICKET_TTL_MS } = require('../src/amap-js-proxy');

async function startTestApp(setupFn) {
  const app = express();
  setupFn(app);
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  return {
    base,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

test('createAmapJsService: 未认证与未配置 AMAP_JS_KEY 时的引导响应', async () => {
  let authedUnit = null;
  const service = createAmapJsService({
    getConfig: () => ({ jsKey: '', jsSecret: '' }),
    secretSeed: 'test-seed',
  });
  const srv = await startTestApp((app) => {
    app.use((req, _res, next) => {
      if (authedUnit) req.unit = authedUnit;
      next();
    });
    app.get('/api/scene-map/bootstrap', (req, res) => service.handleBootstrap(req, res));
  });

  try {
    const unauth = await fetch(`${srv.base}/api/scene-map/bootstrap`);
    assert.equal(unauth.status, 401);
    assert.equal((await unauth.json()).code, 'UNIT_AUTH_REQUIRED');

    authedUnit = { id: 'unit-example', name: '示例县消防救援大队' };
    const unconfigured = await fetch(`${srv.base}/api/scene-map/bootstrap`);
    assert.equal(unconfigured.status, 200);
    const body = await unconfigured.json();
    assert.equal(body.configured, false);
    assert.equal(body.code, 'AMAP_JS_NOT_CONFIGURED');
  } finally {
    await srv.close();
  }
});

test('createAmapJsService: 已配置 Key+Secret 签发短期票据且绝不泄露 jsSecret', async () => {
  let currentNow = 1_700_000_000_000;
  const service = createAmapJsService({
    getConfig: () => ({ jsKey: 'demo-js-key', jsSecret: 'top-secret-jscode' }),
    secretSeed: 'unit-test-seed',
    now: () => currentNow,
  });

  const srv = await startTestApp((app) => {
    app.use((req, _res, next) => {
      req.unit = { id: 'unit-example', name: '示例县消防救援大队' };
      req.auth = { sessionId: 'sess-123' };
      next();
    });
    app.get('/api/scene-map/bootstrap', (req, res) => service.handleBootstrap(req, res));
  });

  try {
    const res = await fetch(`${srv.base}/api/scene-map/bootstrap`);
    assert.equal(res.status, 200);
    const rawText = await res.text();
    assert.equal(rawText.includes('top-secret-jscode'), false, '响应体绝不允许包含 jsSecret');
    const body = JSON.parse(rawText);
    assert.equal(body.configured, true);
    assert.equal(body.jsKey, 'demo-js-key');
    assert.equal(body.hasSecurityProxy, true);
    assert.equal(body.expiresInMs, TICKET_TTL_MS);
    assert.match(body.proxyPath, /^\/api\/amap-proxy\/[^/]+\/_AMapService$/);

    const ticket = body.proxyPath.split('/')[3];
    const claims = service.verifyTicket(ticket, currentNow + 1000);
    assert.deepEqual(claims, { unitId: 'unit-example', sessionId: 'sess-123' });

    // 篡改或过期票据均被拒绝
    const tampered = `${ticket.slice(0, -1)}${ticket.endsWith('A') ? 'B' : 'A'}`;
    assert.equal(service.verifyTicket(tampered, currentNow + 1000), null);
    assert.equal(service.verifyTicket(ticket, currentNow + TICKET_TTL_MS + 1), null);
  } finally {
    await srv.close();
  }
});

test('proxyRouter: 分流 webapi/restapi、覆盖伪造 jscode 并透传二进制与状态码', async () => {
  const upstreamCalls = [];
  const fakeFetch = async (url, init) => {
    upstreamCalls.push({ url, method: init.method, headers: init.headers });
    const parsed = new URL(url);
    if (parsed.pathname.startsWith('/v4/map/styles')) {
      return new Response(Buffer.from([0x1f, 0x8b, 0x08, 0x00]), {
        status: 200,
        headers: { 'content-type': 'application/octet-stream' },
      });
    }
    return new Response(JSON.stringify({ status: '1', info: 'OK' }), {
      status: 200,
      headers: { 'content-type': 'application/json; charset=utf-8' },
    });
  };

  const service = createAmapJsService({
    getConfig: () => ({ jsKey: 'demo-js-key', jsSecret: 'real-server-jscode' }),
    secretSeed: 'proxy-seed',
    fetchImpl: fakeFetch,
    webapiBase: 'https://webapi.example.test',
    restapiBase: 'https://restapi.example.test',
  });
  const ticket = service.issueTicket({ unitId: 'unit-example', sessionId: 'sess-1' });

  const srv = await startTestApp((app) => {
    app.use('/api/amap-proxy', service.proxyRouter);
  });

  try {
    // 1. v4/map/styles 路由至 webapi 并强制覆写客户端传入的伪造 jscode
    const styleRes = await fetch(
      `${srv.base}/api/amap-proxy/${ticket}/_AMapService/v4/map/styles?styleid=normal&jscode=fake-client-code`,
    );
    assert.equal(styleRes.status, 200);
    assert.equal(styleRes.headers.get('content-type'), 'application/octet-stream');
    assert.deepEqual(Buffer.from(await styleRes.arrayBuffer()), Buffer.from([0x1f, 0x8b, 0x08, 0x00]));
    assert.equal(upstreamCalls.length, 1);
    const styleUrl = new URL(upstreamCalls[0].url);
    assert.equal(styleUrl.origin, 'https://webapi.example.test');
    assert.equal(styleUrl.pathname, '/v4/map/styles');
    assert.equal(styleUrl.searchParams.get('styleid'), 'normal');
    assert.equal(styleUrl.searchParams.get('jscode'), 'real-server-jscode');

    // 2. 其他路径（如 v3/geocode/regeo）路由至 restapi
    const regeoRes = await fetch(
      `${srv.base}/api/amap-proxy/${ticket}/_AMapService/v3/geocode/regeo?location=119.18,29.03`,
    );
    assert.equal(regeoRes.status, 200);
    assert.equal((await regeoRes.json()).status, '1');
    assert.equal(upstreamCalls.length, 2);
    const regeoUrl = new URL(upstreamCalls[1].url);
    assert.equal(regeoUrl.origin, 'https://restapi.example.test');
    assert.equal(regeoUrl.pathname, '/v3/geocode/regeo');
    assert.equal(regeoUrl.searchParams.get('location'), '119.18,29.03');
    assert.equal(regeoUrl.searchParams.get('jscode'), 'real-server-jscode');
  } finally {
    await srv.close();
  }
});

test('proxyRouter: 拦截无效票据、路径穿越、非 GET 方法与上游失败 502', async () => {
  const service = createAmapJsService({
    getConfig: () => ({ jsKey: 'demo-js-key', jsSecret: 'real-server-jscode' }),
    secretSeed: 'guard-seed',
    fetchImpl: async () => {
      throw new Error('upstream down');
    },
  });
  const ticket = service.issueTicket({ unitId: 'unit-example', sessionId: 'sess-1' });

  const srv = await startTestApp((app) => {
    app.use('/api/amap-proxy', service.proxyRouter);
  });

  try {
    const badTicket = await fetch(`${srv.base}/api/amap-proxy/invalid.ticket/_AMapService/v3/config/district`);
    assert.equal(badTicket.status, 401);
    assert.equal((await badTicket.json()).code, 'MAP_TICKET_INVALID');

    const badMethod = await fetch(`${srv.base}/api/amap-proxy/${ticket}/_AMapService/v3/config/district`, {
      method: 'POST',
    });
    assert.equal(badMethod.status, 405);

    const traversalRes = await new Promise((resolve, reject) => {
      const target = new URL(srv.base);
      const req = http.request({
        hostname: target.hostname,
        port: target.port,
        path: `/api/amap-proxy/${ticket}/_AMapService/v3/%2e%2e/secret`,
        method: 'GET',
      }, (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          resolve({
            status: res.statusCode,
            body: JSON.parse(Buffer.concat(chunks).toString('utf8')),
          });
        });
      });
      req.on('error', reject);
      req.end();
    });
    assert.equal(traversalRes.status, 400);
    assert.equal(traversalRes.body.code, 'AMAP_PROXY_PATH_INVALID');

    const backslashTraversal = await fetch(`${srv.base}/api/amap-proxy/${ticket}/_AMapService/v3/a%5cb`);
    assert.equal(backslashTraversal.status, 400);
    assert.equal((await backslashTraversal.json()).code, 'AMAP_PROXY_PATH_INVALID');

    const emptySubpath = await fetch(`${srv.base}/api/amap-proxy/${ticket}/_AMapService`);
    assert.equal(emptySubpath.status, 400);

    const upstreamFail = await fetch(`${srv.base}/api/amap-proxy/${ticket}/_AMapService/v3/geocode/regeo`);
    assert.equal(upstreamFail.status, 502);
    assert.equal((await upstreamFail.json()).code, 'AMAP_UPSTREAM_FAILED');
  } finally {
    await srv.close();
  }
});

test('server.js 集成: 引导路由走单位认证且代理路由使用票据旁路头鉴权', async () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-amap-server-'));
  process.env.WATCHDOG_DATA_DIR = tmpDir;
  process.env.AMAP_JS_KEY = 'server-test-js-key';
  process.env.AMAP_JS_SECRET = 'server-test-js-secret';

  const app = require('../src/server');
  const srv = await startTestApp((wrapper) => wrapper.use(app));

  try {
    // 引导接口挂载在 server.js 中：测试模式下 req.unit 默认未认证时应被拒绝或走认证
    const bootstrapRes = await fetch(`${srv.base}/api/scene-map/bootstrap`, {
      headers: {
        'X-Unit-Id': 'example-county-fire-rescue',
        'X-Unit-Code': '1001',
      },
    });
    // server.js 在 NODE_ENV=test 且 WATCHDOG_UNIT_AUTH_REQUIRED=0 时 req.unit 为 undefined -> 401 UNIT_AUTH_REQUIRED
    assert.equal(bootstrapRes.status, 401);
    assert.equal((await bootstrapRes.json()).code, 'UNIT_AUTH_REQUIRED');

    // 代理路由挂载在全局会话中间件之前，带非法票据时返回 MAP_TICKET_INVALID 而非 SESSION_REQUIRED
    const proxyRes = await fetch(`${srv.base}/api/amap-proxy/bad.ticket/_AMapService/v3/geocode/regeo`);
    assert.equal(proxyRes.status, 401);
    assert.equal((await proxyRes.json()).code, 'MAP_TICKET_INVALID');
  } finally {
    await srv.close();
  }
});
