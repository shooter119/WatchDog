CREATE TABLE hazardous_chemicals (
  id TEXT PRIMARY KEY,
  name_cn TEXT NOT NULL,
  name_en TEXT NOT NULL DEFAULT '',
  aliases TEXT[] NOT NULL DEFAULT '{}',
  un_number TEXT NOT NULL DEFAULT '',
  cas_number TEXT NOT NULL DEFAULT '',
  danger_category TEXT NOT NULL DEFAULT '',
  danger_sign_color TEXT NOT NULL DEFAULT '',
  water_reactivity TEXT NOT NULL DEFAULT 'normal',
  danger_summary TEXT NOT NULL DEFAULT '',
  forbidden_agents TEXT NOT NULL DEFAULT '',
  extinguishing_agents TEXT NOT NULL DEFAULT '',
  firefighting_tips TEXT NOT NULL DEFAULT '',
  protective_level TEXT NOT NULL DEFAULT '',
  isolation_distance TEXT NOT NULL DEFAULT '',
  leak_handling TEXT NOT NULL DEFAULT '',
  first_aid TEXT NOT NULL DEFAULT '',
  appearance TEXT NOT NULL DEFAULT '',
  flash_point TEXT NOT NULL DEFAULT '',
  explosion_limit TEXT NOT NULL DEFAULT '',
  vapor_density TEXT NOT NULL DEFAULT '',
  notes TEXT NOT NULL DEFAULT '',
  active BOOLEAN NOT NULL DEFAULT true,
  created_by TEXT REFERENCES unit_members(id),
  updated_by TEXT REFERENCES unit_members(id),
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);

CREATE INDEX idx_hazmats_un ON hazardous_chemicals(un_number);
CREATE INDEX idx_hazmats_name ON hazardous_chemicals(name_cn);
CREATE INDEX idx_hazmats_water ON hazardous_chemicals(water_reactivity);
CREATE INDEX idx_hazmats_active_time ON hazardous_chemicals(active, updated_at DESC);
