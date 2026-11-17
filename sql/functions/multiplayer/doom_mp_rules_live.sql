CREATE OR REPLACE FUNCTION doom.doom_mp_rules_live()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE r mp_rules%ROWTYPE;
BEGIN
  SELECT x.* INTO r FROM mp_rules x JOIN mp_match m ON m.mode = x.mode LIMIT 1;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;
  UPDATE mp_match SET respawn_monsters = r.monster_respawn, altdeath = r.item_respawn,
                      weapons_stay = r.weapons_stay, death_restart = r.death_restart AND r.mode = 'solo';
  UPDATE doom_constants SET value = r.item_respawn_s * 35 WHERE name = 'ITEM_RESPAWN_TICS' AND value <> r.item_respawn_s * 35;
  UPDATE doom_constants SET value = r.monster_respawn_s * 35 WHERE name = 'MONSTER_RESPAWN_TICS' AND value <> r.monster_respawn_s * 35;
  RETURN 1;
END $function$;
