CREATE OR REPLACE FUNCTION doom.doom_cheat(p_map_id integer, p_player_thing_id integer, p_code text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  message text;
  code text;
  ignored integer;
  _r1 record;
  _r2 record;
  _r3 record;
BEGIN

-- Apply one typed cheat code and return the message Doom prints for it.
--
-- (p_local.h): INVULNTICS 30 s, INVISTICS and IRONTICS 60 s, INFRATICS 120 s.
message := '';
code := UPPER(doom_cheat.p_code::text);

IF _cs.code = 'IDDQD' THEN
  UPDATE player_state SET god_mode = NOT god_mode
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int;
  FOR _r1 IN SELECT CASE WHEN god_mode THEN 'Degreelessness Mode ON'
              ELSE 'Degreelessness Mode OFF' END AS m
  FROM player_state
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int
LOOP message := _r1.m; END LOOP;
END IF;
-- IDSPISPOPD is Doom 1's spelling, IDCLIP Doom 2's. Both are accepted.
IF _cs.code = 'IDCLIP' OR _cs.code = 'IDSPISPOPD' THEN
  UPDATE player_state SET noclip = NOT noclip
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int;
  FOR _r2 IN SELECT CASE WHEN noclip THEN 'No Clipping Mode ON'
              ELSE 'No Clipping Mode OFF' END AS m
  FROM player_state
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int
LOOP message := _r2.m; END LOOP;
END IF;
IF _cs.code = 'IDFA' OR _cs.code = 'IDKFA' THEN
  -- The arsenal itself is the same one the menu cheat grants.
  ignored := doom_cheat_arsenal(doom_cheat.p_map_id, doom_cheat.p_player_thing_id);
  -- ST_Responder: idfa_armor 200 of idfa_armor_class 2 (blue), set, not
  -- added; idkfa the same (2026-11-21: both left the armor as it was)
  UPDATE player_state SET armor=200, armor_class=2
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int;
  message := 'Ammo (no keys) Added';
END IF;
IF _cs.code = 'IDKFA' THEN
  UPDATE player_state SET key_red=TRUE, key_blue=TRUE, key_yellow=TRUE
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int;
  message := 'Very Happy Ammo Added';
END IF;
IF _cs.code = 'IDBEHOLDV' THEN
  UPDATE player_state SET invuln_tics=1050
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int;
  message := 'Invulnerability';
END IF;
IF _cs.code = 'IDBEHOLDS' THEN
  UPDATE player_state SET berserk=TRUE, health=GREATEST(health,100)
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int;
  message := 'Berserk';
END IF;
IF _cs.code = 'IDBEHOLDI' THEN
  UPDATE player_state SET invis_tics=2100
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int;
  message := 'Partial Invisibility';
END IF;
IF _cs.code = 'IDBEHOLDR' THEN
  UPDATE player_state SET radsuit_tics=2100
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int;
  message := 'Radiation Suit';
END IF;
IF _cs.code = 'IDBEHOLDA' THEN
  UPDATE player_state SET power_map=TRUE
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int;
  message := 'Computer Area Map';
END IF;
IF _cs.code = 'IDBEHOLDL' THEN
  UPDATE player_state SET light_amp_tics=4200
  WHERE map_id=doom_cheat.p_map_id::int AND player_thing_id=doom_cheat.p_player_thing_id::int;
  message := 'Light Amplification Visor';
END IF;
IF _cs.code = 'IDCHOPPERS' THEN
  INSERT INTO player_weapon_owned (map_id, player_thing_id, weapon_id)
  VALUES (doom_cheat.p_map_id::int, doom_cheat.p_player_thing_id::int, 8)
  ON CONFLICT DO NOTHING;
  message := '... doesn''t suck - GM';
END IF;
IF _cs.code = 'IDMYPOS' THEN
  -- Vanilla prints these as raw fixed-point hex, which is unreadable; map
  -- units rounded to whole numbers say the same thing.
  FOR _r3 IN SELECT 'ang=' || ROUND(t.angle)::int::text
      || '; x,y=(' || ROUND(t.x)::int::text
      || ',' || ROUND(t.y)::int::text || ')' AS m
  FROM things t
  WHERE t.map_id=doom_cheat.p_map_id::int AND t.id=doom_cheat.p_player_thing_id::int
LOOP message := _r3.m; END LOOP;
END IF;
RETURN _cs.message;
END _cs;
$function$;
