const { randomUUID } = require('node:crypto');
const { CloudBasePostgrestClient } = require('./cloudbase-postgrest');

const db = new CloudBasePostgrestClient();

const DEFAULT_HOTWORDS = ['龙游大队', '龙游', '龙翔路站', '永安路站', '兴园站', '头车', '两车', '三车', '四车', '内攻', '搜救'];
const DEFAULT_FIREFIGHTERS = [
  '李翔', '盛承华', '楼松超', '徐向相', '柯峰', '祝彪',
  '陆河圣', '洪辰', '沈松鹏', '金志明', '陈俊鹏', '叶华杰', '杨熙豪', '施豪杰', '袁超', '马李臣',
  '邢中本', '何家琦', '余贤耀', '徐莘焕', '杨小杰', '祝徐迁', '方文斌', '徐昊扬', '郑丽文', '郑怡',
  '郑涛', '占鑫涛', '叶健智', '胡海龙', '伊余健', '曹建罡', '马鑫', '徐康', '张烜烨', '李微',
  '储嘉俊', '毛伟', '陈俊安', '赵建平', '吴拥军', '路康清', '毕灵珂', '刘羽杰', '陈鑫', '廖淑明', '毛泽旭',
  '林成成', '程晓波', '郭逸', '蓝程雄', '成帅', '姚肖江', '毕文龙', '周志峰', '吕文建', '刘林辉',
  '齐征臣', '严仕华', '袁友顺', '劳凯董', '方罗进', '马俊', '刘振坤', '贺智成', '丁以强', '易子云',
  '李瑞', '宋宇', '宁成鑫', '甲巴有拉', '吉布小夫', '方梦龙',
  '游方远', '巫垚东', '万自良', '戴晓明', '李志鹏', '徐小龙', '吴鹏晖', '叶程刚', '陈嘉豪', '姚顺',
  '贺官', '孙国彬', '吴志云', '陈子俊', '何金伟', '周子俊', '何哲锴', '徐刚', '姜俊翰', '文闻',
  '张文浩', '宋博韬',
];

function incidentNumberFor(timestamp) {
  const date = new Date(timestamp);
  return date.getFullYear() + '年' + (date.getMonth() + 1) + '月' + date.getDate() + '日' +
    String(date.getHours()).padStart(2, '0') + '时' + String(date.getMinutes()).padStart(2, '0') + '分';
}

function parseJson(value) {
  if (value == null || value === '') return null;
  if (typeof value !== 'string') return value;
  try { return JSON.parse(value); } catch { return value; }
}

function eventWithPayload(row) {
  return row ? { ...row, payload: parseJson(row.payload) } : undefined;
}

function limitOf(value, fallback, maximum) {
  return Math.min(Number(value) || fallback, maximum);
}

function rowOf(rows) {
  return Array.isArray(rows) ? rows[0] : rows;
}

async function insertOne(table, row, options = {}) {
  return rowOf(await db.insert(table, row, options));
}

async function initialize() {
  if (process.env.CLOUDBASE_SKIP_SEED === '1') return;
  const [hotwords, firefighters, stations] = await Promise.all([
    db.select('hotwords', { select: 'id', limit: 1 }),
    db.select('firefighters', { select: 'id', limit: 1 }),
    db.select('stations', { select: 'id', limit: 1 }),
  ]);
  const now = Date.now();
  if (hotwords.length === 0) {
    await db.insert('hotwords', DEFAULT_HOTWORDS.map((word, index) => ({ id: randomUUID(), word, created_at: now + index })), {
      onConflict: 'word', ignoreDuplicates: true,
    });
  }
  if (firefighters.length === 0) {
    await db.insert('firefighters', DEFAULT_FIREFIGHTERS.map((name, index) => ({ id: randomUUID(), name, created_at: now + index })), {
      onConflict: 'name', ignoreDuplicates: true,
    });
  }
  if (stations.length === 0) {
    await db.insert('stations', ['龙翔路站', '永安路站', '兴园站'].map((name) => ({
      id: randomUUID(), name, normalized_name: name.replace(/\s+/g, ''), created_at: now, created_by: 'system',
    })), { onConflict: 'normalized_name', ignoreDuplicates: true });
  }
}

