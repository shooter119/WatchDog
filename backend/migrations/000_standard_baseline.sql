-- WatchDog 标准 PostgreSQL 基线。
-- 生产与本地均直接使用标准 PostgreSQL，不依赖供应商专有角色或 API。

CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  checksum TEXT NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS units (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  verification_code TEXT NOT NULL UNIQUE,
  roster_version BIGINT NOT NULL DEFAULT 1,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS unit_members (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL REFERENCES units(id),
  real_name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'manager', 'admin')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  UNIQUE (unit_id, real_name)
);

CREATE TABLE IF NOT EXISTS auth_sessions (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  unit_id TEXT NOT NULL REFERENCES units(id),
  member_id TEXT REFERENCES unit_members(id),
  device_id TEXT,
  real_name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'manager', 'admin')),
  created_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL,
  last_seen_at BIGINT NOT NULL,
  revoked_at BIGINT
);

CREATE TABLE IF NOT EXISTS incidents (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL REFERENCES units(id),
  number TEXT NOT NULL UNIQUE,
  title TEXT,
  suggested_title TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  created_at BIGINT NOT NULL,
  last_activity_at BIGINT NOT NULL,
  archived_at BIGINT,
  archived_by TEXT,
  auto_archived INTEGER NOT NULL DEFAULT 0,
  unresolved_active_count INTEGER NOT NULL DEFAULT 0,
  created_by TEXT,
  version INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS entries (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL,
  name TEXT NOT NULL,
  pressure_mpa DOUBLE PRECISION,
  duration_min INTEGER NOT NULL DEFAULT 0,
  entry_at BIGINT NOT NULL,
  exit_at BIGINT NOT NULL,
  exited_at BIGINT,
  source TEXT NOT NULL DEFAULT 'voice',
  raw_text TEXT,
  created_at BIGINT NOT NULL,
  cylinder_vol_l DOUBLE PRECISION,
  consumption_lpm DOUBLE PRECISION,
  consumption_actual_lpm DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS pressure_samples (
  id BIGSERIAL PRIMARY KEY,
  entry_id TEXT NOT NULL REFERENCES entries(id),
  scene TEXT NOT NULL,
  name TEXT NOT NULL,
  pressure_mpa DOUBLE PRECISION NOT NULL,
  reported_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS notes (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL,
  text TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT '其他',
  author TEXT NOT NULL DEFAULT '',
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS firefighters (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL REFERENCES units(id),
  name TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'user' CHECK (source IN ('builtin', 'user')),
  created_by_member_id TEXT,
  created_by_name TEXT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  UNIQUE (unit_id, name)
);

CREATE TABLE IF NOT EXISTS hotwords (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL REFERENCES units(id),
  word TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'user' CHECK (source IN ('builtin', 'user')),
  created_by_member_id TEXT,
  created_by_name TEXT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  UNIQUE (unit_id, word)
);

CREATE TABLE IF NOT EXISTS stations (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  normalized_name TEXT NOT NULL UNIQUE,
  created_at BIGINT NOT NULL,
  created_by TEXT
);

CREATE TABLE IF NOT EXISTS incident_forces (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL REFERENCES incidents(id),
  station_id TEXT REFERENCES stations(id),
  station_name TEXT NOT NULL,
  vehicle_count INTEGER NOT NULL DEFAULT 0,
  personnel_count INTEGER NOT NULL DEFAULT 0,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  UNIQUE (incident_id, station_name)
);

CREATE TABLE IF NOT EXISTS incident_events (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL REFERENCES incidents(id),
  type TEXT NOT NULL,
  occurred_at BIGINT NOT NULL,
  recorded_at BIGINT NOT NULL,
  actor_device_id TEXT,
  actor_name TEXT,
  source TEXT NOT NULL DEFAULT 'online',
  client_op_id TEXT,
  payload JSONB,
  revision_of TEXT,
  voided_at BIGINT
);

CREATE TABLE IF NOT EXISTS operation_ledger (
  unit_id TEXT NOT NULL REFERENCES units(id),
  client_op_id TEXT NOT NULL,
  incident_id TEXT REFERENCES incidents(id),
  operation_type TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'succeeded')),
  result_json JSONB,
  response_status INTEGER,
  event_id TEXT,
  actor_device_id TEXT,
  actor_name TEXT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  lease_until BIGINT,
  completed_at BIGINT,
  PRIMARY KEY (unit_id, client_op_id)
);

CREATE TABLE IF NOT EXISTS device_profiles (
  device_id TEXT PRIMARY KEY,
  unit_id TEXT REFERENCES units(id),
  real_name TEXT NOT NULL DEFAULT '',
  updated_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS user_settings (
  user_id TEXT NOT NULL,
  scene TEXT NOT NULL DEFAULT 'default',
  key TEXT NOT NULL,
  value JSONB NOT NULL,
  updated_at BIGINT NOT NULL,
  PRIMARY KEY (user_id, scene, key)
);

CREATE TABLE IF NOT EXISTS logs (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  device TEXT,
  op_id TEXT,
  level TEXT NOT NULL DEFAULT 'info',
  stage TEXT NOT NULL,
  msg TEXT NOT NULL DEFAULT '',
  data JSONB,
  created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS chat_messages (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS sync_streams (
  stream_key TEXT PRIMARY KEY,
  last_sequence BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS sync_events (
  stream_key TEXT NOT NULL REFERENCES sync_streams(stream_key),
  sequence BIGINT NOT NULL,
  event_id TEXT NOT NULL UNIQUE,
  unit_id TEXT NOT NULL REFERENCES units(id),
  incident_id TEXT REFERENCES incidents(id),
  event_type TEXT NOT NULL,
  aggregate_id TEXT,
  client_op_id TEXT,
  payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at BIGINT NOT NULL,
  created_at BIGINT NOT NULL,
  PRIMARY KEY (stream_key, sequence)
);

CREATE INDEX IF NOT EXISTS idx_unit_members_lookup ON unit_members(unit_id, real_name, status);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_token ON auth_sessions(token_hash);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_device ON auth_sessions(unit_id, device_id, revoked_at);
CREATE INDEX IF NOT EXISTS idx_incidents_unit_status_activity ON incidents(unit_id, status, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_entries_scene ON entries(scene, entry_at DESC);
CREATE INDEX IF NOT EXISTS idx_pressure_samples_entry ON pressure_samples(entry_id, reported_at DESC);
CREATE INDEX IF NOT EXISTS idx_notes_scene ON notes(scene, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_firefighters_unit_created ON firefighters(unit_id, created_at);
CREATE INDEX IF NOT EXISTS idx_hotwords_unit_created ON hotwords(unit_id, created_at);
CREATE INDEX IF NOT EXISTS idx_incident_forces_incident ON incident_forces(incident_id, station_name);
CREATE INDEX IF NOT EXISTS idx_incident_events_time ON incident_events(incident_id, occurred_at DESC, recorded_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS idx_incident_events_client_op ON incident_events(client_op_id) WHERE client_op_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sync_events_unit ON sync_events(unit_id, stream_key, sequence);
CREATE INDEX IF NOT EXISTS idx_sync_events_incident ON sync_events(incident_id, stream_key, sequence);
CREATE INDEX IF NOT EXISTS idx_sync_events_created ON sync_events(created_at);

CREATE OR REPLACE FUNCTION watchdog_notify_sync_event() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('watchdog_sync', json_build_object(
    'stream_key', NEW.stream_key,
    'sequence', NEW.sequence
  )::text);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS sync_events_notify ON sync_events;
CREATE TRIGGER sync_events_notify AFTER INSERT ON sync_events
FOR EACH ROW EXECUTE FUNCTION watchdog_notify_sync_event();
