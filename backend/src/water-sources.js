'use strict';

const crypto = require('node:crypto');

const VALID_CATEGORIES = ['hydrant', 'natural', 'pump_connector'];
const VALID_STATUSES = ['available', 'unavailable'];
const VALID_INTAKE_METHODS = ['portable_pump', 'fire_truck', 'remote_supply'];
const MAX_ACTIVE_PER_UNIT = 5000;
const APP_RESTORE_WINDOW_MS = 60 * 1000;
const NAME_MAX_LEN = 120;
const NOTE_MAX_LEN = 500;
const LAT_MIN = 3;
const LAT_MAX = 55;
const LNG_MIN = 73;
const LNG_MAX = 136;

function createError(code, status, message) {
  const err = new Error(message || code);
  err.code = code;
  err.status = status;
  return err;
}

function escapeIlike(value) {
  return String(value || '').replace(/[\\%_]/g, '\\$&');
}

function normalizeCategory(raw) {
  if (typeof raw !== 'string') {
    throw createError('INVALID_CATEGORY', 400, '水源类别无效');
  }
  const value = raw.trim();
  if (!VALID_CATEGORIES.includes(value)) {
    throw createError('INVALID_CATEGORY', 400, '水源类别无效，仅支持 hydrant / natural / pump_connector');
  }
  return value;
}

function normalizeStatus(raw, { defaultToAvailable = false } = {}) {
  if ((raw === undefined || raw === null || raw === '') && defaultToAvailable) {
    return 'available';
  }
  if (typeof raw !== 'string') {
    throw createError('INVALID_STATUS', 400, '水源状态无效');
  }
  const value = raw.trim();
  if (!VALID_STATUSES.includes(value)) {
    throw createError('INVALID_STATUS', 400, '水源状态无效，仅支持 available / unavailable');
  }
  return value;
}

function normalizeName(raw) {
  if (typeof raw !== 'string') {
    throw createError('INVALID_NAME', 400, '水源名称不能为空');
  }
  const value = raw.trim();
  if (value.length < 1 || value.length > NAME_MAX_LEN) {
    throw createError('INVALID_NAME', 400, `水源名称长度须在 1 到 ${NAME_MAX_LEN} 字之间`);
  }
  return value;
}

function parseCoordinate(raw) {
  if (typeof raw === 'number') return raw;
  if (typeof raw === 'string' && raw.trim() !== '') return Number(raw);
  return Number.NaN;
}

function normalizeCoordinates(rawLat, rawLng) {
  const lat = parseCoordinate(rawLat);
  const lng = parseCoordinate(rawLng);
  if (
    !Number.isFinite(lat) ||
    !Number.isFinite(lng) ||
    lat < LAT_MIN ||
    lat > LAT_MAX ||
    lng < LNG_MIN ||
    lng > LNG_MAX
  ) {
    throw createError(
      'INVALID_COORDINATES',
      400,
      `经纬度超出有效范围（纬度 ${LAT_MIN}~${LAT_MAX}，经度 ${LNG_MIN}~${LNG_MAX}）`,
    );
  }
  return { lat, lng };
}

function normalizeNote(raw) {
  if (raw === undefined || raw === null) return '';
  if (typeof raw !== 'string') {
    throw createError('INVALID_NOTE', 400, '备注格式无效');
  }
  const value = raw.trim();
  if (value.length > NOTE_MAX_LEN) {
    throw createError('INVALID_NOTE', 400, `备注长度不能超过 ${NOTE_MAX_LEN} 字`);
  }
  return value;
}

function normalizeIntakeMethods(category, raw) {
  if (category !== 'natural') {
    if (raw === undefined || raw === null) return [];
    if (!Array.isArray(raw)) {
      throw createError('INVALID_INTAKE_METHODS', 400, '非天然水源不支持设置取水方式');
    }
    if (raw.length > 0) {
      throw createError('INVALID_INTAKE_METHODS', 400, '非天然水源的取水方式必须为空');
    }
    return [];
  }

  if (!Array.isArray(raw) || raw.length === 0) {
    throw createError('INVALID_INTAKE_METHODS', 400, '天然水源必须至少选择 1 项取水方式');
  }
  const selected = new Set();
  for (const item of raw) {
    if (typeof item !== 'string') {
      throw createError('INVALID_INTAKE_METHODS', 400, '取水方式包含无效项');
    }
    const trimmed = item.trim();
    if (!VALID_INTAKE_METHODS.includes(trimmed)) {
      throw createError('INVALID_INTAKE_METHODS', 400, '取水方式包含无效值');
    }
    selected.add(trimmed);
  }
  if (selected.size === 0) {
    throw createError('INVALID_INTAKE_METHODS', 400, '天然水源必须至少选择 1 项取水方式');
  }
  // 按固定顺序去重规范化
  return VALID_INTAKE_METHODS.filter((method) => selected.has(method));
}

