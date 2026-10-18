-- 现场口述记录：水印视频/照片中的语音内容，经人工核对后写入。
-- 只保存文字与元数据，媒体文件保留在拍摄设备本地，服务端不存原图与原视频。
CREATE TABLE IF NOT EXISTS incident_observations (
  id TEXT PRIMARY KEY,
  incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
  unit_id TEXT NOT NULL REFERENCES units(id),
  source_type TEXT NOT NULL DEFAULT 'video'
    CHECK (source_type IN ('video', 'photo', 'audio')),
  captured_at BIGINT NOT NULL,
  transcript TEXT NOT NULL DEFAULT '',
  structured JSONB NOT NULL DEFAULT '{}'::jsonb,
  status TEXT NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('proposed', 'confirmed')),
  media_ref TEXT NOT NULL DEFAULT '',
  created_by TEXT NOT NULL DEFAULT '',
  created_at BIGINT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_incident_observations_incident
  ON incident_observations(incident_id, captured_at DESC);
