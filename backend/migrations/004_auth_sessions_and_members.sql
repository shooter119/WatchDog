-- 单位成员准入与服务端会话。
-- 成员名单由部署配置/管理流程显式维护；不从全局消防员名单自动推导。

CREATE TABLE IF NOT EXISTS public.unit_members (
  id TEXT PRIMARY KEY,
  unit_id TEXT NOT NULL,
  real_name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'manager', 'admin')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  UNIQUE (unit_id, real_name)
);

CREATE INDEX IF NOT EXISTS idx_unit_members_lookup
  ON public.unit_members(unit_id, real_name, status);

CREATE TABLE IF NOT EXISTS public.auth_sessions (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  unit_id TEXT NOT NULL,
  member_id TEXT,
  device_id TEXT,
  real_name TEXT NOT NULL,
  role TEXT NOT NULL DEFAULT 'member' CHECK (role IN ('member', 'manager', 'admin')),
  created_at BIGINT NOT NULL,
  expires_at BIGINT NOT NULL,
  last_seen_at BIGINT NOT NULL,
  revoked_at BIGINT
);

CREATE INDEX IF NOT EXISTS idx_auth_sessions_token
  ON public.auth_sessions(token_hash);
CREATE INDEX IF NOT EXISTS idx_auth_sessions_device
  ON public.auth_sessions(unit_id, device_id, revoked_at);

ALTER TABLE public.unit_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auth_sessions ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.unit_members TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.auth_sessions TO service_role;
