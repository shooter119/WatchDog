const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID, createHash } = require('node:crypto');
const { promisify } = require('node:util');
const { execFile } = require('node:child_process');
const sharp = require('sharp');
const yauzl = require('yauzl');
const { XMLParser } = require('fast-xml-parser');
const { forceError } = require('./force-fields');
const { MODULES } = require('./key-site-content');
const runFile = promisify(execFile);
const { DEFAULT_LIMITS, keySiteLimits } = require('./key-site-limits');
const error = (message, code = 'KEY_SITE_FILE_INVALID', status = 415) => forceError(message, code, status);
const idValid = value => typeof value === 'string' && /^[a-zA-Z0-9_-]{1,128}$/.test(value);

async function inspectDocx(buffer) {
  const zip = await new Promise((resolve, reject) => yauzl.fromBuffer(buffer, { lazyEntries: true }, (err, value) => err ? reject(err) : resolve(value)));
  let entries = 0, total = 0, document = false, types = false;
  const names = new Set();
  try {
    await new Promise((resolve, reject) => {
      zip.on('error', reject); zip.on('end', resolve);
      zip.on('entry', entry => {
        (async () => {
          total += entry.uncompressedSize;
          if (names.has(entry.fileName)) throw error('DOCX包含重复条目，请重新导出文件');
          names.add(entry.fileName);
          if (++entries > 5000 || total > 100 * 1024 * 1024 || entry.uncompressedSize > 20 * 1024 * 1024
            || (entry.generalPurposeBitFlag & 1) || /vbaProject|activeX|embeddings\//i.test(entry.fileName)) throw error('不支持加密、宏或嵌入可执行对象的DOCX');
          if (!entry.fileName.endsWith('.xml') && !entry.fileName.endsWith('.rels')) {
            zip.readEntry(); return;
          }
          const stream = await new Promise((r, j) => zip.openReadStream(entry, (err, value) => err ? j(err) : r(value)));
          const chunks = []; let size = 0;
          for await (const chunk of stream) { size += chunk.length; if (size > 20 * 1024 * 1024) throw error('DOCX内容超过限制'); chunks.push(chunk); }
          const xml = Buffer.concat(chunks).toString('utf8');
          if (/<!DOCTYPE|<!ENTITY/i.test(xml)) throw error('不支持含外部实体的DOCX');
          const parsed = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '', removeNSPrefix: true }).parse(xml);
          if (entry.fileName === 'word/document.xml') document = Boolean(parsed.document);
          if (entry.fileName === '[Content_Types].xml') {
            const overrides = parsed.Types?.Override || [];
            types = (Array.isArray(overrides) ? overrides : [overrides]).some(item => item.ContentType === 'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml');
          }
          if (entry.fileName.endsWith('.rels')) {
            const relationships = parsed.Relationships?.Relationship || [];
            for (const rel of Array.isArray(relationships) ? relationships : [relationships]) {
              if (rel.TargetMode === 'External' && !String(rel.Type).endsWith('/hyperlink')) throw error('请移除DOCX中的外部引用图片或模板后重试');
            }
          }
          zip.readEntry();
        })().catch(reject);
      });
      zip.readEntry();
    });
  } finally { zip.close(); }
  if (!document || !types) throw error('文件不是有效的DOCX');
}

