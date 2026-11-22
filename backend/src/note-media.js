'use strict';

const fs = require('node:fs/promises');
const fsSync = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const multer = require('multer');
const sharp = require('sharp');

const MAX_PHOTO_BYTES = 15 * 1024 * 1024;
const MAX_VIDEO_BYTES = 60 * 1024 * 1024;
const MAX_THUMB_BYTES = 2 * 1024 * 1024;
const MAX_PHOTO_PIXELS = 100 * 1024 * 1024;
const DEFAULT_RETENTION_DAYS = Number(process.env.NOTE_MEDIA_RETENTION_DAYS || 90);
const DEFAULT_MAX_TOTAL_BYTES = Number(
  process.env.NOTE_MEDIA_MAX_TOTAL_BYTES || 5 * 1024 * 1024 * 1024,
);
const TMP_ORPHAN_AGE_MS = 3600 * 1000;
const ID_RE = /^[a-zA-Z0-9_-]{1,128}$/;

function resolveNoteMediaRoot(rootDir) {
  if (rootDir) return path.resolve(rootDir);
  if (process.env.NOTE_MEDIA_DIR) return path.resolve(process.env.NOTE_MEDIA_DIR);
  const dataDir = process.env.WATCHDOG_DATA_DIR || path.join(__dirname, '..', 'data');
  return path.resolve(dataDir, 'note-media');
}

function noteMediaError(message, code = 'NOTE_MEDIA_INVALID', status = 400) {
  const err = new Error(message);
  err.code = code;
  err.status = status;
  return err;
}

function isValidId(id) {
  return typeof id === 'string' && ID_RE.test(id);
}

function publicNoteMedia(row) {
  if (!row) return null;
  const available = row.purged_at == null && Boolean(row.file_path);
  return {
    id: row.id,
    kind: row.kind,
    mime: row.mime,
    size_bytes: Number(row.size_bytes) || 0,
    duration_ms: Number(row.duration_ms) || 0,
    width: Number(row.width) || 0,
    height: Number(row.height) || 0,
    captured_at: Number(row.captured_at) || 0,
    address: row.address || '',
    weather: row.weather || '',
    available,
    purged_at: row.purged_at != null ? Number(row.purged_at) : null,
    file_url: `/api/note-media/${row.id}/file`,
    thumb_url: row.thumb_path
      ? `/api/note-media/${row.id}/thumb`
      : (row.kind === 'photo' ? `/api/note-media/${row.id}/file` : ''),
  };
}

function inferNoteCategory(text) {
  const t = String(text || '').trim();
  if (/爆炸|爆燃|闪燃|轰燃|回燃|复燃|阴燃|倒塌|坍塌|泄漏|中毒|窒息|触电|受伤|伤亡|坠落|失控|蔓延|飞火|流淌火|险情|异常|爆裂|带电/.test(t)) {
    return '异常';
  }
  if (/撤离|撤出|撤退|收队|归队|收工|回撤|收操|撤收|清理|残火|监护|留守|移交|交接|结束|收尾|战评|总结/.test(t)) {
    return '撤离';
  }
  if (/出水|供水|送水|中继|水带|水枪|水炮|泡沫|干粉|灭火|扑灭|扑救|冷却|降温|堵截|夹攻|强攻|总攻|合围|突破|掩护|控制火势|压制|水幕|火势控制/.test(t)) {
    return '出水';
  }
  if (/搜救|搜寻|搜索|侦查|侦察|侦检|探测|被困|遇险|失联|救人|疏散|转移|救出|抬出|登高|破拆|排烟|通风|内攻|开辟通道|查找火源/.test(t)) {
    return '搜救';
  }
  if (/出动|接警|调派|调度|增援|到场|到达|进入|集结|部署|展开|阵地|警戒|封锁|隔离|指挥部|集结点|战备|待命|保障|协同|力量|指挥/.test(t)) {
    return '部署';
  }
  return '其他';
}

