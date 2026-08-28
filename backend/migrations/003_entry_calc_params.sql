-- 保存每条进场记录实际使用的气瓶容量与消耗率，避免后续压力复核回退到全局默认值。
ALTER TABLE public.entries ADD COLUMN IF NOT EXISTS cylinder_vol_l DOUBLE PRECISION;
ALTER TABLE public.entries ADD COLUMN IF NOT EXISTS consumption_lpm DOUBLE PRECISION;
