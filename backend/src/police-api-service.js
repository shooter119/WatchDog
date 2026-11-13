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
    alarm_phone: item.alarmPhone != null ? String(item.alarmPhone).trim() : '',
    alarm_person_phone: item.alarmPersonPhone != null ? String(item.alarmPersonPhone).trim() : '',
    alarm_person_name: item.alarmPersonName != null ? String(item.alarmPersonName).trim() : '',
    alarm_mode_name: item.alarmModeName != null ? String(item.alarmModeName).trim() : '',
    incident_nature_name: item.incidentNatureName != null ? String(item.incidentNatureName).trim() : '',
    dispatch_vehicle: item.dispatchVehicle != null ? String(item.dispatchVehicle).trim() : '',
    dispatch_organization: item.dispatchOrganization != null ? String(item.dispatchOrganization).trim() : '',
  };
}

function sanitizeCoordinates(lat, lon) {
  const latitude = parseFloat(lat);
  const longitude = parseFloat(lon);
  if (Number.isFinite(latitude) && Number.isFinite(longitude) &&
      latitude >= 27.5 && latitude <= 31.0 &&
      longitude >= 118.0 && longitude <= 121.0) {
    return {
      latitude: String(lat),
      longitude: String(lon),
    };
  }
  return { latitude: null, longitude: null };
}

function extractContacts(ext = {}) {
  const contacts = [];
  const clean = (p) => String(p || '').trim().replace(/[^\d+ -]/g, '');
  const isInvalid = (p) => !p || /^(?:0?110|119|120|122)$/.test(p.replace(/\D/g, '')) || p.replace(/\D/g, '').length < 7;

  const personPhone = clean(ext.alarm_person_phone);
  const alarmPhone = clean(ext.alarm_phone);

  let chosen = '';
  if (personPhone && !isInvalid(personPhone)) {
    chosen = personPhone;
  } else if (alarmPhone && !isInvalid(alarmPhone)) {
    chosen = alarmPhone;
  }

  if (chosen) {
    contacts.push({
      role: '报警人',
      name: String(ext.alarm_person_name || '').trim() || '报警人',
      phone: chosen,
    });
  }
  return contacts;
}

function buildDispatchSummary({ dispatch_vehicle = '', dispatch_organization = '', squadron_name = '' } = {}) {
  const parts = [];
  const v = String(dispatch_vehicle || '').trim();
  const o = String(dispatch_organization || '').trim();
  const s = String(squadron_name || '').trim();
  if (v && v !== '0') parts.push(`${v}车`);
  if (o && o !== '0') parts.push(`${o}站`);
  const prefix = parts.join(' ');
  if (prefix && s) {
    return `${prefix} (主调: ${s})`;
  }
  if (prefix) return prefix;
  if (s) return `主调: ${s}`;
  return '';
}

function sanitizeOfficialStatus(status = '') {
  const s = String(status || '').trim();
  if (!s || s === '其他' || s === '真警') return '';
  return s;
}

function isTerminalOfficialStatus(status = '') {
  const normalized = String(status || '').replace(/\s+/g, '').trim();
  if (!normalized) return false;
  return /^(?:归队|已归队|结案|已结案|填报|完成|已完成|结束|注销|作废|虚警|假警)$/.test(normalized) ||
    normalized.includes('归队') ||
    normalized.includes('结案') ||
    normalized.includes('填报');
}

function cleanIncidentLocation(rawAddress = '', districtName = '') {
  let addr = String(rawAddress || '').replace(/\s+/g, '').trim();
  const dist = String(districtName || '').replace(/\s+/g, '').trim();
  if (!addr) return dist && dist !== '市辖区' && dist !== '衢州市' ? dist : '';

  // 剥离冗余省级/自治区前缀
  addr = addr.replace(/^[\u4e00-\u9fa5]{2,5}(?:省|自治区)/, '');
  // 当后续已包含区/县/县级市时，剥离冗余地级市前缀
  addr = addr.replace(/^[\u4e00-\u9fa5]{2,5}市(?=[\u4e00-\u9fa5]{2,5}(?:区|县|市))/, '');
  // 消除相邻重复叠加的区县前缀（如“示例县示例县文化路1号”）
  addr = addr.replace(/^([\u4e00-\u9fa5]{2,5}(?:区|县|市))\1/, '$1');

  if (dist && dist !== '市辖区' && dist !== '衢州市' && !addr.includes(dist)) {
    const shortDist = dist.replace(/[区县市]$/, '');
    if (!shortDist || !addr.startsWith(shortDist)) {
      addr = `${dist}${addr}`;
    }
  }
  return addr;
}

function cleanIncidentEvent({
  incident_type = '',
  disposal_object_name = '',
  incident_describe = '',
} = {}) {
  const type = String(incident_type || '').trim();
  const obj = String(disposal_object_name || '').trim();
  let desc = String(incident_describe || '').trim();

  if (desc) {
    desc = desc
      .replace(/官方状态[:：][^，。；·\n]+/g, '')
      .replace(/[，,。；;·\s]*(?:暂)?无人员(?:被困|伤亡|受伤)[，,。；;·\s]*/g, '，')
      .replace(/[，,。；;·\s]*人员被困情况不明[，,。；;·\s]*/g, '，')
      .replace(/[，,。；;·\s]*(?:群众|电话)?报警[，,。；;·\s]*/g, '，')
      .replace(/[，,。；;·\s]*110转警[，,。；;·\s]*/g, '，')
      .replace(/^[，,。；;·\s]+|[，,。；;·\s]+$/g, '')
      .replace(/，{2,}/g, '，');
    if (desc) {
      if (desc.length <= 26) return desc;
      const firstClause = desc.split(/[，。；;\n]/).map((s) => s.trim()).find(Boolean) || desc;
      return firstClause.length > 24 ? `${firstClause.slice(0, 23)}…` : firstClause;
    }
  }

  if (type && obj && obj !== '其他' && !type.includes(obj)) {
    return `${type}（${obj}）`;
  }
  return type || (obj && obj !== '其他' ? obj : '') || '警情';
}

function buildSituationDescription({
  incident_type = '',
  disposal_object_name = '',
  incident_describe = '',
  alarm_mode_name = '',
  incident_status = '',
} = {}) {
  const desc = String(incident_describe || '').trim();
  if (desc) return desc;
  const type = String(incident_type || '').trim() || '警情';
  const obj = String(disposal_object_name || '').trim();
  let base = (obj && obj !== '其他') ? `${type}（${obj}）` : type;

  const extras = [];
  const mode = String(alarm_mode_name || '').trim();
  if (mode && mode !== '其他') extras.push(mode);
  const status = sanitizeOfficialStatus(incident_status);
  if (status) extras.push(`官方状态: ${status}`);

  if (extras.length > 0) {
    return `${base} · ${extras.join(' · ')}`;
  }
  return base;
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
  peekCachedIncidents,
  isQuzhouIncident,
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
  _resetCacheForTest,
  DEFAULT_UPSTREAM_URL,
};
