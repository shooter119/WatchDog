-- 数据完整性约束采用 NOT VALID：保留历史异常数据，但立即拒绝新的非法写入。
-- 预检报告确认历史数据清洁后，再由运维单独执行 VALIDATE CONSTRAINT。

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'entries_pressure_range') THEN
    ALTER TABLE public.entries ADD CONSTRAINT entries_pressure_range
      CHECK (pressure_mpa IS NULL OR (pressure_mpa > 0 AND pressure_mpa <= 40)) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'entries_duration_nonnegative') THEN
    ALTER TABLE public.entries ADD CONSTRAINT entries_duration_nonnegative
      CHECK (duration_min >= 0) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'entries_cylinder_range') THEN
    ALTER TABLE public.entries ADD CONSTRAINT entries_cylinder_range
      CHECK (cylinder_vol_l IS NULL OR (cylinder_vol_l > 0 AND cylinder_vol_l <= 20)) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'entries_consumption_range') THEN
    ALTER TABLE public.entries ADD CONSTRAINT entries_consumption_range
      CHECK (consumption_lpm IS NULL OR (consumption_lpm > 0 AND consumption_lpm <= 300)) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pressure_samples_range') THEN
    ALTER TABLE public.pressure_samples ADD CONSTRAINT pressure_samples_range
      CHECK (pressure_mpa > 0 AND pressure_mpa <= 40) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'incident_forces_counts_range') THEN
    ALTER TABLE public.incident_forces ADD CONSTRAINT incident_forces_counts_range
      CHECK (vehicle_count BETWEEN 0 AND 999 AND personnel_count BETWEEN 0 AND 999) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'incidents_unit_fk') THEN
    ALTER TABLE public.incidents ADD CONSTRAINT incidents_unit_fk
      FOREIGN KEY (unit_id) REFERENCES public.units(id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'incident_events_incident_fk') THEN
    ALTER TABLE public.incident_events ADD CONSTRAINT incident_events_incident_fk
      FOREIGN KEY (incident_id) REFERENCES public.incidents(id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'incident_forces_incident_fk') THEN
    ALTER TABLE public.incident_forces ADD CONSTRAINT incident_forces_incident_fk
      FOREIGN KEY (incident_id) REFERENCES public.incidents(id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'pressure_samples_entry_fk') THEN
    ALTER TABLE public.pressure_samples ADD CONSTRAINT pressure_samples_entry_fk
      FOREIGN KEY (entry_id) REFERENCES public.entries(id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'unit_members_unit_fk') THEN
    ALTER TABLE public.unit_members ADD CONSTRAINT unit_members_unit_fk
      FOREIGN KEY (unit_id) REFERENCES public.units(id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'auth_sessions_unit_fk') THEN
    ALTER TABLE public.auth_sessions ADD CONSTRAINT auth_sessions_unit_fk
      FOREIGN KEY (unit_id) REFERENCES public.units(id) NOT VALID;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'auth_sessions_member_fk') THEN
    ALTER TABLE public.auth_sessions ADD CONSTRAINT auth_sessions_member_fk
      FOREIGN KEY (member_id) REFERENCES public.unit_members(id) NOT VALID;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_incident_events_incident_op
  ON public.incident_events(incident_id, client_op_id)
  WHERE client_op_id IS NOT NULL;
