export const REPEATABLE_KINDS = new Set([
  'productionUnit',
  'warehouseStock',
  'storageTank',
  'contact',
]);

export const MODULE_META = {
  cards: { key: 'cards', label: '作战信息卡', group: '九大标准分项' },
  hazards: { key: 'hazards', label: '仓库与储罐', group: '九大标准分项' },
  organization: { key: 'organization', label: '单位联系人', group: '九大标准分项' },
  maps: { key: 'maps', label: '地图与 360° 全景', group: '图纸与预案' },
  plans: { key: 'plans', label: '应急预案', group: '图纸与预案' },
};

export const OUTLINE_GROUPS = [
  {
    label: '作战信息卡（6项）',
    items: [
      { id: 'kind:siteOverview', module: 'cards', kind: 'siteOverview', label: '单位基本情况' },
      { id: 'kind:surroundings', module: 'cards', kind: 'surroundings', label: '毗邻与道路' },
      { id: 'kind:productionUnit', module: 'cards', kind: 'productionUnit', label: '生产装置' },
      { id: 'kind:fireProtection', module: 'cards', kind: 'fireProtection', label: '消防设施及水源' },
      { id: 'kind:processFlow', module: 'cards', kind: 'processFlow', label: '工艺流程' },
      { id: 'kind:safetyNotice', module: 'cards', kind: 'safetyNotice', label: '重点提示' },
    ],
  },
  {
    label: '危险品与组织（3项）',
    items: [
      { id: 'kind:warehouseStock', module: 'hazards', kind: 'warehouseStock', label: '仓库库存' },
      { id: 'kind:storageTank', module: 'hazards', kind: 'storageTank', label: '储罐' },
      { id: 'kind:contact', module: 'organization', kind: 'contact', label: '单位联系人' },
    ],
  },
  {
    label: '图纸、全景与预案',
    items: [
      { id: 'module:maps', module: 'maps', kind: null, label: '地图与 360° 全景' },
      { id: 'module:plans', module: 'plans', kind: null, label: '应急预案' },
    ],
  },
];

export function getFieldsForRecord(schema, module, kind) {
  if (kind && schema?.kinds?.[kind]?.fields) {
    return schema.kinds[kind].fields;
  }
  return schema?.legacyFields?.[module] || [];
}

export function getFieldLabel(schema, field) {
  return schema?.fieldLabels?.[field] || field;
}

export function countOutlineSection(item, content, schema) {
  const entries = Array.isArray(content?.[item.module]) ? content[item.module] : [];
  if (item.kind) {
    const matching = entries.filter((e) => e.kind === item.kind);
    if (REPEATABLE_KINDS.has(item.kind)) {
      return `${matching.length}项`;
    }
    const specFields = schema?.kinds?.[item.kind]?.fields || [];
    const filled = matching.reduce((acc, entry) => {
      const f = entry.fields || {};
      return acc + specFields.filter((k) => String(f[k] || '').trim()).length;
    }, 0);
    return `${filled}/${specFields.length}`;
  }
  return `${entries.length}项`;
}

export function sanitizeSiteProfilePayload(site, overrides = {}) {
  const base = site || {};
  const merged = { ...base, ...overrides };
  return {
    name: String(merged.name ?? '').trim(),
    short_name: String(merged.short_name ?? '').trim(),
    address: String(merged.address ?? '').trim(),
    district: String(merged.district ?? '').trim(),
    site_type: String(merged.site_type ?? '').trim(),
    owner_unit_id: merged.owner_unit_id || undefined,
    active: merged.active !== undefined ? Boolean(merged.active) : true,
    revision: base.revision !== undefined ? base.revision : undefined,
  };
}

/**
 * Pure serializer for module records — guarantees non-maps modules NEVER lose entry.sources,
 * and maps module cleanly resolves mutual exclusion between 360 panos and flat maps.
 */
export function serializeModuleEntries(module, records) {
  const output = [];
  for (const rec of records || []) {
    if (rec.removed) continue;

    const title = String(rec.title ?? '').trim();
    const body = String(rec.body ?? '').trim();
    const fields = {};
    let hasFieldValue = false;
    for (const [k, rawVal] of Object.entries(rec.fields || {})) {
      const val = String(rawVal ?? '').trim();
      if (val) {
        fields[k] = val;
        hasFieldValue = true;
      }
    }

    let sources = [];
    if (module === 'maps') {
      const selectedPanos = (rec.selectedPanos || [])
        .filter((p) => p.attachmentId)
        .slice(0, 30)
        .map((p) => ({
          attachmentId: String(p.attachmentId),
          page: 1,
          paragraph: String(p.paragraph ?? '').trim(),
        }));

      if (selectedPanos.length > 0) {
        sources = selectedPanos;
      } else if (rec.flatMapAttachmentId) {
        const prevFlat = (rec.originalSources || []).find(
          (s) => s.attachmentId === rec.flatMapAttachmentId,
        );
        sources = [{
          attachmentId: String(rec.flatMapAttachmentId),
          page: Math.max(1, Number.parseInt(rec.flatMapPage, 10) || 1),
          paragraph: String(prevFlat?.paragraph ?? ''),
        }];
      } else {
        // Preserve any non-ready attachment references that were not shown in ready selectors
        sources = (rec.preservedSources || []).slice(0, 30);
      }
    } else {
      // CRITICAL P0-1 FIX: preserve document/AI sources for cards, plans, organization, hazards
      sources = Array.isArray(rec.originalSources) ? rec.originalSources.slice(0, 30) : [];
    }

    const isDefaultTitleOnly = !hasFieldValue && !body && sources.length === 0 && rec.isBlankTemplate && title === rec.defaultTitle;
    if (isDefaultTitleOnly || (!title && !hasFieldValue && !body && sources.length === 0)) {
      continue;
    }

    const entry = {
      title: title || rec.defaultTitle || '未命名条目',
      body,
      fields,
      sources,
    };
    if (rec.kind) entry.kind = rec.kind;
    output.push(entry);
  }
  return output;
}
