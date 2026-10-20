ALTER TABLE incidents
  ADD COLUMN key_site_version_id TEXT REFERENCES key_site_versions(id),
  ADD COLUMN key_site_link JSONB,
  ADD COLUMN key_site_link_revision INTEGER NOT NULL DEFAULT 0;
CREATE TABLE incident_key_site_references (
  incident_id TEXT NOT NULL REFERENCES incidents(id),
  version_id TEXT NOT NULL REFERENCES key_site_versions(id),
  first_linked_by TEXT NOT NULL REFERENCES unit_members(id),
  first_linked_at BIGINT NOT NULL,
  PRIMARY KEY(incident_id,version_id)
);
CREATE INDEX incident_key_site_version_refs ON incident_key_site_references(version_id,incident_id);
