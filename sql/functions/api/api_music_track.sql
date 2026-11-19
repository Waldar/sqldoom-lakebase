CREATE OR REPLACE FUNCTION doom.api_music_track(p_map text)
 RETURNS TABLE(name text, audio_data bytea, audio_format text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
AS $function$
-- One map's music track by the map's name (E1M3), for idmus (api_cheat_key
-- answers 'music:E1M3'): the page plays it until the next map change, whose
-- own track api_stage_music then gives, as Doom goes back to the level's
-- music at the next level. Only for a caller with a seat.
  SELECT ma.name::text, ma.audio_data, ma.audio_format
  FROM maps mx
  JOIN map_music mm ON mm.map_id = mx.map_id
  JOIN music_assets ma ON ma.name = mm.music_name
  WHERE mx.name = api_music_track.p_map
    AND EXISTS (SELECT 1 FROM mp_players mp WHERE mp.role_name = doom_caller());
$function$;
REVOKE ALL ON FUNCTION doom.api_music_track(text) FROM PUBLIC;