const ready = initialize();

async function listEntries({ activeOnly = false, limit = 500, scene = 'default' } = {}) {
  const filters = { scene };
  if (activeOnly) filters.exited_at = { op: 'is', value: 'null' };
  return db.select('entries', { filters, order: 'entry_at.desc', limit });
}

async function getEntry(id) {
  return db.select('entries', { filters: { id }, single: true });
}

async function createEntry({ id, scene = 'default', name, pressureMpa, durationMin, entryAtMs, exitAtMs, source = 'voice', rawText = null }) {
  const entry = await insertOne('entries', {
    id, scene, name, pressure_mpa: pressureMpa, duration_min: durationMin,
    entry_at: entryAtMs, exit_at: exitAtMs, source, raw_text: rawText, created_at: Date.now(),
  });
  if (pressureMpa != null) await addPressureSample({ entryId: id, scene, name, pressureMpa, reportedAtMs: entryAtMs });
  return entry || getEntry(id);
}

async function markExited(id, exitedAtMs) {
  const result = await db.update('entries', { id }, { exited_at: exitedAtMs });
  return result.rows[0] || getEntry(id);
}

async function findActiveByName(scene, name) {
  return db.select('entries', {
    filters: { scene, name, exited_at: { op: 'is', value: 'null' } },
    order: 'entry_at.asc', limit: 1, single: true,
  });
}

async function updateEntry(id, { name, pressureMpa, durationMin, exitAtMs, consumptionActualLpm }) {
  const values = {};
  if (name != null) values.name = name;
  if (pressureMpa != null) values.pressure_mpa = pressureMpa;
  if (durationMin != null) values.duration_min = durationMin;
  if (exitAtMs != null) values.exit_at = exitAtMs;
  if (consumptionActualLpm != null) values.consumption_actual_lpm = consumptionActualLpm;
  if (Object.keys(values).length === 0) return getEntry(id);
  const result = await db.update('entries', { id }, values);
  return result.rows[0] || getEntry(id);
}

async function addPressureSample({ entryId, scene = 'default', name, pressureMpa, reportedAtMs }) {
  await insertOne('pressure_samples', {
    entry_id: entryId, scene, name, pressure_mpa: pressureMpa, reported_at: reportedAtMs,
  });
}

async function lastPressureSample(entryId) {
  return db.select('pressure_samples', { filters: { entry_id: entryId }, order: 'reported_at.desc', limit: 1, single: true });
}

async function listPressureSamples(entryId, { limit = 20 } = {}) {
  return db.select('pressure_samples', { filters: { entry_id: entryId }, order: 'reported_at.desc', limit });
}

async function listFirefighters() {
  return db.select('firefighters', { select: 'id,name', order: 'created_at.asc' });
}

async function addFirefighter(id, name) {
  return insertOne('firefighters', { id, name, created_at: Date.now() });
}

async function removeFirefighter(id) {
  return (await db.remove('firefighters', { id })).changes;
}

async function listHotwords() {
  return db.select('hotwords', { select: 'id,word', order: 'created_at.asc' });
}

async function addHotword(id, word) {
  return insertOne('hotwords', { id, word, created_at: Date.now() });
}

async function removeHotword(id) {
  return (await db.remove('hotwords', { id })).changes;
}

async function purgeOldExited(days = 7) {
  const cutoff = Date.now() - days * 24 * 3600 * 1000;
  const old = await db.select('entries', { select: 'id', filters: { exited_at: { op: 'lt', value: cutoff } } });
  if (old.length === 0) return 0;
  const ids = old.map((row) => row.id);
  const removed = (await db.remove('entries', { id: { op: 'in', value: ids } })).changes;
  await db.remove('pressure_samples', { entry_id: { op: 'in', value: ids } });
  return removed;
}

