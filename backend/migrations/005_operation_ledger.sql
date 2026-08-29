-- 关键写操作的幂等账本。
-- 账本只记录请求摘要与已完成结果，不把未完成操作当作成功；失败时由应用删除 pending 行。

CREATE TABLE IF NOT EXISTS public.operation_ledger (
  unit_id TEXT NOT NULL DEFAULT '',
  client_op_id TEXT NOT NULL,
  incident_id TEXT,
  operation_type TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'succeeded')),
  result_json TEXT,
  response_status INTEGER,
  event_id TEXT,
  actor_device_id TEXT,
  actor_name TEXT,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  lease_until BIGINT,
  completed_at BIGINT,
  PRIMARY KEY (unit_id, client_op_id)
);

ALTER TABLE public.operation_ledger ADD COLUMN IF NOT EXISTS lease_until BIGINT;

CREATE INDEX IF NOT EXISTS idx_operation_ledger_incident
  ON public.operation_ledger(unit_id, incident_id, updated_at);

ALTER TABLE public.operation_ledger ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.operation_ledger TO service_role;
