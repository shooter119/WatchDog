const logger = require('./logger');
const {
  resolveDistrict,
  sanitizeOfficialStatus,
  isTerminalOfficialStatus,
  cleanIncidentLocation,
  cleanIncidentEvent,
  buildSituationDescription,
  extractContacts,
  buildDispatchSummary,
  sanitizeCoordinates,
  buildRuleFallbackStructured,
} = require('./external-incident-organizer');

const DEFAULT_QUERYLIST_URL = 'http://220.189.211.80:10480/ds-mit-web/rest/mit/fire/v1.0/disater/querylist';
const DEFAULT_HOMEINFO_URL = 'http://220.189.211.80:10480/ds-mit-web/rest/mit/fire/v1.0/home/homeinfo';
const DEFAULT_UPSTREAM_URL = process.env.POLICE_API_QUERYLIST_URL || process.env.POLICE_API_ORGLIST_URL || DEFAULT_QUERYLIST_URL;
const DEFAULT_SCOPE_SQUADRON_ID = process.env.POLICE_API_SCOPE_SQUADRON_ID || '1f2ce829f50c446bb8b21e816c3ba7f2';
const CACHE_TTL_MS = 60 * 1000; // 1 分钟短时缓存
const THREE_DAYS_MS = 3 * 24 * 60 * 60 * 1000;

let testHomeInfoUrl = null;

// 衢州市行政区与支队匹配关键字
const QUZHOU_KEYWORDS = ['衢州', '柯城', '衢江', '江山', '龙游', '常山', '开化'];

// 浙江省除衢州外的其他地市，用于排除跨市异地演练/拉动警单
const OTHER_ZHEJIANG_CITIES = ['杭州', '宁波', '温州', '嘉兴', '湖州', '绍兴', '金华', '舟山', '台州', '丽水'];

let memoryCache = {
  data: [],
  fetchedAt: 0,
};
let inFlightPromise = null;

function isQuzhouIncident(item) {
  if (!item) return false;
  const detachment = String(item.detachmentOrgName || '').trim();
  const brigade = String(item.brigadeOrganizationName || '').trim();
  const district = String(item.districtName || '').trim();
  const squadron = String(item.squadronOrganizationName || '').trim();
  const address = String(item.crimeAddress || '').trim();

  // 1. 组织归属：支队、大队、站或行政区必须属于衢州管辖
  const belongsToQuzhou = detachment.includes('衢州') ||
    QUZHOU_KEYWORDS.some((kw) => detachment.includes(kw) || brigade.includes(kw) || district.includes(kw) || squadron.includes(kw));

  if (!belongsToQuzhou) return false;

  // 2. 事发地址校验：若明确包含浙江其他地市名称且不含衢州各县市关键字，判定为异地拉动演练，予以排除
  const hasOtherCity = OTHER_ZHEJIANG_CITIES.some((city) => address.includes(city));
  const hasQuzhouLocal = QUZHOU_KEYWORDS.some((kw) => address.includes(kw));
  if (hasOtherCity && !hasQuzhouLocal) {
    return false;
  }

  // 3. 包含（拉动）/演练且地址明确不在衢州本地的，排除
  if ((address.includes('拉动') || address.includes('演练')) && hasOtherCity) {
    return false;
  }

  return true;
}

/**
 * 判断上游警情是否已经进入“派警处置”阶段（已调派力量）。
 *
 * 接处警工作流按「报警电话 → 受理立案 → 派警处置」推进：
 * - 保留全部已调派力量的记录（含内部测试/演练警情，不按性质/作废字样一刀切）；
 * - 仅过滤显式未调派，或无实际派车/派员/派站/调派时间且处于接警/受理/立案/作废/注销态的记录。
 */
