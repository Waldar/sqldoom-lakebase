CREATE OR REPLACE FUNCTION doom.doom_cs_monsters(p_map_id integer, p_player_thing_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
DECLARE
  pre bigint;
  plan bigint;
  stepped boolean;
  respawning boolean;
BEGIN

-- Only the noise bit of the plan is read before think: ask for it alone.
pre := CASE WHEN EXISTS (SELECT 1 FROM player_weapons pw WHERE pw.map_id=doom_cs_monsters.p_map_id
                         AND pw.fired_this_tick) THEN 1 ELSE 0 END;
PERFORM doom_cs_monster_retarget(doom_cs_monsters.p_map_id,doom_cs_monsters.p_player_thing_id);
IF (_cs.pre & 1) <> 0 THEN PERFORM doom_cs_monster_noise(doom_cs_monsters.p_map_id); END IF;
PERFORM doom_cs_monster_think(doom_cs_monsters.p_map_id,doom_cs_monsters.p_player_thing_id);

-- Re-planned: every bit below is a question about the state the think stage
-- has just written.
plan := doom_cs_monster_plan(doom_cs_monsters.p_map_id);

-- Last tic's staging is cleared whether or not anyone steps this tic, or the
-- move stage would replay it.
DELETE FROM monster_steps WHERE map_id=doom_cs_monsters.p_map_id;
stepped := false;
IF (_cs.plan & 2) <> 0 THEN stepped := doom_cs_monster_step(doom_cs_monsters.p_map_id,doom_cs_monsters.p_player_thing_id); END IF;
IF _cs.stepped THEN PERFORM doom_cs_monster_move(doom_cs_monsters.p_map_id,doom_cs_monsters.p_player_thing_id); END IF;

IF (_cs.plan & 4) <> 0 THEN PERFORM doom_cs_monster_float(doom_cs_monsters.p_map_id,doom_cs_monsters.p_player_thing_id); END IF;
IF (_cs.plan & 8) <> 0 THEN PERFORM doom_cs_monster_chase(doom_cs_monsters.p_map_id,doom_cs_monsters.p_player_thing_id); END IF;
IF (_cs.plan & 16) <> 0 THEN PERFORM doom_cs_monster_attack(doom_cs_monsters.p_map_id,doom_cs_monsters.p_player_thing_id); END IF;
IF (_cs.plan & 32) <> 0 THEN PERFORM doom_cs_monster_barrel(doom_cs_monsters.p_map_id); END IF;
IF (_cs.plan & 64) <> 0 THEN PERFORM doom_cs_monster_blast(doom_cs_monsters.p_map_id); END IF;

respawning := doom_cs_monster_deaths(doom_cs_monsters.p_map_id,doom_cs_monsters.p_player_thing_id);
IF _cs.respawning THEN PERFORM doom_cs_monster_respawn(doom_cs_monsters.p_map_id,doom_cs_monsters.p_player_thing_id); END IF;
RETURN;
END _cs;
$function$;
