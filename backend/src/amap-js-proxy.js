'use strict';

const crypto = require('node:crypto');
const express = require('express');
const { MinuteRateLimiter } = require('./rate-limiter');

// 高德 JS API 2.0 短期代理凭证有效期（2 小时）。
const TICKET_TTL_MS = 2 * 60 * 60 * 1000;
const UPSTREAM_TIMEOUT_MS = 8000;

/**
 * 构建高德 JS API 2.0 引导与 `_AMapService` 安全代理服务。
 *
 * 设计要点：
 * 1. `AMAP_JS_SECRET`（安全密钥 jscode）只留在服务端，永不下发给客户端；
 * 2. WebView 内由高德脚本发出的 `_AMapService` 请求无法附带自定义会话头，
 *    因此通过路径中的短期 HMAC 票据验证已认证单位身份，防止匿名盗刷；
 * 3. 严格按高德代理规范将 `v4/map/styles` 转发至 `webapi.amap.com`，
 *    其余合法路径转发至 `restapi.amap.com`，并清理路径穿越与客户端伪造的 `jscode`。
 */
function createAmapJsService({
  getConfig,
  secretSeed,
  fetchImpl = fetch,
  now = () => Date.now(),
  webapiBase = 'https://webapi.amap.com',
  restapiBase = 'https://restapi.amap.com',
} = {}) {
  const processFallbackSeed = crypto.randomBytes(32).toString('hex');
  const bootstrapLimiter = new MinuteRateLimiter({ maxEntries: 10000 });
  const proxyLimiter = new MinuteRateLimiter({ maxEntries: 10000 });

  const resolvedWebapiOrigin = new URL(webapiBase).origin;
  const resolvedRestapiOrigin = new URL(restapiBase).origin;

  function readConfig() {
    const raw = typeof getConfig === 'function' ? getConfig() : {};
    return {
      jsKey: String(raw?.jsKey || '').trim(),
      jsSecret: String(raw?.jsSecret || '').trim(),
    };
  }

  function signingKey() {
    const { jsSecret } = readConfig();
    const seed = String(
      secretSeed ||
      process.env.AMAP_JS_PROXY_SECRET ||
      process.env.API_TOKEN ||
      processFallbackSeed,
    );
    return crypto
      .createHash('sha256')
      .update(`watchdog-amap-js:${seed}:${jsSecret}`)
      .digest();
  }

  function issueTicket({ unitId, sessionId = '' }, nowMs = now()) {
    const payload = {
      u: String(unitId || '').trim(),
      s: String(sessionId || '').trim(),
      exp: Number(nowMs) + TICKET_TTL_MS,
    };
    const encoded = Buffer.from(JSON.stringify(payload), 'utf8').toString('base64url');
    const sig = crypto
      .createHmac('sha256', signingKey())
      .update(encoded)
      .digest('base64url');
    return `${encoded}.${sig}`;
  }

  function verifyTicket(ticket, nowMs = now()) {
    if (typeof ticket !== 'string' || ticket.length > 1024) return null;
    const dotIndex = ticket.indexOf('.');
    if (dotIndex <= 0 || dotIndex !== ticket.lastIndexOf('.')) return null;
    const encoded = ticket.slice(0, dotIndex);
    const sig = ticket.slice(dotIndex + 1);
    if (!/^[A-Za-z0-9_-]+$/.test(encoded) || !/^[A-Za-z0-9_-]+$/.test(sig)) {
      return null;
    }
    const expectedSig = crypto
      .createHmac('sha256', signingKey())
      .update(encoded)
      .digest('base64url');
    const sigBuf = Buffer.from(sig, 'utf8');
    const expectedBuf = Buffer.from(expectedSig, 'utf8');
    if (sigBuf.length !== expectedBuf.length) return null;
    if (!crypto.timingSafeEqual(sigBuf, expectedBuf)) return null;

    let payload;
    try {
      payload = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'));
    } catch (_) {
      return null;
    }
    if (
      !payload ||
      typeof payload !== 'object' ||
      typeof payload.u !== 'string' ||
      !payload.u.trim() ||
      !Number.isFinite(payload.exp) ||
      payload.exp <= Number(nowMs)
    ) {
      return null;
    }
    return {
      unitId: payload.u.trim(),
      sessionId: typeof payload.s === 'string' ? payload.s : '',
    };
  }

  function validateSubpath(rawSubpath) {
    if (typeof rawSubpath !== 'string') return null;
    const trimmed = rawSubpath.trim();
    if (!trimmed || trimmed.length > 256) return null;
    if (trimmed.startsWith('/') || trimmed.includes('\\') || trimmed.includes('://')) {
      return null;
    }
    if (/[\x00-\x1f\x7f]/.test(trimmed)) return null;

    let decoded;
    try {
      decoded = decodeURIComponent(trimmed);
    } catch (_) {
      return null;
    }
    if (
      !decoded ||
      decoded.startsWith('/') ||
      decoded.includes('\\') ||
      decoded.includes('://') ||
      /[\x00-\x1f\x7f\s]/.test(decoded)
    ) {
      return null;
    }

    const segments = decoded.split('/');
    for (const seg of segments) {
      if (!seg || seg === '.' || seg === '..' || seg.includes('..') || seg.startsWith('.')) {
        return null;
      }
      if (!/^[a-zA-Z0-9._-]+$/.test(seg)) return null;
    }
    return segments.join('/');
  }

  function handleBootstrap(req, res) {
    if (!req.unit?.id) {
      return res.status(401).json({ error: '请先完成单位认证', code: 'UNIT_AUTH_REQUIRED' });
    }
    const source = req.ip || 'anonymous';
    if (bootstrapLimiter.isLimited(`${source}:${req.unit.id}`, 60, now())) {
      return res.status(429).json({ error: '地图配置请求过于频繁，请稍后再试', code: 'UPSTREAM_RATE_LIMITED' });
    }
    const { jsKey, jsSecret } = readConfig();
    if (!jsKey) {
      return res.json({
        configured: false,
        code: 'AMAP_JS_NOT_CONFIGURED',
        message: '服务端尚未配置高德 Web 端 (JS API) Key',
      });
    }
    const hasSecurityProxy = Boolean(jsSecret);
    const ticket = hasSecurityProxy
      ? issueTicket({ unitId: req.unit.id, sessionId: req.auth?.sessionId || '' }, now())
      : null;
    return res.json({
      configured: true,
      jsKey,
      hasSecurityProxy,
      proxyPath: ticket ? `/api/amap-proxy/${ticket}/_AMapService` : null,
      expiresInMs: TICKET_TTL_MS,
    });
  }

  const proxyRouter = express.Router();

  async function handleProxy(req, res) {
    if (req.method !== 'GET') {
      return res.status(405).json({ error: '仅支持 GET 请求', code: 'METHOD_NOT_ALLOWED' });
    }
    const claims = verifyTicket(req.params.ticket, now());
    if (!claims) {
      return res.status(401).json({ error: '地图代理凭证无效或已过期', code: 'MAP_TICKET_INVALID' });
    }
    if (proxyLimiter.isLimited(claims.unitId, 360, now())) {
      return res.status(429).json({ error: '地图代理请求过于频繁，请稍后再试', code: 'UPSTREAM_RATE_LIMITED' });
    }
    const { jsSecret } = readConfig();
    if (!jsSecret) {
      return res.status(503).json({ error: '高德安全密钥未配置', code: 'AMAP_JS_SECRET_NOT_CONFIGURED' });
    }

    const subpath = validateSubpath(req.params[0] || '');
    const rawOriginalPath = String(req.originalUrl || '').split('?')[0];
    if (
      !subpath ||
      /(?:^|\/)(?:\.|%2e){2}(?:\/|$)/i.test(rawOriginalPath) ||
      /(?:\\|%5c|%00)/i.test(rawOriginalPath)
    ) {
      return res.status(400).json({ error: '非法的地图服务路径', code: 'AMAP_PROXY_PATH_INVALID' });
    }

    const isMapStyles = subpath === 'v4/map/styles' || subpath.startsWith('v4/map/styles/');
    const upstreamBase = (isMapStyles ? webapiBase : restapiBase).replace(/\/+$/, '');
    const expectedOrigin = isMapStyles ? resolvedWebapiOrigin : resolvedRestapiOrigin;

    let targetUrl;
    try {
      targetUrl = new URL(`${upstreamBase}/${subpath}`);
      if (targetUrl.origin !== expectedOrigin) {
        return res.status(400).json({ error: '非法的地图服务路径', code: 'AMAP_PROXY_PATH_INVALID' });
      }
      const incomingUrl = new URL(req.originalUrl || '/', 'http://localhost');
      for (const [key, value] of incomingUrl.searchParams.entries()) {
        if (key.toLowerCase() === 'jscode') continue;
        targetUrl.searchParams.append(key, value);
      }
      targetUrl.searchParams.set('jscode', jsSecret);
    } catch (_) {
      return res.status(400).json({ error: '非法的地图服务路径', code: 'AMAP_PROXY_PATH_INVALID' });
    }

    const forwardHeaders = {
      Accept: req.get('accept') || '*/*',
      'Accept-Language': req.get('accept-language') || 'zh-CN,zh;q=0.9',
    };

    try {
      const upstreamRes = await fetchImpl(targetUrl.toString(), {
        method: 'GET',
        headers: forwardHeaders,
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
      });
      const bodyBuf = Buffer.from(await upstreamRes.arrayBuffer());
      const contentType = upstreamRes.headers?.get?.('content-type');
      if (contentType) {
        res.set('Content-Type', contentType);
      }
      res.set('Cache-Control', 'private, max-age=300');
      return res.status(upstreamRes.status).send(bodyBuf);
    } catch (_) {
      return res.status(502).json({ error: '地图上游服务暂时不可用', code: 'AMAP_UPSTREAM_FAILED' });
    }
  }

  proxyRouter.all('/:ticket/_AMapService', handleProxy);
  proxyRouter.all('/:ticket/_AMapService/*', handleProxy);

  return {
    issueTicket,
    verifyTicket,
    handleBootstrap,
    proxyRouter,
  };
}

module.exports = {
  createAmapJsService,
  TICKET_TTL_MS,
};