async function addLog({ scene = 'default', device = null, opId = null, level = 'info', stage = '', msg = '', data = null }) {
  await insertOne('logs', {
    id: randomUUID(), scene, device, op_id: opId, level, stage,
    msg: String(msg).slice(0, 2000), data: data == null ? null : JSON.stringify(data), created_at: Date.now(),
  });
}

async function listLogs({ scene = 'default', limit = 200, opId = null, device = null } = {}) {
  const filters = { scene };
  if (opId) filters.op_id = opId;
  if (device) filters.device = device;
  return (await db.select('logs', { filters, order: 'created_at.desc', limit: limitOf(limit, 200, 1000) })).map((row) => ({
    ...row, data: parseJson(row.data),
  }));
}

async function clearLogs({ scene = 'default', opId = null } = {}) {
  const filters = { scene };
  if (opId) filters.op_id = opId;
  return (await db.remove('logs', filters)).changes;
}

async function purgeOldLogs(days = 30) {
  return (await db.remove('logs', { created_at: { op: 'lt', value: Date.now() - days * 24 * 3600 * 1000 } })).changes;
}

async function listNotes({ scene = 'default', limit = 500 } = {}) {
  return db.select('notes', { filters: { scene }, order: 'created_at.desc', limit: limitOf(limit, 500, 2000) });
}

async function getNote(id) {
  return db.select('notes', { filters: { id }, single: true });
}

async function createNote({ id, scene = 'default', text, category = '其他', author = '' }) {
  const now = Date.now();
  return insertOne('notes', { id, scene, text, category, author, created_at: now, updated_at: now });
}

async function updateNote(id, { text, category }) {
  const current = await getNote(id);
  if (!current) return undefined;
  const values = { updated_at: Date.now() };
  if (text != null) values.text = text;
  if (category != null) values.category = category;
  const result = await db.update('notes', { id }, values);
  return result.rows[0] || getNote(id);
}

async function deleteNote(id) {
  return (await db.remove('notes', { id })).changes;
}

async function purgeOldNotes(days = 30) {
  return (await db.remove('notes', { created_at: { op: 'lt', value: Date.now() - days * 24 * 3600 * 1000 } })).changes;
}

async function listChatMessages({ scene = 'default', limit = 100 } = {}) {
  return db.select('chat_messages', { filters: { scene }, order: 'created_at.asc', limit: limitOf(limit, 100, 500) });
}

async function createChatMessage({ id, scene = 'default', role, content }) {
  return insertOne('chat_messages', { id, scene, role, content: String(content || '').slice(0, 4000), created_at: Date.now() });
}

async function clearChatMessages(scene = 'default') {
  return (await db.remove('chat_messages', { scene })).changes;
}

async function purgeOldChatMessages(days = 30) {
  return (await db.remove('chat_messages', { created_at: { op: 'lt', value: Date.now() - days * 24 * 3600 * 1000 } })).changes;
}

async function getUserSettings(userId, scene = 'default') {
  const rows = await db.select('user_settings', { filters: { user_id: userId, scene } });
  const settings = {};
  let updatedAt = 0;
  for (const row of rows) {
    settings[row.key] = parseJson(row.value);
    updatedAt = Math.max(updatedAt, Number(row.updated_at) || 0);
  }
  return { settings, updatedAt };
}

async function saveUserSettings(userId, scene = 'default', settings = {}) {
  const now = Date.now();
  const rows = Object.entries(settings).map(([key, value]) => ({
    user_id: userId, scene, key: String(key).slice(0, 64), value: JSON.stringify(value), updated_at: now,
  }));
  if (rows.length > 0) await db.upsert('user_settings', rows, { onConflict: 'user_id,scene,key', select: 'user_id,scene,key,value,updated_at' });
  return getUserSettings(userId, scene);
}

