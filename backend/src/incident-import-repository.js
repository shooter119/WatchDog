const { randomUUID, createHash } = require('node:crypto');
const store = require('./postgres-store');
const db = require('./db-postgres');
const { forceError } = require('./force-fields');
const { validateDetails, normalizeStationName } = require('./incident-extraction');

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  return value;
}
function digest(value) { return createHash('sha256').update(typeof value === 'string' || Buffer.isBuffer(value) ? value : JSON.stringify(canonical(value))).digest('hex'); }
async function incidentInUnit(unitId, incidentId, lock = false) {
  const { rows } = await store.query(`SELECT * FROM incidents WHERE id=$1 AND unit_id=$2${lock ? ' FOR UPDATE' : ''}`, [incidentId, unitId]);
  if (!rows[0]) throw forceError('警情不存在', 'IMPORT_NOT_FOUND', 404);
  return rows[0];
}
async function details(unitId, incidentId) {
  await incidentInUnit(unitId, incidentId);
  const { rows } = await store.query('SELECT * FROM incident_details WHERE incident_id=$1 AND unit_id=$2', [incidentId, unitId]);
  return rows[0] || { incident_id: incidentId, unit_id: unitId, data: {}, version: 0 };
}
async function listStations(unitId, includeInactive = false) {
  const { rows } = await store.query(`SELECT s.*, COALESCE((SELECT json_agg(n.normalized_name ORDER BY n.normalized_name) FROM unit_station_names n WHERE n.station_id=s.id AND NOT n.is_primary), '[]'::json) AS aliases FROM unit_stations s WHERE s.unit_id=$1 ${includeInactive ? '' : 'AND s.active'} ORDER BY s.name`, [unitId]);
  return rows;
}
async function addStation(unitId, name, actorId) {
  const clean = String(name || '').trim();
  const normalized = normalizeStationName(clean);
  if (!normalized || clean.length > 80) throw forceError('队伍名称须为1至80字');
  return store.transaction(async () => {
    await store.query('SELECT id FROM units WHERE id=$1 FOR UPDATE', [unitId]);
    const { rows: existing } = await store.query('SELECT s.* FROM unit_station_names n JOIN unit_stations s ON s.id=n.station_id WHERE n.unit_id=$1 AND n.normalized_name=$2', [unitId, normalized]);
    if (existing[0]) {
      if (!existing[0].active) throw forceError('常用队伍已停用，请联系管理员', 'STATION_INACTIVE', 409);
      return existing[0];
    }
    const id = randomUUID(), now = Date.now();
    const { rows } = await store.query('INSERT INTO unit_stations(id, unit_id, name, created_at, updated_at, created_by) VALUES ($1,$2,$3,$4,$4,$5) RETURNING *', [id, unitId, clean, now, actorId]);
    await store.query('INSERT INTO unit_station_names(unit_id, normalized_name, station_id, is_primary) VALUES ($1,$2,$3,TRUE)', [unitId, normalized, id]);
    const directory = await store.query('UPDATE units SET directory_version=directory_version+1 WHERE id=$1 RETURNING directory_version', [unitId]);
    await db.appendSyncEvent({ unitId, eventType: 'directory.updated', aggregateId: id, payload: { id, version: String(directory.rows[0].directory_version) } });
    return rows[0];
  });
}
async function updateStation(unitId, id, patch, actorId) {
  return store.transaction(async () => {
    await store.query('SELECT id FROM units WHERE id=$1 FOR UPDATE', [unitId]);
    const { rows } = await store.query('SELECT * FROM unit_stations WHERE unit_id=$1 AND id=$2 FOR UPDATE', [unitId, id]);
    const current = rows[0];
    if (!current) throw forceError('队伍不存在', 'STATION_NOT_FOUND', 404);
    if (patch.expected_version !== current.version) throw forceError('常用队伍已修改，请刷新', 'VERSION_CONFLICT', 409);
    const name = patch.name === undefined ? current.name : String(patch.name).trim();
    if (!name || name.length > 80) throw forceError('队伍名称须为1至80字');
    if (patch.active !== undefined && typeof patch.active !== 'boolean') throw forceError('队伍状态无效');
    const { rows: oldNames } = await store.query('SELECT normalized_name FROM unit_station_names WHERE station_id=$1 AND NOT is_primary', [id]);
    const aliases = patch.aliases ?? oldNames.map((item) => item.normalized_name);
    if (!Array.isArray(aliases) || aliases.length > 20 || aliases.some((item) => typeof item !== 'string' || !item.trim() || item.length > 80)) throw forceError('别名格式无效');
    const normalized = normalizeStationName(name);
    const names = [...new Set([normalized, ...aliases.map(normalizeStationName)])];
    const collision = await store.query('SELECT station_id FROM unit_station_names WHERE unit_id=$1 AND normalized_name=ANY($2::text[]) AND station_id<>$3', [unitId, names, id]);
    if (collision.rowCount) throw forceError('名称或别名已用于其他队伍', 'STATION_NAME_CONFLICT', 409);
    await store.query('DELETE FROM unit_station_names WHERE station_id=$1', [id]);
    for (const item of names) await store.query('INSERT INTO unit_station_names(unit_id, normalized_name, station_id, is_primary) VALUES ($1,$2,$3,$4)', [unitId, item, id, item === normalized]);
    const changed = await store.query('UPDATE unit_stations SET name=$3, active=$4, version=version+1, updated_at=$5 WHERE unit_id=$1 AND id=$2 RETURNING *', [unitId, id, name, patch.active ?? current.active, Date.now()]);
    // Audit changes without copying phone numbers or imported report text.
    await store.query('INSERT INTO unit_station_history(id, unit_id, station_id, actor_id, before_data, after_data, created_at) VALUES ($1,$2,$3,$4,$5,$6,$7)', [randomUUID(), unitId, id, actorId, JSON.stringify({ ...current, aliases: oldNames.map((n) => n.normalized_name) }), JSON.stringify({ ...changed.rows[0], aliases }), Date.now()]);
    const directory = await store.query('UPDATE units SET directory_version=directory_version+1 WHERE id=$1 RETURNING directory_version', [unitId]);
    await db.appendSyncEvent({ unitId, eventType: 'directory.updated', aggregateId: id, payload: { id, version: String(directory.rows[0].directory_version) } });
    return changed.rows[0];
  });
}
function stationDistance(a,b) {
  let previous=Array.from({length:b.length+1},(_,i)=>i);
  for(let i=1;i<=a.length;i++) {
    const next=[i];
    for(let j=1;j<=b.length;j++) next[j]=Math.min(next[j-1]+1,previous[j]+1,previous[j-1]+(a[i-1]===b[j-1]?0:1));
    previous=next;
  }
  return previous[b.length];
}
async function matchForces(unitId, incidentId, forces) {
  const current = await db.listIncidentForces(incidentId);
  const common = await listStations(unitId);
  const global = await db.listStations();
  return forces.map((force) => {
    const key = normalizeStationName(force.station_name);
    let target = current.find((item) => normalizeStationName(item.station_name) === key);
    const unit = common.find((item) => normalizeStationName(item.name) === key || item.aliases.includes(key));
    const system = global.find((item) => normalizeStationName(item.name) === key);
    target ||= current.find((item) => (unit && item.unit_station_id === unit.id) || (system && item.station_id === system.id));
    return { ...force, match: target ? 'current' : unit ? 'unit' : system ? 'system' : 'unmatched',
      target_force_id: target?.id || null, expected_version: target?.version || null,
      unit_station_id: unit?.id || target?.unit_station_id || null, station_id: system?.id || target?.station_id || null,
      matched_name: target?.station_name || unit?.name || system?.name || null,
      matched_quantity: target ? require('./force-fields').forceQuantityLabel(target) : null,
      candidates: target || unit || system ? [] : [...current,...common,...global]
        .filter((item,index,all)=>all.findIndex((s)=>(s.station_name||s.name)===(item.station_name||item.name))===index)
        .map((item)=>({name:item.station_name||item.name,distance:stationDistance(key,normalizeStationName(item.station_name||item.name))}))
        .filter((item)=>item.distance<=Math.max(1,Math.floor(key.length/4)))
        .sort((a,b)=>a.distance-b.distance).slice(0,3).map(({name})=>({name})),
    };
  });
}
async function readImport(unitId, incidentId, actorId, id, lock = false) {
  const { rows } = await store.query(`SELECT * FROM incident_imports WHERE id=$1 AND unit_id=$2 AND incident_id=$3 AND actor_id=$4${lock ? ' FOR UPDATE' : ''}`, [id, unitId, incidentId, actorId]);
  if (!rows[0]) throw forceError('导入记录不存在', 'IMPORT_NOT_FOUND', 404);
  return rows[0];
}
function publicImport(row) {
  const { actor_id, actor_name, unit_id, lease_until, apply_hash, input_hash, ...result } = row;
  result.pages = row.pages.map(({ file_path, ...page }) => page);
  return result;
}
function detailPatch(raw, current = {}) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw forceError('警情资料格式无效');
  const validated = validateDetails(raw);
  const patch = Object.fromEntries(Object.keys(raw).filter((key) => Object.hasOwn(validated, key)).map((key) => [key, validated[key]]));
  return { ...current, ...patch };
}
async function applyImport({ unitId, incidentId, actorId, actorName, importId, opId, body }) {
  if (!opId || opId.length > 128) throw forceError('缺少有效操作ID');
  const hash = digest({ importId, incidentId, body });
  return store.transaction(async () => {
    // Consistent lock order: unit -> incident -> task -> detail -> forces.
    await store.query('SELECT id FROM units WHERE id=$1 FOR UPDATE', [unitId]);
    const incident = await incidentInUnit(unitId, incidentId, true);
    const task = await readImport(unitId, incidentId, actorId, importId, true);
    const previous = await db.getOperation(unitId, opId);
    if (previous) {
      if (previous.request_hash !== hash || previous.operation_type !== 'incident_import') throw forceError('同一操作ID的内容不一致', 'CLIENT_OP_ID_CONFLICT', 409);
      if (task.status === 'applied' && task.apply_op_id === opId && task.apply_hash === hash) return task.applied_result;
      throw forceError('操作处理中或操作ID已使用', 'OPERATION_IN_PROGRESS', 409);
    }
    if (incident.status !== 'active') throw forceError('警情已归档，不能导入', 'INCIDENT_ARCHIVED', 409);
    if (!['ready', 'partial'].includes(task.status) || Number(task.expires_at) <= Date.now()) throw forceError('导入草稿不可应用，请重新分析', 'IMPORT_NOT_READY', 409);
    if ((task.status === 'partial' || task.draft?.incomplete) && body.accept_incomplete !== true) throw forceError('请确认部分图片未识别，资料可能不完整');
    if (task.draft?.details?.multiple_incidents && !Number.isInteger(body.selected_page)) throw forceError('请选定单起警情后再应用');
    if (body.selected_page !== undefined && !task.pages.some((p) => p.index === body.selected_page && p.status === 'succeeded')) throw forceError('所选警情页无效');
    if (task.pages.find((p) => p.index === body.selected_page)?.result?.multiple_incidents) throw forceError('所选图片仍包含多起警情，请先编辑提取文字，仅保留本次警情');
    if (task.draft?.conflicts?.length && body.conflicts_reviewed !== true) throw forceError('请核对识别冲突');
    if (body.expected_incident_version !== Number(incident.version)) throw forceError('警情名称已更新，请核对后重试', 'VERSION_CONFLICT', 409);
    const current = await details(unitId, incidentId);
    if (body.expected_details_version !== current.version) throw forceError('警情资料已更新，请核对后重试', 'VERSION_CONFLICT', 409);
    if (!Array.isArray(body.forces) || body.forces.length > 60) throw forceError('力量登记格式无效');
    await db.beginOperation({ unitId, clientOpId: opId, incidentId, operationType: 'incident_import', requestHash: hash, actorDeviceId: actorId, actorName });
    const now = Date.now();
    const data = detailPatch(body.details || {}, current.data);
    const version = current.version + 1;
    await store.query('INSERT INTO incident_details(incident_id, unit_id, data, version, updated_at, updated_by) VALUES ($1,$2,$3,$4,$5,$6) ON CONFLICT(incident_id) DO UPDATE SET data=EXCLUDED.data, version=EXCLUDED.version, updated_at=EXCLUDED.updated_at, updated_by=EXCLUDED.updated_by', [incidentId, unitId, JSON.stringify(data), version, now, actorId]);
    await store.query('INSERT INTO incident_detail_history(id, incident_id, unit_id, import_id, before_data, after_data, actor_id, created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8)', [randomUUID(), incidentId, unitId, importId, JSON.stringify(current.data), JSON.stringify(data), actorId, now]);
    if (body.replace_title === true) {
      const title = String(body.title || '').trim();
      if (!title || title.length > 80) throw forceError('警情名称须为1至80字');
      await db.updateIncidentTitle(incidentId, title, { expectedVersion: Number(incident.version) });
    }
    const targets = new Set();
    const names = new Set();
    const saved = [];
    for (const item of body.forces) {
      if (!item || typeof item.station_name !== 'string') throw forceError('队伍名称无效');
      const key = normalizeStationName(item.station_name);
      if (names.has(key)) throw forceError('本次导入存在重复队伍，请先合并');
      names.add(key);
      const target = item.target_force_id ? await db.getIncidentForce(item.target_force_id) : null;
      if (item.target_force_id && (!target || target.incident_id !== incidentId)) throw forceError('匹配的力量不存在', 'FORCE_NOT_FOUND', 404);
      if (target && (targets.has(target.id) || item.expected_version !== target.version)) throw forceError('力量匹配重复或记录已更新', 'VERSION_CONFLICT', 409);
      if (target) targets.add(target.id);
      if (!target) {
        const existing = (await db.listIncidentForces(incidentId)).find((f) => normalizeStationName(f.station_name) === key);
        if (existing) throw forceError('该队伍已登记，请重新匹配', 'FORCE_NAME_CONFLICT', 409);
      }
      let unitStationId = item.unit_station_id || null;
      if (item.save_common === true) unitStationId = (await addStation(unitId, item.station_name, actorId)).id;
      if (unitStationId && !(await store.query('SELECT id FROM unit_stations WHERE id=$1 AND unit_id=$2 AND active', [unitStationId, unitId])).rowCount) throw forceError('常用队伍不存在或已停用', 'STATION_NOT_FOUND', 404);
      if (item.station_id && !(await store.query('SELECT id FROM stations WHERE id=$1', [item.station_id])).rowCount) throw forceError('预设队伍不存在');
      const force = await db.upsertIncidentForce({ id: target?.id || randomUUID(), updateOnly: !!target, incidentId,
        stationName: item.station_name, stationId: item.station_id || null, unitStationId,
        vehicleCount: item.vehicle_count, personnelCount: item.personnel_count,
        vehicleCountKnown: item.vehicle_count_known, personnelCountKnown: item.personnel_count_known,
        expectedVersion: target?.version });
      const status = ['dispatched','mobilized','unknown'].includes(item.deployment_status) ? item.deployment_status : 'unknown';
      await store.query('UPDATE incident_forces SET unit_station_id=$2, deployment_status=$3, information_source=$4 WHERE id=$1', [force.id, unitStationId, status, 'import']);
      saved.push(await db.getIncidentForce(force.id));
    }
    await db.touchIncidentActivity(incidentId, now);
    const event = await db.appendIncidentEvent({ incidentId, type: 'incident_import_applied', actorDeviceId: actorId, actorName, clientOpId: opId, payload: { import_id: importId, force_count: saved.length, details_version: version } });
    const updatedIncident = { ...await db.getIncident(incidentId, { unitId }),
      info: Object.fromEntries(['original_category','specific_type','location','received_at'].filter((key) => data[key]).map((key) => [key,data[key]])) };
    const allForces = await db.listIncidentForces(incidentId);
    const sync = await db.appendSyncEvent({ unitId, incidentId, eventType: 'import.applied', aggregateId: importId, payload: { incident: updatedIncident, forces: allForces, details_version: version, details: { incident_id: incidentId, unit_id: unitId, data, version, updated_at: now } } });
    await db.appendSyncEvent({ unitId, eventType: 'incident.updated', aggregateId: incidentId, payload: updatedIncident });
    const result = { import_id: importId, incident: updatedIncident, details_version: version, force_ids: saved.map((f) => f.id), event_id: sync.event_id };
    await store.query("UPDATE incident_imports SET status='applied', applied_at=$2, updated_at=$2, apply_op_id=$3, apply_hash=$4, applied_result=$5 WHERE id=$1", [importId, now, opId, hash, JSON.stringify(result)]);
    await db.completeOperation({ unitId, clientOpId: opId, incidentId, requestHash: hash, result: { import_id: importId }, eventId: event.id });
    return result;
  });
}
module.exports = { digest, incidentInUnit, details, listStations, addStation, updateStation, matchForces, readImport, publicImport, detailPatch, applyImport };

