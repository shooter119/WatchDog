const fs = require('node:fs/promises');
const path = require('node:path');
const { randomUUID } = require('node:crypto');
const store = require('./postgres-store');
const { forceError } = require('./force-fields');
const { extractIncident, mergeExtractions } = require('./incident-extraction');
const repo = require('./incident-import-repository');

const TEMP_DIR = path.resolve(process.env.WATCHDOG_DATA_DIR || path.join(__dirname, '..', 'data'), 'private-import-images');
const MAX_AGE = 24 * 60 * 60 * 1000;
function validateImage(buffer) {
  let width = 0, height = 0, mime;
  if (buffer.length >= 24 && buffer.subarray(0, 8).equals(Buffer.from([137,80,78,71,13,10,26,10]))) {
    width = buffer.readUInt32BE(16); height = buffer.readUInt32BE(20); mime = 'image/png';
  } else if (buffer.length > 4 && buffer[0] === 255 && buffer[1] === 216) {
    let pos = 2;
    while (pos + 4 <= buffer.length) {
      if (buffer[pos] !== 255) break;
      while (buffer[pos] === 255) pos++;
      const marker = buffer[pos++];
      if (marker === 217 || marker === 218) break;
      if (marker === 1 || (marker >= 208 && marker <= 215)) continue;
      if (pos + 2 > buffer.length) break;
      const size = buffer.readUInt16BE(pos);
      if (size < 2 || pos + size > buffer.length) break;
      if ([192,193,194,195,197,198,199,201,202,203,205,206,207].includes(marker) && size >= 8) {
        height = buffer.readUInt16BE(pos + 3); width = buffer.readUInt16BE(pos + 5); mime = 'image/jpeg'; break;
      }
      pos += size;
    }
  }
  if (!mime || !width || !height) throw forceError('图片格式无效，请使用JPEG或PNG图片', 'IMPORT_IMAGE_INVALID', 415);
  if (width * height > 40000000 || width > 30000 || height > 30000) throw forceError('图片像素过大，请裁切或分段后导入', 'IMPORT_IMAGE_TOO_LARGE', 413);
  return { mime, width, height };
}
async function deleteImages(pages) {
  for (const page of pages) {
    if (page.file_path && path.dirname(page.file_path) === TEMP_DIR) await fs.unlink(page.file_path).catch(() => {});
  }
}
async function createTask({ unitId, incidentId, actorId, actorName, text, files = [] }) {
  const clean = typeof text === 'string' ? text.trim() : '';
  if ((clean && files.length) || (!clean && !files.length)) throw forceError('请选择文字或图片导入');
  if (clean.length > 20000 || files.length > 9) throw forceError('文字最多20000字，图片最多9张');
  if (files.reduce((sum, f) => sum + f.buffer.length, 0) > 25 * 1024 * 1024 || files.some((f) => f.buffer.length > 5 * 1024 * 1024)) throw forceError('图片超过上传大小限制', 'IMPORT_UPLOAD_TOO_LARGE', 413);
  const imageInfo = files.map((f) => validateImage(f.buffer));
  const inputHash = repo.digest(clean ? clean.normalize('NFKC').replace(/\s+/g,'') : files.map((f) => repo.digest(f.buffer)).join(':'));
  const pages = [];
  try {
    return await store.transaction(async () => {
      await store.query('SELECT id FROM units WHERE id=$1 FOR UPDATE', [unitId]);
      const incident = await repo.incidentInUnit(unitId, incidentId, true);
      if (incident.status !== 'active') throw forceError('警情已归档，不能导入', 'INCIDENT_ARCHIVED', 409);
      const active = await store.query("SELECT * FROM incident_imports WHERE unit_id=$1 AND status IN ('queued','processing') AND expires_at>$2", [unitId, Date.now()]);
      const duplicate = active.rows.find((r) => r.input_hash === inputHash && r.actor_id === actorId && r.incident_id === incidentId);
      if (duplicate) return repo.publicImport(duplicate);
      if (active.rowCount) throw forceError('本单位已有警情正在分析，请稍后再试', 'IMPORT_UNIT_BUSY', 429);
      const recent = await store.query('SELECT count(*)::int AS count FROM incident_imports WHERE unit_id=$1 AND created_at>$2', [unitId, Date.now() - 60000]);
      if (recent.rows[0].count >= 3) throw forceError('导入过于频繁，请稍后重试', 'IMPORT_RATE_LIMITED', 429);
      const id = randomUUID(), now = Date.now();
      if (clean) pages.push({ index: 1, status: 'queued', text: clean });
      else {
        await fs.mkdir(TEMP_DIR, { recursive: true, mode: 0o700 });
        for (let i = 0; i < files.length; i++) {
          const filePath = path.join(TEMP_DIR, `${id}-${i}-${randomUUID()}`);
          await fs.writeFile(filePath, files[i].buffer, { mode: 0o600, flag: 'wx' });
          pages.push({ index: i + 1, status: 'queued', file_path: filePath, ...imageInfo[i] });
        }
      }
      const inserted = await store.query(`INSERT INTO incident_imports(id,unit_id,incident_id,actor_id,actor_name,source,status,input_hash,pages,created_at,updated_at,expires_at)
        VALUES($1,$2,$3,$4,$5,$6,'queued',$7,$8,$9,$9,$10) RETURNING *`, [id,unitId,incidentId,actorId,actorName,clean ? 'text' : 'images', inputHash, JSON.stringify(pages),now,now+MAX_AGE]);
      const prior = await store.query("SELECT id FROM incident_imports WHERE unit_id=$1 AND incident_id=$2 AND input_hash=$3 AND status='applied' ORDER BY applied_at DESC LIMIT 1", [unitId,incidentId,inputHash]);
      return { ...repo.publicImport(inserted.rows[0]), previously_applied_id: prior.rows[0]?.id || null };
    });
  } catch (error) { await deleteImages(pages); throw error; }
}
async function retryTask(scope, indices) {
  if (!Array.isArray(indices) || !indices.length || indices.some((i) => !Number.isInteger(i))) throw forceError('请选择失败图片');
  return store.transaction(async () => {
    await store.query('SELECT id FROM units WHERE id=$1 FOR UPDATE', [scope.unitId]);
    const task = await repo.readImport(scope.unitId,scope.incidentId,scope.actorId,scope.id,true);
    if (!['failed','partial'].includes(task.status) || Number(task.expires_at) <= Date.now()) throw forceError('此任务不可重试', 'IMPORT_NOT_READY', 409);
    const busy = await store.query("SELECT id FROM incident_imports WHERE unit_id=$1 AND status IN ('queued','processing')", [scope.unitId]);
    if (busy.rowCount) throw forceError('本单位已有任务正在分析', 'IMPORT_UNIT_BUSY', 429);
    for (const i of indices) if (!task.pages.some((p) => p.index === i && p.status === 'failed')) throw forceError('只能重试失败图片');
    const pages = task.pages.map((p) => indices.includes(p.index) ? { ...p, status:'queued', error_code:null } : p);
    const { rows } = await store.query("UPDATE incident_imports SET pages=$2,status='queued',generation=generation+1,updated_at=$3,error_code=NULL,lease_until=NULL WHERE id=$1 RETURNING *", [task.id,JSON.stringify(pages),Date.now()]);
    return repo.publicImport(rows[0]);
  });
}
async function cancelTask(scope) {
  const task = await store.transaction(async () => {
    const row = await repo.readImport(scope.unitId,scope.incidentId,scope.actorId,scope.id,true);
    if (row.status === 'applied') throw forceError('已应用的导入不能取消', 'IMPORT_ALREADY_APPLIED',409);
    await store.query("UPDATE incident_imports SET status='cancelled',generation=generation+1,updated_at=$2,lease_until=NULL,pages='[]'::jsonb,draft=NULL WHERE id=$1", [row.id,Date.now()]);
    return row;
  });
  controllers.get(task.id)?.abort();
  await deleteImages(task.pages);
  return { ok:true };
}
const controllers = new Map();
async function claimTask() {
  return store.transaction(async () => {
    const result = await store.query("SELECT * FROM incident_imports WHERE status='queued' AND expires_at>$1 ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1", [Date.now()]);
    const row = result.rows[0];
    if (!row) return null;
    await store.query("UPDATE incident_imports SET status='processing',lease_until=$2,updated_at=$3 WHERE id=$1", [row.id,Date.now()+660000,Date.now()]);
    return row;
  });
}
async function runTask(task, config, extract = extractIncident) {
  const controller = new AbortController();
  controllers.set(task.id,controller);
  const timer = setTimeout(() => controller.abort(),600000);
  timer.unref?.();
  const pages = task.pages;
  let next = 0;
  let persist = Promise.resolve();
  const save = () => {
    const snapshot = JSON.stringify(pages);
    persist = persist.then(() => store.query("UPDATE incident_imports SET pages=$2,updated_at=$3 WHERE id=$1 AND generation=$4 AND status='processing'", [task.id,snapshot,Date.now(),task.generation]));
    return persist;
  };
  try {
    const worker = async () => {
      while (next < pages.length) {
        const page = pages[next++];
        if (page.status === 'succeeded') continue;
        if (page.status !== 'queued') continue;
        page.status = 'processing'; await save();
        try {
          if (controller.signal.aborted) throw forceError('任务超时','IMPORT_TIMEOUT',504);
          const current = await store.query('SELECT status,generation FROM incident_imports WHERE id=$1', [task.id]);
          if (current.rows[0]?.status !== 'processing' || current.rows[0]?.generation !== task.generation) { controller.abort(); return; }
          const options = { apiKey:config.apiKey,baseUrl:config.baseUrl,model:config.chatModel,text:page.text,signal:controller.signal };
          if (page.file_path) {
            const image = await fs.readFile(page.file_path);
            options.imageDataUrl = `data:${page.mime};base64,${image.toString('base64')}`;
          }
          page.result = await extract(options);
          if (page.text) page.result.raw_text = page.text;
          page.status='succeeded'; page.error_code=null;
        } catch (error) {
          page.status='failed'; page.error_code=/^[A-Z0-9_]{1,64}$/.test(error.code || '') ? error.code : 'IMPORT_PAGE_FAILED';
        }
        await save();
      }
    };
    await Promise.all([worker(),worker()]);
    const draft = mergeExtractions(pages);
    draft.forces = await repo.matchForces(task.unit_id,task.incident_id,draft.forces);
    const count = pages.filter((p) => p.status === 'succeeded').length;
    const status = count === pages.length ? 'ready' : count ? 'partial' : 'failed';
    await store.query("UPDATE incident_imports SET status=$2,draft=$3,pages=$4,lease_until=NULL,updated_at=$5 WHERE id=$1 AND generation=$6 AND status='processing'", [task.id,status,JSON.stringify(draft),JSON.stringify(pages),Date.now(),task.generation]);
  } finally { clearTimeout(timer); controllers.delete(task.id); }
}
async function cleanup() {
  // A crashed worker has no active network handle after its lease. Retain page
  // successes and require the user to retry interrupted pages explicitly.
  const interrupted = await store.query("SELECT * FROM incident_imports WHERE status='processing' AND lease_until<$1", [Date.now()]);
  for (const task of interrupted.rows) {
    const pages = task.pages.map((p) => ['queued','processing'].includes(p.status) ? {...p,status:'failed',error_code:'IMPORT_INTERRUPTED'} : p);
    const draft = mergeExtractions(pages);
    draft.forces = await repo.matchForces(task.unit_id,task.incident_id,draft.forces);
    await store.query("UPDATE incident_imports SET status=$2,pages=$3,draft=$4,lease_until=NULL,updated_at=$5 WHERE id=$1 AND status='processing' AND lease_until<$5", [task.id,pages.some((p)=>p.status==='succeeded')?'partial':'failed',JSON.stringify(pages),JSON.stringify(draft),Date.now()]);
  }
  const { rows } = await store.query("SELECT * FROM incident_imports WHERE (expires_at<$1 AND status NOT IN ('applied','cancelled','expired')) OR (status IN ('applied','cancelled','expired') AND EXISTS (SELECT 1 FROM jsonb_array_elements(pages) p WHERE p ? 'file_path'))", [Date.now()]);
  for (const task of rows) {
    await deleteImages(task.pages);
    if (task.status === 'applied') {
      const retained = task.pages.map(({file_path,...page})=>page);
      await store.query("UPDATE incident_imports SET pages=$2 WHERE id=$1 AND status='applied'",[task.id,JSON.stringify(retained)]);
    } else {
      await store.query("UPDATE incident_imports SET status=CASE WHEN status='cancelled' THEN 'cancelled' ELSE 'expired' END,generation=generation+1,updated_at=$2,pages='[]'::jsonb,draft=NULL WHERE id=$1 AND status<>'applied'", [task.id,Date.now()]);
    }
  }
  // Crash between writing an image and committing its task can leave an orphan.
  const files = await fs.readdir(TEMP_DIR).catch(()=>[]);
  for (const file of files) {
    const filePath=path.join(TEMP_DIR,file);
    const stat=await fs.stat(filePath).catch(()=>null);
    if (stat && Date.now()-stat.mtimeMs>MAX_AGE) await fs.unlink(filePath).catch(()=>{});
  }
}
function startWorker(config, onError = ()=>{}) {
  let working=false, closed=false, lastCleanup=0;
  const tick=async()=>{
    if(working || closed) return;
    working=true;
    try {
      if(Date.now()-lastCleanup>60000) { await cleanup(); lastCleanup=Date.now(); }
      const task=await claimTask();
      if(task) await runTask(task,config);
    } catch(error) { onError(error); }
    finally { working=false; }
  };
  const timer=setInterval(tick,1000); timer.unref();
  return ()=>{ closed=true;clearInterval(timer);for(const c of controllers.values()) c.abort(); };
}
module.exports={ TEMP_DIR,validateImage,deleteImages,createTask,retryTask,cancelTask,claimTask,runTask,cleanup,startWorker };
