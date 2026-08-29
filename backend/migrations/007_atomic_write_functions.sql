-- 关键现场写入的 PostgreSQL 原子命令。
-- 只有在迁移完成并完成真实数据库验收后，才允许打开 WATCHDOG_ATOMIC_OPS_ENABLED。

CREATE OR REPLACE FUNCTION public.watchdog_create_entry_with_event(
  p_entry jsonb,
  p_event jsonb,
  p_activity_at bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  entry_row public.entries;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
BEGIN
  INSERT INTO public.entries (
    id, scene, name, pressure_mpa, duration_min, entry_at, exit_at, source,
    raw_text, cylinder_vol_l, consumption_lpm, created_at
  ) VALUES (
    p_entry->>'id', COALESCE(p_entry->>'scene', 'default'), p_entry->>'name',
    NULLIF(p_entry->>'pressureMpa', '')::double precision,
    COALESCE(NULLIF(p_entry->>'durationMin', '')::integer, 0),
    (p_entry->>'entryAtMs')::bigint, (p_entry->>'exitAtMs')::bigint,
    COALESCE(p_entry->>'source', 'voice'), p_entry->>'rawText',
    NULLIF(p_entry->>'cylinderVolL', '')::double precision,
    NULLIF(p_entry->>'consumptionLpm', '')::double precision,
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000
  ) RETURNING * INTO entry_row;

  IF p_entry->>'pressureMpa' IS NOT NULL THEN
    INSERT INTO public.pressure_samples (entry_id, scene, name, pressure_mpa, reported_at)
    VALUES (
      entry_row.id, entry_row.scene, entry_row.name,
      (p_entry->>'pressureMpa')::double precision, entry_row.entry_at
    );
  END IF;

  UPDATE public.incidents
  SET last_activity_at = GREATEST(last_activity_at, COALESCE(p_activity_at, last_activity_at))
  WHERE id = p_event->>'incidentId' AND status = 'active';

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, p_event->>'incidentId', p_event->>'type',
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, entry_row.entry_at),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id, CASE WHEN p_event ? 'payload' THEN (p_event->'payload')::text ELSE NULL END,
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('entry', to_jsonb(entry_row), 'event', to_jsonb(event_row));
END;
$$;

