ALTER TABLE entries ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 1;
ALTER TABLE entries ADD COLUMN IF NOT EXISTS pressure_reported_at BIGINT;
UPDATE entries SET pressure_reported_at = COALESCE((SELECT MAX(reported_at) FROM pressure_samples WHERE entry_id = entries.id), entry_at) WHERE pressure_reported_at IS NULL;
ALTER TABLE auth_sessions ADD COLUMN IF NOT EXISTS device_name TEXT NOT NULL DEFAULT '';
ALTER TABLE auth_sessions ADD COLUMN IF NOT EXISTS platform TEXT NOT NULL DEFAULT '';
ALTER TABLE auth_sessions ADD COLUMN IF NOT EXISTS revoked_reason TEXT;
CREATE TABLE IF NOT EXISTS auth_device_audit (
  id BIGSERIAL PRIMARY KEY,
  unit_id TEXT NOT NULL,
  member_id TEXT NOT NULL,
  actor_session_id TEXT NOT NULL,
  target_session_id TEXT NOT NULL,
  occurred_at BIGINT NOT NULL,
  action TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_auth_member_devices ON auth_sessions(unit_id, member_id, device_id);
