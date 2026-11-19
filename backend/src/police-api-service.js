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

const DEFAULT_QUERYLIST_URL = process.env.POLICE_API_QUERYLIST_URL || process.env.POLICE_API_ORGLIST_URL || '';
const DEFAULT_HOMEINFO_URL = process.env.POLICE_API_HOMEINFO_URL || '';
const DEFAULT_UPSTREAM_URL = DEFAULT_QUERYLIST_URL;
const DEFAULT_SCOPE_SQUADRON_ID = process.env.POLICE_API_SCOPE_SQUADRON_ID || '';
const CACHE_TTL_MS = 60 * 1000; // 1 分钟短时缓存
const MIN_REFRESH_INTERVAL_MS = 5 * 1000; // 5 秒防击穿冷却
const THREE_DAYS_MS = 3 * 24 * 60 * 60 * 1000;

let testHomeInfoUrl = null;

function getQueryListUrl() {
  return process.env.POLICE_API_QUERYLIST_URL || process.env.POLICE_API_ORGLIST_URL || DEFAULT_QUERYLIST_URL;
}

function getHomeInfoUrl() {
  return testHomeInfoUrl || process.env.POLICE_API_HOMEINFO_URL || DEFAULT_HOMEINFO_URL;
}

function getScopeSquadronId() {
  return process.env.POLICE_API_SCOPE_SQUADRON_ID || DEFAULT_SCOPE_SQUADRON_ID;
}

function getRegionKeywords() {
  const envKw = process.env.POLICE_API_REGION_KEYWORDS;
  if (!envKw) return [];
  try {
    if (envKw.startsWith('[') && envKw.endsWith(']')) {
      const parsed = JSON.parse(envKw);
      if (Array.isArray(parsed)) return parsed.map((s) => String(s).trim()).filter(Boolean);
    }
  } catch (_) {}
  return envKw.split(',').map((s) => s.trim()).filter(Boolean);
}

function getExcludeCities() {
  const envExc = process.env.POLICE_API_EXCLUDE_CITIES;
  if (!envExc) return [];
  try {
    if (envExc.startsWith('[') && envExc.endsWith(']')) {
      const parsed = JSON.parse(envExc);
      if (Array.isArray(parsed)) return parsed.map((s) => String(s).trim()).filter(Boolean);
    }
  } catch (_) {}
  return envExc.split(',').map((s) => s.trim()).filter(Boolean);
}

let memoryCache = {
  data: [],
  fetchedAt: 0,
};
let inFlightPromise = null;

