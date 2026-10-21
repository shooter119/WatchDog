// Device identifiers are display/grouping metadata, never authentication credentials.
function createAuthDevices(store) {
  const owner = auth => {
    if (!auth?.memberId || !auth?.sessionId) throw Object.assign(new Error('请重新认证后管理登录设备'), { status: 401, code: 'SESSION_REQUIRED' });
  };
  async function list(auth) {
    owner(auth);
    const { rows } = await store.query(`SELECT id, device_id, device_name, platform, created_at, last_seen_at
      FROM auth_sessions WHERE unit_id=$1 AND member_id=$2 AND revoked_at IS NULL AND expires_at>$3
      ORDER BY last_seen_at DESC`, [auth.unitId, auth.memberId, Date.now()]);
    const grouped = new Map();
    for (const row of rows) {
      const key = row.device_id || row.id;
      let item = grouped.get(key);
      if (!item) {
        item = { id: row.id, name: row.device_name || (row.device_id ? '未命名设备' : '旧版会话'), platform: row.platform || '未知', last_seen_at: Number(row.last_seen_at), current: false };
        grouped.set(key, item);
      }
      if (row.id === auth.sessionId || (auth.deviceId && row.device_id === auth.deviceId)) item.current = true;
    }
    return [...grouped.values()];
  }
  async function revoke(auth, targetId, others = false) {
    owner(auth);
    return store.transaction(async () => {
      const current = (await store.query('SELECT * FROM auth_sessions WHERE id=$1 AND member_id=$2 AND unit_id=$3 AND revoked_at IS NULL AND expires_at>$4 FOR UPDATE', [auth.sessionId, auth.memberId, auth.unitId, Date.now()])).rows[0];
      if (!current) throw Object.assign(new Error('认证会话已失效'), { status: 401, code: 'SESSION_INVALID' });
      let target;
      if (!others) {
        target = (await store.query('SELECT id, device_id FROM auth_sessions WHERE id=$1 AND member_id=$2 AND unit_id=$3', [targetId, auth.memberId, auth.unitId])).rows[0];
        if (!target) throw Object.assign(new Error('登录设备不存在'), { status: 404, code: 'DEVICE_NOT_FOUND' });
        if (target.id === current.id || (current.device_id && target.device_id === current.device_id)) throw Object.assign(new Error('请使用退出当前单位退出本机'), { status: 400, code: 'CURRENT_DEVICE' });
      }
      const filter = others ? '(id<>$5 AND ($6::text IS NULL OR device_id IS DISTINCT FROM $6))' : '(id=$5 OR ($6::text IS NOT NULL AND device_id=$6))';
      const { rows } = await store.query(`UPDATE auth_sessions SET revoked_at=$4, revoked_reason='device_revoked'
        WHERE unit_id=$1 AND member_id=$2 AND revoked_at IS NULL AND id<>$3 AND ${filter} RETURNING id`,
      [auth.unitId, auth.memberId, current.id, Date.now(), others ? current.id : target.id, others ? current.device_id : target.device_id]);
      for (const row of rows) {
        await store.query('INSERT INTO auth_device_audit(unit_id,member_id,actor_session_id,target_session_id,occurred_at,action) VALUES($1,$2,$3,$4,$5,$6)', [auth.unitId, auth.memberId, current.id, row.id, Date.now(), 'device_revoked']);
        await store.query("SELECT pg_notify('watchdog_sync',$1)", [JSON.stringify({ type: 'session_revoked', session_id: row.id })]);
      }
      return { ok: true, revoked: rows.length };
    });
  }
  async function active(id) {
    return (await store.query('SELECT id FROM auth_sessions WHERE id=$1 AND revoked_at IS NULL AND expires_at>$2', [id, Date.now()])).rows.length > 0;
  }
  return { list, revoke, active };
}
module.exports = { createAuthDevices };