async function updateDetails({unitId,incidentId,actorId,actorName,opId,body}) {
  if(!opId || opId.length>128) throw forceError('缺少有效操作ID');
  const hash=digest({incidentId,body,kind:'details'});
  return store.transaction(async()=>{
    const incident=await incidentInUnit(unitId,incidentId,true);
    const previous=await db.getOperation(unitId,opId);
    if(previous) {
      if(previous.request_hash!==hash || previous.operation_type!=='incident_details') throw forceError('操作ID内容冲突','CLIENT_OP_ID_CONFLICT',409);
      return typeof previous.result_json === 'string' ? JSON.parse(previous.result_json) : previous.result_json;
    }
    if(incident.status!=='active') throw forceError('警情已归档','INCIDENT_ARCHIVED',409);
    const current=await details(unitId,incidentId);
    if(body.expected_version!==current.version) throw forceError('警情资料已修改，请刷新','VERSION_CONFLICT',409);
    const data=detailPatch(body.data,current.data),now=Date.now(),version=current.version+1;
    await db.beginOperation({unitId,clientOpId:opId,incidentId,operationType:'incident_details',requestHash:hash,actorDeviceId:actorId,actorName});
    await store.query('INSERT INTO incident_details(incident_id,unit_id,data,version,updated_at,updated_by) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(incident_id) DO UPDATE SET data=EXCLUDED.data,version=EXCLUDED.version,updated_at=EXCLUDED.updated_at,updated_by=EXCLUDED.updated_by',[incidentId,unitId,JSON.stringify(data),version,now,actorId]);
    await store.query('INSERT INTO incident_detail_history(id,incident_id,unit_id,before_data,after_data,actor_id,created_at) VALUES($1,$2,$3,$4,$5,$6,$7)',[randomUUID(),incidentId,unitId,JSON.stringify(current.data),JSON.stringify(data),actorId,now]);
    const event=await db.appendIncidentEvent({incidentId,type:'incident_details_updated',actorDeviceId:actorId,actorName,clientOpId:opId,payload:{details_version:version}});
    await db.touchIncidentActivity(incidentId,now);
    await db.appendSyncEvent({unitId,incidentId,eventType:'details.updated',payload:{incident_id:incidentId,unit_id:unitId,data,version,updated_at:now}});
    const result={ok:true,version};
    await db.completeOperation({unitId,clientOpId:opId,incidentId,requestHash:hash,result,eventId:event.id});
    return result;
  });
}
async function mergeForces({unitId,incidentId,actorId,actorName,opId,body}) {
  if(!opId || opId.length>128) throw forceError('缺少有效操作ID');
  const hash=digest({incidentId,body,kind:'merge'});
  return store.transaction(async()=>{
    const incident=await incidentInUnit(unitId,incidentId,true);
    const previous=await db.getOperation(unitId,opId);
    if(previous) {
      if(previous.request_hash!==hash || previous.operation_type!=='force_merge') throw forceError('操作ID内容冲突','CLIENT_OP_ID_CONFLICT',409);
      return typeof previous.result_json === 'string' ? JSON.parse(previous.result_json) : previous.result_json;
    }
    if(incident.status!=='active') throw forceError('警情已归档','INCIDENT_ARCHIVED',409);
    const source=await db.getIncidentForce(body.source_id),target=await db.getIncidentForce(body.target_id);
    if(!source || !target || source.id===target.id || source.incident_id!==incidentId || target.incident_id!==incidentId) throw forceError('待合并的力量不存在','FORCE_NOT_FOUND',404);
    if(source.version!==body.source_version || target.version!==body.target_version) throw forceError('力量已修改，请刷新','VERSION_CONFLICT',409);
    if(typeof body.vehicle_count_known!=='boolean' || typeof body.personnel_count_known!=='boolean') throw forceError('请明确最终数量或标记待补充');
    await db.beginOperation({unitId,clientOpId:opId,incidentId,operationType:'force_merge',requestHash:hash,actorDeviceId:actorId,actorName});
    const merged=await db.upsertIncidentForce({id:target.id,updateOnly:true,incidentId,stationName:target.station_name,expectedVersion:target.version,
      vehicleCount:body.vehicle_count,personnelCount:body.personnel_count,vehicleCountKnown:body.vehicle_count_known,personnelCountKnown:body.personnel_count_known});
    const deleted=await store.query('DELETE FROM incident_forces WHERE id=$1 AND version=$2',[source.id,source.version]);
    if(!deleted.rowCount) throw forceError('力量已修改，请刷新','VERSION_CONFLICT',409);
    const event=await db.appendIncidentEvent({incidentId,type:'forces_merged',actorDeviceId:actorId,actorName,clientOpId:opId,payload:{source_id:source.id,target_id:target.id,before:[source,target],after:merged}});
    await db.touchIncidentActivity(incidentId);
    await db.appendSyncEvent({unitId,incidentId,eventType:'force.deleted',aggregateId:source.id,payload:{id:source.id}});
    await db.appendSyncEvent({unitId,incidentId,eventType:'force.upserted',aggregateId:target.id,payload:merged});
    const result={ok:true,id:target.id};
    await db.completeOperation({unitId,clientOpId:opId,incidentId,requestHash:hash,result,eventId:event.id});
    return result;
  });
}
module.exports.updateDetails=updateDetails;
module.exports.mergeForces=mergeForces;
