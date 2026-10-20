const { randomUUID } = require('node:crypto');
const { forceError } = require('./force-fields');
const shape = require('./key-site-content');
const { keySiteLimits } = require('./key-site-limits');
const fail = (message, code = 'KEY_SITE_FORBIDDEN', status = 403) => { throw forceError(message, code, status); };

function createKeySites(store, auth, now = Date.now) {
  // Raw pg queries retain BIGINT strings; published API timestamps are JSON numbers.
  // Keep this at the key-site boundary rather than changing cursor/ID precision globally.
  const query = async (sql, args = []) => (await store.query(sql, args)).rows.map(row => {
    if (typeof row.published_at !== 'string') return row;
    const publishedAt = Number(row.published_at);
    if (!Number.isSafeInteger(publishedAt)) fail('资料发布时间无效', 'KEY_SITE_INVALID_TIMESTAMP', 500);
    return { ...row, published_at: publishedAt };
  });
  async function reader(memberId) {
    const member = (await query("SELECT id,unit_id,real_name FROM unit_members WHERE id=$1 AND status='active' AND review_status='approved'", [memberId]))[0];
    if (!member) fail('请先完成有效成员认证', 'KEY_SITE_AUTH_REQUIRED', 401);
    return member;
  }
  async function site(id, lock = false) {
    const row = (await query(`SELECT * FROM key_sites WHERE id=$1${lock ? ' FOR UPDATE' : ''}`, [id]))[0];
    if (!row) fail('重点单位不存在', 'KEY_SITE_NOT_FOUND', 404);
    return row;
  }
  async function maintain(memberId, id, lock = false) {
    const member = await auth.requireIdentity(memberId);
    const row = await site(id, lock);
    if (member.admin_role !== 'platform_admin' && member.unit_id !== row.owner_unit_id) fail('不能维护其他消防单位的资料');
    return { member, row };
  }
  async function create(memberId, input) {
    const member = await auth.requireIdentity(memberId);
    const fields = shape.profile(input);
    const owner = member.admin_role === 'platform_admin' ? shape.text(input.owner_unit_id || member.unit_id, 128, true) : member.unit_id;
    if (input.owner_unit_id && input.owner_unit_id !== owner) fail('只有平台管理员可指定维护归属');
    return store.transaction(async () => {
      if (!(await query('SELECT id FROM units WHERE id=$1', [owner])).length) fail('维护消防单位不存在', 'KEY_SITE_OWNER_INVALID', 400);

      const id = randomUUID(), time = now();
      const row = (await query(`INSERT INTO key_sites(id,owner_unit_id,name,short_name,address,district,site_type,created_at,updated_at)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8,$8) RETURNING *`, [id, owner, fields.name, fields.short_name, fields.address, fields.district, fields.site_type, time]))[0];
      await query('INSERT INTO key_site_drafts(site_id,content,updated_by,updated_at) VALUES($1,$2,$3,$4)', [id, JSON.stringify(shape.emptyContent()), memberId, time]);
      await auth.audit(memberId, 'key_site_created', id);
      return row;
    });
  }
  async function update(memberId, id, input) {
    return store.transaction(async () => {
      const { member, row } = await maintain(memberId, id, true);
      if (Number(input.revision) !== row.revision) fail('档案已被修改，请重新加载', 'KEY_SITE_CONFLICT', 409);
      const fields = shape.profile(input);
      const owner = input.owner_unit_id || row.owner_unit_id;
      if (owner !== row.owner_unit_id && member.admin_role !== 'platform_admin') fail('只有平台管理员可调整维护归属');
      if (!(await query('SELECT id FROM units WHERE id=$1', [owner])).length) fail('维护消防单位不存在', 'KEY_SITE_OWNER_INVALID', 400);
      if (owner !== row.owner_unit_id) {
        await query('SELECT id FROM units WHERE id=ANY($1::text[]) ORDER BY id FOR UPDATE', [[owner, row.owner_unit_id]]);
        const total = (await query(`SELECT COALESCE(sum(a.size_bytes+COALESCE((a.metadata->>'processedBytes')::bigint,0)),0)::bigint AS bytes
          FROM key_site_attachments a JOIN key_sites s ON s.id=a.site_id WHERE s.owner_unit_id=$1 OR s.id=$2`, [owner, id]))[0];
        if (Number(total.bytes) > keySiteLimits().quotaBytes) fail('目标消防单位的资料存储配额不足', 'KEY_SITE_QUOTA_EXCEEDED', 413);
      }
      if (input.active !== undefined && typeof input.active !== 'boolean') fail('停用状态无效', 'KEY_SITE_INVALID', 400);
      const updated = (await query(`UPDATE key_sites SET name=$2,short_name=$3,address=$4,district=$5,site_type=$6,
        owner_unit_id=$7,active=$8,revision=revision+1,updated_at=$9 WHERE id=$1 RETURNING *`,
      [id, fields.name, fields.short_name, fields.address, fields.district, fields.site_type, owner, input.active ?? row.active, now()]))[0];
      if (owner !== row.owner_unit_id) await auth.audit(memberId, 'key_site_owner_changed', id);
      if (updated.active !== row.active) await auth.audit(memberId, updated.active ? 'key_site_enabled' : 'key_site_disabled', id);
      await auth.audit(memberId, 'key_site_updated', id);
      return updated;
    });
  }
  async function list(memberId, filters = {}, admin = false) {
    const member = admin ? await auth.requireIdentity(memberId) : await reader(memberId);
    const limit = Math.max(1, Math.min(50, parseInt(filters.limit, 10) || 20));
    const offset = Math.max(0, Math.min(1000000, parseInt(filters.offset, 10) || 0));
    const args = [], terms = [];
    const add = value => { args.push(value); return `$${args.length}`; };
    if (admin) {
      if (member.admin_role !== 'platform_admin') terms.push(`s.owner_unit_id=${add(member.unit_id)}`);
    } else terms.push('s.active=true', 's.published_version>0');
    // Readers search the published snapshot, never unreviewed profile edits.
    const field = key => admin ? `s.${key}` : `v.profile->>'${key}'`;
    const needle = shape.text(filters.q, 160);
    if (needle) {
      const parameter = add(`%${needle.replace(/[\\%_]/g, '\\$&')}%`);
      terms.push(`(${['name','short_name','address'].map(key => `${field(key)} ILIKE ${parameter}`).join(' OR ')})`);
    }
    for (const key of ['district', 'site_type']) if (filters[key]) terms.push(`${field(key)}=${add(shape.text(filters[key], 120))}`);
    const where = terms.length ? ` WHERE ${terms.join(' AND ')}` : '';
    const rows = await query(`SELECT ${admin ? 's.*' : 's.id,v.profile,s.published_version,v.published_at'}
      FROM key_sites s LEFT JOIN key_site_versions v ON v.site_id=s.id AND v.version=s.published_version
      ${where} ORDER BY ${field('name')},s.id LIMIT ${add(limit + 1)} OFFSET ${add(offset)}`, args);
    return { sites: rows.slice(0, limit).map(row => admin ? row : { id: row.id, ...row.profile, published_version: row.published_version, published_at: row.published_at }),
      hasMore: rows.length > limit, offset, limit };
  }
  async function draft(memberId, id) {
    await maintain(memberId, id);
    const data = (await query('SELECT * FROM key_site_drafts WHERE site_id=$1', [id]))[0];
    return { site: await site(id), draft: data,
      attachments: await query('SELECT * FROM key_site_attachments WHERE site_id=$1 ORDER BY created_at,id', [id]),
      tasks: await query(`SELECT id,site_id,attachment_id,kind,status,generation,attempts,error_code,draft_revision,created_at,updated_at,
        CASE WHEN kind='ai' THEN jsonb_array_length(result->'pages') END AS page_count,
        CASE WHEN kind='ai' THEN (SELECT count(*)::int FROM jsonb_array_elements(result->'pages') p WHERE p->>'status'='succeeded') END AS completed_pages
        FROM key_site_tasks WHERE site_id=$1 ORDER BY created_at DESC,id DESC LIMIT 100`, [id]) };
  }
  async function saveDraft(memberId, id, input) {
    const data = shape.content(input.content);
    return store.transaction(async () => {
      await maintain(memberId, id, true);
      const rows = await query(`UPDATE key_site_drafts SET content=$2,revision=revision+1,updated_by=$3,updated_at=$4
        WHERE site_id=$1 AND revision=$5 RETURNING *`, [id, JSON.stringify(data), memberId, now(), Number(input.revision)]);
      if (!rows.length) fail('草稿已被修改，请重新加载，勿覆盖他人修改', 'KEY_SITE_CONFLICT', 409);
      await auth.audit(memberId, 'key_site_draft_saved', id);
      return rows[0];
    });
  }
  async function discardDraft(memberId, id, revision) {
    return store.transaction(async () => {
      const { row } = await maintain(memberId, id, true);
      const latest = (await query('SELECT content FROM key_site_versions WHERE site_id=$1 AND version=$2', [id, row.published_version]))[0];
      const rows = await query(`UPDATE key_site_drafts SET content=$2,revision=revision+1,updated_by=$3,updated_at=$4
        WHERE site_id=$1 AND revision=$5 RETURNING *`, [id, JSON.stringify(latest?.content || shape.emptyContent()), memberId, now(), Number(revision)]);
      if (!rows.length) fail('草稿已更新，请重新加载', 'KEY_SITE_CONFLICT', 409);
      await auth.audit(memberId, 'key_site_draft_discarded', id);
      return rows[0];
    });
  }
  async function publish(memberId, id, input) {
    if (input.confirmPlatformSharing !== true) fail('请确认资料向全平台已认证有效成员共享', 'KEY_SITE_SHARING_CONFIRM_REQUIRED', 400);
    return store.transaction(async () => {
      const { row } = await maintain(memberId, id, true);
      if (!row.active) fail('停用的重点单位不能发布', 'KEY_SITE_INACTIVE', 409);
      const draft = (await query('SELECT * FROM key_site_drafts WHERE site_id=$1 FOR UPDATE', [id]))[0];
      if (draft.revision !== Number(input.revision) || row.revision !== Number(input.profileRevision)) fail('资料有更新，请重新核对后发布', 'KEY_SITE_CONFLICT', 409);
      const data = shape.content(draft.content), ids = shape.attachmentIds(data);
      if (!shape.MODULES.some(module => data[module].length)) fail('请先填写资料', 'KEY_SITE_EMPTY', 400);
      const attachments = ids.length ? await query('SELECT * FROM key_site_attachments WHERE site_id=$1 AND id=ANY($2::text[])', [id, ids]) : [];
      if (attachments.length !== ids.length || attachments.some(item => item.status !== 'ready')) fail('来源附件未就绪或不属于本单位', 'KEY_SITE_SOURCE_INVALID', 409);
      const byId = new Map(attachments.map(item => [item.id, item]));
      for (const module of shape.MODULES) for (const entry of data[module]) {
        if (module === 'maps' && entry.sources.length !== 1) fail('每张地图须指定一份已切片的来源附件及页码', 'KEY_SITE_SOURCE_INVALID', 400);
        for (const source of entry.sources) {
          const attachment = byId.get(source.attachmentId);
          if ((source.page && source.page > Number(attachment.metadata.pages || 1))
            || (module === 'maps' && !attachment.metadata.map)) fail('来源页码或地图切片不匹配', 'KEY_SITE_SOURCE_INVALID', 400);
        }
      }
      const version = (await query(`INSERT INTO key_site_versions(id,site_id,version,profile,content,attachment_ids,published_by,published_at)
        VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING *`,
      [randomUUID(), id, row.published_version + 1, JSON.stringify(shape.profile(row)), JSON.stringify(data), JSON.stringify(ids), memberId, now()]))[0];
      await query('UPDATE key_sites SET published_version=$2,updated_at=$3 WHERE id=$1', [id, version.version, now()]);
      await auth.audit(memberId, 'key_site_published', version.id);
      return version;
    });
  }
  async function history(memberId, id) {
    await maintain(memberId, id);
    return query('SELECT v.id,v.version,v.profile,v.published_by,v.published_at,m.real_name AS publisher_name FROM key_site_versions v JOIN unit_members m ON m.id=v.published_by WHERE v.site_id=$1 ORDER BY v.version DESC', [id]);
  }
  async function versionForAdmin(memberId, id, version) {
    await maintain(memberId, id);
    const number = Number(version);
    if (!Number.isInteger(number) || number < 1 || number > 2147483647) fail('资料版本不存在', 'KEY_SITE_VERSION_NOT_FOUND', 404);
    const row = (await query('SELECT v.*,m.real_name AS publisher_name FROM key_site_versions v JOIN unit_members m ON m.id=v.published_by WHERE v.site_id=$1 AND v.version=$2', [id, number]))[0];
    if (!row) fail('资料版本不存在', 'KEY_SITE_VERSION_NOT_FOUND', 404);
    return row;
  }
  async function published(memberId, id, version, incidentId = null) {
    const member = await reader(memberId);
    const row = await site(id);
    const number = version === undefined ? row.published_version : Number(version);
    if (!Number.isInteger(number) || number < 1 || number > 2147483647) fail('暂无已发布资料', 'KEY_SITE_VERSION_NOT_FOUND', 404);
    const data = (await query('SELECT * FROM key_site_versions WHERE site_id=$1 AND version=$2', [id, number]))[0];
    if (!data) fail('暂无已发布资料', 'KEY_SITE_VERSION_NOT_FOUND', 404);
    if (!row.active) {
      const reference = incidentId ? await query(`SELECT r.version_id FROM incident_key_site_references r JOIN incidents i ON i.id=r.incident_id
        WHERE r.incident_id=$1 AND r.version_id=$2 AND i.unit_id=$3`, [incidentId, data.id, member.unit_id]) : [];
      if (!reference.length) fail('重点单位已停用，仅可从有权限的历史警情引用中查阅', 'KEY_SITE_INACTIVE', 404);
    }
    return { ...data, latestVersion: row.published_version, active: row.active };
  }
  async function filters(memberId) {
    await reader(memberId);
    const rows = await query(`SELECT DISTINCT v.profile->>'district' AS district,v.profile->>'site_type' AS site_type FROM key_sites s
      JOIN key_site_versions v ON v.site_id=s.id AND v.version=s.published_version WHERE s.active=true`);
    return { districts: [...new Set(rows.map(row => row.district).filter(Boolean))].sort(), types: [...new Set(rows.map(row => row.site_type).filter(Boolean))].sort() };
  }
  async function recent(memberId, ids) {
    await reader(memberId);
    if (!Array.isArray(ids) || ids.length > 20 || ids.some(id => typeof id !== 'string' || id.length > 128)) fail('最近查看标识无效', 'KEY_SITE_INVALID', 400);
    const rows = await query(`SELECT s.id,v.profile,s.published_version,v.published_at FROM key_sites s JOIN key_site_versions v ON v.site_id=s.id AND v.version=s.published_version
      WHERE s.id=ANY($1::text[]) AND s.active=true`, [ids]);
    return ids.map(id => rows.find(row => row.id === id)).filter(Boolean).map(row => ({ id: row.id, ...row.profile, published_version: row.published_version, published_at: row.published_at }));
  }
  async function duplicates(memberId, input) {
    const member = await auth.requireIdentity(memberId);
    const value = shape.text(input.name, 160, true), address = shape.text(input.address, 500);
    return query(`SELECT id,name,address FROM key_sites WHERE ($3::boolean OR owner_unit_id=$4)
      AND (name ILIKE $1 OR ($2<>'' AND address ILIKE $2)) ORDER BY name LIMIT 20`,
    [`%${value.replace(/[\\%_]/g, '\\$&')}%`, address ? `%${address.replace(/[\\%_]/g, '\\$&')}%` : '', member.admin_role === 'platform_admin', member.unit_id]);
  }
  return { reader, site, maintain, create, update, list, draft, saveDraft, discardDraft, publish, history, versionForAdmin, published, duplicates, filters, recent };
}
module.exports = { createKeySites };
