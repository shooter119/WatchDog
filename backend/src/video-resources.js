const crypto = require('node:crypto');
const express = require('express');

function fail(error, code = 'VIDEO_RESOURCE_INVALID', status = 400) {
  const result = new Error(error);
  result.code = code;
  result.status = status;
  throw result;
}

function text(value, max, { required = false } = {}) {
  const clean = String(value ?? '').trim();
  if (required && !clean) fail('资源名称不能为空');
  if (clean.length > max) fail(`内容过长（最多 ${max} 字）`);
  return clean;
}

function streamUrl(value) {
  const raw = String(value ?? '').trim();
  if (!raw || raw.length > 2048) fail('视频地址无效');
  let parsed;
  try {
    parsed = new URL(raw);
  } catch (_) {
    fail('视频地址格式无效');
  }
  const localHttp = process.env.NODE_ENV === 'test' &&
    parsed.protocol === 'http:' &&
    ['127.0.0.1', 'localhost'].includes(parsed.hostname);
  if (parsed.protocol !== 'https:' && !localHttp) {
    fail('视频地址必须使用 HTTPS');
  }
  if (!parsed.hostname || parsed.username || parsed.password || parsed.hash) {
    fail('视频地址不能包含账号、密码或片段');
  }
  return parsed.toString();
}

function canManage(auth) {
  return Boolean(auth?.memberId) && ['manager', 'admin'].includes(auth.role);
}

function createVideoResources(store) {
  if (!store || typeof store.query !== 'function') {
    throw new Error('Video resource store is required');
  }

  async function list(unitId, { includeInactive = false } = {}) {
    if (!unitId) fail('请先完成单位认证', 'UNIT_AUTH_REQUIRED', 401);
    const rows = await store.query(
      `SELECT * FROM video_resources
       WHERE unit_id=$1 ${includeInactive ? '' : 'AND active=TRUE'}
       ORDER BY sort_order ASC, created_at ASC, id ASC`,
      [unitId],
    );
    return rows.rows;
  }

  async function create(unitId, memberId, input = {}) {
    if (!unitId) fail('请先完成单位认证', 'UNIT_AUTH_REQUIRED', 401);
    if (!memberId) fail('请先完成单位认证', 'UNIT_AUTH_REQUIRED', 401);
    const next = await store.query(
      'SELECT COALESCE(MAX(sort_order), 0) + 10 AS sort_order FROM video_resources WHERE unit_id=$1',
      [unitId],
    );
    const now = Date.now();
    const values = [
      crypto.randomUUID(),
      unitId,
      text(input.name, 80, { required: true }),
      streamUrl(input.streamUrl ?? input.stream_url),
      text(input.description, 240),
      input.active === false ? false : true,
      Number(next.rows[0]?.sort_order) || 10,
      memberId,
      now,
      now,
    ];
    try {
      const result = await store.query(
        `INSERT INTO video_resources(
          id,unit_id,name,stream_url,description,active,sort_order,
          created_by,updated_by,created_at,updated_at
        ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$8,$9,$10)
        RETURNING *`,
        values,
      );
      return result.rows[0];
    } catch (error) {
      if (error.code === '23505') fail('该视频地址已存在', 'VIDEO_RESOURCE_EXISTS', 409);
      throw error;
    }
  }

  async function update(unitId, memberId, id, input = {}) {
    if (!unitId) fail('请先完成单位认证', 'UNIT_AUTH_REQUIRED', 401);
    if (!memberId) fail('请先完成单位认证', 'UNIT_AUTH_REQUIRED', 401);
    const current = (await store.query(
      'SELECT * FROM video_resources WHERE id=$1 AND unit_id=$2',
      [id, unitId],
    )).rows[0];
    if (!current) fail('视频资源不存在', 'VIDEO_RESOURCE_NOT_FOUND', 404);
    const expected = Number(input.expectedVersion ?? input.expected_version);
    if (!Number.isInteger(expected) || expected !== Number(current.version)) {
      fail('视频资源已被其他管理员更新，请刷新后重试', 'VIDEO_RESOURCE_CONFLICT', 409);
    }
    const nextName = input.name === undefined
      ? current.name
      : text(input.name, 80, { required: true });
    const nextUrl = input.streamUrl === undefined && input.stream_url === undefined
      ? current.stream_url
      : streamUrl(input.streamUrl ?? input.stream_url);
    const nextDescription = input.description === undefined
      ? current.description
      : text(input.description, 240);
    const nextActive = input.active === undefined
      ? current.active
      : input.active !== false;
    try {
      const result = await store.query(
        `UPDATE video_resources
         SET name=$3,stream_url=$4,description=$5,active=$6,
             version=version+1,updated_by=$7,updated_at=$8
         WHERE id=$1 AND unit_id=$2 AND version=$9
         RETURNING *`,
        [
          id, unitId, nextName, nextUrl, nextDescription, nextActive,
          memberId, Date.now(), expected,
        ],
      );
      if (!result.rows[0]) {
        fail('视频资源已被其他管理员更新，请刷新后重试', 'VIDEO_RESOURCE_CONFLICT', 409);
      }
      return result.rows[0];
    } catch (error) {
      if (error.code === '23505') fail('该视频地址已存在', 'VIDEO_RESOURCE_EXISTS', 409);
      throw error;
    }
  }

  async function initialize(unitId, input = {}) {
    if (!unitId) fail('消防单位不能为空', 'VIDEO_RESOURCE_INVALID');
    const unit = await store.query('SELECT id FROM units WHERE id=$1', [unitId]);
    if (!unit.rows[0]) fail('消防单位不存在', 'VIDEO_RESOURCE_NOT_FOUND', 404);
    const now = Date.now();
    const next = await store.query(
      'SELECT COALESCE(MAX(sort_order), 0) + 10 AS sort_order FROM video_resources WHERE unit_id=$1',
      [unitId],
    );
    const normalizedUrl = streamUrl(input.streamUrl ?? input.stream_url);
    const result = await store.query(
      `INSERT INTO video_resources(
        id,unit_id,name,stream_url,description,active,sort_order,created_at,updated_at
      ) VALUES($1,$2,$3,$4,$5,TRUE,$6,$7,$7)
      ON CONFLICT(unit_id,stream_url) DO UPDATE SET
        name=EXCLUDED.name,description=EXCLUDED.description,active=TRUE,
        version=video_resources.version+1,updated_at=EXCLUDED.updated_at
      RETURNING *`,
      [
        crypto.randomUUID(), unitId,
        text(input.name, 80, { required: true }),
        normalizedUrl, text(input.description, 240),
        Number(next.rows[0]?.sort_order) || 10, now,
      ],
    );
    return result.rows[0];
  }

  return { list, create, update, initialize };
}

