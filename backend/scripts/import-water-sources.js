#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const VALID_CATEGORIES = new Set(['hydrant', 'natural', 'pump_connector']);
const VALID_STATUSES = new Set(['available', 'unavailable']);
const INTAKE_METHOD_ORDER = ['portable_pump', 'fire_truck', 'remote_supply'];
const VALID_INTAKE_METHODS = new Set(INTAKE_METHOD_ORDER);

const AVAILABLE_COLORS = new Set(['#FF6968', '#7E97FF', '#7AB1F5']);
const UNAVAILABLE_COLORS = new Set(['#FFBF00']);

const FOOTER_MARKERS = [
  '记录所属内容',
  '工作地图中的标记内容',
  '颜色选项的顺序',
];

const NATURAL_KEYWORDS = [
  '天然水源',
  '水塘',
  '鱼塘',
  '消防水池',
  '水池',
  '手抬泵',
  '远程供水',
];

const CONFLICTS_CSV_HEADERS = [
  'source_key',
  'reason',
  'decision',
  'category',
  'status',
  'intake_methods',
  'name',
  'lat',
  'lng',
  'note',
];

const DUPLICATE_RADIUS_METERS = 10;
const EARTH_RADIUS_METERS = 6371000;
const MAX_NAME_LENGTH = 120;
const MAX_NOTE_LENGTH = 500;
const IMPORT_ACTOR_ID = 'import_script';
const IMPORT_ACTOR_NAME = '数据导入脚本';

/**
 * 解析符合 RFC 4180 的 CSV 文本，支持 UTF-8 BOM、双引号转义与引号内嵌换行符。
 * @param {string} rawText
 * @returns {string[][]}
 */
function parseCsv(rawText) {
  const text = String(rawText ?? '').replace(/^\uFEFF/, '');
  const rows = [];
  let row = [];
  let field = '';
  let inQuotes = false;

  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];

    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        field += ch;
      }
      continue;
    }

    if (ch === '"' && field.length === 0) {
      inQuotes = true;
    } else if (ch === ',') {
      row.push(field);
      field = '';
    } else if (ch === '\r') {
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
      if (text[i + 1] === '\n') {
        i += 1;
      }
    } else if (ch === '\n') {
      row.push(field);
      rows.push(row);
      row = [];
      field = '';
    } else {
      field += ch;
    }
  }

  if (inQuotes) {
    throw new Error('CSV 格式错误：存在未闭合的双引号');
  }

  if (field.length > 0 || row.length > 0) {
    row.push(field);
    rows.push(row);
  }

  return rows;
}

/**
 * 将单元格转义为 RFC 4180 格式。
 * @param {unknown} value
 * @returns {string}
 */