const compatibilityIncidentAliases = new Map();

async function getIncident(id) {
  return db.select('incidents', { filters: { id: String(id || '') }, single: true });
}

async function uniqueIncidentNumber(timestamp) {
  const base = incidentNumberFor(timestamp);
  for (let sequence = 1; sequence < 1000; sequence++) {
    const candidate = `${base}${sequence}#警情`;
    if (!await db.select('incidents', { filters: { number: candidate }, select: 'id', single: true })) return candidate;
  }
  throw new Error('无法生成唯一警情编号');
}

async function createIncident({ id = randomUUID(), createdAt = Date.now(), createdBy = null } = {}) {
  const created = Number(createdAt) || Date.now();
  return insertOne('incidents', {
    id, number: await uniqueIncidentNumber(created), status: 'active', created_at: created,
    last_activity_at: created, created_by: createdBy,
  });
}

async function ensureIncidentId(value) {
  const raw = String(value || '').trim();
  if (!raw) throw new Error('缺少警情 ID');
  if (await getIncident(raw)) return raw;
  const byNumber = await db.select('incidents', { filters: { number: raw }, select: 'id', single: true });
  if (byNumber) return byNumber.id;
  if (compatibilityIncidentAliases.has(raw)) return compatibilityIncidentAliases.get(raw);
  const incident = await createIncident({ createdBy: 'compatibility' });
  compatibilityIncidentAliases.set(raw, incident.id);
  return incident.id;
}

async function listIncidents(status = null) {
  const filters = status ? { status } : {};
  const rows = await db.select('incidents', { filters });
  return rows.sort((a, b) => {
    if (status === 'archived') return Number(b.archived_at || 0) - Number(a.archived_at || 0);
    if (status === 'active') return Number(b.last_activity_at || 0) - Number(a.last_activity_at || 0);
    const activeDiff = (a.status === 'active' ? 0 : 1) - (b.status === 'active' ? 0 : 1);
    return activeDiff || Number(b.archived_at || b.last_activity_at || 0) - Number(a.archived_at || a.last_activity_at || 0);
  });
}

async function findRecentActiveIncident(createdAfter) {
  const candidates = await db.select('incidents', {
    filters: { status: 'active', created_at: { op: 'gte', value: Number(createdAfter) || 0 } },
    order: 'created_at.desc', limit: 100,
  });
  for (const incident of candidates) {
    const event = await db.select('incident_events', {
      filters: { incident_id: incident.id, type: 'incident_created' }, select: 'id', limit: 1, single: true,
    });
    if (event) return incident;
  }
  return null;
}

async function updateIncidentTitle(id, title, { expectedVersion = null } = {}) {
  const current = await getIncident(id);
  if (!current) return null;
  if (expectedVersion != null && Number(expectedVersion) !== Number(current.version)) {
    const error = new Error('警情已被其他用户修改，请刷新后重试');
    error.code = 'VERSION_CONFLICT';
    throw error;
  }
  const clean = title == null ? null : String(title).trim().slice(0, 120) || null;
  const result = await db.update('incidents', { id, version: current.version }, { title: clean, version: Number(current.version) + 1 });
  if (result.rows.length === 0 && expectedVersion != null) {
    const error = new Error('警情已被其他用户修改，请刷新后重试');
    error.code = 'VERSION_CONFLICT';
    throw error;
  }
  return result.rows[0] || getIncident(id);
}

async function setIncidentSuggestedTitle(id, title) {
  const clean = title == null ? null : String(title).trim().slice(0, 120) || null;
  const result = await db.update('incidents', { id }, { suggested_title: clean });
  return result.rows[0] || getIncident(id);
}

async function touchIncidentActivity(id, at = Date.now()) {
  const current = await getIncident(id);
  if (!current || current.status !== 'active') return current;
  const value = Math.max(Number(current.last_activity_at) || 0, Number(at) || Date.now());
  const result = await db.update('incidents', { id }, { last_activity_at: value });
  return result.rows[0] || getIncident(id);
}

