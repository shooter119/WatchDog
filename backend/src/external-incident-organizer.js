const { createHash } = require('node:crypto');
const logger = require('./logger');

const VALID_CATEGORIES = new Set(['fire', 'rescue', 'aid']);
const VALID_DEPLOYMENT_STATUSES = new Set(['dispatched', 'mobilized', 'unknown']);

function cleanText(value, max = 500) {
  if (value == null) return '';
  return String(value).replace(/\r\n/g, '\n').trim().slice(0, max);
}

function formatBeijingIso(timestampMs) {
  const ts = Number(timestampMs);
  if (!Number.isFinite(ts) || ts <= 0) return '';
  return `${new Date(ts + 8 * 3600 * 1000).toISOString().slice(0, 19)}+08:00`;
}

function formatBeijingReadable(timestampMs) {
  const iso = formatBeijingIso(timestampMs);
  if (!iso) return '';
  return iso.slice(0, 19).replace('T', ' ');
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
  if (o && o !== '0') {
    parts.push(/^\d+$/.test(o) ? `${o}站` : o);
  }
  const prefix = parts.join(' ');
  if (prefix && s) {
    return `${prefix} (主调: ${s})`;
  }
  if (prefix) return prefix;
  if (s) return `主调: ${s}`;
  return '';
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

function classifyDisasterCategory({
  disaster_category = '',
  incident_type = '',
  disposal_object_name = '',
  incident_describe = '',
  event_summary = '',
} = {}) {
  const explicit = String(disaster_category || '').trim().toLowerCase();
  if (VALID_CATEGORIES.has(explicit)) return explicit;

  const primary = `${incident_type} ${disposal_object_name}`.trim();
  if (/社会救助|公务执勤|安保/.test(primary)) return 'aid';
  if (/抢险救援|反恐排爆/.test(primary)) return 'rescue';
  if (/火灾扑救|灭火/.test(primary)) return 'fire';

  const combined = `${primary} ${event_summary} ${incident_describe}`;
  if (/(?:社会救助|马蜂|蜂窝|戒指|开门|开锁|电梯困人|困电梯|抓蛇|捕蛇|动物|送水|摘除|取物|公务执勤|执勤|安保|帮扶|求助)/.test(combined)) {
    return 'aid';
  }
  if (/(?:抢险|救援|车祸|交通事故|追尾|翻车|侧翻|破拆|坍塌|倒塌|泄漏|漏油|危化|溺水|落水|水域|山岳|排涝|内涝|滑坡|泥石流|台风|地震|塌方|坠井|被卡|卡手|反恐|排爆)/.test(combined)) {
    return 'rescue';
  }
  if (/(?:火|燃|烟|爆|扑救)/.test(combined)) {
    return 'fire';
  }
  return 'fire';
}

function buildAddressStripCandidates(rawAddress = '', addrClean = '') {
  const candidates = new Set();
  const add = (val) => {
    const s = String(val || '').trim();
    if (s.length >= 4) candidates.add(s);
  };
  add(rawAddress);
  add(addrClean);
  for (const base of [String(rawAddress || '').trim(), addrClean]) {
    if (!base) continue;
    const noProvCity = base
      .replace(/^[\u4e00-\u9fa5]{2,5}(?:省|自治区)/, '')
      .replace(/^[\u4e00-\u9fa5]{2,5}市/, '')
      .trim();
    add(noProvCity);
    const noDistrict = noProvCity
      .replace(/^[\u4e00-\u9fa5]{2,5}(?:区|县|市)/, '')
      .trim();
    add(noDistrict);
  }
  return [...candidates].sort((a, b) => b.length - a.length);
}

function cleanIncidentEvent({
  incident_type = '',
  disposal_object_name = '',
  incident_describe = '',
  crime_address = '',
} = {}) {
  const type = String(incident_type || '').trim();
  const obj = String(disposal_object_name || '').trim();
  let desc = String(incident_describe || '').trim();
  const addrClean = cleanIncidentLocation(crime_address);

  if (desc) {
    // 1) 循环（最多2轮）剥离前导日期时间戳、支队/大队/指挥中心接警套话、以及（位于）上述地址/上址前缀
    const leadingDateTimeRe = /^(?:(?:\d{4}年\s*)?\d{1,2}月\s*\d{1,2}[日号](?:\s*\d{1,2}[时:：]\d{1,2}(?:分(?:\d{1,2}秒)?)?)?|\d{4}年(?:\d{1,2}月(?:\d{1,2}[日号])?)?(?:\s*\d{1,2}[时:：]\d{1,2}(?:分(?:\d{1,2}秒)?)?)?|\d{1,2}\s*[时:：]\s*\d{1,2}(?:\s*分(?:\s*\d{1,2}\s*秒)?)?)(?:\s*[许左右])?[，,。；;：:\s]*/;
    const leadingBoilerplateRe = /^(?:[\u4e00-\u9fa5A-Za-z0-9]{0,20}(?:消防救援支队|消防救援大队|支队|大队|指挥中心|接警中心|值班室|中队|救援站))?\s*(?:接到?(?:群众|市民|路人|110|119|上级|指挥中心|报警人)?(?:电话|转警|报警|警情|通知|指令)|接到|接警|接报|转警|接群众报警|接110转警|收到警情)\s*(?:称有|称|反映|求助)?\s*[：:，,、\s]*/;
    const leadingRefAddrRe = /^(?:[（(]?位于[)）]?\s*)?(?:上述地址|上址|该地址)\s*[：:，,、\s]*/;

    for (let round = 0; round < 2; round++) {
      const before = desc;
      desc = desc.replace(leadingDateTimeRe, '');
      desc = desc.replace(leadingBoilerplateRe, '');
      desc = desc.replace(leadingRefAddrRe, '');
      if (desc === before) break;
    }

    // 2) 去掉前导“位于”后，若以完整地址或剥离省市区前缀后的街道门牌子串(>=4字)开头且剥离后仍余>=4个有效字，则剥离重复地址
    const withoutLocated = desc.replace(/^[（(]?位于[)）]?\s*/, '');
    if (withoutLocated !== desc && withoutLocated.replace(/[^\u4e00-\u9fa5A-Za-z0-9]/g, '').length >= 4) {
      desc = withoutLocated;
    }
    const addrCandidates = buildAddressStripCandidates(crime_address, addrClean);
    for (const prefix of addrCandidates) {
      if (prefix.length >= 4 && desc.startsWith(prefix)) {
        const rest = desc.slice(prefix.length).replace(/^[，,。；;：:、\s的]+/, '');
        if (rest.replace(/[^\u4e00-\u9fa5A-Za-z0-9]/g, '').length >= 4) {
          desc = rest;
          break;
        }
      }
    }

    // 3) 剥离尾部派警时间线与队站出动后续文本
    desc = desc
      .replace(/[，,。；;\s]*(?:(?:\d{4}年)?(?:\d{1,2}月)?(?:\d{1,2}[日号])?\s*\d{1,2}[时:：]\d{1,2}(?:分)?(?:\s*许)?\s*[，,、\s]*)?(?:支队|大队|指挥中心)?接到?(?:110|119|群众)?(?:报警|转警|警情|指令|通知)后[\s\S]*$/, '')
      .replace(/[，,。；;\s]*(?:(?:\d{4}年)?(?:\d{1,2}月)?(?:\d{1,2}[日号])?\s*\d{1,2}[时:：]\d{1,2}(?:分)?(?:\s*许)?\s*[，,、\s]*)?(?:(?:调派|派出(?!所)|指令|通知|增派|加派|由)\s*(?:[\u4e00-\u9fa5A-Za-z0-9]{1,20}(?:消防救援站|专职消防队|专职队|特勤站|战保站|中队|大队|支队|站|队|产业园|化工园|集聚区)[、及和\s]*)*)?[\u4e00-\u9fa5A-Za-z0-9]{1,20}(?:消防救援站|专职消防队|专职队|特勤站|战保站|中队|大队|支队|站|队|产业园|化工园|集聚区)\s*出动\s*\d{1,2}\s*车[\s\S]*$/, '');

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
  const base = (obj && obj !== '其他') ? `${type}（${obj}）` : type;

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

function normalizeStationKey(name) {
  return String(name || '').normalize('NFKC').replace(/\s+/g, '').trim();
}

function inferDeploymentStatus(officialStatus = '', describe = '') {
  const combined = `${officialStatus} ${describe}`;
  if (/出动|到场|展开|出水|控制|熄灭|归队|处置/.test(combined)) {
    return 'mobilized';
  }
  if (/调派|调集|立案|接警/.test(combined)) {
    return 'dispatched';
  }
  return 'dispatched';
}

function parseIntOrNull(val) {
  if (val === null || val === undefined || val === '') return null;
  if (typeof val === 'boolean') return null;
  const n = Number(val);
  if (!Number.isInteger(n) || n < 0 || n > 999) return null;
  return n;
}

function cleanParsedStationName(raw) {
  let s = String(raw || '').trim();
  s = s.replace(/^.*?(?:接到?(?:报警|转警|警情|指令|通知)后)/, '');
  s = s.replace(/^.*?(?:调派|派出(?!所)|指令|通知|增派|加派)/, '');
  s = s.replace(/^(?:调派|派出(?!所)|指令|通知|增派|加派)+/, '');
  s = s.replace(/^(?:同时|立即|随后|随即|另外|另|并|再|又|由)+/, '');
  return s.trim();
}

function parseStructuredForces({
  squadron_name = '',
  dispatch_organization = '',
  dispatch_vehicle = '',
  incident_describe = '',
  incident_status = '',
  dispatched_forces = null,
} = {}) {
  const status = inferDeploymentStatus(sanitizeOfficialStatus(incident_status), incident_describe);

  // 如果已有合法的结构化数组，则做归一化清洗后优先返回
  if (Array.isArray(dispatched_forces) && dispatched_forces.length > 0) {
    const deduped = [];
    const seen = new Set();
    for (const item of dispatched_forces) {
      const stationName = cleanText(item?.station_name, 80);
      const key = normalizeStationKey(stationName);
      if (!key || seen.has(key)) continue;
      seen.add(key);
      const dep = VALID_DEPLOYMENT_STATUSES.has(item?.deployment_status) ? item.deployment_status : status;
      deduped.push({
        station_name: stationName,
        vehicle_count: parseIntOrNull(item?.vehicle_count),
        personnel_count: parseIntOrNull(item?.personnel_count),
        deployment_status: dep,
      });
    }
    if (deduped.length > 0) return deduped.slice(0, 20);
  }

  const forcesMap = new Map();
  const addStation = (rawName, vehicleCount = null, personnelCount = null) => {
    const clean = cleanText(rawName, 80);
    const key = normalizeStationKey(clean);
    if (!key) return;
    const prev = forcesMap.get(key);
    if (!prev) {
      forcesMap.set(key, {
        station_name: clean,
        vehicle_count: vehicleCount,
        personnel_count: personnelCount,
        deployment_status: status,
      });
    } else {
      if (prev.vehicle_count == null && vehicleCount != null) prev.vehicle_count = vehicleCount;
      if (prev.personnel_count == null && personnelCount != null) prev.personnel_count = personnelCount;
    }
  };

  // 1. 解析文本中明确提到的“某站/某队/产业园出动X车（车型）Y人”
  const desc = String(incident_describe || '');
  const mentionPattern = /([\u4e00-\u9fa5A-Za-z0-9]{2,24}(?:消防救援站|专职消防队|专职队|特勤站|战保站|中队|站|产业园|化工园|集聚区))\s*(?:出动\s*)?(\d{1,2})\s*车(?:\s*[（(][^）)\n]{1,40}[）)])?(?:\s*(\d{1,3})\s*人(?!被困|受伤|伤亡|死亡))?/g;
  for (const match of desc.matchAll(mentionPattern)) {
    const stationName = cleanParsedStationName(match[1]);
    if (stationName) {
      addStation(stationName, parseIntOrNull(match[2]), parseIntOrNull(match[3]));
    }
  }

  // 2. 解析 dispatch_organization（可能是纯数字站数，也可能是具体站名列表）
  const orgRaw = String(dispatch_organization || '').trim();
  const orgCount = /^\d+$/.test(orgRaw) ? Number(orgRaw) : 0;
  if (orgRaw && !/^\d+$/.test(orgRaw)) {
    for (const part of orgRaw.split(/[、,，;；/\s]+/)) {
      const candidate = part.trim();
      if (candidate && candidate !== '0') addStation(candidate);
    }
  }

  // 3. 主调队站
  const mainStation = cleanText(squadron_name, 80);
  if (mainStation) {
    addStation(mainStation);
  }

  const list = [...forcesMap.values()];
  // 当只有 1 个具名队站且总出动站数 <= 1 时，可将总出动车辆数精确归属到该站；多站且分摊未知时保留 null（待补充），避免虚报
  const totalVehicles = parseIntOrNull(dispatch_vehicle);
  if (list.length === 1 && orgCount <= 1 && totalVehicles != null && totalVehicles > 0) {
    if (list[0].vehicle_count == null) {
      list[0].vehicle_count = totalVehicles;
    }
  }

  return list.slice(0, 20);
}

function extractForcesFromHomeInfo(homeInfoData, fallbackStatus = 'dispatched') {
  if (!homeInfoData || typeof homeInfoData !== 'object') return [];
  const defaultStatus = VALID_DEPLOYMENT_STATUSES.has(fallbackStatus) ? fallbackStatus : 'dispatched';
  const MOBILIZED_STATUS_RE = /出动|途中|到场|展开|出水|控制|熄灭|归队|中返|途返|处置/;

  const stationMap = new Map();
  const ensureStation = (rawName) => {
    const clean = cleanText(rawName, 80);
    const key = normalizeStationKey(clean);
    if (!key || clean === '0' || clean.toLowerCase() === 'null') return null;
    if (!stationMap.has(key)) {
      stationMap.set(key, {
        station_name: clean,
        vehicleKeys: new Map(),
        vehicle_count: null,
        personnel_count: null,
        deployment_status: defaultStatus,
      });
    }
    return stationMap.get(key);
  };

  // 1. 解析 handleOrganizationVehicleList[]：按 organizationName 归组并按 vehicleId/vehicleNumber/index 去重
  const vehicleList = Array.isArray(homeInfoData.handleOrganizationVehicleList)
    ? homeInfoData.handleOrganizationVehicleList
    : [];
  const unnamedVehicles = [];
  vehicleList.forEach((v, idx) => {
    if (!v || typeof v !== 'object') return;
    const orgName = cleanText(v.organizationName || v.dispatchOrganizationName || v.stationName, 80);
    const vKey = (v.vehicleId != null && String(v.vehicleId).trim() !== '')
      ? `id:${String(v.vehicleId).trim()}`
      : ((v.vehicleNumber != null && String(v.vehicleNumber).trim() !== '')
        ? `num:${String(v.vehicleNumber).trim()}`
        : `idx:${idx}`);
    const pRaw = parseIntOrNull(v.personNumber);
    const pVal = pRaw != null && pRaw > 0 ? pRaw : null;
    const vStatus = [
      v.vehicleStatusName,
      v.vehicleStatus,
      v.statusName,
      v.status,
      v.dispatchStatusName,
      v.carStatusName,
    ].filter(Boolean).join(' ');
    const mobilized = MOBILIZED_STATUS_RE.test(vStatus);

    if (!orgName) {
      unnamedVehicles.push({ vKey, pVal, mobilized });
      return;
    }
    const entry = ensureStation(orgName);
    if (!entry) return;
    if (mobilized) entry.deployment_status = 'mobilized';
    if (!entry.vehicleKeys.has(vKey)) {
      entry.vehicleKeys.set(vKey, pVal);
    } else if (entry.vehicleKeys.get(vKey) == null && pVal != null) {
      entry.vehicleKeys.set(vKey, pVal);
    }
  });

  // 仅当该站全部车辆均报告正整数(>0)时才累加人数，存在"0"或空值时保持 null（待补充）
  for (const entry of stationMap.values()) {
    if (entry.vehicleKeys.size > 0) {
      entry.vehicle_count = entry.vehicleKeys.size;
      const personNums = [...entry.vehicleKeys.values()];
      if (personNums.every((n) => n != null && n > 0)) {
        entry.personnel_count = personNums.reduce((sum, n) => sum + n, 0);
      } else {
        entry.personnel_count = null;
      }
    }
  }

  // 2. 结合 dpqk[] 与 dcqk[] 的 organizationName 与 handleBean 补缺
  const dispatchEntries = [
    ...(Array.isArray(homeInfoData.dpqk) ? homeInfoData.dpqk : []),
    ...(Array.isArray(homeInfoData.dcqk) ? homeInfoData.dcqk : []),
  ];
  for (const item of dispatchEntries) {
    if (!item || typeof item !== 'object') continue;
    const entry = ensureStation(item.organizationName);
    if (!entry) continue;
    const itemStatus = [
      item.statusName,
      item.handleStatusName,
      item.dispatchStatusName,
      item.handleBean?.statusName,
      item.handleBean?.dispatchStatusName,
    ].filter(Boolean).join(' ');
    if (MOBILIZED_STATUS_RE.test(itemStatus)) {
      entry.deployment_status = 'mobilized';
    }
    const bean = item.handleBean && typeof item.handleBean === 'object' ? item.handleBean : item;
    const vNum = parseIntOrNull(bean.dispatchVehicleNum);
    if (entry.vehicle_count == null && vNum != null && vNum > 0) {
      entry.vehicle_count = vNum;
    }
    const pNum = parseIntOrNull(bean.handlePersonNum);
    if (entry.personnel_count == null && pNum != null && pNum > 0) {
      entry.personnel_count = pNum;
    }
  }

  // 3. 结合 handleShowBeanList[] 补全未出现队站（仅单站且能确定车辆列表时补车数，多站保持 null）
  const showBeans = Array.isArray(homeInfoData.handleShowBeanList)
    ? homeInfoData.handleShowBeanList
    : [];
  for (const bean of showBeans) {
    if (!bean || typeof bean !== 'object') continue;
    const rawOrg = String(bean.dispatchOrganizationName || '').trim();
    if (!rawOrg) continue;
    const parts = rawOrg
      .split(/[、,，;；/\s]+/)
      .map((s) => cleanText(s, 80))
      .filter((s) => s && s !== '0' && s.toLowerCase() !== 'null');
    if (parts.length === 0) continue;

    const beanVehicles =
      bean.vehicleList ||
      bean.dispatchVehicleList ||
      bean.handleVehicleList ||
      bean.handleOrganizationVehicleList ||
      bean.vehicles ||
      bean.carList;

    for (const part of parts) {
      const entry = ensureStation(part);
      if (!entry) continue;
      if (parts.length === 1 && entry.vehicle_count == null && Array.isArray(beanVehicles) && beanVehicles.length > 0) {
        const deduped = new Set();
        beanVehicles.forEach((v, idx) => {
          const vk = (v && typeof v === 'object')
            ? ((v.vehicleId != null && String(v.vehicleId).trim() !== '')
              ? `id:${String(v.vehicleId).trim()}`
              : ((v.vehicleNumber != null && String(v.vehicleNumber).trim() !== '')
                ? `num:${String(v.vehicleNumber).trim()}`
                : `idx:${idx}`))
            : `raw:${String(v || idx)}`;
          deduped.add(vk);
        });
        if (deduped.size > 0) {
          entry.vehicle_count = deduped.size;
        }
      }
    }
  }

  // 若仅有 1 个具名队站且车辆列表存在未标明队站的车辆记录，则归属到该唯一队站
  if (stationMap.size === 1 && unnamedVehicles.length > 0) {
    const onlyEntry = [...stationMap.values()][0];
    if (onlyEntry.vehicle_count == null) {
      const deduped = new Map();
      for (const uv of unnamedVehicles) {
        if (uv.mobilized) onlyEntry.deployment_status = 'mobilized';
        if (!deduped.has(uv.vKey)) {
          deduped.set(uv.vKey, uv.pVal);
        } else if (deduped.get(uv.vKey) == null && uv.pVal != null) {
          deduped.set(uv.vKey, uv.pVal);
        }
      }
      if (deduped.size > 0) {
        onlyEntry.vehicle_count = deduped.size;
        const pVals = [...deduped.values()];
        if (onlyEntry.personnel_count == null && pVals.every((n) => n != null && n > 0)) {
          onlyEntry.personnel_count = pVals.reduce((sum, n) => sum + n, 0);
        }
      }
    }
  }

  return [...stationMap.values()]
    .slice(0, 20)
    .map(({ station_name, vehicle_count, personnel_count, deployment_status }) => ({
      station_name,
      vehicle_count,
      personnel_count,
      deployment_status,
    }));
}

function mergeHomeInfoIntoIncident(ext = {}, homeInfoData = null) {
  const base = ext && typeof ext === 'object' ? { ...ext } : {};
  if (!homeInfoData || typeof homeInfoData !== 'object') {
    return base;
  }

  const existingDesc = String(base.incident_describe || '').trim();
  const homeDesc = String(homeInfoData.incidentDescribe || '').trim();
  const descBackfilled = !existingDesc && Boolean(homeDesc);
  if (descBackfilled) {
    base.incident_describe = homeDesc;
  }

  const fallbackStatus = inferDeploymentStatus(
    sanitizeOfficialStatus(base.incident_status),
    base.incident_describe,
  );
  const homeForces = extractForcesFromHomeInfo(homeInfoData, fallbackStatus);
  const existingForces = Array.isArray(base.dispatched_forces) && base.dispatched_forces.length > 0
    ? parseStructuredForces({ ...base, dispatched_forces: base.dispatched_forces })
    : [];
  const textForces = parseStructuredForces({ ...base, dispatched_forces: null });

  const pickPositiveInt = (...vals) => {
    for (const v of vals) {
      const n = parseIntOrNull(v);
      if (n != null && n > 0) return n;
    }
    return null;
  };

  const mergedMap = new Map();
  const upsertMerged = (force, source) => {
    const cleanName = cleanText(force?.station_name, 80);
    const key = normalizeStationKey(cleanName);
    if (!key) return;
    const prev = mergedMap.get(key) || {
      station_name: cleanName,
      deployment_status: fallbackStatus,
      _home_vehicle: null,
      _text_vehicle: null,
      _existing_vehicle: null,
      _home_person: null,
      _text_person: null,
      _existing_person: null,
    };
    if (source === 'home') {
      prev._home_vehicle = force.vehicle_count;
      prev._home_person = force.personnel_count;
      if (cleanName) prev.station_name = cleanName;
    } else if (source === 'text') {
      prev._text_vehicle = force.vehicle_count;
      prev._text_person = force.personnel_count;
    } else {
      prev._existing_vehicle = force.vehicle_count;
      prev._existing_person = force.personnel_count;
    }
    if (force.deployment_status === 'mobilized') {
      prev.deployment_status = 'mobilized';
    } else if (!VALID_DEPLOYMENT_STATUSES.has(prev.deployment_status) && VALID_DEPLOYMENT_STATUSES.has(force.deployment_status)) {
      prev.deployment_status = force.deployment_status;
    }
    mergedMap.set(key, prev);
  };

  for (const f of existingForces) upsertMerged(f, 'existing');
  for (const f of textForces) upsertMerged(f, 'text');
  for (const f of homeForces) upsertMerged(f, 'home');

  const mergedForces = [...mergedMap.values()]
    .slice(0, 20)
    .map((item) => ({
      station_name: item.station_name,
      vehicle_count: pickPositiveInt(item._home_vehicle, item._text_vehicle, item._existing_vehicle),
      personnel_count: pickPositiveInt(item._existing_person, item._text_person, item._home_person),
      deployment_status: item.deployment_status,
    }));

  const hasValidAiSummary = base.ai_status === 'ready' && Boolean(cleanText(base.event_summary, 60));
  const nextInput = {
    ...base,
    dispatched_forces: mergedForces.length > 0 ? mergedForces : base.dispatched_forces,
  };

  if (descBackfilled) {
    if (!hasValidAiSummary) {
      delete nextInput.event_summary;
      delete nextInput.situation_detail;
    } else if (nextInput.situation_detail === buildSituationDescription({ ...base, incident_describe: '' })) {
      delete nextInput.situation_detail;
    }
    delete nextInput.raw_merged_text;
    delete nextInput.content_hash;
  }

  return buildRuleFallbackStructured(nextInput, nextInput.raw_payload);
}

function extractCasualtiesAndHazmat(describe = '') {
  const text = String(describe || '');
  let trapped = '';
  let injured = '';
  let hazardous_materials = '';

  const trappedMatch = text.match(/(?:暂)?无人员被困|没有人员被困|有\d*名?人员被困|人员被困情况不明|[\u4e00-\u9fa50-9]{0,6}被困/);
  if (trappedMatch && /(?:被困)/.test(trappedMatch[0])) {
    trapped = trappedMatch[0];
  }

  const injuredMatch = text.match(/(?:暂)?无人员(?:伤亡|受伤)|没有人员(?:伤亡|受伤)|有\d*名?人员(?:伤亡|受伤)/);
  if (injuredMatch) {
    injured = injuredMatch[0];
  }

  const hazmatMatch = text.match(/(?:液化气|天然气|煤气|燃气|汽油|柴油|乙醇|甲醇|危化品|化学品|锂电池|硫酸|氨气)/);
  if (hazmatMatch) {
    hazardous_materials = hazmatMatch[0];
  }

  return { trapped, injured, hazardous_materials };
}

function extractFactHighlights({
  event_summary = '',
  incident_level = '',
  disposal_object_name = '',
  trapped = '',
  injured = '',
  hazardous_materials = '',
  official_status = '',
} = {}) {
  const tags = [];
  const pushUnique = (val) => {
    const clean = cleanText(val, 24);
    if (!clean || clean === '其他') return;
    if (event_summary.includes(clean)) return;
    if (!tags.includes(clean)) tags.push(clean);
  };

  if (trapped && !/无人员被困/.test(trapped)) pushUnique(trapped);
  if (injured && !/无人员(?:伤亡|受伤)/.test(injured)) pushUnique(injured);
  if (hazardous_materials) pushUnique(`涉${hazardous_materials}`);
  if (disposal_object_name && disposal_object_name !== '其他') pushUnique(disposal_object_name);
  if (incident_level) pushUnique(incident_level);
  if (official_status) pushUnique(official_status);

  return tags.slice(0, 3);
}

const KNOWN_RAW_KEYS = new Set([
  'id', 'external_id', 'incidentNumber', 'incident_number',
  'detachmentOrgName', 'detachment_name', 'brigadeOrganizationName', 'brigade_name',
  'squadronOrganizationName', 'squadron_name', 'districtName', 'district_name',
  'incidentTypeName', 'incident_type', 'disposalObjectName', 'disposal_object_name',
  'incidentLevelName', 'incident_level', 'incidentStatusName', 'incident_status',
  'crimeAddress', 'crime_address', 'incidentDescribe', 'incident_describe',
  'registerIncidentTime', 'register_time', 'latitude', 'longitude',
  'alarmPhone', 'alarm_phone', 'alarmPersonPhone', 'alarm_person_phone',
  'alarmPersonName', 'alarm_person_name', 'alarmModeName', 'alarm_mode_name',
  'incidentNatureName', 'incident_nature_name',
  'dispatchVehicle', 'dispatch_vehicle', 'dispatchOrganization', 'dispatch_organization',
  'dispatchPerson', 'dispatchPersonnel', 'dispatch_person',
  'dispatchTime', 'dispatch_time', 'firstDispatchTime', 'sendTime',
  'siteVehicle', 'site_vehicle', 'siteOrganization', 'site_organization',
  'whetherTestSign', 'whether_test_sign', 'detachmentOrgId', 'detachment_id',
  'dispatchStatusName', 'dispatchStatus', 'dispatch_status',
  'whetherDispatch', 'isDispatch',
  'raw_payload', 'raw_merged_text', 'content_hash',
]);

function buildRawMergedText(rawItem = {}, normalized = {}) {
  const src = { ...(rawItem && typeof rawItem === 'object' ? rawItem : {}), ...normalized };
  const lines = [];
  const addLine = (label, value) => {
    const s = cleanText(value, 1500);
    if (s) lines.push(`${label}: ${s}`);
  };

  addLine('警情编号', src.incident_number || src.incidentNumber);
  addLine('立案时间', formatBeijingReadable(src.register_time || src.registerIncidentTime));
  addLine('所属支队', src.detachment_name || src.detachmentOrgName);
  addLine('所属大队', src.brigade_name || src.brigadeOrganizationName);
  addLine('主调队站', src.squadron_name || src.squadronOrganizationName);
  addLine('行政区域', resolveDistrict(src));
  addLine('警情类型', src.incident_type || src.incidentTypeName);
  addLine('处置对象', src.disposal_object_name || src.disposalObjectName);
  addLine('警情等级', src.incident_level || src.incidentLevelName);
  addLine('警情性质', src.incident_nature_name || src.incidentNatureName);
  addLine('官方状态', sanitizeOfficialStatus(src.incident_status || src.incidentStatusName));
  addLine('调派状态', src.dispatchStatusName || src.dispatchStatus || src.dispatch_status);
  addLine('接警方式', src.alarm_mode_name || src.alarmModeName);
  addLine('原始地址', src.crime_address || src.crimeAddress);
  if (src.latitude && src.longitude) {
    addLine('经纬度', `${src.latitude}, ${src.longitude}`);
  }
  addLine('警情描述', src.incident_describe || src.incidentDescribe);
  const dv = String(src.dispatch_vehicle || src.dispatchVehicle || '').trim();
  if (dv && dv !== '0') addLine('出动车辆数', `${dv}车`);
  const dp = parseIntOrNull(src.dispatch_person ?? src.dispatchPerson ?? src.dispatchPersonnel);
  if (dp != null && dp > 0) addLine('出动人数', `${dp}人`);
  const dorg = String(src.dispatch_organization || src.dispatchOrganization || '').trim();
  if (dorg && dorg !== '0') addLine('出动队站', dorg);

  const alarmName = cleanText(src.alarm_person_name || src.alarmPersonName, 80);
  const alarmPhone = cleanText(src.alarm_person_phone || src.alarmPersonPhone || src.alarm_phone || src.alarmPhone, 40);
  if (alarmName || alarmPhone) {
    addLine('报警联系', [alarmName, alarmPhone].filter(Boolean).join(' '));
  }

  // 把上游其他非空补充字段一并揉入，避免未来接口新增关键文本被遗漏
  if (rawItem && typeof rawItem === 'object') {
    for (const [k, v] of Object.entries(rawItem)) {
      if (KNOWN_RAW_KEYS.has(k) || v == null) continue;
      if (typeof v === 'string' || typeof v === 'number') {
        const text = cleanText(v, 300);
        if (text && text !== '0' && text !== 'null') {
          lines.push(`扩展字段(${k}): ${text}`);
        }
      }
    }
  }

  return lines.join('\n');
}

function computeContentHash(ext = {}) {
  // 状态词（如出动→到场→归队）频繁变化，排除在外以复用同一警情的 AI 结构化事件结果
  const canonical = {
    external_id: String(ext.external_id || ''),
    incident_number: String(ext.incident_number || ''),
    incident_type: String(ext.incident_type || ''),
    disposal_object_name: String(ext.disposal_object_name || ''),
    incident_level: String(ext.incident_level || ''),
    crime_address: String(ext.crime_address || ''),
    incident_describe: String(ext.incident_describe || ''),
    squadron_name: String(ext.squadron_name || ''),
    brigade_name: String(ext.brigade_name || ''),
    district_name: String(ext.district_name || ''),
    dispatch_vehicle: String(ext.dispatch_vehicle || ''),
    dispatch_organization: String(ext.dispatch_organization || ''),
  };
  return createHash('sha256').update(JSON.stringify(canonical)).digest('hex').slice(0, 24);
}

function buildRuleFallbackStructured(ext = {}, rawItem = null) {
  const district = resolveDistrict(ext);
  const locationDisplay = cleanIncidentLocation(
    cleanText(ext.location_display, 300) || ext.crime_address,
    district,
  );
  const officialStatus = sanitizeOfficialStatus(ext.incident_status);
  const eventSummary = cleanText(ext.event_summary, 60) || cleanIncidentEvent(ext);
  const disasterCategory = classifyDisasterCategory({
    disaster_category: ext.disaster_category,
    incident_type: ext.incident_type,
    disposal_object_name: ext.disposal_object_name,
    incident_describe: ext.incident_describe,
    event_summary: eventSummary,
  });
  const specificType = cleanText(ext.specific_type, 80) ||
    ((ext.disposal_object_name && ext.disposal_object_name !== '其他')
      ? cleanText(ext.disposal_object_name, 80)
      : cleanText(ext.incident_type, 80));
  const situationDetail = cleanText(ext.situation_detail, 1500) || buildSituationDescription(ext);
  const extracted = extractCasualtiesAndHazmat(ext.incident_describe);
  const dispatchedForces = parseStructuredForces(ext);
  const dispatchSummary = buildDispatchSummary(ext);
  const contacts = extractContacts(ext);
  const factHighlights = extractFactHighlights({
    event_summary: eventSummary,
    incident_level: ext.incident_level,
    disposal_object_name: ext.disposal_object_name,
    trapped: extracted.trapped,
    injured: extracted.injured,
    hazardous_materials: extracted.hazardous_materials,
    official_status: officialStatus,
  });
  const rawMergedText = ext.raw_merged_text || buildRawMergedText(rawItem, ext);
  const contentHash = ext.content_hash || computeContentHash(ext);

  return {
    ...ext,
    district_name: district || ext.district_name || '',
    location_display: locationDisplay,
    official_status: officialStatus,
    event_summary: eventSummary,
    disaster_category: disasterCategory,
    specific_type: specificType,
    situation_detail: situationDetail,
    trapped: cleanText(ext.trapped || extracted.trapped, 300),
    injured: cleanText(ext.injured || extracted.injured, 300),
    hazardous_materials: cleanText(ext.hazardous_materials || extracted.hazardous_materials, 500),
    dispatched_forces: dispatchedForces,
    dispatch_summary: dispatchSummary,
    contacts,
    fact_highlights: factHighlights,
    raw_merged_text: rawMergedText,
    content_hash: contentHash,
    ai_status: ext.ai_status || 'fallback',
    ai_model: ext.ai_model || '',
    ai_organized_at: ext.ai_organized_at || null,
  };
}

const ORGANIZE_SYSTEM_PROMPT = `你是消防救援指挥中心的警情信息重组助手。
你会收到一条把原始派警各字段揉合在一起的文本。请阅读全部内容，按消防指挥接处警阅读习惯重新组织字段。

严格规则：
1. 只输出合法 JSON 对象，不要包含 Markdown 代码块或任何解释。
2. 严禁编造或推测原文没有提及的人数、车辆数、伤亡情况或原因；未知文本留空字符串，未知整数填 null。
3. 字段优先级与含义：
   - event_summary：最关键！6~22字，简明扼要说清“什么对象/场所发生了什么灾情”（如“沿街商铺电线短路起火”“居民住宅电梯困人救助”“货车追尾驾驶室人员被困”），禁止直接用街道门牌作为事件摘要。
   - disaster_category：必须是 "fire"（火灾扑救）、"rescue"（抢险救援）或 "aid"（社会救助）之一。
   - specific_type：具体处置对象或细分灾情类型（不超过30字）。
   - incident_level：警情等级（如“一级”“二级”，无则空字符串）。
   - location_display：规范化事发地点，去除冗余省/地级市与重复县区前缀，但务必完整保留区县、乡镇街道、村社、路名门牌与楼栋详情。
   - district_name：所属区县名称（如“示例县”，无则空字符串）。
   - situation_detail：简明清晰的现场情况汇总。
   - trapped / injured / hazardous_materials：明确提及的被困、受伤、危化品情况原文摘录，未提及留空字符串。
   - fact_highlights：0~3条简短高价值补充标签（如 ["四层民房","有人员被困"]），不要与 event_summary 或 location_display 重复。
   - dispatched_forces：数组，每项 {"station_name":"","vehicle_count":null,"personnel_count":null}；只有原文或出动字段明确且唯一指向某队站数量时才填整数，否则填 null，禁止凭空平分车辆数。`;

async function organizeWithDeepSeek({
  apiKey,
  baseUrl = 'https://api.deepseek.com',
  model = 'deepseek-chat',
  rawMergedText,
  fallback,
  fetchImpl = fetch,
  timeoutMs = 8000,
} = {}) {
  if (!apiKey || !rawMergedText) {
    return { ...fallback, ai_status: apiKey ? 'failed' : 'fallback' };
  }

  try {
    const endpoint = `${String(baseUrl || 'https://api.deepseek.com').replace(/\/+$/, '')}/chat/completions`;
    const res = await fetchImpl(endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: model || 'deepseek-chat',
        temperature: 0.1,
        max_tokens: 800,
        response_format: { type: 'json_object' },
        messages: [
          { role: 'system', content: ORGANIZE_SYSTEM_PROMPT },
          { role: 'user', content: `请整理以下原始派警全量信息：\n\n${rawMergedText}` },
        ],
      }),
      signal: AbortSignal.timeout(timeoutMs),
    });

    if (!res.ok) {
      logger.warn(`[ExternalOrganizer] DeepSeek HTTP ${res.status}`);
      return { ...fallback, ai_status: 'failed' };
    }

    const payload = await res.json();
    const content = payload?.choices?.[0]?.message?.content;
    if (!content) {
      return { ...fallback, ai_status: 'failed' };
    }

    const parsed = JSON.parse(
      String(content).trim().replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, ''),
    );
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
      return { ...fallback, ai_status: 'failed' };
    }

    const eventSummary = cleanText(parsed.event_summary, 60) || fallback.event_summary;
    const category = VALID_CATEGORIES.has(parsed.disaster_category)
      ? parsed.disaster_category
      : classifyDisasterCategory({
        incident_type: fallback.incident_type,
        disposal_object_name: parsed.specific_type || fallback.specific_type,
        event_summary: eventSummary,
        incident_describe: fallback.incident_describe,
      });
    const locationDisplay = cleanIncidentLocation(
      cleanText(parsed.location_display, 300) || fallback.location_display,
      cleanText(parsed.district_name, 40) || fallback.district_name,
    );
    const districtName = cleanText(parsed.district_name, 40) || fallback.district_name;
    const specificType = cleanText(parsed.specific_type, 80) || fallback.specific_type;
    const incidentLevel = cleanText(parsed.incident_level, 40) || fallback.incident_level;
    const situationDetail = cleanText(parsed.situation_detail, 1500) || fallback.situation_detail;
    const trapped = cleanText(parsed.trapped, 300) || fallback.trapped;
    const injured = cleanText(parsed.injured, 300) || fallback.injured;
    const hazardousMaterials = cleanText(parsed.hazardous_materials, 500) || fallback.hazardous_materials;

    const rawHighlights = Array.isArray(parsed.fact_highlights) ? parsed.fact_highlights : [];
    const factHighlights = rawHighlights
      .map((item) => cleanText(item, 28))
      .filter((item) => item && !eventSummary.includes(item))
      .slice(0, 3);

    const parsedForces = Array.isArray(parsed.dispatched_forces) && parsed.dispatched_forces.length > 0
      ? parseStructuredForces({
        ...fallback,
        dispatched_forces: parsed.dispatched_forces,
      })
      : fallback.dispatched_forces;

    return {
      ...fallback,
      event_summary: eventSummary,
      disaster_category: category,
      specific_type: specificType,
      incident_level: incidentLevel,
      location_display: locationDisplay || fallback.location_display,
      district_name: districtName,
      situation_detail: situationDetail,
      trapped,
      injured,
      hazardous_materials: hazardousMaterials,
      fact_highlights: factHighlights.length > 0 ? factHighlights : fallback.fact_highlights,
      dispatched_forces: parsedForces,
      ai_status: 'ready',
      ai_model: model || 'deepseek-chat',
      ai_organized_at: Date.now(),
    };
  } catch (err) {
    logger.warn(`[ExternalOrganizer] DeepSeek organize fallback: ${err?.message || String(err)}`);
    return { ...fallback, ai_status: 'failed' };
  }
}