function escapeCsvCell(value) {
  const str = value == null ? '' : String(value);
  if (/[",\r\n]/.test(str)) {
    return `"${str.replace(/"/g, '""')}"`;
  }
  return str;
}

/**
 * 序列化带 UTF-8 BOM 的 RFC 4180 CSV 文本。
 * @param {string[]} headers
 * @param {Array<Record<string, unknown> | unknown[]>} rows
 * @returns {string}
 */
function stringifyCsv(headers, rows) {
  const lines = [headers.map(escapeCsvCell).join(',')];
  for (const row of rows) {
    const values = Array.isArray(row)
      ? row
      : headers.map((header) => row[header]);
    lines.push(values.map(escapeCsvCell).join(','));
  }
  return `\uFEFF${lines.join('\n')}\n`;
}

/**
 * 标准化颜色值并映射默认可用状态。
 * @param {string} rawColor
 * @returns {'available' | 'unavailable' | null}
 */
function mapColorToStatus(rawColor) {
  let normalized = String(rawColor ?? '').trim().toUpperCase();
  if (!normalized) return null;
  if (/^[0-9A-F]{6}$/.test(normalized)) {
    normalized = `#${normalized}`;
  }
  if (AVAILABLE_COLORS.has(normalized)) return 'available';
  if (UNAVAILABLE_COLORS.has(normalized)) return 'unavailable';
  return null;
}

/**
 * 规范化取水方式数组（去重 + 固定顺序）。
 * @param {string[]} methods
 * @returns {string[]}
 */
function normalizeIntakeMethods(methods) {
  const set = new Set();
  for (const item of methods || []) {
    const token = String(item ?? '').trim();
    if (VALID_INTAKE_METHODS.has(token)) {
      set.add(token);
    }
  }
  return INTAKE_METHOD_ORDER.filter((m) => set.has(m));
}

/**
 * 按设计文档 §5 规则对水源自动分类，并提取天然水源取水方式。
 * @param {string} name
 * @param {string} note
 * @returns {{ category: 'hydrant' | 'natural' | 'pump_connector', intake_methods: string[] }}
 */
function classifyWaterSource(name, note) {
  const combined = `${name || ''}\n${note || ''}`;
  if (combined.includes('水泵接合器')) {
    return { category: 'pump_connector', intake_methods: [] };
  }

  const isNatural = NATURAL_KEYWORDS.some((kw) => combined.includes(kw));
  if (isNatural) {
    const methods = [];
    if (combined.includes('手抬泵')) methods.push('portable_pump');
    if (combined.includes('消防车')) methods.push('fire_truck');
    if (combined.includes('远程供水')) methods.push('remote_supply');
    return {
      category: 'natural',
      intake_methods: normalizeIntakeMethods(methods),
    };
  }

  return { category: 'hydrant', intake_methods: [] };
}

/**
 * 校验并解析 GCJ-02 经纬度（高德位置编码通常为 "lng,lat"）。
 * @param {string} rawCoord
 * @param {string} [rawLng]
 * @param {string} [rawLat]
 * @returns {{ valid: boolean, lat: number | null, lng: number | null, rawCoordString: string }}
 */
function parseCoordinates(rawCoord, rawLng = '', rawLat = '') {
  const coordText = String(rawCoord ?? '').trim();
  const lngText = String(rawLng ?? '').trim();
  const latText = String(rawLat ?? '').trim();

  let lngStr = '';
  let latStr = '';
  let rawCoordString = coordText;

  if (coordText) {
    const parts = coordText.split(/[,，\s]+/).filter(Boolean);
    if (parts.length === 2) {
      [lngStr, latStr] = parts;
    }
  } else if (lngText || latText) {
    lngStr = lngText;
    latStr = latText;
    rawCoordString = `${lngText},${latText}`;
  }

  if (!lngStr || !latStr) {
    return { valid: false, lat: null, lng: null, rawCoordString };
  }

  const lng = Number(lngStr);
  const lat = Number(latStr);
  const valid = Number.isFinite(lat)
    && Number.isFinite(lng)
    && lat >= 3 && lat <= 55
    && lng >= 73 && lng <= 136;

  return {
    valid,
    lat: valid ? lat : null,
    lng: valid ? lng : null,
    rawCoordString,
  };
}

/**
 * 基于原始未修改名称 + 原始经纬度字符串生成不可变指纹 source_key（即 import_key）。
 * @param {string} rawName
 * @param {string} rawCoord
 * @param {number} [occurrence=1]
 * @returns {string}
 */
function computeSourceKey(rawName, rawCoord, occurrence = 1) {
  const payload = `${String(rawName ?? '')}\u0000${String(rawCoord ?? '')}`;
  const digest = crypto.createHash('sha256').update(payload, 'utf8').digest('hex').slice(0, 24);
  return occurrence > 1 ? `amap_v1:${digest}#${occurrence}` : `amap_v1:${digest}`;
}

/**
 * 计算两点间 Haversine 球面距离（米）。
 * @param {number} lat1
 * @param {number} lng1
 * @param {number} lat2
 * @param {number} lng2
 * @returns {number}
 */
function distanceMeters(lat1, lng1, lat2, lng2) {
  const toRad = (deg) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2
    + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return EARTH_RADIUS_METERS * c;
}

/**
 * 检测颜色映射默认状态与描述文本是否存在矛盾。
 * @param {'available' | 'unavailable' | null} status
 * @param {string} note
 * @param {string} [name='']
 * @returns {boolean}
 */
function detectColorNoteConflict(status, note, name = '') {
  if (!status) return false;
  const text = `${name || ''}\n${note || ''}`.trim();
  if (!text) return false;

  // 先剥离否定故障短语，避免「无损坏」误触发「损坏」
  const withoutNegatedFault = text.replace(/(?:无损坏|未损坏|没有损坏|不损坏|无故障|未故障)/g, '');
  const faultPattern = /(?:无水|没水|没有水|损坏|锈死|打不开|移除|已拆|拆除|停用|故障|坏了|废弃|埋压|圈占|不可用|不能用)/;
  const hasFault = faultPattern.test(withoutNegatedFault);

  if (status === 'available') {
    return hasFault;
  }

  if (status === 'unavailable') {
    if (hasFault) return false;
    // 剥离否定可用短语，避免「不可用」「不正常」「没有水」误触发正向词
    const withoutNegatedPositive = text.replace(/(?:不可用|不能用|不正常|没有水|无水|没水)/g, '');
    const positivePattern = /(?:无损坏|完好|正常出水|有水|正常|可用)/;
    return positivePattern.test(withoutNegatedPositive);
  }

  return false;
}

/**
 * 判断某行是否为高德导出表尾说明段落的起始行。
 * @param {string[]} row
 * @returns {boolean}
 */
function isFooterRow(row) {
  return row.some((cell) => {
    const text = String(cell ?? '').trim();
    return text && FOOTER_MARKERS.some((marker) => text.includes(marker));
  });
}

/**
 * 自动识别高德工作地图导出 CSV 表头与关键列索引（显式忽略照片/图片列）。
 * @param {string[][]} rows
 * @returns {{ headerIndex: number, columns: Record<string, number> }}
 */
function detectAmapHeader(rows) {
  const maxScan = Math.min(rows.length, 20);
  for (let i = 0; i < maxScan; i += 1) {
    const cells = rows[i].map((c) => String(c ?? '').trim());
    const columns = {
      name: -1,
      color: -1,
      description: -1,
      location: -1,
      lng: -1,
      lat: -1,
      address: -1,
    };

    for (let j = 0; j < cells.length; j += 1) {
      const header = cells[j];
      const lower = header.toLowerCase();
      // 照片列直接丢弃
      if (!header || header.includes('照片') || header.includes('图片') || lower.includes('photo') || lower.includes('image')) {
        continue;
      }
      if (columns.name === -1 && (header === '名称' || header.includes('名称') || header === '标题')) {
        columns.name = j;
      } else if (columns.color === -1 && (header === '颜色' || header.includes('颜色'))) {
        columns.color = j;
      } else if (columns.description === -1 && (header === '描述' || header.includes('描述') || header === '备注')) {
        columns.description = j;
      } else if (columns.location === -1 && (header.includes('位置编码') || header.includes('经纬度') || lower === 'location')) {
        columns.location = j;
      } else if (columns.lng === -1 && (header === '经度' || lower === 'lng' || lower === 'lon' || lower === 'longitude')) {
        columns.lng = j;
      } else if (columns.lat === -1 && (header === '纬度' || lower === 'lat' || lower === 'latitude')) {
        columns.lat = j;
      } else if (columns.address === -1 && (header === '地址' || header.includes('地址'))) {
        columns.address = j;
      }
    }

    const hasCoordColumn = columns.location !== -1 || (columns.lng !== -1 && columns.lat !== -1);
    if (columns.name !== -1 && (hasCoordColumn || columns.color !== -1 || columns.description !== -1)) {
      return { headerIndex: i, columns };
    }
  }

  throw new Error('未能识别高德工作地图 CSV 表头（缺少「名称」及位置/颜色/描述列）');
}

/**
 * 规范化备注文本：统一换行符、trim、限长 500 字。
 * @param {string} rawNote
 * @returns {string}
 */
function normalizeNote(rawNote) {
  const cleaned = String(rawNote ?? '').replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim();
  return cleaned.length > MAX_NOTE_LENGTH ? cleaned.slice(0, MAX_NOTE_LENGTH) : cleaned;
}

/**
 * 阶段一核心分析：解析高德导出 CSV、剥离表尾、丢弃照片列、分类并检出四类冲突。
 * @param {string} csvText
 */
function analyzeAmapCsv(csvText) {
  const rows = parseCsv(csvText);
  const { headerIndex, columns } = detectAmapHeader(rows);

  const parsedEntries = [];
  const keyCounts = new Map();
  let stoppedAtFooter = false;

  for (let i = headerIndex + 1; i < rows.length; i += 1) {
    const row = rows[i];
    if (isFooterRow(row)) {
      stoppedAtFooter = true;
      break;
    }
    const isEmpty = row.every((cell) => String(cell ?? '').trim() === '');
    if (isEmpty) continue;

    const rawName = columns.name !== -1 ? String(row[columns.name] ?? '') : '';
    const rawColor = columns.color !== -1 ? String(row[columns.color] ?? '') : '';
    const rawDescription = columns.description !== -1 ? String(row[columns.description] ?? '') : '';
    const rawLocation = columns.location !== -1 ? String(row[columns.location] ?? '') : '';
    const rawLng = columns.lng !== -1 ? String(row[columns.lng] ?? '') : '';
    const rawLat = columns.lat !== -1 ? String(row[columns.lat] ?? '') : '';

    const rawCoordForKey = columns.location !== -1 ? rawLocation : `${rawLng},${rawLat}`;
    const baseKeyInput = `${rawName}\u0000${rawCoordForKey}`;
    const occurrence = (keyCounts.get(baseKeyInput) || 0) + 1;
    keyCounts.set(baseKeyInput, occurrence);

    const sourceKey = computeSourceKey(rawName, rawCoordForKey, occurrence);
    const name = rawName.trim();
    const note = normalizeNote(rawDescription);
    const coord = parseCoordinates(rawLocation, rawLng, rawLat);
    const status = mapColorToStatus(rawColor);
    const { category, intake_methods: intakeMethods } = classifyWaterSource(name, note);

    const reasons = [];
    if (!name || name.length > MAX_NAME_LENGTH) {
      reasons.push('invalid_name');
    }
    if (!coord.valid) {
      reasons.push('invalid_coordinates');
    }
    if (!status) {
      reasons.push('unknown_color');
    } else if (detectColorNoteConflict(status, note, name)) {
      reasons.push('color_note_conflict');
    }
    if (category === 'natural' && intakeMethods.length === 0) {
      reasons.push('missing_intake_methods');
    }

    parsedEntries.push({
      source_key: sourceKey,
      category,
      name,
      lat: coord.valid ? coord.lat : coord.rawCoordString,
      lng: coord.valid ? coord.lng : '',
      coordValid: coord.valid,
      numericLat: coord.lat,
      numericLng: coord.lng,
      status: status || '',
      intake_methods: intakeMethods,
      note,
      reasons,
    });
  }

  // 检出 10 米内同类别近距疑似重复点（仅针对有效坐标）
  for (let i = 0; i < parsedEntries.length; i += 1) {
    const a = parsedEntries[i];
    if (!a.coordValid) continue;
    for (let j = i + 1; j < parsedEntries.length; j += 1) {
      const b = parsedEntries[j];
      if (!b.coordValid) continue;
      if (a.category !== b.category) continue;
      const dist = distanceMeters(a.numericLat, a.numericLng, b.numericLat, b.numericLng);
      if (dist <= DUPLICATE_RADIUS_METERS) {
        if (!a.reasons.includes('duplicate_within_10m')) {
          a.reasons.push('duplicate_within_10m');
        }
        if (!b.reasons.includes('duplicate_within_10m')) {
          b.reasons.push('duplicate_within_10m');
        }
      }
    }
  }

  const clean = [];
  const conflicts = [];

  for (const entry of parsedEntries) {
    if (entry.reasons.length === 0) {
      clean.push({
        import_key: entry.source_key,
        category: entry.category,
        name: entry.name,
        lat: entry.numericLat,
        lng: entry.numericLng,
        status: entry.status,
        intake_methods: entry.intake_methods,
        note: entry.note,
      });
    } else {
      conflicts.push({
        source_key: entry.source_key,
        reason: entry.reasons.join(';'),
        decision: '',
        category: entry.category,
        status: entry.status,
        intake_methods: entry.intake_methods.join('|'),
        name: entry.name,
        lat: entry.coordValid ? String(entry.numericLat) : entry.lat,
        lng: entry.coordValid ? String(entry.numericLng) : '',
        note: entry.note,
      });
    }
  }

  const byReason = {};
  for (const item of conflicts) {
    for (const r of item.reason.split(';').filter(Boolean)) {
      byReason[r] = (byReason[r] || 0) + 1;
    }
  }

  return {
    clean,
    conflicts,
    stats: {
      total_parsed: parsedEntries.length,
      clean_count: clean.length,
      conflict_count: conflicts.length,
      stopped_at_footer: stoppedAtFooter,
      conflicts_by_reason: byReason,
    },
  };
}

/**
 * 阶段一：执行 --dry-run，写出 clean.json 和 conflicts.csv。
 * @param {{ csvPath: string, outDir: string }} options
 */
function runDryRun({ csvPath, outDir }) {
  if (!csvPath) throw new Error('缺少必需参数：--csv <path>');
  if (!outDir) throw new Error('缺少必需参数：--out-dir <dir>');

  const csvText = fs.readFileSync(csvPath, 'utf8');
  const result = analyzeAmapCsv(csvText);

  fs.mkdirSync(outDir, { recursive: true });
  const cleanPath = path.join(outDir, 'clean.json');
  const conflictsPath = path.join(outDir, 'conflicts.csv');

  const cleanPayload = {
    generated_at: new Date().toISOString(),
    source_csv: path.basename(csvPath),
    summary: result.stats,
    items: result.clean,
  };
  fs.writeFileSync(cleanPath, `${JSON.stringify(cleanPayload, null, 2)}\n`, 'utf8');
  fs.writeFileSync(conflictsPath, stringifyCsv(CONFLICTS_CSV_HEADERS, result.conflicts), 'utf8');

  return {
    cleanPath,
    conflictsPath,
    ...result,
  };
}

/**
 * 校验并规范化单条准备入库的记录。
 * @param {Record<string, unknown>} raw
 * @param {string} sourceLabel
 */
function validateImportRecord(raw, sourceLabel) {
  const importKey = String(raw.import_key ?? raw.source_key ?? '').trim();
  if (!importKey) {
    throw new Error(`${sourceLabel} 缺少 source_key / import_key`);
  }

  const category = String(raw.category ?? '').trim();
  if (!VALID_CATEGORIES.has(category)) {
    throw new Error(`${sourceLabel} (${importKey}) 类别无效：${category}`);
  }

  const status = String(raw.status ?? '').trim();
  if (!VALID_STATUSES.has(status)) {
    throw new Error(`${sourceLabel} (${importKey}) 状态无效：${status}`);
  }

  const name = String(raw.name ?? '').trim();
  if (!name || name.length > MAX_NAME_LENGTH) {
    throw new Error(`${sourceLabel} (${importKey}) 名称无效（需 1-${MAX_NAME_LENGTH} 字符）`);
  }

  const lat = Number(raw.lat);
  const lng = Number(raw.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || lat < 3 || lat > 55 || lng < 73 || lng > 136) {
    throw new Error(`${sourceLabel} (${importKey}) 坐标无效或越界：lat=${raw.lat}, lng=${raw.lng}`);
  }

  let intakeList = [];
  if (Array.isArray(raw.intake_methods)) {
    intakeList = raw.intake_methods;
  } else if (typeof raw.intake_methods === 'string' && raw.intake_methods.trim()) {
    intakeList = raw.intake_methods.split(/[|,，\s]+/).filter(Boolean);
  }

  let intakeMethods = [];
  if (category === 'natural') {
    for (const token of intakeList) {
      if (!VALID_INTAKE_METHODS.has(String(token).trim())) {
        throw new Error(`${sourceLabel} (${importKey}) 取水方式无效：${token}`);
      }
    }
    intakeMethods = normalizeIntakeMethods(intakeList);
    if (intakeMethods.length === 0) {
      throw new Error(`${sourceLabel} (${importKey}) 天然水源必须至少包含 1 项取水方式`);
    }
  }

  const note = normalizeNote(raw.note ?? '');

  return {
    import_key: importKey,
    category,
    name,
    lat,
    lng,
    status,
    intake_methods: intakeMethods,
    note,
  };
}

/**
 * 解析人工裁定表 overrides.csv，仅保留 decision=keep 的行并校验字段。
 * @param {string} csvText
 */
function loadOverridesCsv(csvText) {
  const rows = parseCsv(csvText);
  if (rows.length === 0) return { kept: [], droppedCount: 0, skippedCount: 0 };

  const headers = rows[0].map((h) => String(h ?? '').trim());
  const indexByName = new Map();
  headers.forEach((h, idx) => indexByName.set(h, idx));

  const requiredCols = ['source_key', 'decision', 'category', 'status', 'intake_methods', 'name', 'lat', 'lng', 'note'];
  for (const col of requiredCols) {
    if (!indexByName.has(col)) {
      throw new Error(`overrides.csv 缺少必需列：${col}`);
    }
  }

  const kept = [];
  let droppedCount = 0;
  let skippedCount = 0;

  for (let i = 1; i < rows.length; i += 1) {
    const row = rows[i];
    if (row.every((cell) => String(cell ?? '').trim() === '')) continue;

    const get = (col) => String(row[indexByName.get(col)] ?? '');
    const decision = get('decision').trim().toLowerCase();

    if (decision === 'drop') {
      droppedCount += 1;
      continue;
    }
    if (decision !== 'keep') {
      skippedCount += 1;
      continue;
    }

    const record = validateImportRecord({
      source_key: get('source_key'),
      category: get('category'),
      status: get('status'),
      intake_methods: get('intake_methods'),
      name: get('name'),
      lat: get('lat'),
      lng: get('lng'),
      note: get('note'),
    }, `overrides.csv 第 ${i + 1} 行`);

    kept.push(record);
  }

  return { kept, droppedCount, skippedCount };
}

/**
 * 合并 clean.json 与 overrides.csv 中裁定为 keep 的记录（按 import_key 去重，overrides 优先）。
 * @param {Array<Record<string, unknown>>} cleanItems
 * @param {Array<Record<string, unknown>>} overrideItems
 */
function mergeImportRecords(cleanItems, overrideItems) {
  const byKey = new Map();
  for (let i = 0; i < (cleanItems || []).length; i += 1) {
    const rec = validateImportRecord(cleanItems[i], `clean.json 第 ${i + 1} 条`);
    byKey.set(rec.import_key, rec);
  }
  for (let i = 0; i < (overrideItems || []).length; i += 1) {
    const rec = validateImportRecord(overrideItems[i], `overrides 第 ${i + 1} 条`);
    byKey.set(rec.import_key, rec);
  }
  return Array.from(byKey.values());
}

/**
 * 阶段二：执行 --apply，合并 clean.json 与 overrides.csv 并调用 waterSources.upsertImportedBatch 幂等入库。
 * @param {{
 *   unitId: string,
 *   cleanPath?: string,
 *   overridesPath?: string,
 *   forceOverwrite?: boolean,
 *   waterSources?: { upsertImportedBatch: Function },
 * }} options
 */
async function runApply({
  unitId,
  cleanPath,
  overridesPath,
  forceOverwrite = false,
  waterSources,
}) {
  if (!unitId || !String(unitId).trim()) {
    throw new Error('缺少必需参数：--unit-id <id>');
  }
  if (!cleanPath && !overridesPath) {
    throw new Error('至少需要提供 --clean <file> 或 --overrides <file>');
  }

  let cleanItems = [];
  if (cleanPath) {
    const parsed = JSON.parse(fs.readFileSync(cleanPath, 'utf8'));
    cleanItems = Array.isArray(parsed) ? parsed : (Array.isArray(parsed?.items) ? parsed.items : null);
    if (!cleanItems) {
      throw new Error(`clean.json 格式无效：需要数组或包含 items 数组的对象 (${cleanPath})`);
    }
  }

  let overrideResult = { kept: [], droppedCount: 0, skippedCount: 0 };
  if (overridesPath) {
    const csvText = fs.readFileSync(overridesPath, 'utf8');
    overrideResult = loadOverridesCsv(csvText);
  }

  const records = mergeImportRecords(cleanItems, overrideResult.kept);

  let svc = waterSources;
  let storeToClose = null;

  if (!svc) {
    process.env.WATCHDOG_DB_DRIVER = 'postgres';
    const store = require('../src/postgres-store');
    await store.ready;
    const { createWaterSources } = require('../src/water-sources');
    svc = createWaterSources(store);
    storeToClose = store;
  }

  try {
    const batchResult = await svc.upsertImportedBatch(String(unitId).trim(), records, {
      forceOverwrite: Boolean(forceOverwrite),
      actorId: IMPORT_ACTOR_ID,
      actorName: IMPORT_ACTOR_NAME,
    });

    return {
      unit_id: String(unitId).trim(),
      clean_count: cleanItems.length,
      overrides_kept: overrideResult.kept.length,
      overrides_dropped: overrideResult.droppedCount,
      overrides_skipped: overrideResult.skippedCount,
      total_submitted: records.length,
      force_overwrite: Boolean(forceOverwrite),
      result: batchResult,
    };
  } finally {
    if (storeToClose && typeof storeToClose.close === 'function') {
      await storeToClose.close();
    }
  }
}

/**
 * 解析命令行参数。
 * @param {string[]} argv
 */
function parseCliArgs(argv) {
  const args = {
    mode: null,
    csvPath: null,
    outDir: null,
    unitId: null,
    cleanPath: null,
    overridesPath: null,
    forceOverwrite: false,
    help: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === '--help' || token === '-h') {
      args.help = true;
    } else if (token === '--dry-run') {
      args.mode = 'dry-run';
    } else if (token === '--apply') {
      args.mode = 'apply';
    } else if (token === '--force-overwrite') {
      args.forceOverwrite = true;
    } else if (token === '--csv') {
      args.csvPath = argv[++i];
    } else if (token === '--out-dir') {
      args.outDir = argv[++i];
    } else if (token === '--unit-id') {
      args.unitId = argv[++i];
    } else if (token === '--clean') {
      args.cleanPath = argv[++i];
    } else if (token === '--overrides') {
      args.overridesPath = argv[++i];
    } else {
      throw new Error(`未知参数：${token}`);
    }
  }

  return args;
}

