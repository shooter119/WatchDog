const express = require('express');
const { MinuteRateLimiter } = require('./rate-limiter');

const SESSION = '__Host-watchdog_admin';
const BROWSER = '__Host-watchdog_browser';
const cookieOptions = { secure: true, httpOnly: true, sameSite: 'strict', path: '/' };
function cookie(req, name) {
  return String(req.headers.cookie || '').split(';').map((part) => part.trim())
    .find((part) => part.startsWith(`${name}=`))?.slice(name.length + 1) || '';
}
const wrap = (handler) => (req, res, next) => Promise.resolve(handler(req, res)).catch((error) => {
  if (error.status) return res.status(error.status).json({ code: error.code, error: error.code });
  next(error);
});

function createAdminRouter(auth, { origin = 'https://fireman119.xyz', sites, files } = {}) {
  const router = express.Router();
  const limiter = new MinuteRateLimiter();
  router.use((req, res, next) => {
    res.set('Cache-Control', 'no-store');
    // No cross-origin credential sharing for this independent authentication surface.
    res.removeHeader('Access-Control-Allow-Origin');
    if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method) && req.get('Origin') !== origin) {
      return res.status(403).json({ code: 'ADMIN_ORIGIN_INVALID' });
    }
    if (req.path.startsWith('/login/') && limiter.isLimited(req.ip, 90)) {
      return res.status(429).json({ code: 'ADMIN_RATE_LIMITED' });
    }
    next();
  });
  router.post('/login/challenges', wrap(async (req, res) => {
    const challenge = await auth.challenge();
    res.cookie(BROWSER, challenge.browser, { ...cookieOptions, maxAge: 120000 });
    const qrPayload = `https://fireman119.xyz/admin/scan#${challenge.id}.${challenge.scan}`;
    res.json({ id: challenge.id, expiresAt: challenge.expiresAt,
      qrPayload, qrImage: await require('qrcode').toDataURL(qrPayload, { width: 320, margin: 3 }) });
  }));
  router.post('/login/claim', wrap(async (req, res) => {
    const result = await auth.claim(req.body.id, cookie(req, BROWSER));
    if (!result) return res.status(202).json({ state: 'pending' });
    res.cookie(SESSION, result.token, { ...cookieOptions, maxAge: 8 * 3600000 });
    res.clearCookie(BROWSER, cookieOptions);
    return res.json({ member: result.member, csrf: result.csrf });
  }));
  router.use((req, res, next) => {
    auth.session(cookie(req, SESSION), req.get('X-CSRF-Token'), !['GET', 'HEAD'].includes(req.method), req.path !== '/me' && req.get('X-Admin-Poll') !== '1')
      .then((member) => { req.admin = member; next(); })
      .catch((error) => error.status
        ? res.status(error.status).json({ code: error.code }) : next(error));
  });
  router.get('/me', (req, res) => res.json({ member: req.admin,
    csrf: require('./admin-auth').hash(`csrf:${cookie(req, SESSION)}`) }));
  router.post('/logout', wrap(async (req, res) => {
    await auth.logout(cookie(req, SESSION), req.body.all === true);
    res.clearCookie(SESSION, cookieOptions);
    res.json({ ok: true });
  }));
  router.put('/grants/:memberId', wrap(async (req, res) => {
    await auth.setGrant(req.admin.id, req.params.memberId, req.body.role);
    res.json({ ok: true });
  }));
  router.get('/members', wrap(async (req, res) => res.json({ members: await auth.listMembers(req.admin.id) })));
  router.get('/units', wrap(async (req, res) => res.json({ units: await auth.listUnits(req.admin.id) })));
  router.get('/audit', wrap(async (req, res) => res.json({ events: await auth.listAudit(req.admin.id, req.query.offset) })));
  if (sites && files) router.use('/key-sites', require('./key-site-routes').createKeySiteAdminRouter(sites, files));
  return router;
}

function createAdminAppRouter(auth) {
  const router = express.Router();
  const limiter = new MinuteRateLimiter();
  router.use((req, res, next) => {
    res.set('Cache-Control', 'no-store');
    if (!req.auth?.memberId) return res.status(401).json({ code: 'SESSION_REQUIRED' });
    if (limiter.isLimited(req.auth.memberId, 30)) return res.status(429).json({ code: 'ADMIN_RATE_LIMITED' });
    next();
  });
  router.get('/capability', wrap(async (req, res) => res.json({ member: await auth.identity(req.auth.memberId) || null })));
  router.post('/confirm', wrap(async (req, res) => {
    await auth.confirm(req.body.id, req.body.scan, req.auth.memberId, req.body.cancel === true);
    res.json({ ok: true });
  }));
  return router;
}
module.exports = { createAdminRouter, createAdminAppRouter };
