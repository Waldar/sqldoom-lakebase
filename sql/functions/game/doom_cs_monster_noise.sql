CREATE OR REPLACE FUNCTION doom.doom_cs_monster_noise(p_map_id integer)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
<<_cs>>
BEGIN

WITH RECURSIVE
noise_origin AS (
  SELECT ps.sector_id
  FROM player_state ps
  JOIN player_weapons pw ON pw.map_id = ps.map_id
   AND pw.player_thing_id = ps.player_thing_id
  WHERE ps.map_id = doom_cs_monster_noise.p_map_id::int
    AND ps.alive AND pw.fired_this_tick AND ps.sector_id IS NOT NULL
),
sound_edges AS MATERIALIZED (
  SELECT ld.fsec AS a, ld.bsec AS b,
         CASE WHEN (ld.flags & 64) <> 0 THEN 1 ELSE 0 END AS block
  FROM linedef_geom ld
  JOIN sectors sf ON sf.map_id = ld.map_id AND sf.id = ld.fsec
  JOIN sectors sb ON sb.map_id = ld.map_id AND sb.id = ld.bsec
  WHERE ld.map_id = doom_cs_monster_noise.p_map_id::int
    AND LEAST(sf.ceil_height, sb.ceil_height)
      - GREATEST(sf.floor_height, sb.floor_height) > 0
  UNION ALL
  SELECT ld.bsec, ld.fsec,
         CASE WHEN (ld.flags & 64) <> 0 THEN 1 ELSE 0 END
  FROM linedef_geom ld
  JOIN sectors sf ON sf.map_id = ld.map_id AND sf.id = ld.fsec
  JOIN sectors sb ON sb.map_id = ld.map_id AND sb.id = ld.bsec
  WHERE ld.map_id = doom_cs_monster_noise.p_map_id::int
    AND LEAST(sf.ceil_height, sb.ceil_height)
      - GREATEST(sf.floor_height, sb.floor_height) > 0
),
flood AS (
  SELECT sector_id, 0 AS block FROM noise_origin
  UNION
  SELECT e.b, f.block + e.block
  FROM flood f JOIN sound_edges e ON e.a = f.sector_id
  WHERE f.block + e.block <= 1
)
-- A_Look with a soundtarget (2026-11-24): a monster placed deaf (MTF_AMBUSH,
-- flag 8) only notes the noise (heard) and wakes when it sees the player, in
-- any direction (doom_cs_monster_think); the others wake now, with their
-- reaction time before the first shot (8 chases, none on Nightmare). Until
-- then the noise woke deaf monsters too.
UPDATE monster_ai ai
SET state = CASE WHEN (t.flags & 8) <> 0 THEN ai.state ELSE 'see' END,
    seq_index = CASE WHEN (t.flags & 8) <> 0 THEN ai.seq_index ELSE 0 END,
    state_tics = CASE WHEN (t.flags & 8) <> 0 THEN ai.state_tics ELSE 0 END,
    heard = heard OR (t.flags & 8) <> 0,
    attack_cooldown = CASE WHEN (t.flags & 8) <> 0 THEN ai.attack_cooldown
      WHEN EXISTS (SELECT 1 FROM game_tic_commands g WHERE g.map_id = ai.map_id AND g.skill = 4) THEN 0
      ELSE 8 * COALESCE((SELECT f.tics FROM thing_ai_frames f WHERE f.thing_type = t.type
                         AND f.state = 'see' AND f.seq_index = 0), 3)
             / COALESCE((SELECT mc.calls_per_frame FROM monster_chase_defs mc
                         WHERE mc.thing_type = t.type), 2) END
FROM things t, render_things rt, flood fl
WHERE ai.map_id = doom_cs_monster_noise.p_map_id::int
  AND t.map_id = ai.map_id AND t.id = ai.thing_id
  AND rt.map_id = ai.map_id AND rt.thing_id = ai.thing_id
  AND ai.state = 'stand' AND NOT ai.heard
  AND NOT EXISTS (SELECT 1 FROM thing_combat_defs cd
                  WHERE cd.thing_type = t.type AND cd.explodes)
  AND COALESCE(ai.sector_id, rt.sector_id) = fl.sector_id;
RETURN;
END _cs;
$function$;
