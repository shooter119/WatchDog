CREATE TABLE IF NOT EXISTS external_incidents (
  external_id TEXT PRIMARY KEY,
  incident_number TEXT NOT NULL DEFAULT '',
  raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
  raw_merged_text TEXT NOT NULL DEFAULT '',
  content_hash TEXT NOT NULL DEFAULT '',
  ai_status TEXT NOT NULL DEFAULT 'fallback'
    CHECK (ai_status IN ('pending', 'ready', 'fallback', 'failed')),
  ai_model TEXT NOT NULL DEFAULT '',
  ai_organized_at BIGINT,
  event_summary TEXT NOT NULL DEFAULT '',
  disaster_category TEXT NOT NULL DEFAULT 'fire'
    CHECK (disaster_category IN ('fire', 'rescue', 'aid')),
  incident_type TEXT NOT NULL DEFAULT '',
  specific_type TEXT NOT NULL DEFAULT '',
  incident_level TEXT NOT NULL DEFAULT '',
  official_status TEXT NOT NULL DEFAULT '',
  location_display TEXT NOT NULL DEFAULT '',
  crime_address TEXT NOT NULL DEFAULT '',
  district_name TEXT NOT NULL DEFAULT '',
  detachment_name TEXT NOT NULL DEFAULT '',
  brigade_name TEXT NOT NULL DEFAULT '',
  squadron_name TEXT NOT NULL DEFAULT '',
  register_time BIGINT NOT NULL DEFAULT 0,
  latitude TEXT,
  longitude TEXT,
  situation_detail TEXT NOT NULL DEFAULT '',
  trapped TEXT NOT NULL DEFAULT '',
  injured TEXT NOT NULL DEFAULT '',
  hazardous_materials TEXT NOT NULL DEFAULT '',
  dispatch_summary TEXT NOT NULL DEFAULT '',
  dispatched_forces JSONB NOT NULL DEFAULT '[]'::jsonb,
  fact_highlights JSONB NOT NULL DEFAULT '[]'::jsonb,
  contacts JSONB NOT NULL DEFAULT '[]'::jsonb,
  scraped_at BIGINT NOT NULL DEFAULT 0,
  updated_at BIGINT NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_external_incidents_register_time
  ON external_incidents(register_time DESC);
CREATE INDEX IF NOT EXISTS idx_external_incidents_number
  ON external_incidents(incident_number);