function buildDefaultMediaNoteText({ kind, durationMs = 0, address = '' } = {}) {
  const cleanAddr = String(address || '').trim();
  if (kind === 'photo') {
    return cleanAddr ? `现场拍照 · ${cleanAddr}` : '现场拍照';
  }
  const sec = Math.max(0, Math.round((Number(durationMs) || 0) / 1000));
  const base = sec > 0 ? `现场拍摄视频（${sec}s）` : '现场拍摄视频';
  return cleanAddr ? `${base} · ${cleanAddr}` : base;
}

async function detectVideoFormat(filePath) {
  const fh = await fs.open(filePath, 'r');
  try {
    const header = Buffer.alloc(16);
    const { bytesRead } = await fh.read(header, 0, 16, 0);
    if (bytesRead >= 8 && header.subarray(4, 8).toString('ascii') === 'ftyp') {
      return { ext: '.mp4', mime: 'video/mp4' };
    }
    if (bytesRead >= 4 && header[0] === 0x1a && header[1] === 0x45 && header[2] === 0xdf && header[3] === 0xa3) {
      return { ext: '.webm', mime: 'video/webm' };
    }
    throw noteMediaError('仅支持 MP4 或 WebM 格式视频', 'NOTE_MEDIA_TYPE_INVALID', 415);
  } finally {
    await fh.close();
  }
}

async function moveFile(srcPath, destPath) {
  try {
    await fs.rename(srcPath, destPath);
  } catch (error) {
    if (error?.code !== 'EXDEV') throw error;
    await fs.copyFile(srcPath, destPath);
    await fs.unlink(srcPath).catch(() => {});
  }
}

function safeSubPath(rootDir, relPath) {
  if (!relPath || typeof relPath !== 'string') return null;
  const resolvedRoot = path.resolve(rootDir);
  const abs = path.resolve(resolvedRoot, relPath);
  if (abs === resolvedRoot || !abs.startsWith(resolvedRoot + path.sep)) return null;
  return abs;
}

async function removePathsQuietly(paths) {
  for (const p of paths) {
    if (!p) continue;
    await fs.rm(p, { force: true }).catch(() => {});
  }
}

async function deleteNoteMediaFiles(mediaRows, { rootDir } = {}) {
  const resolvedRoot = resolveNoteMediaRoot(rootDir);
  for (const row of mediaRows || []) {
    if (!row || !isValidId(row.id)) continue;
    const dir = safeSubPath(resolvedRoot, row.id);
    if (!dir) continue;
    await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
  }
}

