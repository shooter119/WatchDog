-- 火场日志照片/视频附件元信息与生命周期状态（媒体二进制存于 VPS 私有卷，数据库仅存元信息）。
-- 支持已归档警情 90 天保留 + 5 GB 总空间上限自动清理；清理仅清空媒体路径并写入 purged_at，文字日志永久保留。
CREATE TABLE IF NOT EXISTS note_media (
  id TEXT PRIMARY KEY,
  note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  unit_id TEXT NOT NULL REFERENCES units(id),
  kind TEXT NOT NULL CHECK (kind IN ('photo', 'video')),
  mime TEXT NOT NULL,
  file_path TEXT NOT NULL DEFAULT '',
  thumb_path TEXT NOT NULL DEFAULT '',
  size_bytes BIGINT NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  width INTEGER NOT NULL DEFAULT 0,
  height INTEGER NOT NULL DEFAULT 0,
  captured_at BIGINT NOT NULL DEFAULT 0,
  address TEXT NOT NULL DEFAULT '',
  weather TEXT NOT NULL DEFAULT '',
  created_by TEXT NOT NULL DEFAULT '',
  created_at BIGINT NOT NULL,
  purged_at BIGINT
);

CREATE INDEX IF NOT EXISTS idx_note_media_note
  ON note_media(note_id, created_at ASC);

CREATE INDEX IF NOT EXISTS idx_note_media_incident
  ON note_media(incident_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_note_media_active_quota
  ON note_media(created_at ASC)
  WHERE purged_at IS NULL;
