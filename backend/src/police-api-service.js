const logger = require('./logger');

const DEFAULT_UPSTREAM_URL = process.env.POLICE_API_ORGLIST_URL || 'http://220.189.211.80:10480/ds-mit-web/rest/mit/fire/v1.0/disater/orglist';
const CACHE_TTL_MS = 60 * 1000; // 1 分钟短时缓存
const THREE_DAYS_MS = 3 * 24 * 60 * 60 * 1000;

// 衢州市行政区与支队匹配关键字
const QUZHOU_KEYWORDS = ['衢州', '柯城', '衢江', '江山', '龙游', '常山', '开化'];

let memoryCache = {
  data: [],
  fetchedAt: 0,
};
let inFlightPromise = null;

function isQuzhouIncident(item) {
  if (!item) return false;
  const detachment = String(item.detachmentOrgName || '').trim();
  if (detachment.includes('衢州')) return true;
  const brigade = String(item.brigadeOrganizationName || '').trim();
  const district = String(item.districtName || '').trim();
  return QUZHOU_KEYWORDS.some((kw) => detachment.includes(kw) || brigade.includes(kw) || district.includes(kw));
}

function normalizeExternalIncident(item) {
  return {
    external_id: String(item.id || ''),
    incident_number: String(item.incidentNumber || ''),
    detachment_name: String(item.detachmentOrgName || ''),
    brigade_name: String(item.brigadeOrganizationName || ''),
    squadron_name: String(item.squadronOrganizationName || ''),
    district_name: String(item.districtName || ''),
    incident_type: String(item.incidentTypeName || '其他'),
    incident_level: String(item.incidentLevelName || ''),
    incident_status: String(item.incidentStatusName || ''),
    crime_address: String(item.crimeAddress || ''),
    incident_describe: String(item.incidentDescribe || ''),
    register_time: Number(item.registerIncidentTime) || 0,
    latitude: item.latitude != null ? String(item.latitude) : null,
    longitude: item.longitude != null ? String(item.longitude) : null,
  };
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
      // 只要保留衢州市且在最近三天内的
      if (isQuzhouIncident(item)) {
        if (regTime >= cutoffTime) {
          allQuzhou.push(normalizeExternalIncident(item));
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

function _resetCacheForTest() {
  memoryCache = { data: [], fetchedAt: 0 };
  inFlightPromise = null;
}

module.exports = {
  getQuzhouIncidents,
  isQuzhouIncident,
  normalizeExternalIncident,
  _resetCacheForTest,
  DEFAULT_UPSTREAM_URL,
};
