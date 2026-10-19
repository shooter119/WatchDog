-- Persist revocation even if a member is re-enabled before their next HTTP request.
CREATE FUNCTION revoke_changed_member_admin_sessions() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status IS DISTINCT FROM OLD.status OR NEW.review_status IS DISTINCT FROM OLD.review_status
    OR NEW.role IS DISTINCT FROM OLD.role OR NEW.unit_id IS DISTINCT FROM OLD.unit_id THEN
    UPDATE admin_sessions SET revoked_at=(extract(epoch FROM clock_timestamp()) * 1000)::bigint
      WHERE member_id=NEW.id AND revoked_at IS NULL;
    UPDATE admin_challenges SET state='cancelled' WHERE member_id=NEW.id AND state='confirmed';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER member_admin_revocation AFTER UPDATE ON unit_members
  FOR EACH ROW EXECUTE FUNCTION revoke_changed_member_admin_sessions();
