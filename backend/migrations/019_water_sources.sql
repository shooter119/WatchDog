CREATE TABLE water_sources (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL REFERENCES units(id) ON DELETE CASCADE,
  category TEXT NOT NULL CHECK (category IN ('hydrant', 'natural', 'pump_connector')),
  name TEXT NOT NULL CHECK (char_length(trim(name)) BETWEEN 1 AND 120),
  lat DOUBLE PRECISION NOT NULL CHECK (lat BETWEEN 3 AND 55),
  lng DOUBLE PRECISION NOT NULL CHECK (lng BETWEEN 73 AND 136),
  status TEXT NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'unavailable')),
  intake_methods TEXT[] NOT NULL DEFAULT '{}',
  note TEXT NOT NULL DEFAULT '' CHECK (char_length(note) <= 500),
  import_key TEXT,
  created_by TEXT NOT NULL DEFAULT '',
  created_by_name TEXT NOT NULL DEFAULT '',
  created_at BIGINT NOT NULL,
  updated_by TEXT NOT NULL DEFAULT '',
  updated_by_name TEXT NOT NULL DEFAULT '',
  updated_at BIGINT NOT NULL,
  deleted_at BIGINT,
  deleted_by TEXT,
  deleted_by_name TEXT,
  CONSTRAINT chk_water_sources_intake_methods CHECK (
    intake_methods <@ ARRAY['portable_pump', 'fire_truck', 'remote_supply']::text[]
    AND array_position(intake_methods, NULL) IS NULL
    AND (
      (category = 'natural' AND cardinality(intake_methods) >= 1)
      OR (category <> 'natural' AND intake_methods = '{}')
    )
  )
);

CREATE INDEX idx_water_sources_unit_active
  ON water_sources (unit_id, updated_at DESC)
  WHERE deleted_at IS NULL;

CREATE INDEX idx_water_sources_unit_deleted
  ON water_sources (unit_id, deleted_at DESC)
  WHERE deleted_at IS NOT NULL;

CREATE UNIQUE INDEX uq_water_sources_unit_import_key
  ON water_sources (unit_id, import_key)
  WHERE import_key IS NOT NULL;
