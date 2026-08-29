-- 007 中的原子 RPC 使用 ON CONFLICT (client_op_id)。
-- 001 的部分唯一索引只覆盖非空值，不能作为该冲突目标；补充完整唯一索引。
-- PostgreSQL 唯一索引允许多个 NULL，因此不会改变没有 client_op_id 的事件写入行为。
CREATE UNIQUE INDEX IF NOT EXISTS idx_incident_events_client_op_id_full
  ON public.incident_events(client_op_id);