async function processUploadedNoteMedia({
  id,
  kind,
  tempPath,
  thumbTempPath = null,
  rootDir,
  reportedWidth = 0,
  reportedHeight = 0,
}) {
  if (!isValidId(id)) throw noteMediaError('媒体编号无效', 'NOTE_MEDIA_INVALID', 400);
  if (!['photo', 'video'].includes(kind)) {
    throw noteMediaError('媒体类型仅支持 photo 或 video', 'NOTE_MEDIA_TYPE_INVALID', 400);
  }
  const resolvedRoot = resolveNoteMediaRoot(rootDir);
  const stat = await fs.stat(tempPath).catch(() => null);
  if (!stat || stat.size <= 0) {
    throw noteMediaError('上传文件为空', 'NOTE_MEDIA_EMPTY', 400);
  }

  const targetDir = safeSubPath(resolvedRoot, id);
  if (!targetDir) throw noteMediaError('媒体存储路径无效', 'NOTE_MEDIA_INVALID', 400);
  await fs.mkdir(targetDir, { recursive: true });

  try {
    if (kind === 'photo') {
      if (stat.size > MAX_PHOTO_BYTES) {
        throw noteMediaError('照片不能超过 15 MB', 'NOTE_MEDIA_TOO_LARGE', 413);
      }
      let meta;
      try {
        meta = await sharp(tempPath, { limitInputPixels: MAX_PHOTO_PIXELS }).metadata();
      } catch (_) {
        throw noteMediaError('图片文件无效或分辨率过大', 'NOTE_MEDIA_TYPE_INVALID', 415);
      }
      if (!['jpeg', 'png', 'webp'].includes(meta.format)) {
        throw noteMediaError('照片仅支持 JPG/PNG/WebP 格式', 'NOTE_MEDIA_TYPE_INVALID', 415);
      }
      const mediaAbs = path.join(targetDir, 'media.jpg');
      const thumbAbs = path.join(targetDir, 'thumb.jpg');
      const mainInfo = await sharp(tempPath, { limitInputPixels: MAX_PHOTO_PIXELS })
        .rotate()
        .resize({ width: 1920, height: 1920, fit: 'inside', withoutEnlargement: true })
        .jpeg({ quality: 84, mozjpeg: true })
        .toFile(mediaAbs);
      await sharp(mediaAbs, { limitInputPixels: MAX_PHOTO_PIXELS })
        .resize({ width: 480, height: 480, fit: 'inside', withoutEnlargement: true })
        .jpeg({ quality: 75, mozjpeg: true })
        .toFile(thumbAbs);
      const thumbStat = await fs.stat(thumbAbs);
      return {
        mime: 'image/jpeg',
        filePath: `${id}/media.jpg`,
        thumbPath: `${id}/thumb.jpg`,
        sizeBytes: mainInfo.size + thumbStat.size,
        width: mainInfo.width || 0,
        height: mainInfo.height || 0,
      };
    }

    // 视频处理：按魔数校验 MP4/WebM，不读入整包到内存，直接原子移入私有卷目录
    if (stat.size > MAX_VIDEO_BYTES) {
      throw noteMediaError('视频不能超过 60 MB', 'NOTE_MEDIA_TOO_LARGE', 413);
    }
    const { ext, mime } = await detectVideoFormat(tempPath);
    const fileName = `media${ext}`;
    const mediaAbs = path.join(targetDir, fileName);
    await moveFile(tempPath, mediaAbs);

    let thumbRel = '';
    let thumbBytes = 0;
    let width = Math.max(0, Math.floor(Number(reportedWidth) || 0));
    let height = Math.max(0, Math.floor(Number(reportedHeight) || 0));

    if (thumbTempPath) {
      const thumbStat = await fs.stat(thumbTempPath).catch(() => null);
      if (thumbStat && thumbStat.size > 0) {
        if (thumbStat.size > MAX_THUMB_BYTES) {
          throw noteMediaError('视频封面不能超过 2 MB', 'NOTE_MEDIA_TOO_LARGE', 413);
        }
        try {
          const thumbAbs = path.join(targetDir, 'thumb.jpg');
          const thumbInfo = await sharp(thumbTempPath, { limitInputPixels: MAX_PHOTO_PIXELS })
            .rotate()
            .resize({ width: 480, height: 480, fit: 'inside', withoutEnlargement: true })
            .jpeg({ quality: 75, mozjpeg: true })
            .toFile(thumbAbs);
          thumbRel = `${id}/thumb.jpg`;
          thumbBytes = thumbInfo.size;
          if (!width) width = thumbInfo.width || 0;
          if (!height) height = thumbInfo.height || 0;
        } catch (err) {
          if (err.code?.startsWith('NOTE_MEDIA_')) throw err;
          throw noteMediaError('视频封面图片无效', 'NOTE_MEDIA_TYPE_INVALID', 415);
        }
      }
    }

    return {
      mime,
      filePath: `${id}/${fileName}`,
      thumbPath: thumbRel,
      sizeBytes: stat.size + thumbBytes,
      width,
      height,
    };
  } catch (error) {
    await fs.rm(targetDir, { recursive: true, force: true }).catch(() => {});
    throw error;
  }
}

