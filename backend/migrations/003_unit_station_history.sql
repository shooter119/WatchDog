CREATE TABLE unit_station_history (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL REFERENCES units(id),
  station_id TEXT NOT NULL REFERENCES unit_stations(id),
  actor_id TEXT NOT NULL,
  before_data JSONB NOT NULL,
  after_data JSONB NOT NULL,
  created_at BIGINT NOT NULL
);