function rowToNormalizedPatch(row, liveFallback) {
  if (!row) return liveFallback;
  const parseJsonArray = (val) => {
    if (Array.isArray(val)) return val;
    if (typeof val === 'string') {
      try {
        const parsed = JSON.parse(val);
        return Array.isArray(parsed) ? parsed : [];
      } catch {
        return [];
      }
    }
    return [];
  };
  const forces = parseJsonArray(row.dispatched_forces);
  const highlights = parseJsonArray(row.fact_highlights);
  const contacts = parseJsonArray(row.contacts);
  return {
    ...liveFallback,
    event_summary: row.event_summary || liveFallback.event_summary,
    disaster_category: VALID_CATEGORIES.has(row.disaster_category)
      ? row.disaster_category
      : liveFallback.disaster_category,
    specific_type: row.specific_type || liveFallback.specific_type,
    incident_level: row.incident_level || liveFallback.incident_level,
    // 官方状态以实时抓取值优先，保障状态变化零延迟反映
    official_status: liveFallback.official_status || sanitizeOfficialStatus(row.official_status),
    location_display: row.location_display || liveFallback.location_display,
    district_name: row.district_name || liveFallback.district_name,
    situation_detail: row.situation_detail || liveFallback.situation_detail,
    trapped: row.trapped || liveFallback.trapped,
    injured: row.injured || liveFallback.injured,
    hazardous_materials: row.hazardous_materials || liveFallback.hazardous_materials,
    dispatch_summary: row.dispatch_summary || liveFallback.dispatch_summary,
    dispatched_forces: forces.length > 0 ? forces : liveFallback.dispatched_forces,
    fact_highlights: highlights.length > 0 ? highlights : liveFallback.fact_highlights,
    contacts: contacts.length > 0 ? contacts : liveFallback.contacts,
    raw_merged_text: row.raw_merged_text || liveFallback.raw_merged_text,
    content_hash: row.content_hash || liveFallback.content_hash,
    ai_status: row.ai_status || liveFallback.ai_status,
    ai_model: row.ai_model || '',
    ai_organized_at: row.ai_organized_at ? Number(row.ai_organized_at) : null,
  };
}

