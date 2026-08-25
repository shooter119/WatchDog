-- WatchDog CloudBase PG 模式初始结构。
-- 运行时通过 PostgREST + service_role 访问；本文件仅由 db:migrate 执行。

CREATE TABLE IF NOT EXISTS public.entries (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  name TEXT NOT NULL,
  pressure_mpa DOUBLE PRECISION,
  duration_min INTEGER NOT NULL DEFAULT 0,
  entry_at BIGINT NOT NULL,
  exit_at BIGINT NOT NULL,
  exited_at BIGINT,
  source TEXT NOT NULL DEFAULT 'voice',
  raw_text TEXT,
  created_at BIGINT NOT NULL,
  consumption_actual_lpm DOUBLE PRECISION
);

CREATE TABLE IF NOT EXISTS public.firefighters (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.hotwords (
  id TEXT PRIMARY KEY,
  word TEXT NOT NULL UNIQUE,
  created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.logs (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  device TEXT,
  op_id TEXT,
  level TEXT NOT NULL DEFAULT 'info',
  stage TEXT NOT NULL,
  msg TEXT NOT NULL DEFAULT '',
  data TEXT,
  created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.user_settings (
  user_id TEXT NOT NULL,
  scene TEXT NOT NULL DEFAULT 'default',
  key TEXT NOT NULL,
  value TEXT NOT NULL,
  updated_at BIGINT NOT NULL,
  PRIMARY KEY (user_id, scene, key)
);

CREATE TABLE IF NOT EXISTS public.pressure_samples (
  id BIGSERIAL PRIMARY KEY,
  entry_id TEXT NOT NULL,
  scene TEXT NOT NULL DEFAULT 'default',
  name TEXT NOT NULL,
  pressure_mpa DOUBLE PRECISION NOT NULL,
  reported_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.notes (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  text TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT '其他',
  author TEXT NOT NULL DEFAULT '',
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.chat_messages (
  id TEXT PRIMARY KEY,
  scene TEXT NOT NULL DEFAULT 'default',
  role TEXT NOT NULL,
  content TEXT NOT NULL,
  created_at BIGINT NOT NULL
);

CREATE TABLE IF NOT EXISTS public.incidents (
  id TEXT PRIMARY KEY,
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

CREATE TABLE IF NOT EXISTS public.incident_events (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL,
  type TEXT NOT NULL,
  occurred_at BIGINT NOT NULL,
  recorded_at BIGINT NOT NULL,
  actor_device_id TEXT,
  actor_name TEXT,
  source TEXT NOT NULL DEFAULT 'online',
  client_op_id TEXT,
  payload TEXT,
  revision_of TEXT,
  voided_at BIGINT
);

CREATE TABLE IF NOT EXISTS public.stations (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  normalized_name TEXT NOT NULL UNIQUE,
  created_at BIGINT NOT NULL,
  created_by TEXT
);

CREATE TABLE IF NOT EXISTS public.incident_forces (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL,
  station_id TEXT,
  station_name TEXT NOT NULL,
  vehicle_count INTEGER NOT NULL DEFAULT 0,
  personnel_count INTEGER NOT NULL DEFAULT 0,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  version INTEGER NOT NULL DEFAULT 1,
  UNIQUE (incident_id, station_name)
);

CREATE TABLE IF NOT EXISTS public.device_profiles (
  device_id TEXT PRIMARY KEY,
  real_name TEXT NOT NULL DEFAULT '',
  updated_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_entries_entry_at ON public.entries(entry_at);
CREATE INDEX IF NOT EXISTS idx_entries_scene ON public.entries(scene, entry_at);
CREATE INDEX IF NOT EXISTS idx_logs_scene ON public.logs(scene, created_at);
CREATE INDEX IF NOT EXISTS idx_logs_op ON public.logs(op_id);
CREATE INDEX IF NOT EXISTS idx_user_settings_scene ON public.user_settings(scene, user_id);
CREATE INDEX IF NOT EXISTS idx_samples_entry ON public.pressure_samples(entry_id, reported_at);
CREATE INDEX IF NOT EXISTS idx_notes_scene ON public.notes(scene, created_at);
CREATE INDEX IF NOT EXISTS idx_chat_scene ON public.chat_messages(scene, created_at);
CREATE INDEX IF NOT EXISTS idx_incidents_status_activity ON public.incidents(status, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_incidents_archived_at ON public.incidents(archived_at DESC);
CREATE INDEX IF NOT EXISTS idx_incident_events_time ON public.incident_events(incident_id, occurred_at DESC, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_incident_forces_incident ON public.incident_forces(incident_id, station_name);
CREATE UNIQUE INDEX IF NOT EXISTS idx_incident_events_op ON public.incident_events(client_op_id) WHERE client_op_id IS NOT NULL;

ALTER TABLE public.entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.firefighters ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hotwords ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.pressure_samples ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.incidents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.incident_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.incident_forces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_profiles ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO service_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO service_role;