function printUsage() {
  console.log([
    '用法：',
    '  阶段一（脱敏清洗与冲突检出）：',
    '    node backend/scripts/import-water-sources.js --dry-run --csv <path> --out-dir <dir>',
    '',
    '  阶段二（合并人工裁定并幂等入库）：',
    '    node backend/scripts/import-water-sources.js --apply --unit-id <id> --clean <clean.json> [--overrides <overrides.csv>] [--force-overwrite]',
  ].join('\n'));
}

async function main(argv = process.argv.slice(2)) {
  const args = parseCliArgs(argv);
  if (args.help || !args.mode) {
    printUsage();
    if (!args.help) process.exitCode = 1;
    return;
  }

  if (args.mode === 'dry-run') {
    const out = runDryRun({ csvPath: args.csvPath, outDir: args.outDir });
    console.log(JSON.stringify({
      mode: 'dry-run',
      clean_path: out.cleanPath,
      conflicts_path: out.conflictsPath,
      stats: out.stats,
    }, null, 2));
    return;
  }

  if (args.mode === 'apply') {
    const out = await runApply({
      unitId: args.unitId,
      cleanPath: args.cleanPath,
      overridesPath: args.overridesPath,
      forceOverwrite: args.forceOverwrite,
    });
    console.log(JSON.stringify({
      mode: 'apply',
      ...out,
    }, null, 2));
  }
}

module.exports = {
  CONFLICTS_CSV_HEADERS,
  IMPORT_ACTOR_ID,
  IMPORT_ACTOR_NAME,
  parseCsv,
  stringifyCsv,
  mapColorToStatus,
  normalizeIntakeMethods,
  classifyWaterSource,
  parseCoordinates,
  computeSourceKey,
  distanceMeters,
  detectColorNoteConflict,
  detectAmapHeader,
  analyzeAmapCsv,
  runDryRun,
  loadOverridesCsv,
  mergeImportRecords,
  runApply,
  parseCliArgs,
};

if (require.main === module) {
  main().catch((err) => {
    console.error(`导入脚本执行失败：${err.message}`);
    process.exitCode = 1;
  });
}
