-- 国内 OTA 公开对象桶。
-- Bucket 只允许匿名读取已知公开对象；CI 使用独立凭据写入，不把后端 service_role 放进 GitHub。

DO $$
DECLARE
  bucket_is_public boolean;
BEGIN
  SELECT b."public"
    INTO bucket_is_public
    FROM storage.buckets AS b
   WHERE b.id = 'watchdog-ota';

  IF NOT FOUND THEN
    INSERT INTO storage.buckets (
      id, name, "public", file_size_limit, allowed_mime_types
    ) VALUES (
      'watchdog-ota', 'watchdog-ota', true, 167772160,
      ARRAY['application/json', 'application/json; charset=utf-8',
            'application/vnd.android.package-archive']::text[]
    );
  ELSIF bucket_is_public IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'watchdog-ota bucket exists but is not public; review manually';
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
      FROM pg_policies
     WHERE schemaname = 'storage'
       AND tablename = 'objects'
       AND policyname = 'watchdog_ota_public_read'
  ) THEN
    CREATE POLICY watchdog_ota_public_read
      ON storage.objects
      FOR SELECT
      TO anon, authenticated
      USING (bucket_id = 'watchdog-ota');
  END IF;
END $$;