function mapRow(row) {
  if (!row) return null;
  return {
    id: row.id,
    unit_id: row.unit_id,
    category: row.category,
    name: row.name,
    lat: Number(row.lat),
    lng: Number(row.lng),
    status: row.status,
    intake_methods: Array.isArray(row.intake_methods) ? [...row.intake_methods] : [],
    note: row.note ?? '',
    created_by: row.created_by ?? '',
    created_by_name: row.created_by_name ?? '',
    created_at: Number(row.created_at),
    updated_by: row.updated_by ?? '',
    updated_by_name: row.updated_by_name ?? '',
    updated_at: Number(row.updated_at),
    deleted_at: row.deleted_at === null || row.deleted_at === undefined ? null : Number(row.deleted_at),
    deleted_by: row.deleted_by ?? null,
    deleted_by_name: row.deleted_by_name ?? null,
  };
}

function createWaterSources(store, options = {}) {
  const now = typeof options.now === 'function' ? options.now : () => Date.now();
  const maxActivePerUnit = Number.isFinite(Number(options.maxActivePerUnit))
    ? Math.max(1, Math.floor(Number(options.maxActivePerUnit)))
    : MAX_ACTIVE_PER_UNIT;

  async function countActive(unitId) {
    const res = await store.query(
      'SELECT COUNT(*) AS cnt FROM water_sources WHERE unit_id = $1 AND deleted_at IS NULL',
      [unitId],
    );
    return Number(res.rows[0]?.cnt || 0);
  }

  async function getSummary(unitId) {
    const res = await store.query(
      `SELECT
        COUNT(*) AS total,
        COUNT(*) FILTER (WHERE status = 'available') AS available,
        COUNT(*) FILTER (WHERE status = 'unavailable') AS unavailable,
        COUNT(*) FILTER (WHERE category = 'hydrant') AS hydrant,
        COUNT(*) FILTER (WHERE category = 'natural') AS natural_count,
        COUNT(*) FILTER (WHERE category = 'pump_connector') AS pump_connector
      FROM water_sources
      WHERE unit_id = $1 AND deleted_at IS NULL`,
      [unitId],
    );
    const row = res.rows[0] || {};
    return {
      total: Number(row.total || 0),
      available: Number(row.available || 0),
      unavailable: Number(row.unavailable || 0),
      by_category: {
        hydrant: Number(row.hydrant || 0),
        natural: Number(row.natural_count || 0),
        pump_connector: Number(row.pump_connector || 0),
      },
    };
  }

  async function listByUnit(unitId, {
    category = '',
    status = '',
    q = '',
    deleted = 'none',
    offset,
    limit,
  } = {}) {
    const conditions = ['unit_id = $1'];
    const params = [unitId];
    let idx = 2;

    const deletedMode = ['none', 'only', 'all'].includes(deleted) ? deleted : 'none';
    if (deletedMode === 'none') {
      conditions.push('deleted_at IS NULL');
    } else if (deletedMode === 'only') {
      conditions.push('deleted_at IS NOT NULL');
    }

    const trimmedCategory = typeof category === 'string' ? category.trim() : '';
    if (trimmedCategory) {
      const validCat = normalizeCategory(trimmedCategory);
      params.push(validCat);
      conditions.push(`category = $${idx}`);
      idx++;
    }

    const trimmedStatus = typeof status === 'string' ? status.trim() : '';
    if (trimmedStatus) {
      const validStatus = normalizeStatus(trimmedStatus);
      params.push(validStatus);
      conditions.push(`status = $${idx}`);
      idx++;
    }

    const trimmedQ = typeof q === 'string' ? q.trim() : '';
    if (trimmedQ) {
      params.push(`%${escapeIlike(trimmedQ)}%`);
      conditions.push(`(name ILIKE $${idx} ESCAPE '\\' OR note ILIKE $${idx} ESCAPE '\\')`);
      idx++;
    }

    const whereClause = `WHERE ${conditions.join(' AND ')}`;
    const orderBy = deletedMode === 'only'
      ? 'ORDER BY deleted_at DESC, updated_at DESC, id ASC'
      : 'ORDER BY updated_at DESC, id ASC';

    const summary = await getSummary(unitId);

    if (limit !== undefined && limit !== null) {
      const safeLimit = Math.min(Math.max(1, Math.floor(Number(limit) || 50)), 200);
      const safeOffset = Math.max(0, Math.floor(Number(offset) || 0));
      const countRes = await store.query(
        `SELECT COUNT(*) AS total FROM water_sources ${whereClause}`,
        params,
      );
      const total = Number(countRes.rows[0]?.total || 0);
      const dataRes = await store.query(
        `SELECT * FROM water_sources ${whereClause} ${orderBy} LIMIT $${idx} OFFSET $${idx + 1}`,
        [...params, safeLimit, safeOffset],
      );
      return {
        items: dataRes.rows.map(mapRow),
        total,
        offset: safeOffset,
        limit: safeLimit,
        summary,
      };
    }

    const dataRes = await store.query(
      `SELECT * FROM water_sources ${whereClause} ${orderBy}`,
      params,
    );
    const items = dataRes.rows.map(mapRow);
    return {
      items,
      total: items.length,
      summary,
    };
  }

  async function getById(unitId, id) {
    const res = await store.query(
      'SELECT * FROM water_sources WHERE id = $1 AND unit_id = $2',
      [id, unitId],
    );
    return mapRow(res.rows[0]);
  }

  async function create(unitId, data = {}, { actorId = '', actorName = '' } = {}) {
    const category = normalizeCategory(data.category);
    const name = normalizeName(data.name);
    const { lat, lng } = normalizeCoordinates(data.lat, data.lng);
    const status = normalizeStatus(data.status, { defaultToAvailable: true });
    const intakeMethods = normalizeIntakeMethods(category, data.intake_methods);
    const note = normalizeNote(data.note);

    const activeCount = await countActive(unitId);
    if (activeCount >= maxActivePerUnit) {
      throw createError(
        'WATER_SOURCE_LIMIT_REACHED',
        409,
        `本单位活跃水源点位已达上限（${maxActivePerUnit} 条）`,
      );
    }

    const id = crypto.randomUUID();
    const nowMs = Number(now());
    const actor = String(actorId || '');
    const actorLabel = String(actorName || '');

    const res = await store.query(
      `INSERT INTO water_sources (
        id, unit_id, category, name, lat, lng, status, intake_methods, note,
        created_by, created_by_name, created_at,
        updated_by, updated_by_name, updated_at
      ) VALUES (
        $1, $2, $3, $4, $5, $6, $7, $8, $9,
        $10, $11, $12,
        $10, $11, $12
      ) RETURNING *`,
      [
        id,
        unitId,
        category,
        name,
        lat,
        lng,
        status,
        intakeMethods,
        note,
        actor,
        actorLabel,
        nowMs,
      ],
    );
    return mapRow(res.rows[0]);
  }

  async function update(unitId, id, data = {}, { actorId = '', actorName = '' } = {}) {
    const existingRes = await store.query(
      'SELECT * FROM water_sources WHERE id = $1 AND unit_id = $2 AND deleted_at IS NULL',
      [id, unitId],
    );
    const existing = existingRes.rows[0];
    if (!existing) {
      throw createError('WATER_SOURCE_NOT_FOUND', 404, '水源点位不存在或已删除');
    }

    const nextCategory = data.category !== undefined
      ? normalizeCategory(data.category)
      : existing.category;
    const nextName = data.name !== undefined
      ? normalizeName(data.name)
      : existing.name;
    const { lat: nextLat, lng: nextLng } = normalizeCoordinates(
      data.lat !== undefined ? data.lat : Number(existing.lat),
      data.lng !== undefined ? data.lng : Number(existing.lng),
    );
    const nextStatus = data.status !== undefined
      ? normalizeStatus(data.status)
      : existing.status;
    const nextNote = data.note !== undefined
      ? normalizeNote(data.note)
      : (existing.note ?? '');

    let nextIntakeMethods;
    if (nextCategory !== 'natural') {
      // 从 natural 变更为非 natural 时自动清空 intake_methods；若调用方显式传非空数组则拒绝
      nextIntakeMethods = data.intake_methods !== undefined
        ? normalizeIntakeMethods(nextCategory, data.intake_methods)
        : [];
    } else {
      const rawIntake = data.intake_methods !== undefined
        ? data.intake_methods
        : (Array.isArray(existing.intake_methods) ? existing.intake_methods : []);
      nextIntakeMethods = normalizeIntakeMethods('natural', rawIntake);
    }

    const nowMs = Number(now());
    const actor = String(actorId || '');
    const actorLabel = String(actorName || '');

    const res = await store.query(
      `UPDATE water_sources SET
        category = $3,
        name = $4,
        lat = $5,
        lng = $6,
        status = $7,
        intake_methods = $8,
        note = $9,
        updated_by = $10,
        updated_by_name = $11,
        updated_at = $12
      WHERE id = $1 AND unit_id = $2 AND deleted_at IS NULL
      RETURNING *`,
      [
        id,
        unitId,
        nextCategory,
        nextName,
        nextLat,
        nextLng,
        nextStatus,
        nextIntakeMethods,
        nextNote,
        actor,
        actorLabel,
        nowMs,
      ],
    );
    if (!res.rows.length) {
      throw createError('WATER_SOURCE_NOT_FOUND', 404, '水源点位不存在或已删除');
    }
    return mapRow(res.rows[0]);
  }

  async function softDelete(unitId, id, { actorId = '', actorName = '' } = {}) {
    const nowMs = Number(now());
    const actor = String(actorId || '');
    const actorLabel = String(actorName || '');

    const res = await store.query(
      `UPDATE water_sources SET
        deleted_at = $3,
        deleted_by = $4,
        deleted_by_name = $5,
        updated_by = $4,
        updated_by_name = $5,
        updated_at = $3
      WHERE id = $1 AND unit_id = $2 AND deleted_at IS NULL
      RETURNING id, deleted_at`,
      [id, unitId, nowMs, actor, actorLabel],
    );
    if (!res.rows.length) {
      throw createError('WATER_SOURCE_NOT_FOUND', 404, '水源点位不存在或已删除');
    }
    return {
      id: res.rows[0].id,
      deleted_at: Number(res.rows[0].deleted_at),
    };
  }

  async function restore(unitId, id, {
    actorId = '',
    actorName = '',
    enforceWindow = false,
    windowMs = APP_RESTORE_WINDOW_MS,
  } = {}) {
    const existingRes = await store.query(
      'SELECT * FROM water_sources WHERE id = $1 AND unit_id = $2',
      [id, unitId],
    );
    const existing = existingRes.rows[0];
    if (!existing) {
      throw createError('WATER_SOURCE_NOT_FOUND', 404, '水源点位不存在');
    }
    if (existing.deleted_at === null || existing.deleted_at === undefined) {
      return mapRow(existing);
    }

    const nowMs = Number(now());
    if (enforceWindow) {
      const deletedAt = Number(existing.deleted_at);
      if (existing.deleted_by !== String(actorId || '') || (nowMs - deletedAt) > windowMs) {
        throw createError(
          'RESTORE_WINDOW_EXPIRED',
          409,
          '超过 60 秒撤销时限或非原删除人，请联系管理员在后台回收站恢复',
        );
      }
    }

    const activeCount = await countActive(unitId);
    if (activeCount >= maxActivePerUnit) {
      throw createError(
        'WATER_SOURCE_LIMIT_REACHED',
        409,
        `本单位活跃水源点位已达上限（${maxActivePerUnit} 条）`,
      );
    }

    const actor = String(actorId || '');
    const actorLabel = String(actorName || '');
    const res = await store.query(
      `UPDATE water_sources SET
        deleted_at = NULL,
        deleted_by = NULL,
        deleted_by_name = NULL,
        updated_by = $3,
        updated_by_name = $4,
        updated_at = $5
      WHERE id = $1 AND unit_id = $2
      RETURNING *`,
      [id, unitId, actor, actorLabel, nowMs],
    );
    return mapRow(res.rows[0]);
  }

  async function upsertImportedBatch(unitId, records = [], {
    forceOverwrite = false,
    actorId = 'import_script',
    actorName = '导入脚本',
  } = {}) {
    if (typeof unitId !== 'string' || !unitId.trim()) {
      throw createError('UNIT_ID_REQUIRED', 400, '必须指定有效的 unitId');
    }
    if (!Array.isArray(records)) {
      throw createError('INVALID_RECORDS', 400, '导入记录必须为数组');
    }
    const normalizedUnitId = unitId.trim();
    const actor = String(actorId || 'import_script');
    const actorLabel = String(actorName || '导入脚本');

    const prepared = records.map((rec, index) => {
      const importKey = String(rec?.import_key ?? rec?.source_key ?? '').trim();
      if (!importKey) {
        throw createError('INVALID_IMPORT_KEY', 400, `第 ${index + 1} 条记录缺少 import_key`);
      }
      const category = normalizeCategory(rec.category);
      const name = normalizeName(rec.name);
      const { lat, lng } = normalizeCoordinates(rec.lat, rec.lng);
      const status = normalizeStatus(rec.status, { defaultToAvailable: true });
      const intakeMethods = normalizeIntakeMethods(category, rec.intake_methods);
      const note = normalizeNote(rec.note);
      return {
        importKey,
        category,
        name,
        lat,
        lng,
        status,
        intakeMethods,
        note,
      };
    });

    return store.transaction(async () => {
      let inserted = 0;
      let updated = 0;
      let skipped = 0;
      const baseActive = await countActive(normalizedUnitId);
      const nowMs = Number(now());

      for (const rec of prepared) {
        const id = crypto.randomUUID();
        if (!forceOverwrite) {
          const res = await store.query(
            `INSERT INTO water_sources (
              id, unit_id, category, name, lat, lng, status, intake_methods, note, import_key,
              created_by, created_by_name, created_at,
              updated_by, updated_by_name, updated_at
            ) VALUES (
              $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
              $11, $12, $13,
              $11, $12, $13
            )
            ON CONFLICT (unit_id, import_key) WHERE import_key IS NOT NULL DO NOTHING
            RETURNING id`,
            [
              id,
              normalizedUnitId,
              rec.category,
              rec.name,
              rec.lat,
              rec.lng,
              rec.status,
              rec.intakeMethods,
              rec.note,
              rec.importKey,
              actor,
              actorLabel,
              nowMs,
            ],
          );
          if (res.rows.length > 0) {
            inserted++;
            if (baseActive + inserted > maxActivePerUnit) {
              throw createError(
                'WATER_SOURCE_LIMIT_REACHED',
                409,
                `本单位活跃水源点位已达上限（${maxActivePerUnit} 条）`,
              );
            }
          } else {
            skipped++;
          }
        } else {
          const res = await store.query(
            `INSERT INTO water_sources (
              id, unit_id, category, name, lat, lng, status, intake_methods, note, import_key,
              created_by, created_by_name, created_at,
              updated_by, updated_by_name, updated_at
            ) VALUES (
              $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
              $11, $12, $13,
              $11, $12, $13
            )
            ON CONFLICT (unit_id, import_key) WHERE import_key IS NOT NULL DO UPDATE SET
              category = EXCLUDED.category,
              name = EXCLUDED.name,
              lat = EXCLUDED.lat,
              lng = EXCLUDED.lng,
              status = EXCLUDED.status,
              intake_methods = EXCLUDED.intake_methods,
              note = EXCLUDED.note,
              updated_by = EXCLUDED.updated_by,
              updated_by_name = EXCLUDED.updated_by_name,
              updated_at = EXCLUDED.updated_at
            WHERE water_sources.updated_by = 'import_script' AND water_sources.deleted_at IS NULL
            RETURNING (xmax = 0) AS was_inserted`,
            [
              id,
              normalizedUnitId,
              rec.category,
              rec.name,
              rec.lat,
              rec.lng,
              rec.status,
              rec.intakeMethods,
              rec.note,
              rec.importKey,
              actor,
              actorLabel,
              nowMs,
            ],
          );
          if (res.rows.length > 0) {
            if (res.rows[0].was_inserted) {
              inserted++;
              if (baseActive + inserted > maxActivePerUnit) {
                throw createError(
                  'WATER_SOURCE_LIMIT_REACHED',
                  409,
                  `本单位活跃水源点位已达上限（${maxActivePerUnit} 条）`,
                );
              }
            } else {
              updated++;
            }
          } else {
            skipped++;
          }
        }
      }

      return {
        total: prepared.length,
        inserted,
        updated,
        skipped,
      };
    });
  }

  return {
    listByUnit,
    getById,
    getSummary,
    create,
    update,
    softDelete,
    restore,
    upsertImportedBatch,
  };
}

module.exports = {
  createWaterSources,
  mapRow,
  normalizeCategory,
  normalizeStatus,
  normalizeName,
  normalizeCoordinates,
  normalizeNote,
  normalizeIntakeMethods,
  VALID_CATEGORIES,
  VALID_STATUSES,
  VALID_INTAKE_METHODS,
  MAX_ACTIVE_PER_UNIT,
  APP_RESTORE_WINDOW_MS,
};