async function unresolvedActiveCount(id) {
  return (await db.select('entries', { filters: { scene: id, exited_at: { op: 'is', value: 'null' } }, select: 'id' })).length;
}

async function archiveIncident(id, { archivedBy = null, now = Date.now(), auto = false } = {}) {
  const current = await getIncident(id);
  if (!current) return null;
  if (current.status === 'archived') return current;
  const result = await db.update('incidents', { id, status: 'active' }, {
    status: 'archived', archived_at: now, archived_by: archivedBy, auto_archived: auto ? 1 : 0,
    unresolved_active_count: await unresolvedActiveCount(id), version: Number(current.version) + 1,
  });
  return result.rows[0] || getIncident(id);
}

async function archiveStaleIncidents({ now = Date.now(), inactivityMs = 12 * 3600 * 1000 } = {}) {
  const stale = await db.select('incidents', {
    filters: { status: 'active', last_activity_at: { op: 'lte', value: now - inactivityMs } }, select: 'id',
  });
  for (const row of stale) {
    const archived = await archiveIncident(row.id, { archivedBy: 'system', now, auto: true });
    await appendIncidentEvent({
      incidentId: row.id, type: 'incident_archived', occurredAt: now, recordedAt: now,
      actorName: '系统', source: 'online', payload: { auto: true, unresolved_active_count: archived.unresolved_active_count },
    });
  }
  return stale.length;
}

async function getIncidentEvent(id) {
  return eventWithPayload(await db.select('incident_events', { filters: { id }, single: true }));
}

async function getIncidentEventByClientOp(clientOpId) {
  if (!clientOpId) return undefined;
  return eventWithPayload(await db.select('incident_events', { filters: { client_op_id: clientOpId }, single: true }));
}

async function appendIncidentEvent({
  id = randomUUID(), incidentId, type, occurredAt = Date.now(), recordedAt = Date.now(),
  actorDeviceId = null, actorName = null, source = 'online', clientOpId = null,
  payload = null, revisionOf = null, voidedAt = null,
} = {}) {
  if (clientOpId) {
    const duplicate = await getIncidentEventByClientOp(clientOpId);
    if (duplicate) return duplicate;
  }
  try {
    const row = await insertOne('incident_events', {
      id, incident_id: incidentId, type, occurred_at: Number(occurredAt) || Date.now(),
      recorded_at: Number(recordedAt) || Date.now(), actor_device_id: actorDeviceId, actor_name: actorName,
      source, client_op_id: clientOpId, payload: payload == null ? null : JSON.stringify(payload),
      revision_of: revisionOf, voided_at: voidedAt,
    });
    return eventWithPayload(row || await getIncidentEvent(id));
  } catch (error) {
    if (clientOpId && error.status === 409) return getIncidentEventByClientOp(clientOpId);
    throw error;
  }
}

async function listIncidentEvents(incidentId, { limit = 2000 } = {}) {
  const rows = await db.select('incident_events', {
    filters: { incident_id: incidentId }, order: 'occurred_at.desc,recorded_at.desc', limit: limitOf(limit, 2000, 5000),
  });
  return rows.map(eventWithPayload);
}

async function listStations() {
  return db.select('stations', { select: 'id,name,created_at,created_by', order: 'name.asc' });
}

async function addStation({ name, createdBy = null } = {}) {
  const clean = String(name || '').trim().slice(0, 80);
  const normalized = clean.replace(/消防救援站$/, '站').replace(/\s+/g, '');
  if (!normalized) throw new Error('消防站名称不能为空');
  const existing = await db.select('stations', { filters: { normalized_name: normalized }, single: true });
  if (existing) return existing;
  return insertOne('stations', { id: randomUUID(), name: clean, normalized_name: normalized, created_at: Date.now(), created_by: createdBy });
}