async function purgeArchivedNoteMedia(
  store,
  {
    rootDir,
    retentionDays = DEFAULT_RETENTION_DAYS,
    maxTotalBytes = DEFAULT_MAX_TOTAL_BYTES,
    now = Date.now(),
  } = {},
) {
  if (!store || typeof store.query !== 'function') {
    return { expiredCount: 0, quotaCount: 0, orphanCount: 0, freedBytes: 0 };
  }
  const resolvedRoot = resolveNoteMediaRoot(rootDir);
  let expiredCount = 0;
  let quotaCount = 0;
  let orphanCount = 0;
  let freedBytes = 0;

  // 第一阶段：清理已归档警情且超过保留期限的媒体文件（处置中警情绝不清理）
  const cutoff = now - Math.max(1, Number(retentionDays) || 90) * 24 * 3600 * 1000;
  const expiredRes = await store.query(
    `SELECT m.id, m.size_bytes
       FROM note_media m
       JOIN incidents i ON i.id = m.incident_id
      WHERE m.purged_at IS NULL
        AND i.status <> 'active'
        AND m.created_at < $1
      ORDER BY m.created_at ASC`,
    [cutoff],
  );
  if (expiredRes.rows.length > 0) {
    await deleteNoteMediaFiles(expiredRes.rows, { rootDir: resolvedRoot });
    const ids = expiredRes.rows.map((r) => r.id);
    await store.query(
      `UPDATE note_media
          SET purged_at = $1, file_path = '', thumb_path = ''
        WHERE id = ANY($2::text[]) AND purged_at IS NULL`,
      [now, ids],
    );
    expiredCount = expiredRes.rows.length;
    freedBytes += expiredRes.rows.reduce((sum, r) => sum + (Number(r.size_bytes) || 0), 0);
  }

  // 第二阶段：若总占用仍超出空间上限，仅按时间顺序淘汰最老的已归档警情媒体
  const capBytes = Math.max(0, Number(maxTotalBytes) || 0);
  if (capBytes > 0) {
    const sumRes = await store.query(
      'SELECT COALESCE(SUM(size_bytes), 0)::bigint AS total FROM note_media WHERE purged_at IS NULL',
    );
    let totalBytes = Number(sumRes.rows[0]?.total || 0);
    while (totalBytes > capBytes) {
      const oldestRes = await store.query(
        `SELECT m.id, m.size_bytes
           FROM note_media m
           JOIN incidents i ON i.id = m.incident_id
          WHERE m.purged_at IS NULL
            AND i.status <> 'active'
          ORDER BY m.created_at ASC
          LIMIT 50`,
      );
      if (oldestRes.rows.length === 0) break;
      const victimIds = [];
      for (const row of oldestRes.rows) {
        if (totalBytes <= capBytes) break;
        victimIds.push(row.id);
        const bytes = Number(row.size_bytes) || 0;
        totalBytes = Math.max(0, totalBytes - bytes);
        freedBytes += bytes;
        quotaCount++;
      }
      if (victimIds.length === 0) break;
      await deleteNoteMediaFiles(
        victimIds.map((id) => ({ id })),
        { rootDir: resolvedRoot },
      );
      await store.query(
        `UPDATE note_media
            SET purged_at = $1, file_path = '', thumb_path = ''
          WHERE id = ANY($2::text[]) AND purged_at IS NULL`,
        [now, victimIds],
      );
    }
  }

  // 第三阶段：清理未登记在库中的孤儿目录以及超时残留 .tmp 文件
  const entries = await fs.readdir(resolvedRoot, { withFileTypes: true }).catch(() => []);
  if (entries.length > 0) {
    const activeRes = await store.query('SELECT id FROM note_media WHERE purged_at IS NULL');
    const activeIds = new Set(activeRes.rows.map((r) => r.id));
    for (const entry of entries) {
      if (entry.name === '.tmp') {
        const tmpDir = path.join(resolvedRoot, '.tmp');
        const tmpFiles = await fs.readdir(tmpDir, { withFileTypes: true }).catch(() => []);
        for (const f of tmpFiles) {
          if (!f.isFile()) continue;
          const abs = path.join(tmpDir, f.name);
          const st = await fs.stat(abs).catch(() => null);
          if (st && now - st.mtimeMs > TMP_ORPHAN_AGE_MS) {
            await fs.rm(abs, { force: true }).catch(() => {});
          }
        }
        continue;
      }
      if (entry.isDirectory() && isValidId(entry.name) && !activeIds.has(entry.name)) {
        const orphanDir = safeSubPath(resolvedRoot, entry.name);
        if (orphanDir) {
          await fs.rm(orphanDir, { recursive: true, force: true }).catch(() => {});
          orphanCount++;
        }
      }
    }
  }

  return { expiredCount, quotaCount, orphanCount, freedBytes };
}

