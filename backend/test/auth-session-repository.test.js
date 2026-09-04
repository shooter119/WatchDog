const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const crypto = require('crypto');

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'watchdog-auth-db-'));
process.env.NODE_ENV = 'test';
process.env.WATCHDOG_DB_DRIVER = 'sqlite';
process.env.WATCHDOG_DATA_DIR = tmpDir;
process.env.WATCHDOG_SEED_UNIT_MEMBERS = '[{"real_name":"成员甲","role":"manager"}]';
const db = require('../src/db');

test('认证仓储：成员准入、会话哈希、过期与撤销', () => {
  const member = db.findUnitMember('longyou-county-fire-rescue', '成员甲');
  assert.equal(member.role, 'manager');
  assert.equal(db.findUnitMember('longyou-county-fire-rescue', '不存在'), undefined);

  const expiredHash = crypto.createHash('sha256').update('expired').digest('hex');
  db.createAuthSession({
    id: 'expired-session', tokenHash: expiredHash, unitId: member.unit_id, memberId: member.id,
    deviceId: 'device-a', realName: member.real_name, role: member.role,
    createdAt: Date.now() - 2000, expiresAt: Date.now() - 1000,
  });
  assert.equal(db.getAuthSession(expiredHash), undefined);
  assert.equal(db.getAuthSessionRecord(expiredHash).id, 'expired-session');
  assert.equal(db.refreshAuthSession(expiredHash, { expiresAt: Date.now() + 60_000 }), undefined);

  const currentHash = crypto.createHash('sha256').update('current').digest('hex');
  const session = db.createAuthSession({
    id: 'current-session', tokenHash: currentHash, unitId: member.unit_id, memberId: member.id,
    deviceId: 'device-a', realName: member.real_name, role: member.role,
    expiresAt: Date.now() + 60_000,
  });
  assert.equal(session.token_hash, currentHash);
  assert.equal(db.getAuthSession(currentHash).role, 'manager');
  const previousExpiry = session.expires_at;
  const refreshed = db.refreshAuthSession(currentHash, { expiresAt: previousExpiry + 60_000 });
  assert.equal(refreshed.expires_at, previousExpiry + 60_000);
  assert.equal(db.touchAuthSession(currentHash), 1);
  assert.equal(db.revokeAuthSession(currentHash), 1);
  assert.equal(db.getAuthSession(currentHash), undefined);
  assert.notEqual(db.getAuthSessionRecord(currentHash).revoked_at, null);
});
