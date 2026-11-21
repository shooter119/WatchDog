'use strict';

const express = require('express');
const { MinuteRateLimiter } = require('./rate-limiter');

const wrap = (handler) => (req, res, next) =>
  Promise.resolve(handler(req, res)).catch((error) => {
    if (error && error.status) {
      return res.status(error.status).json({
        code: error.code || 'BAD_REQUEST',
        error: error.message || error.code || '请求参数无效',
      });
    }
    next(error);
  });

const safeBody = (req) => (req.body && typeof req.body === 'object' && !Array.isArray(req.body) ? req.body : {});

const safeLimit = (raw, fallback = 50, max = 200) => {
  const n = Number.parseInt(String(raw ?? ''), 10);
  return Math.min(Math.max(1, Number.isFinite(n) ? n : fallback), max);
};

const safeOffset = (raw) => {
  const n = Number.parseInt(String(raw ?? ''), 10);
  return Math.max(0, Number.isFinite(n) ? n : 0);
};

function createWaterSourceAppRouter(waterSources, options = {}) {
  const router = express.Router();
  const writeLimiter = options.rateLimiter || new MinuteRateLimiter({ maxEntries: 10000 });
  const writeLimitPerMin = Number.isFinite(Number(options.writeLimitPerMin))
    ? Math.max(1, Math.floor(Number(options.writeLimitPerMin)))
    : 30;
  const now = typeof options.now === 'function' ? options.now : () => Date.now();

  router.use((req, res, next) => {
    res.set('Cache-Control', 'private, no-store');
    if (!req.auth?.memberId || !req.auth?.unitId) {
      return res.status(401).json({ code: 'SESSION_REQUIRED', error: '请先登录个人账号' });
    }
    next();
  });

  function checkWriteLimit(req, res, next) {
    if (writeLimiter.isLimited(req.auth.memberId, writeLimitPerMin, now())) {
      return res.status(429).json({
        code: 'WATER_SOURCE_RATE_LIMITED',
        error: '水源操作过于频繁，请稍后再试',
      });
    }
    next();
  }

  function actorFromReq(req) {
    return {
      actorId: String(req.auth.memberId || ''),
      actorName: String(req.auth.realName || ''),
    };
  }

  router.get('/', wrap(async (req, res) => {
    const result = await waterSources.listByUnit(req.auth.unitId, { deleted: 'none' });
    res.json({
      items: result.items,
      summary: result.summary,
    });
  }));

  router.post('/', checkWriteLimit, wrap(async (req, res) => {
    const item = await waterSources.create(req.auth.unitId, safeBody(req), actorFromReq(req));
    res.status(201).json({ item });
  }));

  router.patch('/:id', checkWriteLimit, wrap(async (req, res) => {
    const item = await waterSources.update(
      req.auth.unitId,
      req.params.id,
      safeBody(req),
      actorFromReq(req),
    );
    res.json({ item });
  }));

  router.delete('/:id', checkWriteLimit, wrap(async (req, res) => {
    const result = await waterSources.softDelete(
      req.auth.unitId,
      req.params.id,
      actorFromReq(req),
    );
    res.json(result);
  }));

  router.post('/:id/restore', checkWriteLimit, wrap(async (req, res) => {
    const item = await waterSources.restore(req.auth.unitId, req.params.id, {
      ...actorFromReq(req),
      enforceWindow: true,
    });
    res.json({ item });
  }));

  return router;
}

function createWaterSourceAdminRouter(waterSources, adminAuth = null) {
  const router = express.Router();

  router.use((req, res, next) => {
    res.set('Cache-Control', 'private, no-store');
    next();
  });

  function resolveAdminUnitId(req, explicitUnitId) {
    const admin = req.admin;
    if (!admin || !admin.unit_id) {
      const err = new Error('无权访问管理接口');
      err.status = 403;
      err.code = 'ADMIN_FORBIDDEN';
      throw err;
    }
    const requested = String(
      explicitUnitId !== undefined ? explicitUnitId : (req.query.unit_id ?? ''),
    ).trim();

    if (admin.admin_role === 'platform_admin') {
      return requested || admin.unit_id;
    }
    if (requested && requested !== admin.unit_id) {
      const err = new Error('无权访问其他单位水源数据');
      err.status = 403;
      err.code = 'UNIT_FORBIDDEN';
      throw err;
    }
    return admin.unit_id;
  }

  async function recordAudit(actorId, action, targetId) {
    if (adminAuth && typeof adminAuth.audit === 'function' && actorId) {
      await adminAuth.audit(actorId, action, targetId);
    }
  }

  function actorFromAdmin(req) {
    return {
      actorId: String(req.admin?.id || ''),
      actorName: String(req.admin?.real_name || ''),
    };
  }

  router.get('/', wrap(async (req, res) => {
    const unitId = resolveAdminUnitId(req);
    const deleted = ['none', 'only', 'all'].includes(req.query.deleted) ? req.query.deleted : 'none';
    const offset = safeOffset(req.query.offset);
    const limit = safeLimit(req.query.limit, 50, 200);
    const result = await waterSources.listByUnit(unitId, {
      category: req.query.category,
      status: req.query.status,
      q: req.query.q,
      deleted,
      offset,
      limit,
    });
    res.json(result);
  }));

  router.post('/', wrap(async (req, res) => {
    const body = safeBody(req);
    const unitId = resolveAdminUnitId(req, body.unit_id !== undefined ? body.unit_id : req.query.unit_id);
    const item = await waterSources.create(unitId, body, actorFromAdmin(req));
    await recordAudit(req.admin.id, 'water_source_created', item.id);
    res.status(201).json({ item });
  }));

  router.patch('/:id', wrap(async (req, res) => {
    const body = safeBody(req);
    const unitId = resolveAdminUnitId(req, body.unit_id !== undefined ? body.unit_id : req.query.unit_id);
    const item = await waterSources.update(unitId, req.params.id, body, actorFromAdmin(req));
    await recordAudit(req.admin.id, 'water_source_updated', item.id);
    res.json({ item });
  }));

  router.delete('/:id', wrap(async (req, res) => {
    const body = safeBody(req);
    const unitId = resolveAdminUnitId(req, body.unit_id !== undefined ? body.unit_id : req.query.unit_id);
    const result = await waterSources.softDelete(unitId, req.params.id, actorFromAdmin(req));
    await recordAudit(req.admin.id, 'water_source_deleted', req.params.id);
    res.json(result);
  }));

  router.post('/:id/restore', wrap(async (req, res) => {
    const body = safeBody(req);
    const unitId = resolveAdminUnitId(req, body.unit_id !== undefined ? body.unit_id : req.query.unit_id);
    const item = await waterSources.restore(unitId, req.params.id, {
      ...actorFromAdmin(req),
      enforceWindow: false,
    });
    await recordAudit(req.admin.id, 'water_source_restored', item.id);
    res.json({ item });
  }));

  return router;
}

module.exports = {
  createWaterSourceAppRouter,
  createWaterSourceAdminRouter,
};