function parseByteRange(rangeHeader, totalSize) {
  if (!rangeHeader || typeof rangeHeader !== 'string') return null;
  const match = /^bytes=(\d*)-(\d*)$/.exec(rangeHeader.trim());
  if (!match) return { invalid: true };
  const [, startStr, endStr] = match;
  if (startStr === '' && endStr === '') return { invalid: true };
  let start;
  let end;
  if (startStr === '') {
    const suffix = Number(endStr);
    if (!Number.isFinite(suffix) || suffix <= 0) return { invalid: true };
    start = Math.max(0, totalSize - suffix);
    end = totalSize - 1;
  } else {
    start = Number(startStr);
    end = endStr === '' ? totalSize - 1 : Math.min(Number(endStr), totalSize - 1);
  }
  if (!Number.isFinite(start) || !Number.isFinite(end) || start < 0 || start >= totalSize || end < start) {
    return { invalid: true };
  }
  return { start, end };
}

function streamMediaFile(req, res, absPath, mimeType) {
  fs.stat(absPath)
    .then((stat) => {
      if (!stat.isFile()) {
        if (!res.headersSent) {
          res.status(410).json({ error: '附件媒体已被清理', code: 'NOTE_MEDIA_PURGED' });
        }
        return;
      }
      const total = stat.size;
      res.setHeader('Accept-Ranges', 'bytes');
      res.setHeader('Cache-Control', 'private, max-age=86400');
      res.setHeader('Content-Type', mimeType);

      const range = parseByteRange(req.headers.range, total);
      if (range?.invalid) {
        res.status(416).setHeader('Content-Range', `bytes */${total}`).end();
        return;
      }

      const streamOpts = range ? { start: range.start, end: range.end } : {};
      if (range) {
        res.status(206);
        res.setHeader('Content-Range', `bytes ${range.start}-${range.end}/${total}`);
        res.setHeader('Content-Length', range.end - range.start + 1);
      } else {
        res.status(200);
        res.setHeader('Content-Length', total);
      }

      const stream = fsSync.createReadStream(absPath, streamOpts);
      req.on('close', () => {
        if (!stream.destroyed) stream.destroy();
      });
      stream.on('error', () => {
        if (!res.headersSent) {
          res.status(500).json({ error: '读取媒体文件失败', code: 'NOTE_MEDIA_READ_ERROR' });
        } else {
          res.destroy();
        }
      });
      stream.pipe(res);
    })
    .catch((err) => {
      if (res.headersSent) return;
      if (err?.code === 'ENOENT') {
        return res.status(410).json({ error: '附件媒体已被清理', code: 'NOTE_MEDIA_PURGED' });
      }
      return res.status(500).json({ error: '读取媒体文件失败', code: 'NOTE_MEDIA_READ_ERROR' });
    });
}

