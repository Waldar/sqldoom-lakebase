CREATE OR REPLACE FUNCTION doom.doom_mp_world_flags(p_dm boolean)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE n integer;
BEGIN
  -- Recorded from the solo flags, once per thing (a flipped thing no longer
  -- matches the condition, and ON CONFLICT keeps the first record).
  INSERT INTO mp_dm_things (map_id, thing_id, solo_flags, dm_flags)
  SELECT t.map_id, t.id, t.flags,
         CASE WHEN d.kind::text LIKE 'key\_%' THEN t.flags | 16 ELSE t.flags & ~16 END
  FROM things t JOIN pickup_defs d ON d.thing_type = t.type
  WHERE ((t.flags & 16) <> 0) <> (d.kind::text LIKE 'key\_%')
  ON CONFLICT (map_id, thing_id) DO NOTHING;
  UPDATE things t
  SET flags = CASE WHEN p_dm THEN x.dm_flags ELSE x.solo_flags END
  FROM mp_dm_things x
  WHERE t.map_id = x.map_id AND t.id = x.thing_id
    AND t.flags <> CASE WHEN p_dm THEN x.dm_flags ELSE x.solo_flags END;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $function$;
