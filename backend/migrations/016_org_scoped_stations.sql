-- 预设消防站归属到组织。不在迁移里写真实单位名称：
-- 只有一个单位时，把尚未归属的旧站挂到该单位；多单位库保持未归属，由私有种子按站名认领。

ALTER TABLE stations ADD COLUMN IF NOT EXISTS unit_id TEXT REFERENCES units(id);

DO $$
BEGIN
  IF (SELECT COUNT(*) FROM units) = 1 THEN
    UPDATE stations
    SET unit_id = (SELECT id FROM units)
    WHERE unit_id IS NULL;
  END IF;
END $$;

ALTER TABLE stations DROP CONSTRAINT IF EXISTS stations_name_key;
ALTER TABLE stations DROP CONSTRAINT IF EXISTS stations_normalized_name_key;

CREATE UNIQUE INDEX IF NOT EXISTS stations_unit_normalized_uidx ON stations (unit_id, normalized_name);
CREATE INDEX IF NOT EXISTS stations_unit_idx ON stations (unit_id);