const wrap = (handler) => (req, res, next) => Promise.resolve(handler(req, res)).catch((error) => {
  if (error.status) {
    return res.status(error.status).json({ code: error.code, error: error.message });
  }
  next(error);
});

function createVideoResourceRouter(resources) {
  const router = express.Router();
  router.use((req, res, next) => {
    res.set('Cache-Control', 'private, no-store');
    if (!req.auth?.memberId || !req.unit?.id) {
      return res.status(401).json({
        code: 'SESSION_REQUIRED',
        error: '请先完成单位认证',
      });
    }
    next();
  });
  router.get('/access', (req, res) => {
    res.json({ can_manage: canManage(req.auth) });
  });
  router.get('/', wrap(async (req, res) => {
    const includeInactive = canManage(req.auth) &&
      ['1', 'true'].includes(String(req.query.include_inactive || '').toLowerCase());
    res.json({
      resources: await resources.list(req.unit.id, { includeInactive }),
    });
  }));
  router.post('/', wrap(async (req, res) => {
    if (!canManage(req.auth)) {
      return res.status(403).json({
        code: 'MANAGEMENT_REQUIRED',
        error: '视频资源管理仅限管理员',
      });
    }
    res.status(201).json(
      await resources.create(req.unit.id, req.auth.memberId, req.body),
    );
  }));
  router.patch('/:id', wrap(async (req, res) => {
    if (!canManage(req.auth)) {
      return res.status(403).json({
        code: 'MANAGEMENT_REQUIRED',
        error: '视频资源管理仅限管理员',
      });
    }
    res.json(
      await resources.update(
        req.unit.id,
        req.auth.memberId,
        req.params.id,
        req.body,
      ),
    );
  }));
  return router;
}

module.exports = {
  createVideoResources,
  createVideoResourceRouter,
  canManage,
  streamUrl,
};
