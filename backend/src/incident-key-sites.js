const { createHash } = require('node:crypto');
const { forceError } = require('./force-fields');
const fail = (message, code, status = 409) => { throw forceError(message, code, status); };
function createIncidentKeySites(store, db, sites, now = Date.now) {
  const query = async (sql, args = []) => (await store.query(sql, args)).rows;
  async function scope(memberId, incidentId, lock = false) {
    const member = await sites.reader(memberId);
    const incident = (await query(`SELECT * FROM incidents WHERE id=$1 AND unit_id=$2${lock ? ' FOR UPDATE' : ''}`, [incidentId, member.unit_id]))[0];
    if (!incident) fail('警情不存在或不在当前协作范围', 'INCIDENT_NOT_FOUND', 404);
    return { member, incident };
  }
  async function read(memberId, incidentId) {
    const { incident } = await scope(memberId, incidentId);
    let latestVersion = null, active = null;
    if (incident.key_site_link) {
      const site = await sites.site(incident.key_site_link.siteId);
      latestVersion = site.published_version; active = site.active;
    }
    const history = await query(`SELECT r.version_id,v.site_id,v.version,v.profile,r.first_linked_at,m.real_name AS first_linked_by
      FROM incident_key_site_references r JOIN key_site_versions v ON v.id=r.version_id
      JOIN unit_members m ON m.id=r.first_linked_by WHERE r.incident_id=$1 ORDER BY r.first_linked_at DESC,v.version DESC`, [incidentId]);
    return { link: incident.key_site_link, revision: incident.key_site_link_revision, latestVersion,
      active, newVersionAvailable: Boolean(incident.key_site_link && latestVersion > incident.key_site_link.version), history };
  }
  async function change(memberId, incidentId, input, { operationId, deviceId = null } = {}) {
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(operationId || '')) fail('缺少合法操作编号，请重新提交', 'KEY_SITE_OPERATION_REQUIRED', 400);
    const revision = Number(input.revision);
    if (!Number.isInteger(revision) || revision < 0) fail('关联修订号无效', 'KEY_SITE_INVALID', 400);
    const targetId = input.siteId == null ? null : String(input.siteId);
    const versionNumber = targetId ? Number(input.version) : null;
    if (targetId && (!Number.isInteger(versionNumber) || versionNumber < 1 || versionNumber > 2147483647)) fail('请选择已发布资料版本', 'KEY_SITE_INVALID', 400);
    const requestHash = createHash('sha256').update(JSON.stringify({ incidentId, targetId, versionNumber, revision,
      name: input.confirmName || '', address: input.confirmAddress || '' })).digest('hex');
    return store.transaction(async () => {
      await query('SELECT pg_advisory_xact_lock(hashtextextended($1,119012))', [operationId]);
      const { member, incident } = await scope(memberId, incidentId, true);
      const previous = await db.getIncidentEventByClientOp(operationId);
      if (previous) {
        if (previous.incident_id !== incidentId || previous.type !== 'key_site_link_changed' || previous.payload?.requestHash !== requestHash || previous.payload?.operatorMemberId !== member.id) {
          fail('操作编号已用于其他操作，请重新核对', 'CLIENT_OP_ID_CONFLICT');
        }
        return { incident: await db.getIncident(incidentId), event: previous, replayed: true };
      }
      if (incident.status !== 'active') fail('警情已归档，不能更改关联', 'INCIDENT_ARCHIVED');
      if (incident.key_site_link_revision !== revision) fail('关联已被其他成员修改，请重新加载核对', 'KEY_SITE_LINK_CONFLICT');
      let link = null, version = null;
      if (targetId) {
        // This lock also serializes publish/disable against the reviewed selection.
        const target = await sites.site(targetId, true);
        if (!target.active) fail('重点单位已停用，不能新关联', 'KEY_SITE_INACTIVE');
        if (target.published_version !== versionNumber) fail('已有更新资料，请重新核对名称、地址和版本', 'KEY_SITE_NEW_VERSION');
        version = (await query('SELECT * FROM key_site_versions WHERE site_id=$1 AND version=$2', [targetId, versionNumber]))[0];
        if (!version) fail('暂无已发布资料', 'KEY_SITE_VERSION_NOT_FOUND', 404);
        if (input.confirmName !== version.profile.name || input.confirmAddress !== version.profile.address) fail('请核对重点单位名称和地址后确认', 'KEY_SITE_LINK_REVIEW_REQUIRED', 400);
        link = { siteId: targetId, versionId: version.id, version: version.version, name: version.profile.name,
          address: version.profile.address, linkedBy: member.id, linkedByName: member.real_name, linkedAt: now() };
      }
      await query(`UPDATE incidents SET key_site_version_id=$2,key_site_link=$3,key_site_link_revision=key_site_link_revision+1,
        version=version+1,last_activity_at=$4 WHERE id=$1`, [incidentId, version?.id || null, link ? JSON.stringify(link) : null, now()]);
      if (version) await query(`INSERT INTO incident_key_site_references(incident_id,version_id,first_linked_by,first_linked_at)
        VALUES($1,$2,$3,$4) ON CONFLICT DO NOTHING`, [incidentId, version.id, member.id, now()]);
      const event = await db.appendIncidentEvent({ incidentId, type: 'key_site_link_changed', actorDeviceId: deviceId,
        actorName: member.real_name, clientOpId: operationId, occurredAt: now(),
        payload: { link, previousLink: incident.key_site_link, revision: revision + 1, operatorMemberId: member.id, requestHash } });
      return { incident: await db.getIncident(incidentId), event, replayed: false };
    });
  }
  return { read, change, scope };
}
function createIncidentKeySiteRouter(service) {
  const router = require('express').Router();
  const wrap = handler => (req, res, next) => Promise.resolve(handler(req, res)).catch(error => error.status
    ? res.status(error.status).json({ code: error.code, error: error.message }) : next(error));
  router.get('/:id/key-site', wrap(async (req, res) => {
    res.set('Cache-Control', 'private, no-store');
    res.json(await service.read(req.auth?.memberId, req.params.id));
  }));
  router.put('/:id/key-site', wrap(async (req, res) => {
    const result = await service.change(req.auth?.memberId, req.params.id, req.body, { operationId: req.get('X-Op-Id'), deviceId: req.auth?.deviceId });
    res.set('Cache-Control', 'private, no-store'); res.json(result);
  }));
  return router;
}
module.exports = { createIncidentKeySites, createIncidentKeySiteRouter };
