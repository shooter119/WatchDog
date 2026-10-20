const crypto = require('node:crypto');

const hash = (value) => crypto.createHash('sha256').update(String(value || '')).digest('hex');
const secret = () => crypto.randomBytes(32).toString('base64url');
const fail = (code, status = 403) => { throw Object.assign(new Error(code), { code, status }); };

// Store injection lets the same authorization boundary run against isolated PostgreSQL schemas.
function createAdminAuth(store, now = Date.now, { onGrantChanged } = {}) {
  const query = async (sql, args = []) => (await store.query(sql, args)).rows;
  const audit = (actor, action, target = null) => query(
    'INSERT INTO admin_audit(id,actor_id,action,target_id,created_at) VALUES($1,$2,$3,$4,$5)',
    [crypto.randomUUID(), actor, action, target, now()],
  );
  async function identity(memberId) {
    return (await query(`SELECT m.id, m.unit_id, u.name AS unit_name, m.real_name, m.role AS unit_role, g.role AS admin_role
      FROM unit_members m JOIN units u ON u.id=m.unit_id JOIN admin_grants g ON g.member_id=m.id
      WHERE m.id=$1 AND m.status='active' AND m.review_status='approved'
      AND (g.role='platform_admin' OR m.role IN ('manager','admin'))`, [memberId]))[0];
  }
  async function requireIdentity(memberId) {
    const member = await identity(memberId);
    if (!member) fail('ADMIN_FORBIDDEN');
    return member;
  }
  async function setGrant(actorId, memberId, role, { bootstrap = false } = {}) {
    if (role !== null && !['unit_admin', 'platform_admin'].includes(role)) fail('ADMIN_ROLE_INVALID', 400);
    return store.transaction(async () => {
      // Serialize grant changes, including first-admin initialization and last-admin protection.
      await query('SELECT pg_advisory_xact_lock(119008)');
      if (bootstrap) {
        if (role !== 'platform_admin') fail('ADMIN_ROLE_INVALID', 400);
      } else if ((await requireIdentity(actorId)).admin_role !== 'platform_admin') fail('ADMIN_FORBIDDEN');
      const target = (await query('SELECT * FROM unit_members WHERE id=$1 FOR UPDATE', [memberId]))[0];
      if (!target || (role !== null && (target.status !== 'active' || target.review_status !== 'approved'))
        || (role === 'unit_admin' && !['manager', 'admin'].includes(target.role))) fail('ADMIN_MEMBER_INVALID', 400);
      const platforms = await query(`SELECT m.id FROM unit_members m JOIN admin_grants g ON g.member_id=m.id
        WHERE g.role='platform_admin' AND m.status='active' AND m.review_status='approved'`);
      if (bootstrap && platforms.length) fail('ADMIN_ALREADY_INITIALIZED', 409);
      if (role !== 'platform_admin' && platforms.length === 1 && platforms[0].id === memberId) fail('ADMIN_LAST_PLATFORM', 409);
      if (role === null) await query('DELETE FROM admin_grants WHERE member_id=$1', [memberId]);
      else await query(`INSERT INTO admin_grants(member_id,role,granted_by,updated_at) VALUES($1,$2,$3,$4)
        ON CONFLICT(member_id) DO UPDATE SET role=$2, granted_by=$3, updated_at=$4`, [memberId, role, actorId, now()]);
      await query('UPDATE admin_sessions SET revoked_at=$2 WHERE member_id=$1 AND revoked_at IS NULL', [memberId, now()]);
      await query("UPDATE admin_challenges SET state='cancelled' WHERE member_id=$1 AND state='confirmed'", [memberId]);
      await audit(actorId, bootstrap ? 'admin_initialized' : role ? 'grant_set' : 'grant_revoked', memberId);
      if (onGrantChanged) await onGrantChanged(target);
    });
  }
  async function challenge() {
    const id = crypto.randomUUID(), browser = secret(), scan = secret();
    const expiresAt = now() + 120000;
    await query('DELETE FROM admin_challenges WHERE expires_at<$1', [now() - 86400000]);
    await query('INSERT INTO admin_challenges(id,browser_hash,scan_hash,expires_at) VALUES($1,$2,$3,$4)', [id, hash(browser), hash(scan), expiresAt]);
    return { id, browser, scan, expiresAt };
  }
  async function confirm(id, scan, memberId, cancel = false) {
    return store.transaction(async () => {
      await requireIdentity(memberId);
      const rows = await query(`UPDATE admin_challenges SET member_id=$3,state=$4
        WHERE id=$1 AND scan_hash=$2 AND state='pending' AND expires_at>$5 RETURNING id`,
      [id, hash(scan), memberId, cancel ? 'cancelled' : 'confirmed', now()]);
      if (!rows.length) fail('ADMIN_CHALLENGE_INVALID', 409);
      await audit(memberId, cancel ? 'login_cancelled' : 'login_confirmed');
    });
  }
  async function claim(id, browser) {
    return store.transaction(async () => {
      const record = (await query(`SELECT * FROM admin_challenges WHERE id=$1 AND browser_hash=$2
        AND expires_at>$3 FOR UPDATE`, [id, hash(browser), now()]))[0];
      if (!record || ['consumed', 'cancelled'].includes(record.state)) fail('ADMIN_CHALLENGE_INVALID', 409);
      if (record.state === 'pending') return null;
      const member = await requireIdentity(record.member_id);
      const token = secret(), csrf = hash(`csrf:${token}`), time = now();
      await query('UPDATE admin_challenges SET state=\'consumed\' WHERE id=$1', [id]);
      await query(`INSERT INTO admin_sessions(token_hash,member_id,csrf_hash,created_at,last_seen_at)
        VALUES($1,$2,$3,$4,$4)`, [hash(token), member.id, hash(csrf), time]);
      await audit(member.id, 'login');
      return { token, csrf, member };
    });
  }
  async function session(token, csrf, write = false, touch = true) {
    const record = (await query(`SELECT * FROM admin_sessions WHERE token_hash=$1 AND revoked_at IS NULL
      AND created_at>$2 AND last_seen_at>$3`, [hash(token), now() - 8 * 3600000, now() - 30 * 60000]))[0];
    if (!record) fail('ADMIN_SESSION_INVALID', 401);
    const member = await identity(record.member_id);
    if (!member) {
      await query('UPDATE admin_sessions SET revoked_at=$2 WHERE member_id=$1 AND revoked_at IS NULL', [record.member_id, now()]);
      fail('ADMIN_SESSION_INVALID', 401);
    }
    if (write && hash(csrf) !== record.csrf_hash) fail('ADMIN_CSRF_INVALID');
    if (touch) await query('UPDATE admin_sessions SET last_seen_at=$2 WHERE token_hash=$1', [hash(token), now()]);
    return member;
  }
  async function logout(token, all = false) {
    return store.transaction(async () => {
      const member = await session(token);
      await query(all ? 'UPDATE admin_sessions SET revoked_at=$2 WHERE member_id=$1 AND revoked_at IS NULL'
        : 'UPDATE admin_sessions SET revoked_at=$2 WHERE token_hash=$1', [all ? member.id : hash(token), now()]);
      await audit(member.id, all ? 'logout_all' : 'logout');
    });
  }
  async function listMembers(actorId) {
    if ((await requireIdentity(actorId)).admin_role !== 'platform_admin') fail('ADMIN_FORBIDDEN');
    return query(`SELECT m.id,m.real_name,m.unit_id,u.name AS unit_name,m.role AS unit_role,
      g.role AS admin_role FROM unit_members m JOIN units u ON u.id=m.unit_id
      LEFT JOIN admin_grants g ON g.member_id=m.id
      WHERE (m.status='active' AND m.review_status='approved') OR g.member_id IS NOT NULL
      ORDER BY u.name,m.real_name LIMIT 1000`);
  }
  async function listAudit(actorId, offset = 0) {
    if ((await requireIdentity(actorId)).admin_role !== 'platform_admin') fail('ADMIN_FORBIDDEN');
    return query('SELECT a.*,m.real_name AS actor_name FROM admin_audit a LEFT JOIN unit_members m ON m.id=a.actor_id ORDER BY a.created_at DESC,a.id LIMIT 100 OFFSET $1',
      [Math.max(0, Math.min(1000000, Number.parseInt(offset, 10) || 0))]);
  }
  async function listUnits(actorId) {
    const member = await requireIdentity(actorId);
    return query('SELECT id,name FROM units WHERE $1::boolean OR id=$2 ORDER BY name', [member.admin_role === 'platform_admin', member.unit_id]);
  }
  return { identity, requireIdentity, setGrant, challenge, confirm, claim, session, logout, audit, listMembers, listAudit, listUnits };
}
module.exports = { createAdminAuth, hash };