CREATE OR REPLACE FUNCTION public.watchdog_upsert_force_with_event(
  p_force jsonb,
  p_event jsonb,
  p_activity_at bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  force_id text := COALESCE(p_force->>'id', md5(random()::text || clock_timestamp()::text));
  incident_id_value text := p_force->>'incidentId';
  station_name_value text := left(trim(COALESCE(p_force->>'stationName', '')), 80);
  station_id_value text := NULLIF(p_force->>'stationId', '');
  vehicle_count_value integer := COALESCE(NULLIF(p_force->>'vehicleCount', '')::integer, 0);
  personnel_count_value integer := COALESCE(NULLIF(p_force->>'personnelCount', '')::integer, 0);
  expected_version_value integer := NULLIF(p_force->>'expectedVersion', '')::integer;
  force_row public.incident_forces;
  current_row public.incident_forces;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(COALESCE(incident_id_value, '') || ':' || station_name_value));
  SELECT * INTO current_row FROM public.incident_forces
  WHERE public.incident_forces.incident_id = incident_id_value AND public.incident_forces.station_name = station_name_value
  FOR UPDATE;

  IF current_row.id IS NOT NULL THEN
    IF expected_version_value IS NOT NULL AND current_row.version <> expected_version_value THEN
      RETURN jsonb_build_object('conflict', true, 'force', to_jsonb(current_row), 'event', NULL);
    END IF;
    UPDATE public.incident_forces
    SET station_id = station_id_value, vehicle_count = vehicle_count_value,
        personnel_count = personnel_count_value, updated_at = EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
        version = version + 1
    WHERE id = current_row.id AND version = current_row.version
    RETURNING * INTO force_row;
  ELSE
    INSERT INTO public.incident_forces (
      id, incident_id, station_id, station_name, vehicle_count, personnel_count, created_at, updated_at, version
    ) VALUES (
      force_id, incident_id_value, station_id_value, station_name_value, vehicle_count_value, personnel_count_value,
      EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
      EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000, 1
    ) RETURNING * INTO force_row;
  END IF;

  UPDATE public.incidents
  SET last_activity_at = GREATEST(last_activity_at, COALESCE(p_activity_at, last_activity_at))
  WHERE id = incident_id_value AND status = 'active';

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, incident_id_value, p_event->>'type',
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id, CASE WHEN p_event ? 'payload' THEN (p_event->'payload')::text ELSE NULL END,
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('conflict', false, 'force', to_jsonb(force_row), 'event', to_jsonb(event_row), 'changed', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.watchdog_delete_force_with_event(
  p_id text,
  p_incident_id text,
  p_activity_at bigint DEFAULT NULL,
  p_event jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  deleted_id text;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
BEGIN
  DELETE FROM public.incident_forces WHERE id = p_id AND incident_id = p_incident_id RETURNING id INTO deleted_id;
  IF deleted_id IS NULL THEN
    RETURN jsonb_build_object('changed', false, 'event', NULL);
  END IF;

  UPDATE public.incidents
  SET last_activity_at = GREATEST(last_activity_at, COALESCE(p_activity_at, last_activity_at))
  WHERE id = p_incident_id AND status = 'active';

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, p_incident_id, p_event->>'type',
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id, CASE WHEN p_event ? 'payload' THEN (p_event->'payload')::text ELSE NULL END,
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('changed', true, 'event', to_jsonb(event_row));
END;
$$;

CREATE OR REPLACE FUNCTION public.watchdog_rename_incident_with_event(
  p_id text,
  p_title text,
  p_expected_version integer DEFAULT NULL,
  p_event jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  incident_row public.incidents;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
BEGIN
  UPDATE public.incidents
  SET title = p_title, version = version + 1
  WHERE id = p_id AND (p_expected_version IS NULL OR version = p_expected_version)
  RETURNING * INTO incident_row;

  IF NOT FOUND THEN
    SELECT * INTO incident_row FROM public.incidents WHERE id = p_id;
    IF p_expected_version IS NOT NULL AND incident_row.id IS NOT NULL THEN
      RETURN jsonb_build_object('conflict', true, 'incident', to_jsonb(incident_row), 'event', NULL);
    END IF;
    RETURN jsonb_build_object('conflict', false, 'incident', to_jsonb(incident_row), 'event', NULL, 'changed', false);
  END IF;

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, p_id, p_event->>'type',
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id, CASE WHEN p_event ? 'payload' THEN (p_event->'payload')::text ELSE NULL END,
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('conflict', false, 'incident', to_jsonb(incident_row), 'event', to_jsonb(event_row), 'changed', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.watchdog_archive_incident_with_event(
  p_id text,
  p_archived_by text DEFAULT NULL,
  p_now bigint DEFAULT NULL,
  p_auto boolean DEFAULT false,
  p_event jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  archive_at bigint := COALESCE(p_now, EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000);
  unresolved_count integer;
  incident_row public.incidents;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
BEGIN
  SELECT count(*) INTO unresolved_count FROM public.entries WHERE scene = p_id AND exited_at IS NULL;
  UPDATE public.incidents
  SET status = 'archived', archived_at = archive_at, archived_by = p_archived_by,
      auto_archived = CASE WHEN p_auto THEN 1 ELSE 0 END,
      unresolved_active_count = unresolved_count, version = version + 1
  WHERE id = p_id AND status = 'active'
  RETURNING * INTO incident_row;

  IF NOT FOUND THEN
    SELECT * INTO incident_row FROM public.incidents WHERE id = p_id;
    RETURN jsonb_build_object('incident', to_jsonb(incident_row), 'changed', false, 'event', NULL);
  END IF;

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, p_id, COALESCE(p_event->>'type', 'incident_archived'),
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, archive_at),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id,
    jsonb_build_object('auto', p_auto, 'unresolved_active_count', unresolved_count)::text,
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('incident', to_jsonb(incident_row), 'changed', true, 'event', to_jsonb(event_row));
END;
$$;

CREATE OR REPLACE FUNCTION public.watchdog_create_note_with_event(
  p_note jsonb,
  p_event jsonb,
  p_activity_at bigint DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  note_row public.notes;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
BEGIN
  INSERT INTO public.notes (id, scene, text, category, author, created_at, updated_at)
  VALUES (
    p_note->>'id', COALESCE(p_note->>'scene', 'default'), p_note->>'text',
    COALESCE(p_note->>'category', '其他'), COALESCE(p_note->>'author', ''),
    COALESCE(NULLIF(p_note->>'createdAt', '')::bigint, EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000),
    COALESCE(NULLIF(p_note->>'createdAt', '')::bigint, EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000)
  ) RETURNING * INTO note_row;

  UPDATE public.incidents
  SET last_activity_at = GREATEST(last_activity_at, COALESCE(p_activity_at, note_row.created_at))
  WHERE id = p_event->>'incidentId' AND status = 'active';

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, p_event->>'incidentId', p_event->>'type',
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, note_row.created_at),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id, CASE WHEN p_event ? 'payload' THEN (p_event->'payload')::text ELSE NULL END,
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('note', to_jsonb(note_row), 'event', to_jsonb(event_row));
END;
$$;

CREATE OR REPLACE FUNCTION public.watchdog_exit_entry_with_event(
  p_entry_id text,
  p_exited_at bigint,
  p_incident_id text,
  p_activity_at bigint DEFAULT NULL,
  p_event jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  entry_row public.entries;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
BEGIN
  UPDATE public.entries SET exited_at = p_exited_at
  WHERE id = p_entry_id AND exited_at IS NULL
  RETURNING * INTO entry_row;

  IF NOT FOUND THEN
    SELECT * INTO entry_row FROM public.entries WHERE id = p_entry_id;
    RETURN jsonb_build_object('entry', to_jsonb(entry_row), 'event', NULL, 'changed', false);
  END IF;

  UPDATE public.incidents
  SET last_activity_at = GREATEST(last_activity_at, COALESCE(p_activity_at, last_activity_at))
  WHERE id = p_incident_id AND status = 'active';

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, p_event->>'incidentId', p_event->>'type',
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, p_exited_at),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id, CASE WHEN p_event ? 'payload' THEN (p_event->'payload')::text ELSE NULL END,
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('entry', to_jsonb(entry_row), 'event', to_jsonb(event_row), 'changed', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.watchdog_update_pressure_with_event(
  p_entry_id text,
  p_scene text,
  p_name text,
  p_pressure_mpa double precision,
  p_reported_at bigint,
  p_duration_min integer,
  p_exit_at bigint,
  p_consumption_actual_lpm double precision DEFAULT NULL,
  p_incident_id text DEFAULT NULL,
  p_activity_at bigint DEFAULT NULL,
  p_event jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  entry_row public.entries;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
BEGIN
  INSERT INTO public.pressure_samples (entry_id, scene, name, pressure_mpa, reported_at)
  VALUES (p_entry_id, p_scene, p_name, p_pressure_mpa, p_reported_at);

  UPDATE public.entries
  SET name = COALESCE(NULLIF(p_name, ''), name), pressure_mpa = p_pressure_mpa,
      duration_min = p_duration_min, exit_at = p_exit_at,
      consumption_actual_lpm = COALESCE(p_consumption_actual_lpm, consumption_actual_lpm)
  WHERE id = p_entry_id
  RETURNING * INTO entry_row;

  UPDATE public.incidents
  SET last_activity_at = GREATEST(last_activity_at, COALESCE(p_activity_at, last_activity_at))
  WHERE id = p_incident_id AND status = 'active';

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, p_event->>'incidentId', p_event->>'type',
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, p_reported_at),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id, CASE WHEN p_event ? 'payload' THEN (p_event->'payload')::text ELSE NULL END,
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('entry', to_jsonb(entry_row), 'event', to_jsonb(event_row));
END;
$$;

CREATE OR REPLACE FUNCTION public.watchdog_create_incident_with_event(
  p_id text,
  p_unit_id text DEFAULT NULL,
  p_created_at bigint DEFAULT NULL,
  p_created_by text DEFAULT NULL,
  p_event jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  created_at_value bigint := COALESCE(p_created_at, EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000);
  number_base text;
  candidate text;
  sequence_no integer := 1;
  incident_row public.incidents;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
  recent_row public.incidents;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext(COALESCE(p_unit_id, '')));

  SELECT * INTO recent_row FROM public.incidents i
  WHERE i.status = 'active' AND i.created_at >= created_at_value - 60000
    AND (p_unit_id IS NULL OR i.unit_id = p_unit_id)
    AND EXISTS (SELECT 1 FROM public.incident_events e WHERE e.incident_id = i.id AND e.type = 'incident_created')
  ORDER BY i.created_at DESC LIMIT 1;
  IF FOUND THEN
    RETURN jsonb_build_object('cooldown', true, 'recent', to_jsonb(recent_row));
  END IF;

  number_base := to_char(to_timestamp(created_at_value / 1000.0), 'YYYY"年"FMMM"月"FMDD"日"HH24"时"MI"分"');
  LOOP
    candidate := number_base || sequence_no::text || '#警情';
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.incidents WHERE number = candidate);
    sequence_no := sequence_no + 1;
  END LOOP;

  INSERT INTO public.incidents (id, unit_id, number, status, created_at, last_activity_at, created_by)
  VALUES (p_id, p_unit_id, candidate, 'active', created_at_value, created_at_value, p_created_by)
  RETURNING * INTO incident_row;

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, incident_row.id, COALESCE(p_event->>'type', 'incident_created'),
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, created_at_value),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id, jsonb_build_object('number', incident_row.number),
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('cooldown', false, 'incident', to_jsonb(incident_row), 'event', to_jsonb(event_row));
END;
$$;

CREATE OR REPLACE FUNCTION public.watchdog_update_note_with_event(
  p_id text,
  p_text text DEFAULT NULL,
  p_category text DEFAULT NULL,
  p_incident_id text DEFAULT NULL,
  p_activity_at bigint DEFAULT NULL,
  p_event jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  note_row public.notes;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
BEGIN
  UPDATE public.notes
  SET text = COALESCE(p_text, text), category = COALESCE(p_category, category),
      updated_at = EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000
  WHERE id = p_id
  RETURNING * INTO note_row;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('note', NULL, 'event', NULL, 'changed', false);
  END IF;

  UPDATE public.incidents
  SET last_activity_at = GREATEST(last_activity_at, COALESCE(p_activity_at, last_activity_at))
  WHERE id = p_incident_id AND status = 'active';

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, p_incident_id, p_event->>'type',
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id, CASE WHEN p_event ? 'payload' THEN (p_event->'payload')::text ELSE NULL END,
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('note', to_jsonb(note_row), 'event', to_jsonb(event_row), 'changed', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.watchdog_delete_note_with_event(
  p_id text,
  p_incident_id text,
  p_activity_at bigint DEFAULT NULL,
  p_event jsonb DEFAULT '{}'::jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  deleted_id text;
  event_row public.incident_events;
  event_id text := COALESCE(p_event->>'id', md5(random()::text || clock_timestamp()::text));
  event_op_id text := NULLIF(p_event->>'clientOpId', '');
BEGIN
  DELETE FROM public.notes WHERE id = p_id AND scene = p_incident_id RETURNING id INTO deleted_id;
  IF deleted_id IS NULL THEN
    RETURN jsonb_build_object('changed', false, 'event', NULL);
  END IF;

  UPDATE public.incidents
  SET last_activity_at = GREATEST(last_activity_at, COALESCE(p_activity_at, last_activity_at))
  WHERE id = p_incident_id AND status = 'active';

  INSERT INTO public.incident_events (
    id, incident_id, type, occurred_at, recorded_at, actor_device_id, actor_name,
    source, client_op_id, payload, revision_of, voided_at
  ) VALUES (
    event_id, p_incident_id, p_event->>'type',
    COALESCE(NULLIF(p_event->>'occurredAt', '')::bigint, EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000),
    EXTRACT(EPOCH FROM clock_timestamp())::bigint * 1000,
    p_event->>'actorDeviceId', p_event->>'actorName', COALESCE(p_event->>'source', 'online'),
    event_op_id, CASE WHEN p_event ? 'payload' THEN (p_event->'payload')::text ELSE NULL END,
    p_event->>'revisionOf', NULLIF(p_event->>'voidedAt', '')::bigint
  ) ON CONFLICT (client_op_id) DO NOTHING;

  SELECT * INTO event_row FROM public.incident_events
  WHERE (event_op_id IS NOT NULL AND client_op_id = event_op_id) OR (event_op_id IS NULL AND id = event_id)
  ORDER BY recorded_at DESC LIMIT 1;
  RETURN jsonb_build_object('changed', true, 'event', to_jsonb(event_row));
END;
$$;

REVOKE ALL ON FUNCTION public.watchdog_create_entry_with_event(jsonb, jsonb, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchdog_create_note_with_event(jsonb, jsonb, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchdog_exit_entry_with_event(text, bigint, text, bigint, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchdog_update_pressure_with_event(text, text, text, double precision, bigint, integer, bigint, double precision, text, bigint, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchdog_create_incident_with_event(text, text, bigint, text, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchdog_upsert_force_with_event(jsonb, jsonb, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchdog_delete_force_with_event(text, text, bigint, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchdog_rename_incident_with_event(text, text, integer, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchdog_archive_incident_with_event(text, text, bigint, boolean, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchdog_update_note_with_event(text, text, text, text, bigint, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.watchdog_delete_note_with_event(text, text, bigint, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.watchdog_create_entry_with_event(jsonb, jsonb, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.watchdog_create_note_with_event(jsonb, jsonb, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.watchdog_exit_entry_with_event(text, bigint, text, bigint, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.watchdog_update_pressure_with_event(text, text, text, double precision, bigint, integer, bigint, double precision, text, bigint, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.watchdog_create_incident_with_event(text, text, bigint, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.watchdog_upsert_force_with_event(jsonb, jsonb, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.watchdog_delete_force_with_event(text, text, bigint, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.watchdog_rename_incident_with_event(text, text, integer, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.watchdog_archive_incident_with_event(text, text, bigint, boolean, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.watchdog_update_note_with_event(text, text, text, text, bigint, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.watchdog_delete_note_with_event(text, text, bigint, jsonb) TO service_role;
