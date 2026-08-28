-- 单位认证与警情归属。
-- 仅新增单位表和可空归属字段；历史警情保持 unit_id = NULL，不自动改归属。

CREATE TABLE IF NOT EXISTS public.units (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  verification_code TEXT NOT NULL UNIQUE,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);

ALTER TABLE public.incidents ADD COLUMN IF NOT EXISTS unit_id TEXT;
ALTER TABLE public.device_profiles ADD COLUMN IF NOT EXISTS unit_id TEXT;

CREATE INDEX IF NOT EXISTS idx_incidents_unit_status_activity
  ON public.incidents(unit_id, status, last_activity_at DESC);
CREATE INDEX IF NOT EXISTS idx_device_profiles_unit
  ON public.device_profiles(unit_id, device_id);

ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.units TO service_role;
