CREATE TABLE key_sites (
  id TEXT PRIMARY KEY,
  owner_unit_id TEXT NOT NULL REFERENCES units(id),
  name TEXT NOT NULL,
  short_name TEXT NOT NULL DEFAULT '',
  address TEXT NOT NULL,
  district TEXT NOT NULL DEFAULT '',
  site_type TEXT NOT NULL DEFAULT '',
  active BOOLEAN NOT NULL DEFAULT true,
  published_version INTEGER NOT NULL DEFAULT 0,
  revision INTEGER NOT NULL DEFAULT 1,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);
CREATE INDEX key_sites_filter ON key_sites(active,district,site_type,id);
CREATE INDEX key_sites_owner ON key_sites(owner_unit_id);
CREATE TABLE key_site_drafts (
  site_id TEXT PRIMARY KEY REFERENCES key_sites(id),
  content JSONB NOT NULL,
  revision INTEGER NOT NULL DEFAULT 1,
  updated_by TEXT NOT NULL REFERENCES unit_members(id),
  updated_at BIGINT NOT NULL
);
CREATE TABLE key_site_attachments (
  id TEXT PRIMARY KEY,
  site_id TEXT NOT NULL REFERENCES key_sites(id),
  module TEXT NOT NULL CHECK(module IN ('maps','plans','cards','organization','hazards')),
  filename TEXT NOT NULL,
  mime TEXT NOT NULL,
  size_bytes BIGINT NOT NULL,
  sha256 TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','processing','ready','failed')),
  metadata JSONB NOT NULL DEFAULT '{}',
  uploaded_by TEXT NOT NULL REFERENCES unit_members(id),
  created_at BIGINT NOT NULL
);
CREATE INDEX key_site_attachments_site ON key_site_attachments(site_id);
CREATE TABLE key_site_versions (
  id TEXT PRIMARY KEY,
  site_id TEXT NOT NULL REFERENCES key_sites(id),
  version INTEGER NOT NULL,
  profile JSONB NOT NULL,
  content JSONB NOT NULL,
  attachment_ids JSONB NOT NULL,
  published_by TEXT NOT NULL REFERENCES unit_members(id),
  published_at BIGINT NOT NULL,
  UNIQUE(site_id,version)
);
CREATE TABLE key_site_tasks (
  id TEXT PRIMARY KEY,
  site_id TEXT NOT NULL REFERENCES key_sites(id),
  attachment_id TEXT NOT NULL REFERENCES key_site_attachments(id),
  kind TEXT NOT NULL CHECK(kind IN ('document','map','ai')),
  status TEXT NOT NULL DEFAULT 'queued' CHECK(status IN ('queued','processing','succeeded','failed','cancelled')),
  generation INTEGER NOT NULL DEFAULT 1,
  attempts INTEGER NOT NULL DEFAULT 0,
  lease_token TEXT,
  lease_until BIGINT,
  error_code TEXT,
  result JSONB,
  draft_revision INTEGER,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);
CREATE INDEX key_site_tasks_claim ON key_site_tasks(status,created_at);
