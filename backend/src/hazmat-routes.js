const express = require('express');
const multer = require('multer');

const upload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 10 * 1024 * 1024 } // 10MB limit
});

const wrap = (handler) => (req, res, next) =>
  Promise.resolve(handler(req, res)).catch((error) => {
    if (error.status) return res.status(error.status).json({ code: error.code, error: error.message });
    next(error);
  });

function createHazmatAdminRouter(hazmats, auth = null) {
  const router = express.Router();

  async function recordAudit(actorId, action, targetId) {
    if (auth && typeof auth.audit === 'function' && actorId) {
      await auth.audit(actorId, action, targetId).catch(() => {});
    }
  }

  // 列表与检索
  router.get('/', wrap(async (req, res) => {
    const limit = Math.min(parseInt(req.query.limit || '50', 10), 100);
    const offset = Math.max(parseInt(req.query.offset || '0', 10), 0);
    const result = await hazmats.list({
      query: req.query.q || req.query.query,
      category: req.query.category,
      water: req.query.water,
      limit,
      offset,
      activeOnly: req.query.all !== 'true'
    });
    res.json(result);
  }));

  // 下载导入模板
  router.get('/template', (req, res) => {
    const format = req.query.format === 'xlsx' ? 'xlsx' : 'csv';
    const buffer = hazmats.generateTemplate(format);
    const filename = `hazmat_template_${Date.now()}.${format}`;
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.setHeader('Content-Type', format === 'xlsx'
      ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
      : 'text/csv; charset=utf-8');
    res.send(buffer);
  });

  // 单条详情
  router.get('/:id', wrap(async (req, res) => {
    const item = await hazmats.getById(req.params.id);
    if (!item || !item.active) {
      return res.status(404).json({ code: 'HAZMAT_NOT_FOUND', error: '危化品未找到' });
    }
    res.json({ item });
  }));

  // 手工录入新增
  router.post('/', wrap(async (req, res) => {
    const actorId = req.admin?.id || null;
    const item = await hazmats.create(req.body, actorId);
    await recordAudit(actorId, 'hazmat_created', item.id);
    res.status(201).json({ item });
  }));

  // 编辑更新
  router.put('/:id', wrap(async (req, res) => {
    const actorId = req.admin?.id || null;
    const item = await hazmats.update(req.params.id, req.body, actorId);
    await recordAudit(actorId, 'hazmat_updated', item.id);
    res.json({ item });
  }));

  // 删除 (软删除)
  router.delete('/:id', wrap(async (req, res) => {
    const actorId = req.admin?.id || null;
    const result = await hazmats.remove(req.params.id, actorId);
    await recordAudit(actorId, 'hazmat_deleted', req.params.id);
    res.json(result);
  }));

  // 批量导入
  router.post('/import', upload.single('file'), wrap(async (req, res) => {
    if (!req.file || !req.file.buffer) {
      return res.status(400).json({ code: 'FILE_REQUIRED', error: '请上传有效的 Excel 或 CSV 文件' });
    }
    const actorId = req.admin?.id || null;
    const overwrite = req.body.overwrite === 'true' || req.body.overwrite === true;
    const result = await hazmats.importBatch(req.file.buffer, req.file.originalname, actorId, { overwrite });
    await recordAudit(actorId, 'hazmat_imported', `${result.imported}_imported`);
    res.json(result);
  }));

  return router;
}

function createHazmatAppRouter(hazmats) {
  const router = express.Router();

  // 移动端/现场检索
  router.get('/', wrap(async (req, res) => {
    const limit = Math.min(parseInt(req.query.limit || '20', 10), 100);
    const offset = Math.max(parseInt(req.query.offset || '0', 10), 0);
    const result = await hazmats.list({
      query: req.query.q || req.query.query,
      category: req.query.category,
      water: req.query.water,
      limit,
      offset,
      activeOnly: true
    });
    res.json(result);
  }));

  // 移动端单条处置详情
  router.get('/:id', wrap(async (req, res) => {
    const item = await hazmats.getById(req.params.id);
    if (!item || !item.active) {
      return res.status(404).json({ code: 'HAZMAT_NOT_FOUND', error: '危化品未找到' });
    }
    res.json({ item });
  }));

  return router;
}

module.exports = {
  createHazmatAdminRouter,
  createHazmatAppRouter
};