function registerNoteMediaRoutes(app, deps) {
  const {
    db,
    store,
    rootDir,
    requireIncident,
    ensureOperationScope,
    beginTrackedOperation,
    completeTrackedOperation,
    releaseTrackedOperation,
    cleanCategory,
    actorName,
    deviceKey,
    opKey,
    appendEvent,
    logOp,
    withWriteMetadata,
    logger,
    syncSupported,
    unitAuthRequired = true,
  } = deps;

  const resolvedRoot = resolveNoteMediaRoot(rootDir);
  const tmpDir = path.join(resolvedRoot, '.tmp');
  const upload = multer({
    storage: multer.diskStorage({
      destination: (_req, _file, cb) => {
        fs.mkdir(tmpDir, { recursive: true })
          .then(() => cb(null, tmpDir))
          .catch((err) => cb(err));
      },
      filename: (_req, _file, cb) => {
        cb(null, `${crypto.randomUUID()}.upload`);
      },
    }),
    limits: {
      files: 2,
      fileSize: MAX_VIDEO_BYTES,
      fields: 12,
      fieldSize: 32 * 1024,
    },
  }).fields([
    { name: 'file', maxCount: 1 },
    { name: 'thumb', maxCount: 1 },
  ]);

  const uploadMiddleware = (req, res, next) => {
    const ct = String(req.headers['content-type'] || '').toLowerCase();
    if (!ct.includes('multipart/form-data')) {
      return res.status(400).json({ error: '请使用 multipart/form-data 上传媒体', code: 'NOTE_MEDIA_UPLOAD_INVALID' });
    }
    upload(req, res, async (err) => {
      if (err) {
        const tempPaths = [req.files?.file?.[0]?.path, req.files?.thumb?.[0]?.path].filter(Boolean);
        await removePathsQuietly(tempPaths);
        const status = err.code === 'LIMIT_FILE_SIZE' ? 413 : 400;
        return res.status(status).json({
          error: err.code === 'LIMIT_FILE_SIZE' ? '上传文件超过 60 MB 大小上限' : '媒体上传格式或字段无效',
          code: err.code === 'LIMIT_FILE_SIZE' ? 'NOTE_MEDIA_TOO_LARGE' : 'NOTE_MEDIA_UPLOAD_INVALID',
        });
      }
      next();
    });
  };

  app.post(
    '/api/notes/media',
    async (req, res, next) => {
      try {
        const incident = await requireIncident(req, res, { active: true });
        if (!incident) return;
        if (!await ensureOperationScope(req, res, incident.id)) return;
        req.noteMediaIncident = incident;
        next();
      } catch (error) {
        next(error);
      }
    },
    uploadMiddleware,
    async (req, res, next) => {
      const incident = req.noteMediaIncident;
      const uploadedFile = req.files?.file?.[0] || null;
      const uploadedThumb = req.files?.thumb?.[0] || null;
      const tempPaths = [uploadedFile?.path, uploadedThumb?.path].filter(Boolean);
      let tracked = null;
      let storedMediaId = null;

      try {
        if (!uploadedFile) {
          return res.status(400).json({ error: '缺少上传文件', code: 'NOTE_MEDIA_FILE_REQUIRED' });
        }
        const kind = String(req.body?.kind || '').trim();
        if (!['photo', 'video'].includes(kind)) {
          return res.status(400).json({ error: '媒体类型仅支持 photo 或 video', code: 'NOTE_MEDIA_TYPE_INVALID' });
        }

        const rawText = String(req.body?.text || '').trim();
        if (rawText.length > 2000) {
          return res.status(400).json({ error: '日志内容过长（最多 2000 字）', code: 'TEXT_TOO_LONG' });
        }
        const durationMs = Math.max(0, Math.min(3600 * 1000, Math.floor(Number(req.body?.duration_ms) || 0)));
        const rawCapturedAt = Number(req.body?.captured_at) || Date.now();
        if (rawCapturedAt > Date.now() + 60 * 1000) {
          return res.status(400).json({ error: '拍摄时间不能晚于当前时间', code: 'CAPTURED_AT_INVALID' });
        }
        const address = String(req.body?.address || '').trim().slice(0, 240);
        const weather = String(req.body?.weather || '').trim().slice(0, 120);
        const mediaRef = String(req.body?.media_ref || '').trim().slice(0, 200);
        const syncObservation = String(req.body?.sync_observation || '') === '1';

        const noteText = rawText || buildDefaultMediaNoteText({ kind, durationMs, address });
        const explicitCategory = String(req.body?.category || '').trim();
        const noteCategory = explicitCategory
          ? cleanCategory(explicitCategory)
          : inferNoteCategory(noteText);

        const hashPayload = {
          kind,
          media_ref: mediaRef,
          text: noteText,
          category: noteCategory,
          duration_ms: durationMs,
          captured_at: rawCapturedAt,
          address,
        };

        const operationLedgerEnabled = String(process.env.WATCHDOG_OPERATION_LEDGER_ENABLED ?? '1') !== '0';
        let previous = null;
        if (!operationLedgerEnabled && opKey(req)) {
          previous = await db.getIncidentEventByClientOp(opKey(req));
        }
        if (previous?.incident_id === incident.id) {
          if (previous.type !== 'note') {
            return res.status(409).json({ error: '操作 ID 已用于其他操作，请重新提交', code: 'CLIENT_OP_ID_CONFLICT' });
          }
          const existingNote = await db.getNote(previous.payload?.note_id);
          if (existingNote) return res.json(existingNote);
        }

        tracked = await beginTrackedOperation(req, incident.id, 'note', hashPayload);
        if (tracked?.conflict) {
          return res.status(409).json({ error: '同一操作 ID 的请求内容不一致，请重新提交', code: tracked.code });
        }
        if (tracked?.pending) {
          return res.status(409).json({ error: '该操作正在处理中，请稍后查询结果', code: 'OPERATION_IN_PROGRESS' });
        }
        if (tracked?.replay) {
          return res.status(tracked.replay.status === 201 ? 200 : tracked.replay.status).json(tracked.replay.result);
        }

        if (operationLedgerEnabled && opKey(req)) {
          previous = await db.getIncidentEventByClientOp(opKey(req));
          if (previous?.incident_id === incident.id) {
            if (previous.type !== 'note') {
              await releaseTrackedOperation(tracked);
              return res.status(409).json({ error: '操作 ID 已用于其他操作，请重新提交', code: 'CLIENT_OP_ID_CONFLICT' });
            }
            const existingNote = await db.getNote(previous.payload?.note_id);
            if (existingNote) {
              await completeTrackedOperation(tracked, existingNote, 200, previous.id);
              return res.json(existingNote);
            }
            await releaseTrackedOperation(tracked);
            return res.status(409).json({ error: '操作记录已存在但业务数据缺失，请联系管理员核查', code: 'CLIENT_OP_ID_INCOMPLETE' });
          }
        }

        const author = (await actorName(req)) || '';
        const unitId = req.unit?.id || incident.unit_id;
        const noteId = crypto.randomUUID();
        const mediaId = crypto.randomUUID();
        storedMediaId = mediaId;

        const processed = await processUploadedNoteMedia({
          id: mediaId,
          kind,
          tempPath: uploadedFile.path,
          thumbTempPath: uploadedThumb?.path || null,
          rootDir: resolvedRoot,
          reportedWidth: Number(req.body?.width) || 0,
          reportedHeight: Number(req.body?.height) || 0,
        });

        const createdAt = Date.now();
        const noteArgs = {
          id: noteId,
          scene: incident.id,
          text: noteText,
          category: noteCategory,
          author,
          createdAt,
        };
        const mediaArgs = {
          id: mediaId,
          note_id: noteId,
          incident_id: incident.id,
          unit_id: unitId,
          kind,
          mime: processed.mime,
          file_path: processed.filePath,
          thumb_path: processed.thumbPath,
          size_bytes: processed.sizeBytes,
          duration_ms: durationMs,
          width: processed.width,
          height: processed.height,
          captured_at: rawCapturedAt,
          address,
          weather,
          created_by: deviceKey(req) || '',
          created_at: createdAt,
          purged_at: null,
        };
        const eventArgs = {
          incidentId: incident.id,
          type: 'note',
          occurredAt: createdAt,
          actorDeviceId: deviceKey(req),
          actorName: author || null,
          source: 'online',
          clientOpId: opKey(req),
          payload: {
            note_id: noteId,
            media_id: mediaId,
            text: noteText,
            category: noteCategory,
            author,
          },
        };

        const atomic = await db.createNoteWithMediaAndEvent({
          note: noteArgs,
          media: mediaArgs,
          event: eventArgs,
          activityAt: createdAt,
        });
        storedMediaId = null;

        // 视频中存在语音转文字且此前未手动写入警情口述时，顺便同步至 incident_observations 供 AI 辅助检索
        if (syncObservation && rawText && typeof db.createIncidentObservation === 'function') {
          try {
            const exists = mediaRef && typeof db.hasIncidentObservationByMediaRef === 'function'
              ? await db.hasIncidentObservationByMediaRef(incident.id, mediaRef)
              : false;
            if (!exists) {
              await db.createIncidentObservation({
                id: crypto.randomUUID(),
                incidentId: incident.id,
                unitId,
                sourceType: kind,
                capturedAt: rawCapturedAt,
                transcript: rawText,
                structured: {},
                status: 'confirmed',
                mediaRef,
                createdBy: deviceKey(req) || '',
                createdAt: Date.now(),
              });
              if (syncSupported?.() && unitId) {
                const repo = require('./incident-import-repository');
                if (typeof repo.appendObservationToDetails === 'function') {
                  await repo.appendObservationToDetails({
                    unitId,
                    incidentId: incident.id,
                    actorId: req.auth?.memberId || deviceKey(req) || '',
                    transcript: rawText,
                    capturedAt: rawCapturedAt,
                  });
                }
              }
            }
          } catch (obsErr) {
            logger?.warn?.(`note media observation sync error: ${obsErr.message}`);
          }
        }

        await logOp(req, 'info', 'note_media_created', '已上传水印相机日志', {
          noteId,
          mediaId,
          kind,
          sizeBytes: processed.sizeBytes,
          author: author || '(匿名)',
        });
        await completeTrackedOperation(tracked, atomic.note, 201, atomic.event?.id);
        return res.status(201).json(withWriteMetadata(atomic.note, atomic.event));
      } catch (error) {
        if (storedMediaId) {
          await deleteNoteMediaFiles([{ id: storedMediaId }], { rootDir: resolvedRoot });
        }
        await releaseTrackedOperation(tracked).catch(() => {});
        if (error.code?.startsWith('NOTE_MEDIA_') && !res.headersSent) {
          return res.status(error.status || 400).json({ error: error.message, code: error.code });
        }
        return next(error);
      } finally {
        await removePathsQuietly(tempPaths);
      }
    },
  );

  async function handleReadMedia(req, res, { thumb = false } = {}) {
    try {
      const id = String(req.params.id || '').trim();
      if (!isValidId(id)) {
        return res.status(404).json({ error: '媒体附件不存在', code: 'NOTE_MEDIA_NOT_FOUND' });
      }
      if (unitAuthRequired && !req.unit?.id) {
        return res.status(401).json({ error: '请先完成单位认证', code: 'UNIT_AUTH_REQUIRED' });
      }
      const row = await db.getNoteMedia(id);
      if (!row) {
        return res.status(404).json({ error: '媒体附件不存在', code: 'NOTE_MEDIA_NOT_FOUND' });
      }
      if (req.unit?.id && row.unit_id !== req.unit.id) {
        return res.status(404).json({ error: '媒体附件不存在', code: 'NOTE_MEDIA_NOT_FOUND' });
      }
      if (row.purged_at != null) {
        return res.status(410).json({ error: '附件媒体已超过保留期并清理', code: 'NOTE_MEDIA_PURGED' });
      }
      const rel = thumb ? (row.thumb_path || (row.kind === 'photo' ? row.file_path : '')) : row.file_path;
      const absPath = safeSubPath(resolvedRoot, rel);
      if (!absPath) {
        return res.status(404).json({ error: '媒体缩略图不存在', code: 'NOTE_MEDIA_NOT_FOUND' });
      }
      const mime = thumb ? 'image/jpeg' : (row.mime || 'application/octet-stream');
      return streamMediaFile(req, res, absPath, mime);
    } catch (error) {
      logger?.warn?.(`read note media error: ${error.message}`);
      if (!res.headersSent) {
        return res.status(500).json({ error: '读取媒体文件失败', code: 'NOTE_MEDIA_READ_ERROR' });
      }
    }
  }

  app.get('/api/note-media/:id/file', (req, res) => handleReadMedia(req, res, { thumb: false }));
  app.get('/api/note-media/:id/thumb', (req, res) => handleReadMedia(req, res, { thumb: true }));

  return {
    rootDir: resolvedRoot,
    purgeArchived: (options) => purgeArchivedNoteMedia(store, { rootDir: resolvedRoot, ...options }),
    deleteNoteMediaFiles: (rows) => deleteNoteMediaFiles(rows, { rootDir: resolvedRoot }),
  };
}

module.exports = {
  MAX_PHOTO_BYTES,
  MAX_VIDEO_BYTES,
  MAX_THUMB_BYTES,
  DEFAULT_RETENTION_DAYS,
  DEFAULT_MAX_TOTAL_BYTES,
  resolveNoteMediaRoot,
  publicNoteMedia,
  inferNoteCategory,
  buildDefaultMediaNoteText,
  detectVideoFormat,
  processUploadedNoteMedia,
  deleteNoteMediaFiles,
  purgeArchivedNoteMedia,
  parseByteRange,
  registerNoteMediaRoutes,
};
