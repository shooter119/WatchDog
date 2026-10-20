-- Authorized HTTP-FLV resources are managed per fire unit. URLs stay in the
-- database rather than the public client source because Commander bindings
-- can change and must not be redistributed as fixed configuration.
CREATE TABLE video_resources (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL REFERENCES units(id),
  name TEXT NOT NULL,
  stream_url TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  active BOOLEAN NOT NULL DEFAULT TRUE,
  sort_order INTEGER NOT NULL DEFAULT 0,
  version INTEGER NOT NULL DEFAULT 1,
  created_by TEXT REFERENCES unit_members(id),
  updated_by TEXT REFERENCES unit_members(id),
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  UNIQUE (unit_id, stream_url)
);

CREATE INDEX video_resources_unit_order
  ON video_resources(unit_id, active, sort_order, created_at);
