const express = require('express');
const multer = require('multer');
const wrap = handler => (req, res, next) => Promise.resolve(handler(req, res)).catch(err => {
  if (err.status) return res.status(err.status).json({ code: err.code, error: err.message });
  next(err);
});

function createKeySiteAdminRouter(sites, files, ai) {
  const router = express.Router();
  const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: files.limits.fileBytes, files: 1, fields: 2, parts: 3 } }).single('file');
  let uploading = 0;
  router.use((req, res, next) => { res.set('Cache-Control', 'private, no-store'); next(); });
  router.get('/limits', (req, res) => res.json({ limits: files.limits, aiAvailable: ai?.available() || false }));
  if (ai) {
    router.get('/tasks/:taskId', wrap(async (req, res) => res.json(await ai.read(req.admin.id, req.params.taskId))));
    router.post('/:id/attachments/:attachmentId/ai', wrap(async (req, res) => res.status(201).json(await ai.create(req.admin.id, req.params.id, req.params.attachmentId, req.body.pages))));
    router.post('/tasks/:taskId/ai-retry', wrap(async (req, res) => res.json(await ai.retry(req.admin.id, req.params.taskId, req.body.pages))));
    router.post('/tasks/:taskId/ai-cancel', wrap(async (req, res) => res.json(await ai.cancel(req.admin.id, req.params.taskId))));
    router.post('/tasks/:taskId/ai-apply', wrap(async (req, res) => res.json(await ai.apply(req.admin.id, req.params.taskId, req.body))));
  }
  router.get('/duplicates', wrap(async (req, res) => res.json({ sites: await sites.duplicates(req.admin.id, req.query) })));
  router.get('/', wrap(async (req, res) => res.json(await sites.list(req.admin.id, req.query, true))));
  router.post('/', wrap(async (req, res) => res.status(201).json(await sites.create(req.admin.id, req.body))));
  router.get('/:id', wrap(async (req, res) => res.json(await sites.draft(req.admin.id, req.params.id))));
  router.put('/:id', wrap(async (req, res) => res.json(await sites.update(req.admin.id, req.params.id, req.body))));
  router.put('/:id/draft', wrap(async (req, res) => res.json(await sites.saveDraft(req.admin.id, req.params.id, req.body))));
  router.post('/:id/draft/discard', wrap(async (req, res) => res.json(await sites.discardDraft(req.admin.id, req.params.id, req.body.revision))));
  router.post('/:id/publish', wrap(async (req, res) => res.json(await sites.publish(req.admin.id, req.params.id, req.body))));
  router.get('/:id/history', wrap(async (req, res) => res.json({ versions: await sites.history(req.admin.id, req.params.id) })));
  router.get('/:id/history/:version', wrap(async (req, res) => res.json(await sites.versionForAdmin(req.admin.id, req.params.id, req.params.version))));
  router.post('/:id/attachments/:module', (req, res, next) => {
    if (uploading >= files.limits.concurrency) return res.status(429).json({ code: 'KEY_SITE_BUSY', error: '正在接收其他文件，请稍后重试' });
    sites.maintain(req.admin.id, req.params.id).then(() => {
      if (uploading >= files.limits.concurrency) return res.status(429).json({ code: 'KEY_SITE_BUSY', error: '正在接收其他文件，请稍后重试' });
      uploading++;
      let released = false;
      const release = () => { if (!released) { released = true; uploading--; } };
      req.once('aborted', release); res.once('finish', release); res.once('close', release);
      upload(req, res, err => {
        if (err) return res.status(413).json({ code: 'KEY_SITE_UPLOAD_LIMIT', error: '文件数量、大小或字段超过上传限制' });
        next();
      });
    }).catch(err => err.status ? res.status(err.status).json({ code: err.code, error: err.message }) : next(err));
  }, wrap(async (req, res) => res.status(201).json(await files.upload(req.admin.id, req.params.id, req.params.module, req.file))));
  router.post('/tasks/:taskId/retry', wrap(async (req, res) => res.json(await files.retry(req.admin.id, req.params.taskId))));
  router.use('/:id/attachments/:attachmentId', attachmentRouter(sites, files, true));
  return router;
}

function attachmentRouter(sites, files, admin) {
  const router = express.Router({ mergeParams: true });
  const send = (kind, params = () => []) => wrap(async (req, res) => {
    const attachment = await files.attachmentFor(admin ? req.admin.id : req.auth?.memberId,
      req.params.id, req.params.attachmentId, req.params.version, admin, req.query.incidentId || null);
    if (kind === 'source' && !admin) return res.status(403).json({ code: 'KEY_SITE_SOURCE_PRIVATE', error: '原始上传文件仅维护人员可下载，请阅读已发布的正式附件' });
    let file;
    try { file = await files.filePath(attachment, kind, params(req)); }
    catch (err) {
      if (err.code === 'ENOENT') return res.status(404).json({ code: 'KEY_SITE_FILE_NOT_FOUND', error: '附件暂不可用，请联系维护人员' });
      throw err;
    }
    res.set('Cache-Control', 'private, no-store');
    res.set('X-Content-Type-Options', 'nosniff');
    if (kind === 'source') {
      res.attachment(attachment.filename);
      res.type(attachment.mime);
    }
    res.sendFile(file, { cacheControl: false }, err => {
      if (err && !res.headersSent) res.status(err.statusCode === 404 ? 404 : 500).end();
    });
  });
  router.get('/source', send('source'));
  router.get('/document.pdf', send('pdf'));
  router.get('/pages/:page.jpg', send('page', req => [req.params.page]));
  router.get('/tiles/:z/:x/:y.jpg', send('tile', req => [req.params.z, req.params.x, req.params.y]));
  router.get('/maps/:page/tiles/:z/:x/:y.jpg', send('tile', req => [req.params.page, req.params.z, req.params.x, req.params.y]));
  return router;
}

function createKeySiteAppRouter(sites, files) {
  const router = express.Router();
  router.use((req, res, next) => { res.set('Cache-Control', 'private, no-store'); next(); });
  router.get('/', wrap(async (req, res) => res.json(await sites.list(req.auth?.memberId, req.query))));
  router.get('/access', wrap(async (req, res) => {
    const member = await sites.reader(req.auth?.memberId);
    res.json({ memberId: member.id, unitId: member.unit_id });
  }));
  router.get('/filters', wrap(async (req, res) => res.json(await sites.filters(req.auth?.memberId))));
  router.get('/recent', wrap(async (req, res) => res.json({ sites: await sites.recent(req.auth?.memberId, String(req.query.ids || '').split(',').filter(Boolean)) })));
  const read = wrap(async (req, res) => {
    const data = await sites.published(req.auth?.memberId, req.params.id, req.params.version, req.query.incidentId || null);
    const attachments = [];
    for (const id of data.attachment_ids) {
      const row = await files.attachmentFor(req.auth?.memberId, req.params.id, id, data.version, false, req.query.incidentId || null);
      attachments.push({ id: row.id, module: row.module, filename: row.filename, mime: row.mime, metadata: row.metadata });
    }
    res.json({ ...data, attachments });
  });
  router.get('/:id', read);
  router.get('/:id/versions/:version', read);
  router.use('/:id/versions/:version/attachments/:attachmentId', attachmentRouter(sites, files, false));
  return router;
}
module.exports = { createKeySiteAdminRouter, createKeySiteAppRouter };