function createExternalIncidentOrganizer({
  store = null,
  syncSupported = () => false,
  getLlmConfig = () => ({}),
  fetchImpl = fetch,
  maxConcurrency = 3,
} = {}) {
  const memoryStore = new Map();
  const inFlightAi = new Map();

  async function loadExistingRows(externalIds) {
    const ids = [...new Set(externalIds.filter(Boolean))];
    const map = new Map();
    if (ids.length === 0) return map;

    if (syncSupported() && store) {
      try {
        const rows = await store.select('external_incidents', {
          filters: { external_id: { op: 'in', value: ids } },
        });
        for (const row of rows) {
          map.set(row.external_id, row);
        }
        return map;
      } catch (err) {
        logger.warn(`[ExternalOrganizer] loadExistingRows DB fallback: ${err?.message || String(err)}`);
      }
    }

    for (const id of ids) {
      if (memoryStore.has(id)) map.set(id, memoryStore.get(id));
    }
    return map;
  }

  async function saveRow(item, now = Date.now()) {
    const row = {
      external_id: String(item.external_id || ''),
      incident_number: String(item.incident_number || ''),
      raw_payload: JSON.stringify(item.raw_payload || {}),
      raw_merged_text: String(item.raw_merged_text || ''),
      content_hash: String(item.content_hash || ''),
      ai_status: item.ai_status || 'fallback',
      ai_model: String(item.ai_model || ''),
      ai_organized_at: item.ai_organized_at ? Number(item.ai_organized_at) : null,
      event_summary: String(item.event_summary || ''),
      disaster_category: VALID_CATEGORIES.has(item.disaster_category) ? item.disaster_category : 'fire',
      incident_type: String(item.incident_type || ''),
      specific_type: String(item.specific_type || ''),
      incident_level: String(item.incident_level || ''),
      official_status: String(item.official_status || ''),
      location_display: String(item.location_display || ''),
      crime_address: String(item.crime_address || ''),
      district_name: String(item.district_name || ''),
      detachment_name: String(item.detachment_name || ''),
      brigade_name: String(item.brigade_name || ''),
      squadron_name: String(item.squadron_name || ''),
      register_time: Number(item.register_time) || 0,
      latitude: item.latitude != null ? String(item.latitude) : null,
      longitude: item.longitude != null ? String(item.longitude) : null,
      situation_detail: String(item.situation_detail || ''),
      trapped: String(item.trapped || ''),
      injured: String(item.injured || ''),
      hazardous_materials: String(item.hazardous_materials || ''),
      dispatch_summary: String(item.dispatch_summary || ''),
      dispatched_forces: JSON.stringify(item.dispatched_forces || []),
      fact_highlights: JSON.stringify(item.fact_highlights || []),
      contacts: JSON.stringify(item.contacts || []),
      scraped_at: now,
      updated_at: now,
    };

    memoryStore.set(row.external_id, {
      ...row,
      dispatched_forces: item.dispatched_forces || [],
      fact_highlights: item.fact_highlights || [],
      contacts: item.contacts || [],
      raw_payload: item.raw_payload || {},
    });

    if (syncSupported() && store) {
      try {
        await store.upsert('external_incidents', [row], { onConflict: 'external_id' });
      } catch (err) {
        logger.warn(`[ExternalOrganizer] saveRow DB fallback: ${err?.message || String(err)}`);
      }
    }
  }

  function scheduleAiOrganize(candidate, llm) {
    const key = `${candidate.external_id}:${candidate.content_hash}`;
    if (inFlightAi.has(key)) return inFlightAi.get(key);

    const task = (async () => {
      try {
        const organized = await organizeWithDeepSeek({
          apiKey: llm.apiKey,
          baseUrl: llm.baseUrl,
          model: llm.importModel || llm.model || 'deepseek-chat',
          rawMergedText: candidate.raw_merged_text,
          fallback: candidate,
          fetchImpl,
        });
        await saveRow(organized, Date.now());
        return organized;
      } finally {
        inFlightAi.delete(key);
      }
    })();

    inFlightAi.set(key, task);
    return task;
  }

  async function runBoundedTasks(candidates, llm) {
    const results = new Map();
    const queue = candidates.slice();
    const workers = Array.from({ length: Math.min(maxConcurrency, queue.length) }, async () => {
      while (queue.length > 0) {
        const item = queue.shift();
        if (!item) break;
        const done = await scheduleAiOrganize(item, llm);
        results.set(item.external_id, done);
      }
    });
    await Promise.allSettled(workers);
    return results;
  }

  async function syncIncidents(scrapedList = [], {
    awaitAi = false,
    maxAwaitMs = 2500,
    forceReorganizeIds = null,
  } = {}) {
    if (!Array.isArray(scrapedList) || scrapedList.length === 0) return [];
    const now = Date.now();
    const llm = typeof getLlmConfig === 'function' ? (getLlmConfig() || {}) : {};
    const hasAi = Boolean(llm.apiKey);
    const forceSet = Array.isArray(forceReorganizeIds) && forceReorganizeIds.length > 0
      ? new Set(forceReorganizeIds.map(String))
      : null;

    const fallbacks = scrapedList.map((raw) => buildRuleFallbackStructured(raw, raw?.raw_payload));
    const existingMap = await loadExistingRows(fallbacks.map((item) => item.external_id));

    const results = [];
    const needAi = [];

    for (const fallback of fallbacks) {
      const existing = existingMap.get(fallback.external_id);
      const forced = forceSet == null ? Boolean(forceReorganizeIds === true) : forceSet.has(fallback.external_id);
      const cacheValid = !forced && existing &&
        existing.content_hash === fallback.content_hash &&
        existing.ai_status === 'ready';

      if (cacheValid) {
        const merged = rowToNormalizedPatch(existing, fallback);
        if (existing.official_status !== fallback.official_status) {
          await saveRow(merged, now);
        }
        results.push(merged);
        continue;
      }

      const initialItem = {
        ...fallback,
        ai_status: hasAi ? 'pending' : 'fallback',
      };
      await saveRow(initialItem, now);
      results.push(initialItem);

      if (hasAi) {
        needAi.push(initialItem);
      }
    }

    if (needAi.length > 0) {
      const aiPromise = runBoundedTasks(needAi, llm);
      if (awaitAi) {
        let settledMap = null;
        if (maxAwaitMs > 0) {
          settledMap = await Promise.race([
            aiPromise,
            new Promise((resolve) => setTimeout(() => resolve(null), maxAwaitMs)),
          ]);
        } else {
          settledMap = await aiPromise;
        }
        if (settledMap instanceof Map) {
          return results.map((item) => settledMap.get(item.external_id) || item);
        }
      } else {
        aiPromise.catch(() => {});
      }
    }

    return results;
  }

  async function getStoredIncident(externalId) {
    if (!externalId) return null;
    const map = await loadExistingRows([String(externalId)]);
    return map.get(String(externalId)) || null;
  }

  function resetForTests() {
    memoryStore.clear();
    inFlightAi.clear();
  }

  return {
    syncIncidents,
    getStoredIncident,
    saveIncident: (item, now = Date.now()) => saveRow(item, now),
    resetForTests,
  };
}

module.exports = {
  cleanIncidentLocation,
  cleanIncidentEvent,
  buildSituationDescription,
  extractContacts,
  buildDispatchSummary,
  sanitizeCoordinates,
  sanitizeOfficialStatus,
  isTerminalOfficialStatus,
  resolveDistrict,
  classifyDisasterCategory,
  parseStructuredForces,
  extractForcesFromHomeInfo,
  mergeHomeInfoIntoIncident,
  extractCasualtiesAndHazmat,
  extractFactHighlights,
  buildRawMergedText,
  computeContentHash,
  buildRuleFallbackStructured,
  organizeWithDeepSeek,
  rowToNormalizedPatch,
  createExternalIncidentOrganizer,
  formatBeijingIso,
  normalizeStationName: normalizeStationKey,
};
