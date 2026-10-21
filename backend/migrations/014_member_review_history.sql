CREATE TABLE member_review_history (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL REFERENCES units(id),
  member_id TEXT NOT NULL REFERENCES unit_members(id),
  real_name TEXT NOT NULL,
  review_status TEXT NOT NULL CHECK (review_status IN ('approved','rejected')),
  reviewer_id TEXT REFERENCES unit_members(id),
  reviewer_name TEXT NOT NULL DEFAULT '',
  reviewed_at BIGINT NOT NULL
);
CREATE INDEX member_review_history_unit_time ON member_review_history(unit_id, reviewed_at DESC, id);
-- Preserve the last known review of existing applications without inventing older history.
INSERT INTO member_review_history(id,unit_id,member_id,real_name,review_status,reviewer_id,reviewer_name,reviewed_at)
SELECT m.id,m.unit_id,m.id,m.real_name,m.review_status,m.reviewed_by,COALESCE(r.real_name,''),m.reviewed_at
FROM unit_members m LEFT JOIN unit_members r ON r.id=m.reviewed_by
WHERE m.reviewed_at IS NOT NULL AND m.review_status IN ('approved','rejected');
