const { sanitizeOfficialStatus, sanitizeCoordinates } = require('./police-api-service');
const { normalizeStationName } = require('./incident-extraction');

const ALWAYS_AUTHORITATIVE_FIELDS = [
  'incident_status',
  'dispatch_summary',
  'dispatch_vehicles',
  'dispatch_stations',
  'main_station',
];

const MERGEABLE_TEXT_FIELDS = [
  'level',
  'trapped',
  'injured',
  'hazardous_materials',
  'situation',
  'location',
  'administrative_area',
  'specific_type',
  'latitude',
  'longitude',
];

function cleanStr(value) {
  if (value == null) return '';
  return String(value).trim();
}

function stableJson(value) {
  if (value == null) return '';
  try {
    return JSON.stringify(value);
  } catch (_) {
    return '';
  }
}

/**
 * 将上游官方警情记录投影为与 incident_details.data 对齐的候选增量字段。
 */
function buildUpstreamDetailCandidates(item) {
  if (!item || typeof item !== 'object') return {};
  const coords = sanitizeCoordinates(item.latitude, item.longitude);
  const officialStatus =
    sanitizeOfficialStatus(item.official_status) ||
    sanitizeOfficialStatus(item.incident_status);
  const location = cleanStr(item.location_display || item.crime_address);
  const situation = cleanStr(item.situation_detail || item.incident_describe);
  const contacts = Array.isArray(item.contacts) && item.contacts.length > 0
    ? item.contacts
    : null;

  return {
    incident_status: officialStatus,
    dispatch_summary: cleanStr(item.dispatch_summary),
    dispatch_vehicles: cleanStr(item.dispatch_vehicle),
    dispatch_stations: cleanStr(item.dispatch_organization),
    main_station: cleanStr(item.squadron_name),
    level: cleanStr(item.incident_level),
    trapped: cleanStr(item.trapped),
    injured: cleanStr(item.injured),
    hazardous_materials: cleanStr(item.hazardous_materials),
    situation,
    location,
    administrative_area: cleanStr(item.district_name),
    specific_type: cleanStr(item.specific_type || item.disposal_object_name),
    latitude: cleanStr(coords.latitude),
    longitude: cleanStr(coords.longitude),
    contacts,
  };
}

/**
 * 计算上游警情变化到已建档 incident_details.data 的安全增量补丁。
 *
 * 合并原则（人工优先、绝不清空、增量演进）：
 * 1. `_manual_fields` 中记录的人工编辑字段永不被覆盖；
 * 2. 上游为空值时永不清空现有字段；
 * 3. `incident_status` 及派警汇总字段默认随上游权威演进；
 * 4. 其余灾情字段：现有为空则补齐；否则仅当「与上次同步基准一致（未被人工改过）」
 *    或「历史未记录基准但从未被人工编辑过（version <= 1 或上次也是 police_api_sync）」时更新。
 */
