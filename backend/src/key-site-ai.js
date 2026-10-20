const fs = require('node:fs/promises');
const sharp = require('sharp');
const { randomUUID } = require('node:crypto');
const { forceError } = require('./force-fields');
const shape = require('./key-site-content');
const { extractKeySite, reviewSummary, endpoint } = require('./key-site-extraction');
const { keySiteLimits } = require('./key-site-limits');
const fail = (message, code, status = 409) => { throw forceError(message, code, status); };

function createKeySiteAI(store, sites, files, auth, config, { extract = extractKeySite, now = Date.now } = {}) {
  const limits = keySiteLimits();
  const query = async (sql, args = []) => (await store.query(sql, args)).rows;
  const controllers = new Map();
  const available = () => Boolean(config.apiKey);
  async function read(memberId, taskId, lock = false) {
    const task = (await query(`SELECT * FROM key_site_tasks WHERE id=$1 AND kind='ai'${lock ? ' FOR UPDATE' : ''}`, [taskId]))[0];
    if (!task) fail('AI整理任务不存在', 'KEY_SITE_TASK_NOT_FOUND', 404);
    await sites.maintain(memberId, task.site_id);
    return { ...task, summary: reviewSummary(task.result?.pages || []) };
  }
  function validatePages(selected, total) {
    if (!Array.isArray(selected) || !selected.length || selected.length > limits.aiPages
      || selected.some(page => !Number.isInteger(page) || page < 1 || page > total) || new Set(selected).size !== selected.length) {
      fail(`请明确选择1至${limits.aiPages}页，页码必须属于此附件且不重复`, 'KEY_SITE_AI_PAGES_INVALID', 400);
    }
    return [...selected].sort((a, b) => a - b);
  }
  async function admission(memberId, siteId) {
    const { row } = await sites.maintain(memberId, siteId);
    if (!row.active) fail('停用单位不能新建或重试AI整理', 'KEY_SITE_INACTIVE');
    await query('SELECT id FROM units WHERE id=$1 FOR UPDATE', [row.owner_unit_id]);
    await query('SELECT pg_advisory_xact_lock(hashtextextended($1,119011))', [memberId]);
    const pending = (await query(`SELECT count(*)::int AS count FROM key_site_tasks t JOIN key_sites s ON s.id=t.site_id
      WHERE s.owner_unit_id=$1 AND t.status IN ('queued','processing')`, [row.owner_unit_id]))[0];
    if (pending.count >= limits.unitPending) fail('本消防单位待处理任务已达上限', 'KEY_SITE_BUSY', 429);
    const recent = (await query("SELECT count(*)::int AS count FROM admin_audit WHERE actor_id=$1 AND action IN ('key_site_ai_requested','key_site_ai_retried') AND created_at>$2", [memberId, now() - 60000]))[0];
    if (recent.count >= 3) fail('AI整理请求过于频繁，请稍后重试', 'KEY_SITE_AI_RATE_LIMITED', 429);
  }
  async function create(memberId, siteId, attachmentId, selected) {
    if (!available()) fail('AI服务尚未配置，可继续人工维护资料', 'KEY_SITE_AI_UNAVAILABLE', 503);
    endpoint(config);
    return store.transaction(async () => {
      await sites.maintain(memberId, siteId, true);
      await admission(memberId, siteId);
      const file = await files.attachmentFor(memberId, siteId, attachmentId, undefined, true);
      if (file.status !== 'ready') fail('请先等待原件转换完成', 'KEY_SITE_FILE_NOT_READY');
      const pages = validatePages(selected, Number(file.metadata.pages));
      const duplicate = await query(`SELECT id FROM key_site_tasks WHERE attachment_id=$1 AND kind='ai' AND status IN ('queued','processing')`, [attachmentId]);
      if (duplicate.length) fail('此附件已有AI任务，请等待完成后再操作', 'KEY_SITE_BUSY', 429);
      const draft = (await query('SELECT revision FROM key_site_drafts WHERE site_id=$1', [siteId]))[0];
      const result = { pages: pages.map(page => ({ page, status: 'queued' })), applied: [] };
      if (Buffer.byteLength(JSON.stringify(result)) > limits.aiResultBytes) fail('任务页数超过AI结果大小限制，请减少页数', 'KEY_SITE_AI_RESULT_LIMIT', 413);
      const time = now();
      const task = (await query(`INSERT INTO key_site_tasks(id,site_id,attachment_id,kind,requested_by,draft_revision,result,created_at,updated_at)
        VALUES($1,$2,$3,'ai',$4,$5,$6,$7,$7) RETURNING *`, [randomUUID(), siteId, attachmentId, memberId, draft.revision, JSON.stringify(result), time]))[0];
      await auth.audit(memberId, 'key_site_ai_requested', task.id);
      return task;
    });
  }
  async function retry(memberId, taskId, selected) {
    if (!available()) fail('AI服务尚未配置', 'KEY_SITE_AI_UNAVAILABLE', 503);
    endpoint(config);
    return store.transaction(async () => {
      const task = await read(memberId, taskId, true);
      if (!['partial','failed'].includes(task.status)) fail('仅可重试失败的页面', 'KEY_SITE_AI_NOT_RETRYABLE');
      await admission(memberId, task.site_id);
      const failed = task.result.pages.filter(page => page.status === 'failed').map(page => page.page);
      const indices = validatePages(selected, Number.MAX_SAFE_INTEGER);
      if (indices.some(page => !failed.includes(page))) fail('只能选择本任务失败的页面', 'KEY_SITE_AI_PAGES_INVALID', 400);
      const result = { ...task.result, pages: task.result.pages.map(page => indices.includes(page.page) ? { page: page.page, status: 'queued' } : page) };
      await query(`UPDATE key_site_tasks SET status='queued',generation=generation+1,attempts=0,lease_token=NULL,lease_until=NULL,
        error_code=NULL,result=$2,updated_at=$3,requested_by=$4 WHERE id=$1`, [taskId, JSON.stringify(result), now(), memberId]);
      await auth.audit(memberId, 'key_site_ai_retried', taskId);
      return { ok: true };
    });
  }
  async function cancel(memberId, taskId) {
    await store.transaction(async () => {
      const task = await read(memberId, taskId, true);
      if (task.status === 'cancelled') return;
      await query("UPDATE key_site_tasks SET status='cancelled',generation=generation+1,lease_token=NULL,lease_until=NULL,updated_at=$2 WHERE id=$1", [taskId, now()]);
      await auth.audit(memberId, 'key_site_ai_cancelled', taskId);
    });
    controllers.get(taskId)?.abort();
    return { ok: true };
  }
  async function apply(memberId, taskId, input) {
    if (input.reviewed !== true) fail('请逐项核对原件与待核对事项后再采用', 'KEY_SITE_AI_REVIEW_REQUIRED', 400);
    if (!Array.isArray(input.ids) || !input.ids.length || input.ids.length > 500 || new Set(input.ids).size !== input.ids.length) fail('请选择未采用的建议条目', 'KEY_SITE_AI_SELECTION_INVALID', 400);
    return store.transaction(async () => {
      // Match site -> task lock order used by file operations and concurrent task creation.
      const found = await read(memberId, taskId);
      await sites.maintain(memberId, found.site_id, true);
      const task = await read(memberId, taskId, true);
      if (!['succeeded','partial'].includes(task.status) || task.generation !== Number(input.generation)) fail('AI结果已变化，请重新加载核对', 'KEY_SITE_AI_CONFLICT');
      const draft = (await query('SELECT * FROM key_site_drafts WHERE site_id=$1 FOR UPDATE', [task.site_id]))[0];
      if (draft.revision !== Number(input.revision)) fail('人工草稿已更新，请重新核对；现有修改未被覆盖', 'KEY_SITE_CONFLICT');
      const byId = new Map(task.summary.entries.map(entry => [entry.id, entry]));
      const applied = new Set(task.result.applied || []), next = structuredClone(draft.content);
      if (input.edits !== undefined && (!input.edits || typeof input.edits !== 'object' || Array.isArray(input.edits)
        || Object.keys(input.edits).some(id => !input.ids.includes(id)))) fail('人工修订格式无效', 'KEY_SITE_AI_SELECTION_INVALID', 400);
      for (const id of input.ids) {
        const candidate = byId.get(id);
        if (!candidate || applied.has(id)) fail('条目不存在或已采用', 'KEY_SITE_AI_SELECTION_INVALID', 400);
        const edit = input.edits?.[id];
        const module = edit?.module || candidate.module;
        if (!shape.MODULES.includes(module)) fail('请选择有效资料分类', 'KEY_SITE_AI_SELECTION_INVALID', 400);
        const proposed = edit ? { kind: edit.kind, title: edit.title, body: edit.body, fields: edit.fields, sources: candidate.entry.sources } : candidate.entry;
        const checked = shape.emptyContent(); checked[module] = [proposed];
        const entry = shape.content(checked)[module][0];
        if (module === 'maps') {
          const file = await files.attachmentFor(memberId, task.site_id, task.attachment_id, undefined, true);
          if (!file.metadata.mapPages?.[entry.sources[0].page]) fail('地图建议须先完成该原件的地图切片，请将原件作为地图上传后重新整理', 'KEY_SITE_MAP_NOT_READY');
        }
        entry.sources.forEach(source => { source.paragraph = 'AI摘录后人工核对'; });
        // Only append reviewed candidates. Never replace, merge or clear any existing human entry.
        next[module].push(entry); applied.add(id);
      }
      const data = shape.content(next);
      const rows = await query(`UPDATE key_site_drafts SET content=$2,revision=revision+1,updated_by=$3,updated_at=$4
        WHERE site_id=$1 AND revision=$5 RETURNING *`, [task.site_id, JSON.stringify(data), memberId, now(), draft.revision]);
      if (!rows.length) fail('人工草稿已更新，请重新核对', 'KEY_SITE_CONFLICT');
      const result = JSON.stringify({ ...task.result, applied: [...applied] });
      if (Buffer.byteLength(result) > limits.aiResultBytes) fail('AI结果记录超过限制，请分批手工核对录入', 'KEY_SITE_AI_RESULT_LIMIT', 413);
      await query('UPDATE key_site_tasks SET result=$2,updated_at=$3 WHERE id=$1', [taskId, result, now()]);
      await auth.audit(memberId, 'key_site_ai_applied', taskId);
      return rows[0];
    });
  }
  async function claim() {
    return store.transaction(async () => {
      await query('SELECT pg_advisory_xact_lock(119011)');
      const interrupted = await query("SELECT * FROM key_site_tasks WHERE kind='ai' AND status='processing' AND lease_until<$1 FOR UPDATE", [now()]);
      for (const task of interrupted) {
        const exhausted = task.attempts >= 3;
        const result = { ...task.result, pages: task.result.pages.map(page => ['succeeded','failed'].includes(page.status) ? page
          : { page: page.page, status: exhausted ? 'failed' : 'queued', errorCode: 'KEY_SITE_AI_INTERRUPTED' }) };
        const status = exhausted ? (result.pages.some(page => page.status === 'succeeded') ? 'partial' : 'failed') : 'queued';
        await query(`UPDATE key_site_tasks SET status=$2,result=$3,lease_token=NULL,lease_until=NULL,error_code='KEY_SITE_AI_INTERRUPTED',updated_at=$4 WHERE id=$1`, [task.id, status, JSON.stringify(result), now()]);
      }
      const count = (await query("SELECT count(*)::int AS count FROM key_site_tasks WHERE kind='ai' AND status='processing'"))[0];
      if (count.count >= limits.aiConcurrency) return null;
      const task = (await query("SELECT * FROM key_site_tasks WHERE kind='ai' AND status='queued' ORDER BY created_at,id FOR UPDATE SKIP LOCKED LIMIT 1"))[0];
      if (!task) return null;
      return (await query(`UPDATE key_site_tasks SET status='processing',lease_token=$2,lease_until=$3,attempts=attempts+1,updated_at=$4
        WHERE id=$1 RETURNING *`, [task.id, randomUUID(), now() + 60000, now()]))[0];
    });
  }
  async function run(task) {
    const controller = new AbortController(); controllers.set(task.id, controller);
    const timer = setTimeout(() => controller.abort(), limits.aiTaskTimeoutMs); timer.unref();
    let leaseLost = false;
    const heartbeat = setInterval(() => {
      query("UPDATE key_site_tasks SET lease_until=$3 WHERE id=$1 AND lease_token=$2 AND status='processing' RETURNING id", [task.id, task.lease_token, now() + 60000])
        .then(rows => { if (!rows.length) { leaseLost = true; controller.abort(); } }).catch(() => { leaseLost = true; controller.abort(); });
    }, 15000); heartbeat.unref();
    const result = structuredClone(task.result);
    const persist = async (status = 'processing') => {
      if (Buffer.byteLength(JSON.stringify(result)) > limits.aiResultBytes) fail('AI结果超过任务大小限制，请按更少页数分批整理', 'KEY_SITE_AI_RESULT_LIMIT', 413);
      const rows = await query(`UPDATE key_site_tasks SET result=$3,status=$4,updated_at=$5,
        lease_until=CASE WHEN $4='processing' THEN lease_until ELSE NULL END
        WHERE id=$1 AND lease_token=$2 AND status='processing' RETURNING id`, [task.id, task.lease_token, JSON.stringify(result), status, now()]);
      if (!rows.length || leaseLost) { controller.abort(); fail('此任务已被新的处理进程接管', 'KEY_SITE_AI_LEASE_LOST'); }
    };
    try {
      const attachment = (await query('SELECT * FROM key_site_attachments WHERE id=$1', [task.attachment_id]))[0];
      for (const page of result.pages) {
        if (page.status === 'succeeded' || page.status === 'failed') continue;
        page.status = 'processing'; await persist();
        try {
          controller.signal.throwIfAborted();
          // Revocation or ownership changes also stop future transmissions to the model.
          await sites.maintain(task.requested_by, task.site_id);
          const source = await files.filePath(attachment, 'page', [page.page]);
          const buffer = await sharp(await fs.readFile(source), { limitInputPixels: files.limits.pixels })
            .resize({ width: 2000, height: 2000, fit: 'inside', withoutEnlargement: true }).jpeg({ quality: 88 }).toBuffer();
          page.extraction = await extract({ config, imageDataUrl: `data:image/jpeg;base64,${buffer.toString('base64')}`,
            attachmentId: attachment.id, page: page.page, signal: controller.signal });
          if (Buffer.byteLength(JSON.stringify(result)) > limits.aiResultBytes) fail('AI结果超过大小限制，请减少单批页数', 'KEY_SITE_AI_RESULT_LIMIT', 413);
          page.status = 'succeeded'; delete page.errorCode;
        } catch (err) {
          page.status = 'failed'; page.errorCode = ['ADMIN_FORBIDDEN','KEY_SITE_FORBIDDEN'].includes(err.code) ? 'KEY_SITE_AI_ACCESS_REVOKED'
            : /^KEY_SITE_[A-Z_]+$/.test(err.code || '') ? err.code : 'KEY_SITE_AI_REQUEST_FAILED';
          delete page.extraction;
        }
        await persist();
      }
      const good = result.pages.filter(page => page.status === 'succeeded').length;
      await persist(good === result.pages.length ? 'succeeded' : good ? 'partial' : 'failed');
    } catch (err) {
      if (!leaseLost) {
        const recoverable = result.pages.map(page => page.status === 'succeeded' ? page
          : { page: page.page, status: 'failed', errorCode: /^KEY_SITE_[A-Z_]+$/.test(err.code || '') ? err.code : 'KEY_SITE_AI_REQUEST_FAILED' });
        await query(`UPDATE key_site_tasks SET status=$3,result=$4,error_code=$5,lease_until=NULL,updated_at=$6
          WHERE id=$1 AND lease_token=$2 AND status='processing'`, [task.id, task.lease_token, recoverable.some(page => page.status === 'succeeded') ? 'partial' : 'failed',
        JSON.stringify({ ...result, pages: recoverable }), /^KEY_SITE_[A-Z_]+$/.test(err.code || '') ? err.code : 'KEY_SITE_AI_REQUEST_FAILED', now()]);
      }
    } finally { clearInterval(heartbeat); clearTimeout(timer); if (controllers.get(task.id) === controller) controllers.delete(task.id); }
  }
  function startWorker(onError = () => {}) {
    let busy = false, closed = false;
    const tick = async () => {
      if (busy || closed || !available()) return;
      busy = true;
      try { const task = await claim(); if (task) await run(task); }
      catch (err) { onError(err); }
      finally { busy = false; }
    };
    const timer = setInterval(tick, 1000); timer.unref();
    return () => { closed = true; clearInterval(timer); for (const controller of controllers.values()) controller.abort(); };
  }
  return { available, limits, read, create, retry, cancel, apply, claim, run, startWorker };
}
module.exports = { createKeySiteAI };