function isDispatchedIncident(item) {
  if (!item || typeof item !== 'object') return false;

  const status = String(item.incidentStatusName || item.incident_status || '').trim();
  const dispatchStatus = String(
    item.dispatchStatusName || item.dispatchStatus || item.dispatch_status || '',
  ).trim();

  if (/未调派|待调派|未派警|待派警|未下达|待下达/.test(`${status} ${dispatchStatus}`)) {
    return false;
  }

  const vehicles = Number(item.dispatchVehicle ?? item.dispatch_vehicle);
  const hasVehicle = Number.isFinite(vehicles) && vehicles > 0;

  const personnel = Number(
    item.dispatchPerson ?? item.dispatchPersonnel ?? item.dispatch_person,
  );
  const hasPersonnel = Number.isFinite(personnel) && personnel > 0;

  const orgRaw = String(item.dispatchOrganization ?? item.dispatch_organization ?? '').trim();
  const orgNum = Number(orgRaw);
  const hasOrg = Boolean(
    orgRaw &&
      orgRaw !== '0' &&
      orgRaw.toLowerCase() !== 'null' &&
      (!/^\d+(?:\.\d+)?$/.test(orgRaw) || (Number.isFinite(orgNum) && orgNum > 0)),
  );

  const dispatchTs = Number(
    item.dispatchTime ?? item.firstDispatchTime ?? item.sendTime,
  );
  const hasDispatchTime = Number.isFinite(dispatchTs) && dispatchTs > 0;

  const rawFlag = item.whetherDispatch ?? item.isDispatch;
  const flagStr = rawFlag != null ? String(rawFlag).trim() : '';
  const hasExplicitDispatchFlag =
    rawFlag === true ||
    /^(?:1|true|是|Y|y)$/i.test(flagStr) ||
    /已调派|已派警|已下达/.test(dispatchStatus);

  const hasDispatchedForces =
    hasVehicle || hasPersonnel || hasOrg || hasDispatchTime || hasExplicitDispatchFlag;

  if (hasDispatchedForces) {
    return true;
  }

  if (rawFlag === false || /^(?:0|false|否|N|n)$/i.test(flagStr)) {
    return false;
  }

  const normalizedStatus = status.replace(/\s+/g, '');
  if (/^(?:接警|电话报警|报警|新警情|待接警|受理|受理中|正在受理|预立案|立案|已立案|待立案|作废|注销)$/.test(normalizedStatus)) {
    return false;
  }

  if (/(?:通知|下达|调派|派警|增援|出动|途中|到场|展开|出水|控制|熄灭|清理|处置|中返|途返|返程|归队|填报|结案|战评|完成|结束)/.test(normalizedStatus)) {
    return true;
  }

  const squadron = String(item.squadronOrganizationName || item.squadron_name || '').trim();
  return Boolean(squadron);
}

function normalizeExternalIncident(item) {
  const base = {
    external_id: String(item.id || ''),
    incident_number: String(item.incidentNumber || ''),
    detachment_name: String(item.detachmentOrgName || ''),
    detachment_id: item.detachmentOrgId != null ? String(item.detachmentOrgId).trim() : '',
    brigade_name: String(item.brigadeOrganizationName || ''),
    squadron_name: String(item.squadronOrganizationName || ''),
    district_name: String(item.districtName || ''),
    incident_type: String(item.incidentTypeName || '其他'),
    disposal_object_name: String(item.disposalObjectName || ''),
    incident_level: String(item.incidentLevelName || ''),
    incident_status: String(item.incidentStatusName || ''),
    crime_address: String(item.crimeAddress || ''),
    incident_describe: String(item.incidentDescribe || ''),
    register_time: Number(item.registerIncidentTime) || 0,
    dispatch_time: Number(item.dispatchTime ?? item.firstDispatchTime ?? item.sendTime) || 0,
    latitude: item.latitude != null ? String(item.latitude) : null,
    longitude: item.longitude != null ? String(item.longitude) : null,
    alarm_phone: item.alarmPhone != null ? String(item.alarmPhone).trim() : '',
    alarm_person_phone: item.alarmPersonPhone != null ? String(item.alarmPersonPhone).trim() : '',
    alarm_person_name: item.alarmPersonName != null ? String(item.alarmPersonName).trim() : '',
    alarm_mode_name: item.alarmModeName != null ? String(item.alarmModeName).trim() : '',
    incident_nature_name: item.incidentNatureName != null ? String(item.incidentNatureName).trim() : '',
    dispatch_vehicle: item.dispatchVehicle != null ? String(item.dispatchVehicle).trim() : '',
    dispatch_organization: item.dispatchOrganization != null ? String(item.dispatchOrganization).trim() : '',
    site_vehicle: item.siteVehicle != null ? String(item.siteVehicle).trim() : '',
    site_organization: item.siteOrganization != null ? String(item.siteOrganization).trim() : '',
    whether_test_sign: item.whetherTestSign === 1 || item.whetherTestSign === '1' || item.whetherTestSign === true,
    raw_payload: { ...(item && typeof item === 'object' ? item : {}) },
  };
  return buildRuleFallbackStructured(base, item);
}

function peekCachedIncidents() {
  return Array.isArray(memoryCache.data) ? memoryCache.data.slice() : [];
}

async function fetchFromUpstream(url = DEFAULT_UPSTREAM_URL) {
  const allQuzhou = [];
  const now = Date.now();
  const cutoffTime = now - THREE_DAYS_MS;
  const pageSize = 100;
  let page = 1;

  while (page <= 10) { // 上限 10 页，避免极端情况下死循环
    const body = JSON.stringify({
      whetherPage: true,
      scopeType: 1,
      scopeSquadronId: DEFAULT_SCOPE_SQUADRON_ID,
      squadronIds: [],
      startTime: String(cutoffTime),
      endTime: String(now),
      pagination: { page, size: pageSize },
    });

    const response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body,
      signal: AbortSignal.timeout(10000), // 10 秒超时
    });

    if (!response.ok) {
      throw new Error(`Upstream HTTP ${response.status} ${response.statusText}`);
    }

    const json = await response.json();
    if (json.errorCode !== 0 && json.code !== 0 && json.errorCode !== undefined) {
      throw new Error(`Upstream error: ${json.errorMessage || json.message || JSON.stringify(json)}`);
    }

    const data = json.data || {};
    const list = Array.isArray(data.list) ? data.list : [];
    if (list.length === 0) break;

    let reachedOlderData = false;
    for (const item of list) {
      const regTime = Number(item.registerIncidentTime) || 0;
      // 保留衢州市、最近三天内且已调派力量的警情
      if (isQuzhouIncident(item)) {
        if (regTime >= cutoffTime) {
          if (isDispatchedIncident(item)) {
            allQuzhou.push(normalizeExternalIncident(item));
          }
        } else {
          // 由于上游通常按立案时间倒序排列，若遇到早于3天的衢州警情，可提前结束
          reachedOlderData = true;
        }
      }
    }

    const total = data.pagination?.total || 0;
    if (reachedOlderData || page * pageSize >= total || list.length < pageSize) {
      break;
    }
    page++;
  }

  // 按接警时间倒序排序
  allQuzhou.sort((a, b) => b.register_time - a.register_time);
  return allQuzhou;
}