function computeExternalDetailSyncPatch(currentData = {}, upstreamItem = {}, meta = {}) {
  const current = currentData && typeof currentData === 'object' ? currentData : {};
  const candidates = buildUpstreamDetailCandidates(upstreamItem);
  const manualFields = new Set(
    Array.isArray(current._manual_fields)
      ? current._manual_fields.map((k) => String(k || '').trim()).filter(Boolean)
      : [],
  );
  const prevSynced =
    current._external_synced && typeof current._external_synced === 'object'
      ? current._external_synced
      : null;
  const hasPrevSynced = prevSynced !== null && Object.keys(prevSynced).length > 0;
  const version = Number(meta.version) || 0;
  const updatedBy = cleanStr(meta.updatedBy);
  const neverManuallyEdited = version <= 1 || updatedBy === 'police_api_sync';

  const nextData = { ...current };
  const nextSynced = { ...(prevSynced || {}) };
  const changedFields = [];

  for (const field of ALWAYS_AUTHORITATIVE_FIELDS) {
    const nextVal = candidates[field];
    if (!nextVal) continue;
    nextSynced[field] = nextVal;
    if (manualFields.has(field)) continue;
    const curVal = cleanStr(current[field]);
    if (nextVal !== curVal) {
      nextData[field] = nextVal;
      changedFields.push(field);
    }
  }

  for (const field of MERGEABLE_TEXT_FIELDS) {
    const nextVal = candidates[field];
    if (!nextVal) continue;
    const curVal = cleanStr(current[field]);
    const prevVal = hasPrevSynced ? cleanStr(prevSynced[field]) : '';
    const isUnchangedFromSync = hasPrevSynced && prevVal !== '' && curVal === prevVal;
    const canUpdate =
      !manualFields.has(field) &&
      (curVal === '' ||
        isUnchangedFromSync ||
        (!hasPrevSynced && neverManuallyEdited) ||
        (field === 'situation' && curVal !== '' && nextVal.length > curVal.length && nextVal.includes(curVal)));

    nextSynced[field] = nextVal;
    if (canUpdate && nextVal !== curVal) {
      nextData[field] = nextVal;
      changedFields.push(field);
    }
  }

  if (candidates.contacts && candidates.contacts.length > 0 && !manualFields.has('contacts')) {
    const curContacts = Array.isArray(current.contacts) ? current.contacts : [];
    const nextJson = stableJson(candidates.contacts);
    const curJson = stableJson(curContacts);
    const prevJson = hasPrevSynced ? cleanStr(prevSynced.contacts) : '';
    const canUpdateContacts =
      curContacts.length === 0 ||
      (hasPrevSynced && prevJson !== '' && curJson === prevJson) ||
      (!hasPrevSynced && neverManuallyEdited);
    nextSynced.contacts = nextJson;
    if (canUpdateContacts && nextJson !== curJson) {
      nextData.contacts = candidates.contacts;
      changedFields.push('contacts');
    }
  }

  if (changedFields.length === 0) {
    return { changed: false, changedFields: [], nextData: current };
  }

  nextData._external_synced = nextSynced;
  return {
    changed: true,
    changedFields,
    nextData,
  };
}

/**
 * 筛选出上游新增（当前档案尚未登记）的出动力量，绝不删除已有力量。
 */
function findNewDispatchedForces(existingForces = [], upstreamForces = []) {
  if (!Array.isArray(upstreamForces) || upstreamForces.length === 0) return [];
  const existingKeys = new Set(
    (Array.isArray(existingForces) ? existingForces : [])
      .map((f) => normalizeStationName(f?.station_name || ''))
      .filter(Boolean),
  );
  const additions = [];
  const seenNew = new Set();
  for (const item of upstreamForces) {
    const stationName = cleanStr(item?.station_name);
    const key = normalizeStationName(stationName);
    if (!key || existingKeys.has(key) || seenNew.has(key)) continue;
    seenNew.add(key);
    additions.push(item);
  }
  return additions;
}

/**
 * 记录人工编辑过的字段名，防止后续后台上游同步覆盖。
 */
function markManualEditedFields(beforeData = {}, patchSource = {}, afterData = {}) {
  const manual = new Set(
    Array.isArray(afterData._manual_fields)
      ? afterData._manual_fields.map((k) => String(k || '').trim()).filter(Boolean)
      : [],
  );
  const keys = Object.keys(patchSource && typeof patchSource === 'object' ? patchSource : {});
  for (const key of keys) {
    if (!key || key.startsWith('_')) continue;
    if (stableJson(beforeData?.[key]) !== stableJson(afterData?.[key])) {
      manual.add(key);
    }
  }
  if (manual.size === 0) return afterData;
  return {
    ...afterData,
    _manual_fields: [...manual],
  };
}

module.exports = {
  buildUpstreamDetailCandidates,
  computeExternalDetailSyncPatch,
  findNewDispatchedForces,
  markManualEditedFields,
};