async function listIncidentForces(incidentId) {
  return db.select('incident_forces', { filters: { incident_id: incidentId }, order: 'station_name.asc' });
}

async function getIncidentForce(id) {
  return db.select('incident_forces', { filters: { id }, single: true });
}

function forceCount(value) {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 0 || number > 999) throw new Error('参战车辆或人员数量无效');
  return number;
}

async function upsertIncidentForce({ id = randomUUID(), incidentId, stationId = null, stationName, vehicleCount = 0, personnelCount = 0, expectedVersion = null } = {}) {
  const cleanName = String(stationName || '').trim().slice(0, 80);
  if (!cleanName) throw new Error('消防站名称不能为空');
  const vehicles = forceCount(vehicleCount);
  const personnel = forceCount(personnelCount);
  const current = await db.select('incident_forces', { filters: { incident_id: incidentId, station_name: cleanName }, single: true });
  if (current && expectedVersion != null && Number(expectedVersion) !== Number(current.version)) {
    const error = new Error('该消防站的参战力量已被其他用户修改，请刷新后重试');
    error.code = 'VERSION_CONFLICT';
    throw error;
  }
  if (current) {
    const result = await db.update('incident_forces', { id: current.id, version: current.version }, {
      station_id: stationId, vehicle_count: vehicles, personnel_count: personnel,
      updated_at: Date.now(), version: Number(current.version) + 1,
    });
    if (result.rows.length === 0) {
      const error = new Error('该消防站的参战力量已被其他用户修改，请刷新后重试');
      error.code = 'VERSION_CONFLICT';
      throw error;
    }
    return result.rows[0];
  }
  const now = Date.now();
  return insertOne('incident_forces', {
    id, incident_id: incidentId, station_id: stationId, station_name: cleanName,
    vehicle_count: vehicles, personnel_count: personnel, created_at: now, updated_at: now, version: 1,
  });
}

async function deleteIncidentForce(id) {
  return (await db.remove('incident_forces', { id })).changes;
}

async function getDeviceProfile(deviceId) {
  const id = String(deviceId || '');
  const row = await db.select('device_profiles', { filters: { device_id: id }, single: true });
  return row || { device_id: id, real_name: '', updated_at: 0 };
}

async function saveDeviceProfile(deviceId, realName) {
  const id = String(deviceId || '');
  const name = String(realName || '').trim().slice(0, 32);
  const row = await insertOne('device_profiles', { device_id: id, real_name: name, updated_at: Date.now() }, {
    onConflict: 'device_id',
  });
  return row || getDeviceProfile(id);
}

async function dedupeLegacyIncidentEvents() {
  // 新 CloudBase 数据库不导入旧 SQLite 事件；保留此接口以兼容现有维护调用。
  return 0;
}

module.exports = {
  getIncident, createIncident, listIncidents, findRecentActiveIncident, updateIncidentTitle,
  setIncidentSuggestedTitle, touchIncidentActivity, archiveIncident, archiveStaleIncidents,
  appendIncidentEvent, getIncidentEvent, getIncidentEventByClientOp, listIncidentEvents,
  dedupeLegacyIncidentEvents, listStations, addStation, listIncidentForces, getIncidentForce,
  upsertIncidentForce, deleteIncidentForce, getDeviceProfile, saveDeviceProfile, listEntries,
  getEntry, createEntry, markExited, findActiveByName, updateEntry, addPressureSample,
  lastPressureSample, listPressureSamples, listFirefighters, addFirefighter, removeFirefighter,
  listHotwords, addHotword, removeHotword, purgeOldExited, addLog, listLogs, clearLogs,
  purgeOldLogs, listNotes, getNote, createNote, updateNote, deleteNote, purgeOldNotes,
  listChatMessages, createChatMessage, clearChatMessages, purgeOldChatMessages, getUserSettings,
  saveUserSettings, ready,
};
