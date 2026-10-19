const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const express = require('express');
const { createOrthomapRouter } = require('../src/orthomaps');

test('地图：认证、单位隔离、共享演示、边界与符号链接', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'maps-'));
  const app = express();
  // Unit scope supplied by upstream authenticated middleware, never route parameters.
  app.use((req, res, next) => { if (req.headers['x-test-unit']) req.unit = { id: req.headers['x-test-unit'] }; next(); });
  app.use('/api/maps', createOrthomapRouter(root));
  const server = app.listen(0, '127.0.0.1');
  await new Promise((resolve) => server.once('listening', resolve));
  t.after(async () => { await new Promise((resolve) => server.close(resolve)); await fs.rm(root, { recursive: true, force: true }); });
  async function install(relative, name) {
    const directory = path.join(root, relative);
    await fs.mkdir(path.join(directory, 'tiles/0/0'), { recursive: true });
    await fs.writeFile(path.join(directory, 'map.json'), JSON.stringify({ name, width: 200, height: 100, tileSize: 256, maxZoom: 0 }));
    await fs.writeFile(path.join(directory, 'tiles/0/0/0.jpg'), Buffer.from([255, 216, 255, 217]));
    return directory;
  }
  await install('demo', '演示');
  const privateDirectory = await install('units/unit-a/private', 'A单位私有影像');
  const url = `http://127.0.0.1:${server.address().port}/api/maps`;
  const get = (suffix, unit) => fetch(url + suffix, { headers: unit ? { 'x-test-unit': unit } : {} });
  assert.equal((await get('')).status, 401);
  assert.equal((await get('/demo/tiles/0/0/0.jpg')).status, 401);
  const list = await get('', 'unit-a');
  assert.equal(list.headers.get('cache-control'), 'private, no-store');
  assert.deepEqual((await list.json()).maps.map((m) => m.id), ['demo', 'private']);
  assert.deepEqual((await (await get('', 'unit-b')).json()).maps.map((m) => m.id), ['demo']);
  assert.equal((await get('/private/tiles/0/0/0.jpg', 'unit-b')).status, 404);
  const image = await get('/private/tiles/0/0/0.jpg', 'unit-a');
  assert.equal(image.status, 200);
  assert.match(image.headers.get('content-type'), /image\/jpeg/);
  assert.equal((await image.arrayBuffer()).byteLength, 4);
  for (const suffix of ['/private/tiles/1/0/0.jpg', '/private/tiles/0/1/0.jpg', '/private/tiles/-1/0/0.jpg', '/%2e%2e%2fprivate/tiles/0/0/0.jpg']) {
    assert.equal((await get(suffix, 'unit-a')).status, 404);
  }
  await fs.mkdir(path.join(root, 'units/unit-b'), { recursive: true });
  await fs.symlink(privateDirectory, path.join(root, 'units/unit-b/alias'));
  assert.equal((await get('/alias/tiles/0/0/0.jpg', 'unit-b')).status, 404);
  await fs.unlink(path.join(root, 'demo/tiles/0/0/0.jpg'));
  await fs.symlink(path.join(privateDirectory, 'tiles/0/0/0.jpg'), path.join(root, 'demo/tiles/0/0/0.jpg'));
  assert.equal((await get('/demo/tiles/0/0/0.jpg', 'unit-b')).status, 404);
});
