const express = require('express');
const fs = require('node:fs/promises');
const path = require('node:path');

const safeId = (id) => typeof id === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(id);

// Only operator-installed datasets are served. No upload API and no public static mount.
function createOrthomapRouter(root) {
  const router = express.Router();
  router.use((req, res, next) => {
    res.set('Cache-Control', 'private, no-store');
    if (!safeId(req.unit?.id)) return res.status(401).json({ error: '请先完成单位认证' });
    next();
  });
  const datasetPath = (req, id) => id === 'demo'
    ? path.join(root, 'demo') : path.join(root, 'units', req.unit.id, id);
  async function readMap(req, id) {
    if (!safeId(id)) return null;
    const directory = datasetPath(req, id);
    try {
      const realRoot = await fs.realpath(root);
      const realDirectory = await fs.realpath(directory);
      if (realDirectory !== path.join(realRoot, path.relative(root, directory))) return null;
      const metadataPath = await fs.realpath(path.join(directory, 'map.json'));
      if (path.dirname(metadataPath) !== realDirectory) return null;
      const data = JSON.parse(await fs.readFile(metadataPath, 'utf8'));
      if (!Number.isInteger(data.width) || data.width < 1 || data.width > 1000000 ||
          !Number.isInteger(data.height) || data.height < 1 || data.height > 1000000 ||
          data.tileSize !== 256 || data.maxZoom !== Math.max(0, Math.ceil(Math.log2(Math.max(data.width, data.height) / 256)))) return null;
      return { id, name: String(data.name || id).slice(0, 120), width: data.width,
        height: data.height, tileSize: 256, maxZoom: data.maxZoom,
        demo: id === 'demo', coordinateSystem: 'image-pixels' };
    } catch (error) {
      if (['ENOENT', 'ENOTDIR'].includes(error.code) || error instanceof SyntaxError) return null;
      throw error;
    }
  }
  router.get('/', async (req, res, next) => {
    try {
      let entries = [];
      try { entries = await fs.readdir(path.join(root, 'units', req.unit.id), { withFileTypes: true }); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      const ids = entries.filter((entry) => entry.isDirectory() && safeId(entry.name) && entry.name !== 'demo').map((entry) => entry.name);
      const maps = (await Promise.all(['demo', ...ids].map((id) => readMap(req, id)))).filter(Boolean);
      res.json({ maps });
    } catch (error) { next(error); }
  });
  router.get('/:id/tiles/:z/:x/:y.jpg', async (req, res, next) => {
    try {
      const map = await readMap(req, req.params.id);
      const parts = [req.params.z, req.params.x, req.params.y];
      if (!map || parts.some((part) => !/^\d{1,7}$/.test(part))) return res.sendStatus(404);
      const [z, x, y] = parts.map(Number);
      const factor = 2 ** (map.maxZoom - z);
      if (z > map.maxZoom || x >= Math.ceil(map.width / factor / 256) || y >= Math.ceil(map.height / factor / 256)) return res.sendStatus(404);
      const directory = await fs.realpath(datasetPath(req, map.id));
      let file;
      try { file = await fs.realpath(path.join(directory, 'tiles', String(z), String(x), `${y}.jpg`)); }
      catch (error) { if (error.code === 'ENOENT') return res.sendStatus(404); throw error; }
      if (!file.startsWith(`${directory}${path.sep}`)) return res.sendStatus(404);
      res.sendFile(file, { cacheControl: false, dotfiles: 'deny' }, (error) => {
        if (error && !res.headersSent) res.sendStatus(error.statusCode === 404 ? 404 : 500);
      });
    } catch (error) { next(error); }
  });
  return router;
}
module.exports = { createOrthomapRouter };
