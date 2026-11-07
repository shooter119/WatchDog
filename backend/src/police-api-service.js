const logger = require('./logger');

const DEFAULT_UPSTREAM_URL = process.env.POLICE_API_ORGLIST_URL || 'http://220.189.211.80:10480/ds-mit-web/rest/mit/fire/v1.0/disater/orglist';
const CACHE_TTL_MS = 60 * 1000; // 1 分钟短时缓存
const THREE_DAYS_MS = 3 * 24 * 60 * 60 * 1000;

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

function normalizeExternalIncident(item) {
  return {
    external_id: String(item.id || ''),
    incident_number: String(item.incidentNumber || ''),
    detachment_name: String(item.detachmentOrgName || ''),
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
    latitude: item.latitude != null ? String(item.latitude) : null,
    longitude: item.longitude != null ? String(item.longitude) : null,
  };
}

function buildSituationDescription({ incident_type = '', disposal_object_name = '', incident_describe = '' } = {}) {
  const desc = String(incident_describe || '').trim();
  if (desc) return desc;
  const type = String(incident_type || '').trim() || '警情';
  const obj = String(disposal_object_name || '').trim();
  if (obj && obj !== '其他') {
    return `${type}（${obj}）`;
  }
  return type;
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

function resolveDistrict(item) {
  if (!item) return '';
  const addr = String(item.crime_address || item.crimeAddress || '').trim();
  const brigade = String(item.brigade_name || item.brigadeOrganizationName || '').trim();
  const squadron = String(item.squadron_name || item.squadronOrganizationName || '').trim();
  const rawDist = String(item.district_name || item.districtName || '').trim();

  const qzDistricts = [
    { name: '智慧新城', keys: ['智慧新城', '新城'] },
    { name: '柯城区', keys: ['柯城'] },
    { name: '衢江区', keys: ['衢江'] },
    { name: '江山市', keys: ['江山'] },
    { name: '龙游县', keys: ['龙游'] },
    { name: '常山县', keys: ['常山'] },
    { name: '开化县', keys: ['开化'] },
  ];

  for (const d of qzDistricts) {
    if (addr.includes(d.name) || d.keys.some((k) => addr.includes(k))) return d.name;
  }
  for (const d of qzDistricts) {
    if (d.keys.some((k) => brigade.includes(k))) return d.name;
  }
  for (const d of qzDistricts) {
    if (d.keys.some((k) => squadron.includes(k))) return d.name;
  }
  if (rawDist && rawDist !== '市辖区') return rawDist;
  return '衢州市';
}

function _resetCacheForTest() {
  memoryCache = { data: [], fetchedAt: 0 };
  inFlightPromise = null;
}

module.exports = {
  getQuzhouIncidents,
  isQuzhouIncident,
  normalizeExternalIncident,
  resolveDistrict,
  buildSituationDescription,
  _resetCacheForTest,
  DEFAULT_UPSTREAM_URL,
};
