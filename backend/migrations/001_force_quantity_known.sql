-- Existing zeroes retain their historical meaning. New clients explicitly mark
-- missing quantities unknown while legacy clients keep their numeric contract.
ALTER TABLE incident_forces
  ADD COLUMN vehicle_count_known BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN personnel_count_known BOOLEAN NOT NULL DEFAULT TRUE;
