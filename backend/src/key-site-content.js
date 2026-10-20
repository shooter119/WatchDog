const { forceError } = require('./force-fields');
const MODULES = ['maps', 'plans', 'cards', 'organization', 'hazards'];
const SCHEMA = require('../admin/key-site-schema.json');
const FIELDS = SCHEMA.legacyFields;
function fieldsFor(module, kind) {
  if (kind === undefined || kind === '') return FIELDS[module];
  if (typeof kind !== 'string' || !Object.hasOwn(SCHEMA.kinds, kind) || SCHEMA.kinds[kind].module !== module) {
    throw forceError('标准记录类型与资料模块不匹配', 'KEY_SITE_INVALID');
  }
  return SCHEMA.kinds[kind].fields;
}
const emptyContent = () => Object.fromEntries(MODULES.map(name => [name, []]));
function text(value, max = 2000, required = false) {
  if (value === undefined && !required) return '';
  if (typeof value !== 'string' || value.length > max || (required && !value.trim())) {
    throw forceError('资料字段为空或超过长度限制', 'KEY_SITE_INVALID');
  }
  return value.trim();
}
function profile(input) {
  return { name: text(input.name, 160, true), short_name: text(input.short_name, 80),
    address: text(input.address, 500, true), district: text(input.district, 120), site_type: text(input.site_type, 80) };
}
function content(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input) || Object.keys(input).some(key => !MODULES.includes(key))) {
    throw forceError('资料模块无效', 'KEY_SITE_INVALID');
  }
  const result = emptyContent();
  for (const module of MODULES) {
    const entries = input[module] ?? [];
    if (!Array.isArray(entries) || entries.length > 500) throw forceError('每类资料最多500条', 'KEY_SITE_INVALID');
    result[module] = entries.map(entry => {
      if (!entry || typeof entry !== 'object' || Array.isArray(entry)) throw forceError('资料条目无效', 'KEY_SITE_INVALID');
      const fields = {};
      const keys = fieldsFor(module, entry.kind);
      if (entry.kind && (!entry.fields || typeof entry.fields !== 'object' || Array.isArray(entry.fields)
        || Object.keys(entry.fields).some(key => !keys.includes(key)))) {
        throw forceError('标准记录包含不属于该类型的字段', 'KEY_SITE_INVALID');
      }
      for (const key of keys) fields[key] = text(entry.fields?.[key], 5000);
      if (!Array.isArray(entry.sources ?? []) || (entry.sources?.length || 0) > 30) throw forceError('来源最多30项', 'KEY_SITE_INVALID');
      const sources = (entry.sources || []).map(source => {
        const attachmentId = text(source.attachmentId, 128, true);
        const page = source.page == null ? null : Number(source.page);
        if (page !== null && (!Number.isInteger(page) || page < 1 || page > 200)) throw forceError('来源页码无效', 'KEY_SITE_SOURCE_INVALID');
        return { attachmentId, page, paragraph: text(source.paragraph, 300) };
      });
      return { ...(entry.kind ? { kind: entry.kind } : {}), title: text(entry.title, 200, true), body: text(entry.body, 20000), fields, sources };
    });
  }
  if (Buffer.byteLength(JSON.stringify(result)) > 400000) throw forceError('结构化资料超过400KB限制', 'KEY_SITE_INVALID', 413);
  return result;
}
const attachmentIds = data => [...new Set(MODULES.flatMap(module => data[module].flatMap(entry => entry.sources.map(source => source.attachmentId))))];
module.exports = { MODULES, FIELDS, SCHEMA, fieldsFor, emptyContent, text, profile, content, attachmentIds };
