CREATE TABLE incident_details (
  incident_id TEXT PRIMARY KEY REFERENCES incidents(id),
  unit_id TEXT NOT NULL REFERENCES units(id),
  data JSONB NOT NULL DEFAULT '{}'::jsonb,
  version INTEGER NOT NULL DEFAULT 1,
  updated_at BIGINT NOT NULL,
  updated_by TEXT NOT NULL
);
CREATE TABLE unit_stations (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL REFERENCES units(id),
  name TEXT NOT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  version INTEGER NOT NULL DEFAULT 1,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  created_by TEXT NOT NULL,
  UNIQUE (unit_id, id)
);
-- Names and aliases share one unique namespace within each unit.
CREATE TABLE unit_station_names (
  unit_id TEXT NOT NULL,
  normalized_name TEXT NOT NULL,
  station_id TEXT NOT NULL,
  is_primary BOOLEAN NOT NULL DEFAULT FALSE,
  PRIMARY KEY (unit_id, normalized_name),
  FOREIGN KEY (unit_id, station_id) REFERENCES unit_stations(unit_id, id)
);
ALTER TABLE incident_forces
  ADD COLUMN unit_station_id TEXT REFERENCES unit_stations(id),
  ADD COLUMN deployment_status TEXT,
  ADD COLUMN information_source TEXT;
CREATE TABLE incident_imports (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL REFERENCES units(id),
  incident_id TEXT NOT NULL REFERENCES incidents(id),
  actor_id TEXT NOT NULL,
  actor_name TEXT NOT NULL,
  source TEXT NOT NULL CHECK (source IN ('text', 'images')),
  status TEXT NOT NULL CHECK (status IN ('queued','processing','ready','partial','failed','cancelled','applied','expired')),
  input_hash TEXT NOT NULL,
  pages JSONB NOT NULL,
  draft JSONB,
  error_code TEXT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL,
  lease_until BIGINT,
  generation INTEGER NOT NULL DEFAULT 1,
  apply_op_id TEXT,
  apply_hash TEXT,
  applied_result JSONB,
  applied_at BIGINT
);
CREATE INDEX incident_import_tasks ON incident_imports(status, created_at);
CREATE INDEX incident_import_owner ON incident_imports(unit_id, incident_id, actor_id, created_at);
CREATE UNIQUE INDEX incident_import_apply_op ON incident_imports(unit_id, apply_op_id) WHERE apply_op_id IS NOT NULL;
CREATE TABLE incident_detail_history (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL REFERENCES incidents(id),
  unit_id TEXT NOT NULL REFERENCES units(id),
  import_id TEXT REFERENCES incident_imports(id),
  before_data JSONB NOT NULL,
  after_data JSONB NOT NULL,
  actor_id TEXT NOT NULL,
  created_at BIGINT NOT NULL
);