function createKeySiteFiles(store, sites, auth, { root = path.resolve(process.env.WATCHDOG_DATA_DIR || path.join(__dirname, '..', 'data'), 'private-key-sites'), limits = {}, tools = {} } = {}) {
  const caps = keySiteLimits(limits);
  const query = async (sql, args = []) => (await store.query(sql, args)).rows;
  function directory(id) {
    if (!idValid(id)) throw error('附件不存在', 'KEY_SITE_FILE_NOT_FOUND', 404);
    return path.join(root, id);
  }
  async function inspect(buffer, filename, module) {
    if (!Buffer.isBuffer(buffer) || !buffer.length || buffer.length > caps.fileBytes) throw error('文件超过上传大小限制', 'KEY_SITE_UPLOAD_TOO_LARGE', 413);
    const ext = path.extname(filename).toLowerCase();
    if (['.png', '.jpg', '.jpeg'].includes(ext)) {
      let metadata;
      try { metadata = await sharp(buffer, { limitInputPixels: caps.pixels }).metadata(); }
      catch (_) { throw error('图片无效或像素超过限制'); }
      if (!['jpeg', 'png'].includes(metadata.format) || metadata.width * metadata.height > caps.pixels
        || metadata.width > caps.dimension || metadata.height > caps.dimension || (metadata.pages || 1) !== 1) throw error('图片像素或帧数超过限制');
      return { mime: metadata.format === 'png' ? 'image/png' : 'image/jpeg', ext: metadata.format === 'png' ? '.png' : '.jpg' };
    }
    if (ext === '.pdf' && buffer.subarray(0, 5).toString() === '%PDF-') return { mime: 'application/pdf', ext };
    if (ext === '.docx' && buffer[0] === 80 && buffer[1] === 75) {
      await inspectDocx(buffer);
      return { mime: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', ext };
    }
    throw error('仅支持PDF、DOCX、JPG、PNG，不支持旧版DOC或可执行附件');
  }
  async function upload(memberId, siteId, module, file) {
    await sites.maintain(memberId, siteId);
    if (!MODULES.includes(module) || !file) throw error('请选择资料分类和文件', 'KEY_SITE_FILE_REQUIRED', 400);
    const filename = String(file.originalname || '附件').replace(/[\x00-\x1f/\\]/g, '_').slice(0, 180);
    const info = await inspect(file.buffer, filename, module);
    const id = randomUUID(), folder = directory(id), time = Date.now();
    try {
      return await store.transaction(async () => {
        const { row } = await sites.maintain(memberId, siteId, true);
        // Lock quota per owning fire unit across different sites and concurrent uploads.
        await query('SELECT id FROM units WHERE id=$1 FOR UPDATE', [row.owner_unit_id]);
        const used = (await query(`SELECT COALESCE(sum(a.size_bytes+COALESCE((a.metadata->>'processedBytes')::bigint,0)),0)::bigint AS bytes FROM key_site_attachments a
          JOIN key_sites s ON s.id=a.site_id WHERE s.owner_unit_id=$1`, [row.owner_unit_id]))[0];
        if (Number(used.bytes) + file.buffer.length > caps.quotaBytes) throw error('所属消防单位的资料存储配额已满', 'KEY_SITE_QUOTA_EXCEEDED', 413);
        const pending = (await query(`SELECT count(*)::int AS count FROM key_site_tasks t JOIN key_sites s ON s.id=t.site_id
          WHERE s.owner_unit_id=$1 AND t.status IN ('queued','processing')`, [row.owner_unit_id]))[0];
        if (pending.count >= caps.unitPending) throw error('本消防单位待处理任务已达上限，请稍后上传', 'KEY_SITE_BUSY', 429);
        await fs.mkdir(folder, { recursive: true, mode: 0o700 });
        await fs.writeFile(path.join(folder, `original${info.ext}`), file.buffer, { flag: 'wx', mode: 0o600 });
        const rowFile = (await query(`INSERT INTO key_site_attachments(id,site_id,module,filename,mime,size_bytes,sha256,metadata,uploaded_by,created_at)
          VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) RETURNING *`,
        [id, siteId, module, filename, info.mime, file.buffer.length, createHash('sha256').update(file.buffer).digest('hex'), JSON.stringify({ ext: info.ext }), memberId, time]))[0];
        await query(`INSERT INTO key_site_tasks(id,site_id,attachment_id,kind,created_at,updated_at)
          VALUES($1,$2,$3,$4,$5,$5)`, [randomUUID(), siteId, id, module === 'maps' ? 'map' : 'document', time]);
        await auth.audit(memberId, 'key_site_uploaded', id);
        return rowFile;
      });
    } catch (err) { await fs.rm(folder, { recursive: true, force: true }); throw err; }
  }
  async function command(tool, args, signal) {
    const env = { PATH: process.env.PATH, HOME: process.env.HOME, TMPDIR: process.env.TMPDIR, LC_ALL: 'C', LANG: 'C' };
    try { return await runFile(tools[tool] || tool, args, { signal, timeout: caps.timeoutMs, maxBuffer: 2 * 1024 * 1024, env }); }
    catch (err) {
      if (err.code === 'ENOENT') throw error('服务器缺少文档转换组件', 'KEY_SITE_CONVERTER_UNAVAILABLE', 503);
      const timeout = err.killed || signal?.aborted;
      throw error(timeout ? '文档处理超时，请缩小文件后重试' : '文件损坏、加密或转换失败', timeout ? 'KEY_SITE_PROCESS_TIMEOUT' : 'KEY_SITE_CONVERT_FAILED', 422);
    }
  }
  async function sliceMap(image, output, page, signal, reserve) {
    const { width, height } = await sharp(image, { limitInputPixels: caps.pixels }).metadata();
        const maxZoom = Math.max(0, Math.ceil(Math.log2(Math.max(width, height) / 256)));

        for (let z = 0; z <= maxZoom; z++) {
          signal?.throwIfAborted();
          const factor = 2 ** (maxZoom - z), w = Math.ceil(width / factor), h = Math.ceil(height / factor);
          const level = await sharp(image).resize(w, h).raw().toBuffer({ resolveWithObject: true });
          for (let x = 0; x < Math.ceil(w / 256); x++) {
            const folder = path.join(output, 'tiles', String(page), String(z), String(x)); await fs.mkdir(folder, { recursive: true });
            for (let y = 0; y < Math.ceil(h / 256); y++) {
              signal?.throwIfAborted();
              const tw = Math.min(256, w - x * 256), th = Math.min(256, h - y * 256);
              const saved = await sharp(level.data, { raw: level.info }).extract({ left: x * 256, top: y * 256, width: tw, height: th })
                .extend({ top: 0, left: 0, right: 256 - tw, bottom: 256 - th, background: '#ffffff' }).jpeg({ quality: 88 })
                .toFile(path.join(folder, `${y}.jpg`));
              reserve(saved.size);
            }
          }
        }
    return { width, height, tileSize: 256, maxZoom, coordinateSystem: 'image-pixels' };
  }
  async function processFile(attachment, output, signal) {
    let outputBytes = 0;
    const reserve = size => { outputBytes += size; if (outputBytes + Number(attachment.size_bytes) > caps.quotaBytes) throw error('转换结果超过资料存储配额', 'KEY_SITE_QUOTA_EXCEEDED', 413); };
    const original = path.join(directory(attachment.id), `original${attachment.metadata.ext}`);
    const metadata = { ext: attachment.metadata.ext, output: path.basename(output), pages: 1 };
    await fs.mkdir(output, { recursive: true, mode: 0o700 });
    if (attachment.mime.startsWith('image/')) {
      const saved = await sharp(original, { limitInputPixels: caps.pixels }).rotate().flatten({ background: '#ffffff' }).jpeg({ quality: 90 }).toFile(path.join(output, 'page-1.jpg'));
      reserve(saved.size);
      const dimensions = await sharp(path.join(output, 'page-1.jpg')).metadata();
      metadata.width = dimensions.width; metadata.height = dimensions.height;
      if (attachment.module === 'maps') {
        metadata.map = await sliceMap(path.join(output, 'page-1.jpg'), output, 1, signal, reserve);
        metadata.mapPages = { 1: metadata.map };
      } else {
        const preview = await sharp(path.join(output, 'page-1.jpg')).resize({ width: 2000, height: 2000, fit: 'inside', withoutEnlargement: true }).jpeg().toFile(path.join(output, 'preview.jpg'));
        reserve(preview.size);
      }
      return metadata;
    }
    let pdf = original;
    if (attachment.metadata.ext === '.docx') {
      const profile = path.join(output, 'lo-profile');
      await command('soffice', [`-env:UserInstallation=${require('node:url').pathToFileURL(profile).href}`, '--headless', '--convert-to', 'pdf:writer_pdf_Export', '--outdir', output, original], signal);
      pdf = path.join(output, 'original.pdf');
    }
    const { stdout } = await command('pdfinfo', [pdf], signal);
    const pages = Number(/^Pages:\s+(\d+)/m.exec(stdout)?.[1]);
    if (!Number.isInteger(pages) || pages < 1 || pages > caps.pages) throw error(`文档页数须为1至${caps.pages}页`, 'KEY_SITE_PAGE_LIMIT', 413);
    if (/^Encrypted:\s+yes/m.test(stdout)) throw error('不支持加密PDF', 'KEY_SITE_ENCRYPTED', 415);
    metadata.pages = pages;
    if (attachment.metadata.ext === '.pdf') await fs.copyFile(original, path.join(output, 'original.pdf'));
    reserve((await fs.stat(path.join(output, 'original.pdf'))).size);
    for (let page = 1; page <= pages; page++) {
      signal?.throwIfAborted();
      const scale = Math.min(attachment.module === 'maps' ? 6000 : 2000, Math.floor(Math.sqrt(caps.pixels)));
      await command('pdftoppm', ['-f', String(page), '-l', String(page), '-singlefile', '-scale-to', String(scale), '-jpeg', pdf, path.join(output, `page-${page}`)], signal);
      reserve((await fs.stat(path.join(output, `page-${page}.jpg`))).size);
      if (attachment.module === 'maps') {
        metadata.mapPages ||= {};
        metadata.mapPages[page] = await sliceMap(path.join(output, `page-${page}.jpg`), output, page, signal, reserve);
        metadata.map ||= metadata.mapPages[page];
      }
    }
    await fs.rm(path.join(output, 'lo-profile'), { recursive: true, force: true });
    return metadata;
  }
  async function claim() {
    return store.transaction(async () => {
      await query('SELECT pg_advisory_xact_lock(119010)');
      // Interrupted leases are recoverable; generation tokens fence a stale worker's results.
      await query(`UPDATE key_site_tasks SET status=CASE WHEN attempts>=3 THEN 'failed' ELSE 'queued' END,
        error_code='KEY_SITE_INTERRUPTED',lease_token=NULL,lease_until=NULL,updated_at=$1
        WHERE status='processing' AND kind IN ('document','map') AND lease_until<$1`, [Date.now()]);
      await query(`UPDATE key_site_attachments SET status='failed' WHERE status='processing' AND id IN
        (SELECT attachment_id FROM key_site_tasks WHERE status='failed' AND kind IN ('document','map'))`);
      const count = (await query("SELECT count(*)::int AS count FROM key_site_tasks WHERE status='processing' AND kind IN ('document','map')"))[0];
      if (count.count >= caps.concurrency) return null;
      const task = (await query("SELECT * FROM key_site_tasks WHERE status='queued' AND kind IN ('document','map') ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1"))[0];
      if (!task) return null;
      const token = randomUUID();
      const row = (await query(`UPDATE key_site_tasks SET status='processing',lease_token=$2,lease_until=$3,
        attempts=attempts+1,updated_at=$4 WHERE id=$1 RETURNING *`, [task.id, token, Date.now() + 60000, Date.now()]))[0];
      await query("UPDATE key_site_attachments SET status='processing' WHERE id=$1", [task.attachment_id]);
      return row;
    });
  }
  async function run(task) {
    const attachment = (await query('SELECT * FROM key_site_attachments WHERE id=$1', [task.attachment_id]))[0];
    const output = path.join(directory(task.attachment_id), `processed-${task.lease_token}`);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), caps.taskTimeoutMs); timeout.unref();
    let leaseLost = false;
    const heartbeat = setInterval(() => {
      query("UPDATE key_site_tasks SET lease_until=$3 WHERE id=$1 AND lease_token=$2 AND status='processing' RETURNING id", [task.id, task.lease_token, Date.now() + 60000])
        .then(rows => { if (!rows.length) { leaseLost = true; controller.abort(); } }).catch(() => { leaseLost = true; controller.abort(); });
    }, 15000); heartbeat.unref();
    try {
      const metadata = await processFile(attachment, output, controller.signal);
      async function bytesIn(folder) {
        let sum = 0;
        for (const entry of await fs.readdir(folder, { withFileTypes: true })) {
          const file = path.join(folder, entry.name);
          sum += entry.isDirectory() ? await bytesIn(file) : (await fs.stat(file)).size;
        }
        return sum;
      }
      metadata.processedBytes = await bytesIn(output);
      await store.transaction(async () => {
        const row = await sites.site(attachment.site_id, true);
        await query('SELECT id FROM units WHERE id=$1 FOR UPDATE', [row.owner_unit_id]);
        const used = (await query(`SELECT COALESCE(sum(a.size_bytes+COALESCE((a.metadata->>'processedBytes')::bigint,0)),0)::bigint AS bytes
          FROM key_site_attachments a JOIN key_sites s ON s.id=a.site_id WHERE s.owner_unit_id=$1`, [row.owner_unit_id]))[0];
        if (Number(used.bytes) + metadata.processedBytes > caps.quotaBytes) throw error('转换结果超过资料存储配额', 'KEY_SITE_QUOTA_EXCEEDED', 413);
        const rows = await query("UPDATE key_site_tasks SET status='succeeded',lease_until=NULL,error_code=NULL,result=$3,updated_at=$4 WHERE id=$1 AND lease_token=$2 AND status='processing' RETURNING id", [task.id, task.lease_token, JSON.stringify(metadata), Date.now()]);
        if (!rows.length || leaseLost) throw error('任务已被新的处理进程接管', 'KEY_SITE_LEASE_LOST', 409);
        await query("UPDATE key_site_attachments SET status='ready',metadata=$2 WHERE id=$1", [attachment.id, JSON.stringify(metadata)]);
      });
    } catch (err) {
      await fs.rm(output, { recursive: true, force: true });
      await store.transaction(async () => {
        const rows = await query("UPDATE key_site_tasks SET status='failed',lease_until=NULL,error_code=$3,updated_at=$4 WHERE id=$1 AND lease_token=$2 AND status='processing' RETURNING id", [task.id, task.lease_token, /^KEY_SITE_[A-Z_]+$/.test(err.code || '') ? err.code : 'KEY_SITE_PROCESS_FAILED', Date.now()]);
        if (rows.length) await query("UPDATE key_site_attachments SET status='failed' WHERE id=$1", [attachment.id]);
      });
    } finally { clearInterval(heartbeat); clearTimeout(timeout); }
  }
  async function retry(memberId, taskId) {
    return store.transaction(async () => {
      const task = (await query('SELECT * FROM key_site_tasks WHERE id=$1 FOR UPDATE', [taskId]))[0];
      if (!task) throw error('任务不存在', 'KEY_SITE_TASK_NOT_FOUND', 404);
      await sites.maintain(memberId, task.site_id);
      if (task.status !== 'failed' || !['document', 'map'].includes(task.kind)) throw error('只能重试失败的处理任务', 'KEY_SITE_TASK_NOT_RETRYABLE', 409);
      await query("UPDATE key_site_tasks SET status='queued',generation=generation+1,attempts=0,error_code=NULL,lease_token=NULL,lease_until=NULL,updated_at=$2 WHERE id=$1", [taskId, Date.now()]);
      await query("UPDATE key_site_attachments SET status='queued' WHERE id=$1", [task.attachment_id]);
      await auth.audit(memberId, 'key_site_task_retried', taskId);
      return { ok: true };
    });
  }
  async function attachmentFor(memberId, siteId, attachmentId, version, admin = false, incidentId = null) {
    if (admin) await sites.maintain(memberId, siteId);
    else {
      const published = await sites.published(memberId, siteId, version, incidentId);
      if (!published.attachment_ids.includes(attachmentId)) throw error('此版本不包含该附件', 'KEY_SITE_FILE_NOT_FOUND', 404);
    }
    const row = (await query('SELECT * FROM key_site_attachments WHERE id=$1 AND site_id=$2', [attachmentId, siteId]))[0];
    if (!row) throw error('附件不存在', 'KEY_SITE_FILE_NOT_FOUND', 404);
    return row;
  }
  async function filePath(attachment, kind, parts = []) {
    const folder = directory(attachment.id);
    let file;
    if (kind === 'source') file = path.join(folder, `original${attachment.metadata.ext}`);
    else {
      if (attachment.status !== 'ready' || !/^processed-[a-z0-9-]+$/.test(attachment.metadata.output || '')) throw error('附件尚未就绪', 'KEY_SITE_FILE_NOT_READY', 409);
      const output = path.join(folder, attachment.metadata.output);
      if (kind === 'pdf') {
        if (attachment.mime.startsWith('image/')) throw error('此附件不是PDF', 'KEY_SITE_FILE_NOT_FOUND', 404);
        file = path.join(output, 'original.pdf');
      } else if (kind === 'page') {
        const page = Number(parts[0]);
        if (!Number.isInteger(page) || page < 1 || page > attachment.metadata.pages) throw error('页码不存在', 'KEY_SITE_FILE_NOT_FOUND', 404);
        file = path.join(output, `page-${page}.jpg`);
      } else if (kind === 'tile') {
        const page = parts.length === 4 ? Number(parts[0]) : 1;
        const coordinates = parts.length === 4 ? parts.slice(1) : parts;
        const map = attachment.metadata.mapPages?.[page];
        if (!map || coordinates.length !== 3 || coordinates.some(part => !/^\d{1,7}$/.test(String(part)))) throw error('瓦片不存在', 'KEY_SITE_FILE_NOT_FOUND', 404);
        const [z, x, y] = coordinates.map(Number), factor = 2 ** (map.maxZoom - z);
        if (z > map.maxZoom || x >= Math.ceil(map.width / factor / 256) || y >= Math.ceil(map.height / factor / 256)) throw error('瓦片不存在', 'KEY_SITE_FILE_NOT_FOUND', 404);
        file = path.join(output, 'tiles', String(page), String(z), String(x), `${y}.jpg`);
      } else throw error('附件不存在', 'KEY_SITE_FILE_NOT_FOUND', 404);
    }
    const actualRoot = await fs.realpath(root), actual = await fs.realpath(file);
    if (!actual.startsWith(`${actualRoot}${path.sep}`) || actual !== path.join(actualRoot, path.relative(root, file))) throw error('附件不存在', 'KEY_SITE_FILE_NOT_FOUND', 404);
    return actual;
  }
  async function cleanup() {
    const cutoff = Date.now() - 24 * 3600000;
    for (const entry of await fs.readdir(root, { withFileTypes: true }).catch(err => { if (err.code === 'ENOENT') return []; throw err; })) {
      if (!entry.isDirectory() || !idValid(entry.name)) continue;
      const folder = directory(entry.name);
      const attachment = (await query('SELECT metadata FROM key_site_attachments WHERE id=$1', [entry.name]))[0];
      if (!attachment) {
        if ((await fs.stat(folder)).mtimeMs < cutoff) await fs.rm(folder, { recursive: true, force: true });
        continue;
      }
      for (const output of await fs.readdir(folder, { withFileTypes: true })) {
        if (!output.isDirectory() || !/^processed-[a-z0-9-]+$/.test(output.name) || output.name === attachment.metadata.output) continue;
        const file = path.join(folder, output.name);
        if ((await fs.stat(file)).mtimeMs >= cutoff) continue;
        const active = await query("SELECT id FROM key_site_tasks WHERE attachment_id=$1 AND status='processing' AND lease_token=$2 AND lease_until>$3", [entry.name, output.name.slice(10), Date.now()]);
        if (!active.length) await fs.rm(file, { recursive: true, force: true });
      }
    }
  }
  function startWorker(onError = () => {}) {
    let busy = 0, closed = false, claiming = false, lastCleanup = 0;
    const tick = async () => {
      if (closed || claiming || busy >= caps.concurrency) return;
      claiming = true;
      try {
        if (Date.now() - lastCleanup > 60000) { await cleanup(); lastCleanup = Date.now(); }
        const task = await claim();
        if (task) { busy++; run(task).catch(onError).finally(() => { busy--; }); }
      } catch (err) { onError(err); }
      finally { claiming = false; }
    };
    const timer = setInterval(tick, 1000); timer.unref();
    return () => { closed = true; clearInterval(timer); };
  }
  return { limits: caps, root, upload, inspect, processFile, claim, run, retry, attachmentFor, filePath, cleanup, startWorker };
}
module.exports = { createKeySiteFiles, inspectDocx, DEFAULT_LIMITS };