async function getQuzhouIncidents({ forceRefresh = false, upstreamUrl = DEFAULT_UPSTREAM_URL } = {}) {
  const now = Date.now();
  const isCacheValid = !forceRefresh && (now - memoryCache.fetchedAt < CACHE_TTL_MS) && memoryCache.data.length > 0;

  if (isCacheValid) {
    return {
      list: memoryCache.data,
      fetchedAt: memoryCache.fetchedAt,
      cacheHit: true,
    };
  }

  if (inFlightPromise) {
    const list = await inFlightPromise;
    return {
      list,
      fetchedAt: memoryCache.fetchedAt,
      cacheHit: true,
    };
  }

  inFlightPromise = (async () => {
    try {
      const list = await fetchFromUpstream(upstreamUrl);
      memoryCache = {
        data: list,
        fetchedAt: Date.now(),
      };
      logger.info(`[PoliceApiService] Refreshed Quzhou incidents: ${list.length} items`);
      return list;
    } catch (err) {
      logger.error(`[PoliceApiService] Failed to fetch upstream police incidents: ${err.message}`);
      // 若拉取失败且有旧缓存，降级返回旧缓存
      if (memoryCache.data.length > 0) {
        return memoryCache.data;
      }
      return [];
    } finally {
      inFlightPromise = null;
    }
  })();

  const list = await inFlightPromise;
  return {
    list,
    fetchedAt: memoryCache.fetchedAt || Date.now(),
    cacheHit: false,
  };
}

async function fetchIncidentHomeInfo(externalId, { homeInfoUrl, timeoutMs = 2500 } = {}) {
  const id = String(externalId || '').trim();
  if (!id) return null;

  const configuredUrl = homeInfoUrl || testHomeInfoUrl || process.env.POLICE_API_HOMEINFO_URL || '';
  // 测试环境未注入 mock URL 时短路返回，避免离线/CI 发起外网请求导致超时
  if (process.env.NODE_ENV === 'test' && !configuredUrl) {
    return null;
  }

  const baseUrl = configuredUrl || DEFAULT_HOMEINFO_URL;
  const requestUrl = `${baseUrl}${baseUrl.includes('?') ? '&' : '?'}incidentID=${encodeURIComponent(id)}`;

  try {
    const response = await fetch(requestUrl, {
      method: 'GET',
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!response.ok) {
      logger.warn(`[PoliceApiService] homeinfo HTTP ${response.status} for ${id}`);
      return null;
    }
    const json = await response.json();
    if (!json || typeof json !== 'object') {
      logger.warn(`[PoliceApiService] homeinfo invalid payload for ${id}`);
      return null;
    }
    if (json.errorCode !== 0 && json.code !== 0 && json.errorCode !== undefined) {
      logger.warn(`[PoliceApiService] homeinfo upstream error for ${id}: ${json.errorMessage || json.message || json.errorCode}`);
      return null;
    }
    return json.data || null;
  } catch (err) {
    logger.warn(`[PoliceApiService] homeinfo fetch failed for ${id}: ${err?.message || String(err)}`);
    return null;
  }
}

function _setHomeInfoUrlForTest(url) {
  testHomeInfoUrl = url || null;
}

function _resetCacheForTest() {
  memoryCache = { data: [], fetchedAt: 0 };
  inFlightPromise = null;
  testHomeInfoUrl = null;
}

module.exports = {
  getQuzhouIncidents,
  fetchIncidentHomeInfo,
  peekCachedIncidents,
  isQuzhouIncident,
  isDispatchedIncident,
  normalizeExternalIncident,
  resolveDistrict,
  sanitizeOfficialStatus,
  isTerminalOfficialStatus,
  cleanIncidentLocation,
  cleanIncidentEvent,
  buildSituationDescription,
  extractContacts,
  buildDispatchSummary,
  sanitizeCoordinates,
  _setHomeInfoUrlForTest,
  _resetCacheForTest,
  DEFAULT_QUERYLIST_URL,
  DEFAULT_HOMEINFO_URL,
  DEFAULT_UPSTREAM_URL,
};
