CREATE OR REPLACE FUNCTION public.prepare_media_delete_v1(p_request jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = pg_catalog, public AS $intent$
DECLARE
  original jsonb;
  prior public.media_delete_operations_v1%ROWTYPE;
  op uuid;
  target uuid;
  physical_key text;
BEGIN
  IF jsonb_typeof(p_request) <> 'object' OR
     (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_request) k) IS DISTINCT FROM
     ARRAY['expectedKey','file','mediaId','operationId','root','version'] OR
     p_request->'version' <> '1'::jsonb OR
     jsonb_typeof(p_request->'operationId') <> 'string' OR
     jsonb_typeof(p_request->'mediaId') <> 'string' OR
     (p_request->>'operationId') !~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' OR
     (p_request->>'mediaId') !~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' OR
     jsonb_typeof(p_request->'expectedKey') <> 'string' OR
     jsonb_typeof(p_request->'root') <> 'object' OR jsonb_typeof(p_request->'file') <> 'object'
  THEN RAISE EXCEPTION 'unsupported deletion intent request'; END IF;
  IF (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_request->'root') k) IS DISTINCT FROM ARRAY['device','inode','path'] OR
     (SELECT array_agg(k ORDER BY k) FROM jsonb_object_keys(p_request->'file') k) IS DISTINCT FROM
       ARRAY['bytes','device','inode','links','observedAt','sha256'] OR
     jsonb_typeof(p_request->'root'->'path') <> 'string' OR
     length(p_request->'root'->>'path') NOT BETWEEN 4 AND 4096 OR
     substring(p_request->'root'->>'path',1,1) !~ '^[A-Z]$' OR
     substring(p_request->'root'->>'path',2,2) <> ':' || chr(92) OR
     strpos(p_request->'root'->>'path','/') > 0 OR
     substring(p_request->'root'->>'path',3) ~ '[:<>"|?*[:cntrl:]]' OR
     EXISTS (SELECT FROM unnest(string_to_array(substring(p_request->'root'->>'path',4),chr(92))) s
       WHERE s IN ('','.','..') OR s ~ '[. ]$' OR s ~* '^(con|prn|aux|nul|com[1-9¹²³]|lpt[1-9¹²³])([.]|$)') OR
     jsonb_typeof(p_request->'file'->'bytes') <> 'number' OR
     (p_request->'file'->>'bytes') !~ '^(0|[1-9][0-9]*)$' OR
     (p_request->'file'->>'bytes')::numeric NOT BETWEEN 0 AND 67108864 OR
     p_request->'file'->'links' <> '1'::jsonb OR
     jsonb_typeof(p_request->'file'->'sha256') <> 'string' OR
     (p_request->'file'->>'sha256') !~ '^[0-9a-f]{64}$' OR
     jsonb_typeof(p_request->'file'->'observedAt') <> 'string' OR
     (p_request->'file'->>'observedAt') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[.][0-9]{3}Z$' OR
     to_char((p_request->'file'->>'observedAt')::timestamptz AT TIME ZONE 'UTC',
       'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') <> p_request->'file'->>'observedAt' OR
     p_request->'root'->>'device' IS DISTINCT FROM p_request->'file'->>'device' OR
     EXISTS (SELECT FROM (VALUES (p_request->'root'->'device'),(p_request->'root'->'inode'),
       (p_request->'file'->'device'),(p_request->'file'->'inode')) v(n)
       WHERE jsonb_typeof(n) <> 'string' OR (n #>> '{}') !~ '^(0|[1-9][0-9]{0,19})$'
         OR (n #>> '{}')::numeric > 18446744073709551615) OR
     p_request->'root'->>'inode' = '0' OR p_request->'file'->>'inode' = '0' OR
     (p_request->'root'->>'device')::numeric > 4294967295
  THEN RAISE EXCEPTION 'unsupported deletion intent observation'; END IF;
  op := (p_request->>'operationId')::uuid;
  target := (p_request->>'mediaId')::uuid;
  physical_key := p_request->>'expectedKey';
  IF length(physical_key) NOT BETWEEN 1 AND 4096 OR physical_key !~ '^[ -~]+$' OR
     physical_key ~ '[\\:<>"|?*]' OR physical_key LIKE '/%' OR
     EXISTS (SELECT FROM unnest(string_to_array(physical_key,'/')) s
       WHERE s IN ('','.','..') OR s ~ '[. ]$' OR s ~* '^(con|prn|aux|nul|com[1-9]|lpt[1-9])([.]|$)')
  THEN RAISE EXCEPTION 'unsafe deletion intent key'; END IF;
  -- Serialize capture with every media table writer for this transaction only.
  -- This lock is NOT a durable address reservation after commit.
  LOCK TABLE public.media_files IN SHARE ROW EXCLUSIVE MODE;
  IF (SELECT jsonb_object_agg(a.attname,t.typname) FROM pg_attribute a
      JOIN pg_type t ON t.oid=a.atttypid WHERE a.attrelid='public.media_files'::regclass
      AND a.attnum > 0 AND NOT a.attisdropped) IS DISTINCT FROM
    '{"id":"uuid","filename":"varchar","original_name":"varchar","path":"varchar","mime_type":"varchar","size":"int4","dataset":"varchar","inserted_at":"timestamp","updated_at":"timestamp","workspace_id":"uuid","project_id":"uuid","dataset_id":"uuid","object_key":"varchar","sha1":"text","source_id":"text"}'::jsonb
  THEN RAISE EXCEPTION 'unsupported media row schema'; END IF;
  SELECT * INTO prior FROM public.media_delete_operations_v1 WHERE operation_id = op;
  SELECT to_jsonb(m) INTO original FROM public.media_files m WHERE id = target FOR UPDATE;
  IF FOUND THEN
    IF jsonb_typeof(original->'dataset') IS DISTINCT FROM 'string' OR
       length(original->>'dataset') NOT BETWEEN 1 AND 256 OR original->>'dataset' ~ '[[:cntrl:]]' OR
       jsonb_typeof(original->'path') IS DISTINCT FROM 'string' OR
       length(original->>'path') NOT BETWEEN 1 AND 4096 OR original->>'path' ~ '[[:cntrl:]]'
    THEN RAISE EXCEPTION 'unsupported media row ownership'; END IF;
    IF coalesce(original->>'object_key', original->>'path') IS DISTINCT FROM physical_key OR
       (original->>'size')::bigint IS DISTINCT FROM (p_request->'file'->>'bytes')::bigint
    THEN RAISE EXCEPTION 'media row differs from supplied observation'; END IF;
    IF EXISTS (SELECT FROM public.media_files m WHERE id <> target AND
      lower(coalesce(m.object_key,m.path) COLLATE "C") = lower(physical_key COLLATE "C"))
    THEN RAISE EXCEPTION 'conflicting physical claimant'; END IF;
  END IF;
  IF prior.operation_id IS NOT NULL THEN
    IF prior.request IS DISTINCT FROM p_request OR prior.media_id <> target OR
       (original IS NOT NULL AND prior.raw_row IS DISTINCT FROM original)
    THEN RAISE EXCEPTION 'conflicting deletion intent retry'; END IF;
  ELSE
    IF original IS NULL THEN RAISE EXCEPTION 'media row not found; cannot manufacture intent'; END IF;
    INSERT INTO public.media_delete_operations_v1(operation_id,media_id,state,request,raw_row)
      VALUES(op,target,'prepared',p_request,original) RETURNING * INTO prior;
  END IF;
  RETURN jsonb_build_object('version',1,'state',prior.state,'operationId',prior.operation_id,
    'mediaId',prior.media_id,'request',prior.request,'rawRow',prior.raw_row,
    'preparedAt',to_char(prior.prepared_at AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'rowStillPresent',original IS NOT NULL);
END;
$intent$;
