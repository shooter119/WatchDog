-- Unit directories are new; prevent aliases from registering the same unit team
-- twice under different display names within one incident.
CREATE UNIQUE INDEX incident_force_unit_identity ON incident_forces(incident_id,unit_station_id) WHERE unit_station_id IS NOT NULL;