function isJurisdictionIncident(item, opts = {}) {
  if (!item) return false;
  const detachment = String(item.detachmentOrgName || '').trim();
  const brigade = String(item.brigadeOrganizationName || '').trim();
  const district = String(item.districtName || '').trim();
  const squadron = String(item.squadronOrganizationName || '').trim();
  const address = String(item.crimeAddress || '').trim();

  const regionKeywords = Array.isArray(opts.regionKeywords) ? opts.regionKeywords : getRegionKeywords();
  const excludeCities = Array.isArray(opts.excludeCities) ? opts.excludeCities : getExcludeCities();

  if (regionKeywords.length > 0) {
    const belongsToRegion = regionKeywords.some((kw) =>
      detachment.includes(kw) || brigade.includes(kw) || district.includes(kw) || squadron.includes(kw),
    );
    if (!belongsToRegion) return false;

    if (excludeCities.length > 0) {
      const hasOtherCity = excludeCities.some((city) => address.includes(city));
      const hasRegionLocal = regionKeywords.some((kw) => address.includes(kw));
      if (hasOtherCity && !hasRegionLocal) {
        return false;
      }
      if ((address.includes('拉动') || address.includes('演练')) && hasOtherCity) {
        return false;
      }
    }
    return true;
  }

  if (excludeCities.length > 0) {
    const hasOtherCity = excludeCities.some((city) => address.includes(city));
    if (hasOtherCity && (address.includes('拉动') || address.includes('演练'))) {
      return false;
    }
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

async function fetchFromUpstream(url = getQueryListUrl()) {
  const targetUrl = url || getQueryListUrl();
  if (!targetUrl) {
    logger.info('[PoliceApiService] Upstream querylist URL not configured, returning empty list');
    return [];
  }

  const allIncidents = [];
  const now = Date.now();
  const cutoffTime = now - THREE_DAYS_MS;
  const pageSize = 100;
  let page = 1;

  while (page <= 10) { // 上限 10 页，避免极端情况下死循环
    const body = JSON.stringify({
      whetherPage: true,
      scopeType: 1,
      scopeSquadronId: getScopeSquadronId(),
      squadronIds: [],
      startTime: String(cutoffTime),
      endTime: String(now),
      pagination: { page, size: pageSize },
    });

    const response = await fetch(targetUrl, {
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
      if (regTime > 0 && regTime < cutoffTime) {
        // 由于上游按立案时间倒序排列，只要遇到早于 3 天的有效记录（无论是否本辖区）即可提前结束翻页
        reachedOlderData = true;
        continue;
      }
      if (isJurisdictionIncident(item) && regTime >= cutoffTime) {
        if (isDispatchedIncident(item)) {
          allIncidents.push(normalizeExternalIncident(item));
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
  allIncidents.sort((a, b) => b.register_time - a.register_time);
  return allIncidents;
}

let backgroundRefreshTimer = null;
let backgroundInitialTimer = null;
let defaultOnRefreshed = null;

function isConfigured() {
  return Boolean(getQueryListUrl());
}

function startUpstreamRefresh(targetUrl, { onRefreshed } = {}) {
  if (inFlightPromise) return inFlightPromise;
  const callback = typeof onRefreshed === 'function' ? onRefreshed : defaultOnRefreshed;
  inFlightPromise = (async () => {
    try {
      const list = await fetchFromUpstream(targetUrl);
      memoryCache = {
        data: list,
        fetchedAt: Date.now(),
      };
      logger.info(`[PoliceApiService] Refreshed external incidents: ${list.length} items`);
      if (typeof callback === 'function') {
        Promise.resolve(callback(list)).catch((cbErr) => {
          logger.warn(`[PoliceApiService] onRefreshed hook failed: ${cbErr?.message || String(cbErr)}`);
        });
      }
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
  return inFlightPromise;
}

function startBackgroundRefresh({
  intervalMs = CACHE_TTL_MS,
  initialDelayMs = 1500,
  onRefreshed = null,
} = {}) {
  stopBackgroundRefresh();
  if (typeof onRefreshed === 'function') {
    defaultOnRefreshed = onRefreshed;
  }
  const targetUrl = getQueryListUrl();
  if (!targetUrl) return false;

  const trigger = () => {
    const currentUrl = getQueryListUrl();
    if (!currentUrl) return;
    startUpstreamRefresh(currentUrl, { onRefreshed: defaultOnRefreshed }).catch(() => {});
  };

  if (initialDelayMs > 0) {
    backgroundInitialTimer = setTimeout(() => {
      backgroundInitialTimer = null;
      trigger();
    }, initialDelayMs);
    backgroundInitialTimer.unref?.();
  } else {
    trigger();
  }

  backgroundRefreshTimer = setInterval(trigger, Math.max(MIN_REFRESH_INTERVAL_MS, Number(intervalMs) || CACHE_TTL_MS));
  backgroundRefreshTimer.unref?.();
  return true;
}

function stopBackgroundRefresh() {
  if (backgroundInitialTimer) {
    clearTimeout(backgroundInitialTimer);
    backgroundInitialTimer = null;
  }
  if (backgroundRefreshTimer) {
    clearInterval(backgroundRefreshTimer);
    backgroundRefreshTimer = null;
  }
  defaultOnRefreshed = null;
}

async function getExternalIncidents({
  forceRefresh = false,
  upstreamUrl,
  allowStale = !forceRefresh,
  fallbackLoader = null,
  onRefreshed = null,
} = {}) {
  const targetUrl = upstreamUrl || getQueryListUrl();
  if (!targetUrl) {
    return {
      list: [],
      fetchedAt: 0,
      cacheHit: false,
      stale: false,
    };
  }

  const now = Date.now();
  const isCacheValid = !forceRefresh && (now - memoryCache.fetchedAt < CACHE_TTL_MS) && memoryCache.data.length > 0;
  const isCoolingDown = forceRefresh && (now - memoryCache.fetchedAt < MIN_REFRESH_INTERVAL_MS) && memoryCache.data.length > 0;

  if (isCacheValid || isCoolingDown) {
    return {
      list: memoryCache.data,
      fetchedAt: memoryCache.fetchedAt,
      cacheHit: true,
      stale: false,
    };
  }

  // SWR：非强制刷新时，优先立刻返回旧内存缓存或近期持久化数据，并在后台异步刷新上游
  if (allowStale && !forceRefresh) {
    if (memoryCache.data.length > 0) {
      startUpstreamRefresh(targetUrl, { onRefreshed }).catch(() => {});
      return {
        list: memoryCache.data,
        fetchedAt: memoryCache.fetchedAt,
        cacheHit: true,
        stale: true,
      };
    }
    if (typeof fallbackLoader === 'function') {
      try {
        const persisted = await fallbackLoader();
        if (Array.isArray(persisted) && persisted.length > 0) {
          startUpstreamRefresh(targetUrl, { onRefreshed }).catch(() => {});
          return {
            list: persisted,
            fetchedAt: 0,
            cacheHit: true,
            stale: true,
            fromPersistedStore: true,
          };
        }
      } catch (err) {
        logger.warn(`[PoliceApiService] fallbackLoader failed: ${err?.message || String(err)}`);
      }
    }
  }

  if (inFlightPromise) {
    const list = await inFlightPromise;
    return {
      list,
      fetchedAt: memoryCache.fetchedAt,
      cacheHit: true,
      stale: false,
    };
  }

  const list = await startUpstreamRefresh(targetUrl, { onRefreshed });
  return {
    list,
    fetchedAt: memoryCache.fetchedAt || Date.now(),
    cacheHit: false,
    stale: false,
  };
}

async function fetchIncidentHomeInfo(externalId, { homeInfoUrl, timeoutMs = 2500 } = {}) {
  const id = String(externalId || '').trim();
  if (!id) return null;

  const configuredUrl = homeInfoUrl || testHomeInfoUrl || process.env.POLICE_API_HOMEINFO_URL || DEFAULT_HOMEINFO_URL;
  if (!configuredUrl) {
    return null;
  }

  const baseUrl = configuredUrl;
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

function _setCacheForTest({ data = [], fetchedAt = 0 } = {}) {
  memoryCache = {
    data: Array.isArray(data) ? data : [],
    fetchedAt: Number(fetchedAt) || 0,
  };
}

function _resetCacheForTest() {
  stopBackgroundRefresh();
  memoryCache = { data: [], fetchedAt: 0 };
  inFlightPromise = null;
  testHomeInfoUrl = null;
}

module.exports = {
  getExternalIncidents,
  getQueryListUrl,
  isConfigured,
  startBackgroundRefresh,
  stopBackgroundRefresh,
  fetchIncidentHomeInfo,
  peekCachedIncidents,
  isJurisdictionIncident,
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
  _setCacheForTest,
  _resetCacheForTest,
  DEFAULT_QUERYLIST_URL,
  DEFAULT_HOMEINFO_URL,
  DEFAULT_UPSTREAM_URL,
  DEFAULT_SCOPE_SQUADRON_ID,
  CACHE_TTL_MS,
  MIN_REFRESH_INTERVAL_MS,
  THREE_DAYS_MS,
};
