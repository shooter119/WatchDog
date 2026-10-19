CREATE TABLE admin_grants (
  member_id TEXT PRIMARY KEY REFERENCES unit_members(id),
  role TEXT NOT NULL CHECK (role IN ('unit_admin', 'platform_admin')),
  granted_by TEXT REFERENCES unit_members(id),
  updated_at BIGINT NOT NULL
);
CREATE TABLE admin_challenges (
  id TEXT PRIMARY KEY,
  browser_hash TEXT NOT NULL,
  scan_hash TEXT NOT NULL,
  expires_at BIGINT NOT NULL,
  member_id TEXT REFERENCES unit_members(id),
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'confirmed', 'consumed', 'cancelled'))
);
CREATE TABLE admin_sessions (
  token_hash TEXT PRIMARY KEY,
  member_id TEXT NOT NULL REFERENCES unit_members(id),
  csrf_hash TEXT NOT NULL,
  created_at BIGINT NOT NULL,
  last_seen_at BIGINT NOT NULL,
  revoked_at BIGINT
);
CREATE INDEX admin_sessions_member ON admin_sessions(member_id);
CREATE INDEX admin_challenges_expiry ON admin_challenges(expires_at);
CREATE TABLE admin_audit (
  id TEXT PRIMARY KEY,
  actor_id TEXT REFERENCES unit_members(id),
  action TEXT NOT NULL,
  target_id TEXT,
  created_at BIGINT NOT NULL
);
CREATE INDEX admin_audit_time ON admin_audit(created_at DESC);
