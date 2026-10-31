const fs = require('node:fs');
const path = require('node:path');

// 仓库里只保留假名示例。真实单位、验证码、人员和消防站由部署时的私有文件或环境变量导入。
const EXAMPLE_SEED_PATH = path.join(__dirname, '..', 'seeds', 'org.example.json');

// 这些是通用战术用语，不是单位身份信息。每个已配置组织都会补齐，避免私有种子漏写后识别退步。
const GENERIC_HOTWORDS = ['头车', '两车', '三车', '四车', '内攻', '搜救', '初战'];

// 与 App 端 org_directory.dart 的 genericAsrTerms 保持一致：无组织时只使用这组词。
const GENERIC_ASR_TERMS = [
  ...GENERIC_HOTWORDS,
  '兆帕', '个压', '气瓶', '空气呼吸器', '余量', '进入火场', '出来了', '已出火场', '收到',
];

function uniqueWords(words) {
  const seen = new Set();
  const result = [];
  for (const word of words) {
    const clean = String(word || '').trim();
    if (!clean || seen.has(clean)) continue;
    seen.add(clean);
    result.push(clean);
  }
  return result;
}

function normalizeStationName(name) {
  return String(name || '').trim().slice(0, 80).replace(/消防救援站$/, '站').replace(/\s+/g, '');
}

function parsePeople(value) {
  const items = Array.isArray(value) ? value : [];
  return uniqueWords(items.map((item) => (typeof item === 'string' ? item : item?.name || item?.real_name)))
    .map((name) => ({ name: name.slice(0, 32) }))
    .filter((item) => item.name);
}

function parseStations(value) {
  const items = Array.isArray(value) ? value : [];
  return uniqueWords(items.map((item) => (typeof item === 'string' ? item : item?.name)))
    .map((name) => name.slice(0, 80))
    .filter((name) => normalizeStationName(name));
}

function parseWordList(value) {
  if (Array.isArray(value)) return uniqueWords(value);
  return [];
}

function envList(value) {
  const raw = String(value || '').trim();
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (Array.isArray(parsed)) return parsed;
  } catch (_) {
    // 逗号分隔与 JSON 都接受，方便在进程环境里写短名单。
  }
  return raw.split(/[,，]/).map((item) => item.trim()).filter(Boolean);
}

function parseSeedMembers(value) {
  const items = Array.isArray(value) ? value : envList(value) || [];
  return items.map((item) => {
    if (typeof item === 'string') {
      const [realName, role = 'member'] = item.split(/[:：]/, 2);
      return { real_name: realName, role };
    }
    return { real_name: item?.real_name ?? item?.name, role: item?.role ?? 'member' };
  }).map((item) => ({
    realName: String(item.real_name || '').trim().slice(0, 32),
    role: ['member', 'manager', 'admin'].includes(String(item.role)) ? String(item.role) : 'member',
  })).filter((item) => item.realName);
}

function emptySeed(id, name, verificationCode) {
  return {
    id, name, verificationCode, firefighters: [], stations: [], hotwords: [...GENERIC_HOTWORDS], members: [],
  };
}

function normalizeSeed(raw) {
  const org = raw?.organization && typeof raw.organization === 'object' ? raw.organization : raw || {};
  return {
    id: String(org.id || '').trim(),
    name: String(org.name || '').trim(),
    verificationCode: String(org.verificationCode || org.verification_code || org.code || '').trim(),
    firefighters: parsePeople(raw?.firefighters || []),
    stations: parseStations(raw?.stations || []),
    hotwords: uniqueWords([...(parseWordList(raw?.hotwords)), ...GENERIC_HOTWORDS]),
    members: parseSeedMembers(raw?.members || []),
  };
}

function loadSeedFile(file) {
  const content = fs.readFileSync(file, 'utf8');
  return normalizeSeed(JSON.parse(content));
}

function resolveOrgSeed(env = process.env) {
  if (String(env.WATCHDOG_SKIP_SEED || '') === '1') return null;
  const file = String(env.WATCHDOG_ORG_SEED_FILE || '').trim();
  const envId = String(env.WATCHDOG_SEED_UNIT_ID || '').trim();
  const envName = String(env.WATCHDOG_SEED_UNIT_NAME || '').trim();
  const envCode = String(env.WATCHDOG_SEED_UNIT_CODE || '').trim();
  let seed = null;
  if (file) {
    seed = loadSeedFile(file);
  } else if (envId && envName && envCode) {
    seed = emptySeed(envId, envName, envCode);
  } else if (env.NODE_ENV === 'test' || String(env.WATCHDOG_USE_EXAMPLE_SEED || '') === '1') {
    seed = loadSeedFile(EXAMPLE_SEED_PATH);
  } else {
    return null;
  }
  if (envId) seed.id = envId;
  if (envName) seed.name = envName;
  if (envCode) seed.verificationCode = envCode;
  const firefighters = envList(env.WATCHDOG_SEED_FIREFIGHTERS);
  if (firefighters) seed.firefighters = parsePeople(firefighters);
  const stations = envList(env.WATCHDOG_SEED_STATIONS);
  if (stations) seed.stations = parseStations(stations);
  const hotwords = envList(env.WATCHDOG_SEED_HOTWORDS);
  if (hotwords) seed.hotwords = uniqueWords([...parseWordList(hotwords), ...GENERIC_HOTWORDS]);
  const members = parseSeedMembers(env.WATCHDOG_SEED_UNIT_MEMBERS);
  if (members.length > 0) seed.members = members;
  seed.hotwords = uniqueWords([...seed.hotwords, ...GENERIC_HOTWORDS]);
  if (!seed.id || !seed.name || !seed.verificationCode) return null;
  return seed;
}

module.exports = {
  EXAMPLE_SEED_PATH,
  GENERIC_HOTWORDS,
  GENERIC_ASR_TERMS,
  normalizeStationName,
  parseSeedMembers,
  resolveOrgSeed,
};
