CREATE OR REPLACE FUNCTION doom.api_cheat_key(p_key text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  m integer;
  p integer;
  result text;
  _r1 record;
BEGIN

-- One typed letter or digit into Doom's cheat buffer (doom_cheat_key), for
-- the caller's seat, in single player only: in a solo match that is playing.
-- Returns doom_cheat_key's answer: 'none', 'msg:<text>' (the cheat was
-- applied; the text is also put on the player's message line, which the
-- frames draw, as Doom prints it), 'warp:E<e>M<m>' (idclev: the page asks
-- the app for that map), 'music:E<e>M<m>' (idmus) or 'iddt'.
m := NULL; p := NULL;
FOR _r1 IN SELECT mp.map_id AS m, mp.player_thing_id AS p
FROM mp_players mp JOIN mp_match mm ON mm.map_id = mp.map_id
WHERE mp.role_name = doom_caller() AND mm.mode = 'solo' AND mm.state = 'playing'
LOOP m := _r1.m; p := _r1.p; END LOOP;
IF _cs.m IS NULL OR COALESCE(api_cheat_key.p_key, '') !~ '^[A-Za-z0-9]$' THEN
  RETURN 'none';
END IF;
result := doom_cheat_key(_cs.m, _cs.p, api_cheat_key.p_key);
IF _cs.result LIKE 'msg:_%' THEN
  UPDATE player_state SET message = SUBSTRING(_cs.result FROM 5),
         message_tics = COALESCE((SELECT c.value::int FROM doom_constants c WHERE c.name = 'MESSAGE_TICS'), 140)
  WHERE map_id = _cs.m AND player_thing_id = _cs.p;
END IF;
RETURN _cs.result;
END _cs;
$function$;
REVOKE ALL ON FUNCTION doom.api_cheat_key(text) FROM PUBLIC;
