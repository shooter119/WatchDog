ALTER TABLE key_site_tasks ADD COLUMN requested_by TEXT REFERENCES unit_members(id);
ALTER TABLE key_site_tasks DROP CONSTRAINT key_site_tasks_status_check;
ALTER TABLE key_site_tasks ADD CONSTRAINT key_site_tasks_status_check
  CHECK(status IN ('queued','processing','succeeded','partial','failed','cancelled'));
ALTER TABLE key_site_tasks ADD CONSTRAINT key_site_ai_requester
  CHECK(kind <> 'ai' OR requested_by IS NOT NULL);
CREATE INDEX key_site_ai_requester_time ON key_site_tasks(requested_by,created_at) WHERE kind='ai';
