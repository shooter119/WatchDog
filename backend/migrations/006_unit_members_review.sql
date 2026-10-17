-- 扩展 unit_members 支持自主申请审核流与队站信息，保留向后兼容的默认值
ALTER TABLE unit_members
  ADD COLUMN IF NOT EXISTS review_status TEXT NOT NULL DEFAULT 'approved'
    CHECK (review_status IN ('pending', 'approved', 'rejected')),
  ADD COLUMN IF NOT EXISTS station_name TEXT DEFAULT '',
  ADD COLUMN IF NOT EXISTS phone TEXT DEFAULT '',
  ADD COLUMN IF NOT EXISTS apply_reason TEXT DEFAULT '',
  ADD COLUMN IF NOT EXISTS reviewed_by TEXT REFERENCES unit_members(id),
  ADD COLUMN IF NOT EXISTS reviewed_at BIGINT;

CREATE INDEX IF NOT EXISTS idx_unit_members_review ON unit_members(unit_id, review_status, created_at);
